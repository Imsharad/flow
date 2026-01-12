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
    private let accessibilityManager = AccessibilityManager()
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // Chunking State
    private var lastChunkEndSampleIndex: Int64 = 0
    private var lastConfirmedText: String = ""

    // Context State
    private var textContext: String = ""

    // VAD Configuration
    private let silenceThreshold: Float = 0.005 // Matches existing RMS gate
    private let minSilenceDurationSeconds: Double = 0.7
    private var silenceStartSampleIndex: Int64? = nil

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
        lastChunkEndSampleIndex = sessionStartSampleIndex
        silenceStartSampleIndex = nil
        Task { await accumulator.reset() } // Reset accumulator

        // Capture Context
        captureContext()
        
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
    
    private func captureContext() {
        if let context = accessibilityManager.getActiveWindowContext() {
            // Format context for LLM/Whisper
            // e.g. "Previous context: [App: Xcode, Window: DictationEngine.swift] ..."
            // Ideally, we want to inject this as part of the prompt or system prompt if possible.
            // Whisper prompt is usually previous text.
            // But we can "hallucinate" context by prepending it to the prompt.
            // "System: You are dictating in Xcode. File: DictationEngine.swift. Context: "

            self.textContext = "Context: \(context.appName) - \(context.windowTitle). "
            print("🧠 DictationEngine: Captured Context: \(self.textContext)")
        } else {
            self.textContext = ""
        }
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
            
            let finalText = await self.accumulator.getFullText()
            
            DispatchQueue.main.async { [weak self] in
                self?.onFinalText?(finalText)
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
        let currentHead = ringBuffer.totalSamplesWritten
        
        // 1. Detect VAD Cut Point
        // If we detect significant silence, we "commit" the current segment.
        var cutPoint = currentHead
        let isChunking = await checkVADChunking(currentHead: currentHead)
        
        if isChunking {
             // If VAD triggered a chunk, we set the cut point to where silence started (or current head)
             // For simplicity, we use currentHead as the cut point for the chunk.
             // Ideally we'd backtrack to the start of silence, but `silenceStartSampleIndex` handles that logic.
        }

        // 2. Define Audio Segment to Process
        // We process from `lastChunkEndSampleIndex` to `currentHead`.
        // However, if the segment is too long (>30s), we should have already chunked.
        // If not chunked, we still cap at 30s lookback for the sliding window visual,
        // BUT for the "final" chunk commit we want the whole segment since last commit.
        
        // If `isFinal` is true, we force commit everything pending.
        
        let start = lastChunkEndSampleIndex
        let length = currentHead - start
        
        // Safety check: If segment is empty, skip
        guard length > 0 else { return }

        // Snapshot audio
        let segment = ringBuffer.snapshot(from: start, to: currentHead)
        guard !segment.isEmpty else { return }

        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        guard rms > silenceThreshold || isFinal else {
             // Too quiet, and not forcing final.
             // We might still want to emit partial text if we had some before?
             // Actually, if it's silence, we probably don't update partial text.
             return
        }

        // 3. Transcribe
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            return
        }
        
        // Fetch context from accumulator
        let contextTokens = await accumulator.getContext()
        
        // For text prompt, we combine static context + dynamic accumulated context
        // This is a bit of a hack for Whisper, as it expects "previous text".
        // But adding "Context: AppName" at the start might help steer it?
        // Actually, Whisper works best with just previous text.
        // Let's rely on token context for coherence, and use textContext only if tokens are empty (start of session).

        var promptText: String = ""
        if contextTokens.isEmpty && !self.textContext.isEmpty {
            promptText = self.textContext
        } else {
             promptText = await accumulator.getFullText()
        }
        
        let result = await transcriptionManager.transcribe(buffer: buffer, prompt: promptText, promptTokens: contextTokens)
        guard let (text, tokens) = result else { return }
        
        // 4. Update Accumulator & UI
        if isChunking || isFinal {
            // Commit this chunk
            // Use returned tokens if available, otherwise empty
            await accumulator.append(text: text, tokens: tokens ?? [])
            lastChunkEndSampleIndex = currentHead

            // For VAD chunking, we might want to reset the silence tracker?
            // Handled in checkVADChunking or implicitly by moving the window.

            let fullText = await accumulator.getFullText()

            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        } else {
            // Partial Update
            // Combine commited text + current partial
            let committed = await accumulator.getFullText()
            let combined = committed.isEmpty ? text : "\(committed) \(text)"

            self.callbackQueue.async {
                self.onPartialRawText?(combined)
            }
        }
    }

    /// Checks if we should finalize the current chunk based on VAD.
    private func checkVADChunking(currentHead: Int64) async -> Bool {
        // Look at the last N samples to detect silence.
        // If we see >0.7s of silence, returns true.

        let lookbackSamples = Int64(minSilenceDurationSeconds * Double(audioSampleRate))
        let startCheck = max(lastChunkEndSampleIndex, currentHead - lookbackSamples)

        // If we haven't accumulated enough audio since last chunk to even check for silence, return false
        if currentHead - startCheck < lookbackSamples {
            return false
        }

        let silenceSegment = ringBuffer.snapshot(from: startCheck, to: currentHead)
        guard !silenceSegment.isEmpty else { return false }

        let rms = sqrt(silenceSegment.reduce(0) { $0 + $1 * $1 } / Float(silenceSegment.count))

        if rms < silenceThreshold {
            // It is silent now.
            // In a real VAD state machine, we'd track "Speech -> Silence" transition.
            // Here we are polling. If we are silent for the full lookback duration, we can chunk.

            // But we don't want to chunk repeatedly on silence.
            // We only chunk if we have "Speech" content pending.
            // We can approximate this by checking if the *entire* pending segment is silent.
            // If the pending segment has speech but ends in silence, we chunk.

            // Optimization: Let's trust that if we are here, we might have speech.
            // But if `lastChunkEndSampleIndex` was just updated, we don't want to cut again immediately.

             // Simple Logic:
             // If (Current - LastChunk) > 2 seconds AND (Tail is Silent) -> Chunk.

             let minChunkSize = Int64(2.0 * Double(audioSampleRate))
             if (currentHead - lastChunkEndSampleIndex) > minChunkSize {
                 return true
             }
        }

        return false
    }
}
