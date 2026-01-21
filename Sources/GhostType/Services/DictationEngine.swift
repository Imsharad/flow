import Foundation

/// Local dictation engine (single-process).
///
/// This mirrors the PRD pipeline boundaries so we can later swap the implementation
/// to an XPC service without changing the UI layer.
@MainActor
final class DictationEngine {
    // Callbacks (invoked on `callbackQueue`).
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onPartialRawText: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?

    private let callbackQueue: DispatchQueue

    private let audioSampleRate: Int = 16000
    nonisolated(unsafe) private let ringBuffer: AudioRingBuffer

    // Services
    private let audioManager = AudioInputManager.shared
    private let accessibilityManager = AccessibilityManager() // Injected
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // Chunking / VAD State
    private var lastCommittedSampleIndex: Int64 = 0
    private var silenceStartTimestamp: Date? = nil
    private let silenceThresholdSeconds: TimeInterval = 0.7 // As per progress.md
    private let rmsSpeechThreshold: Float = 0.005

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        // Initialize Manager (Shared instance logic should ideally be lifted to App)
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 
    }
    
    // For testing injection
    init(
         transcriptionManager: TranscriptionManager,
         accumulator: TranscriptionAccumulator,
         ringBuffer: AudioRingBuffer) {
        self.callbackQueue = .main
        self.transcriptionManager = transcriptionManager
        self.accumulator = accumulator
        self.ringBuffer = ringBuffer
    }

    nonisolated func pushAudio(samples: [Float]) {
        ringBuffer.write(samples)
    }

    func manualTriggerStart() {
        if !isRecording {
             handleSpeechStart()
        }
    }

    func manualTriggerEnd() {
        stop()
    }
    
    func warmUp(completion: (() -> Void)? = nil) {
        // Manager handles warmup state implicitly
        completion?()
    }

    // MARK: - Internals

    private func handleSpeechStart() {
        guard !isRecording else { return }
        
        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        lastCommittedSampleIndex = sessionStartSampleIndex
        silenceStartTimestamp = nil
        await accumulator.reset()

        // Capture Active Window Context
        // Move to background to avoid blocking main thread
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let windowContext = await self.accessibilityManager.getActiveWindowContext()
            await MainActor.run {
                print("🧠 DictationEngine: Context captured: \"\(windowContext)\"")
                self.pendingContext = windowContext
            }
        }
        
        // Start audio capture
        do {
            try audioManager.start()
        } catch {
            print("❌ DictationEngine: Failed to start audio manager: \(error)")
            return
        }
        
        isRecording = true
        
        // Notify UI
        DispatchQueue.main.async { [weak self] in
            self?.onSpeechStart?()
        }
        
        startSlidingWindow()
    }
    
    private var pendingContext: String?

    func stop() {
        guard isRecording else { return }
        isRecording = false
        print("🛑 DictationEngine: Stopping...")
        
        audioManager.stop()
        stopSlidingWindow()
        
        // Final drain
        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            // Force one final transcription of the complete buffer
            await self.processOnePass(forceCommit: true)
            
            // For now, we manually trigger speech end callback after final processing
            // In hybrid mode, implicit "final text" is just the last update.
            
            DispatchQueue.main.async { [weak self] in
                self?.onSpeechEnd?()
            }
        }
    }

    // MARK: - Sliding Window Logic
    
    private func startSlidingWindow() {
        stopSlidingWindow()
        // Main Thread Timer for simplicity, but heavy work is in Task
        slidingWindowTimer = Timer.scheduledTimer(withTimeInterval: windowLoopInterval, repeats: true) { [weak self] _ in
            self?.processWindow()
        }
    }
    
    private func stopSlidingWindow() {
        slidingWindowTimer?.invalidate()
        slidingWindowTimer = nil
    }
    
    private func processWindow() {
        Task(priority: .userInitiated) { [weak self] in
            await self?.processOnePass(forceCommit: false)
        }
    }
    
    /// Processes the current audio window.
    /// - Parameter forceCommit: If true, treats the entire remaining buffer as a segment and commits it.
    private func processOnePass(forceCommit: Bool = false) async {
        let currentEnd = ringBuffer.totalSamplesWritten
        
        // 1. Calculate available "new" audio (since last commit)
        // We always read from lastCommitted to currentEnd for the active transcription
        
        // Safety: Don't read if we have no new data
        if currentEnd <= lastCommittedSampleIndex {
            return
        }
        
        // 2. VAD Check on the RECENT audio (last 0.5s or so) to detect silence
        // We look at the last ~100ms for RMS check, but track duration for triggering commit
        let lookbackSamples = Int64(0.1 * Double(audioSampleRate))
        let vadStart = max(lastCommittedSampleIndex, currentEnd - lookbackSamples)
        let vadSegment = ringBuffer.snapshot(from: vadStart, to: currentEnd)
        
        var isSilence = true
        if !vadSegment.isEmpty {
            let rms = sqrt(vadSegment.reduce(0) { $0 + $1 * $1 } / Float(vadSegment.count))
            if rms > rmsSpeechThreshold {
                isSilence = false
            }
        }
        
        // Update Silence Timer
        if isSilence {
            if silenceStartTimestamp == nil {
                silenceStartTimestamp = Date()
            }
        } else {
            silenceStartTimestamp = nil
        }
        
        // 3. Determine if we should COMMIT the current segment
        // Conditions:
        // A. Force Commit (Stop called)
        // B. Silence > Threshold AND we have substantial uncommitted audio (> 1s)
        
        let uncommittedSamples = currentEnd - lastCommittedSampleIndex
        let uncommittedDuration = Double(uncommittedSamples) / Double(audioSampleRate)

        var shouldCommit = forceCommit
        if !shouldCommit,
           let silenceStart = silenceStartTimestamp,
           Date().timeIntervalSince(silenceStart) > silenceThresholdSeconds,
           uncommittedDuration > 1.0 {
            shouldCommit = true
        }

        // 4. Transcription
        // We always transcribe from lastCommittedSampleIndex.
        // If committing, we transcribe up to (currentEnd - silenceDuration) [approx] or just currentEnd.
        // For simplicity, if we detect silence, we commit up to currentEnd because silence is good for Whisper endpointing.

        let samplesToTranscribe = ringBuffer.snapshot(from: lastCommittedSampleIndex, to: currentEnd)

        guard let buffer = AudioBufferBridge.createBuffer(from: samplesToTranscribe, sampleRate: Double(audioSampleRate)) else {
            return
        }
        
        // Context Injection
        let contextTokens = await accumulator.getContext()
        var fullTextHistory = await accumulator.getFullText()

        // Prepend Window Context to the prompt if this is the start (accumulated text is empty)
        // OR if we explicitly want to condition the model.
        // If we have pendingContext, we can prepend it to fullTextHistory (as a prompt).
        if let ctx = pendingContext {
            if fullTextHistory.isEmpty {
                 fullTextHistory = ctx
            } else {
                 // If we already have text, we probably don't need the window context as strongly,
                 // but we can still keep it at the start.
                 fullTextHistory = ctx + "\n" + fullTextHistory
            }
        }

        // Perform Transcription
        let result = await transcriptionManager.transcribe(
            buffer: buffer,
            prompt: fullTextHistory, // For Cloud/Text-based context
            promptTokens: contextTokens // For Local/Token-based context
        )
        
        guard let (text, tokens) = result else { return }

        // 5. Handle Results
        if shouldCommit {
            print("📦 DictationEngine: Committing segment: \"\(text)\"")
            await accumulator.append(text: text, tokens: tokens ?? [])
            lastCommittedSampleIndex = currentEnd
            silenceStartTimestamp = nil // Reset silence timer after commit
            pendingContext = nil // Clear context after first commit (it's now "history" if we managed tokens correctly, but simplified here)

            // On final commit, we send the updated FULL text
            let updatedFullText = await accumulator.getFullText()
             self.callbackQueue.async {
                 self.onPartialRawText?(updatedFullText)
                 if forceCommit {
                     self.onFinalText?(updatedFullText)
                 }
             }
        } else {
            // Preview Mode
            let accumText = await accumulator.getFullText()
            let previewFullText = accumText + " " + text
            self.callbackQueue.async {
                self.onPartialRawText?(previewFullText)
            }
        }
    }
}
