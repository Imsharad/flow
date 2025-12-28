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
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    private var committedSampleIndex: Int64 = 0 // For VAD Chunking
    private var capturedContext: String? = nil
    
    // Chunking Configuration
    private let maxUncommittedDuration: Double = 25.0 // Force chunk if buffer > 25s
    private let minChunkDuration: Double = 2.0 // Don't chunk tiny fragments

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
        
        // Capture Context (on Main Thread)
        // We use a temporary AccessibilityManager to grab context just once at start
        let ax = AccessibilityManager()
        if let ctx = ax.getActiveWindowContext() {
            self.capturedContext = "Active Window: \(ctx.appName) (\(ctx.bundleID)) - Title: \(ctx.windowTitle)"
            print("🧠 DictationEngine: Context Captured -> \(self.capturedContext ?? "")")
        } else {
            self.capturedContext = nil
        }

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        committedSampleIndex = sessionStartSampleIndex
        accumulator.reset()
        
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
            await self.processOnePass(isFinal: true)
            
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
            await self?.processOnePass(isFinal: false)
        }
    }
    
    private func processOnePass(isFinal: Bool = false) async {
        let end = ringBuffer.totalSamplesWritten
        
        // 1. Determine active window
        // Start from committed index, but cap at 30s max window size (Whisper limit)
        // If uncommitted audio > 30s, we might lose data, so we rely on chunking logic to commit before that happens.
        let effectiveStart = committedSampleIndex
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        if rms < 0.005 && !isFinal { return }
        
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }
        
        // 2. Prepare Context
        var prompt = await accumulator.getFullText()

        // Prepend System Context if available and we are at the start (or just include it generally)
        // For Whisper, "prompt" is usually previous text.
        // If we want to inject "instructions" or "context", it's trickier with standard Whisper.
        // But for Cloud/Groq, we can prepend it.
        // For Local/WhisperKit, it might confuse the model if it's not "previous text".
        // HOWEVER, WhisperKit supports "prompt" as decoding option.
        // Let's try appending it to the accumulator text, or just passing it if accumulator is empty.

        if prompt.isEmpty, let ctx = capturedContext {
            // If we have no previous text, seed the prompt with context.
            // "Active App: VSCode. File: main.swift."
            // This acts as a "style" or "vocabulary" primer.
            // We limit it to avoid eating up token window.
            prompt = ctx
        }
        
        // 3. Transcribe
        guard let result = await transcriptionManager.transcribe(buffer: buffer, prompt: prompt) else { return }
        let (text, tokens) = result
        
        // 4. Chunking Logic
        // Calculate duration of uncommitted audio
        let duration = Double(segment.count) / Double(audioSampleRate)

        var shouldCommit = isFinal

        // If duration is getting too long (>25s), force a commit to avoid 30s limit clipping
        if duration > maxUncommittedDuration {
            shouldCommit = true
        }
        
        // Check for silence/segment break if we want to chunk opportunistically
        // (WhisperKit segments are not returned by TranscriptionManager yet, but we could infer from text stability or length)
        
        if shouldCommit {
            await accumulator.append(text: text, tokens: tokens ?? [])
            committedSampleIndex = end // Advance the commit pointer

            // Notify UI with FULL text
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
        } else {
            // Just update partial view
            let committedText = await accumulator.getFullText()
            let combined = committedText.isEmpty ? text : "\(committedText) \(text)"
            self.callbackQueue.async {
                self.onPartialRawText?(combined)
            }
        }
    }
}

