import Foundation
import Accelerate

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
    private let accessibilityManager: AccessibilityManager
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    private var lastChunkEndSampleIndex: Int64 = 0 // Track processed chunks
    private var activeWindowContext: String? // Captured at start of session
    
    // VAD Configuration
    private let silenceThreshold: Float = 0.005
    private let minSilenceDuration: TimeInterval = 0.7 // Increased to 0.7s as per progress.md

    init(
        accessibilityManager: AccessibilityManager = AccessibilityManager(),
        callbackQueue: DispatchQueue = .main
    ) {
        self.accessibilityManager = accessibilityManager
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
         ringBuffer: AudioRingBuffer,
         accessibilityManager: AccessibilityManager = AccessibilityManager()) {
        self.callbackQueue = .main
        self.transcriptionManager = transcriptionManager
        self.accumulator = accumulator
        self.ringBuffer = ringBuffer
        self.accessibilityManager = accessibilityManager
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

        // Capture Window Context
        if let context = accessibilityManager.getActiveWindowContext() {
            activeWindowContext = "Context: App is \(context.appName), Window is \"\(context.windowTitle)\"."
            print("🧠 DictationEngine: \(activeWindowContext!)")
        } else {
            activeWindowContext = nil
        }

        // Reset accumulator
        Task { await accumulator.reset() }
        
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
            
            let fullText = await self.accumulator.getFullText()

            DispatchQueue.main.async { [weak self] in
                // Ensure the UI gets the very last version
                self?.onFinalText?(fullText)
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
        // Calculate effective start.
        // If we have finalized chunks, we start from lastChunkEndSampleIndex.
        // Otherwise, it's the session start.

        // However, if we process a chunk, we update lastChunkEndSampleIndex.
        
        let start = lastChunkEndSampleIndex
        
        // Check if we have enough data (at least 1s or if final)
        if !isFinal && (end - start) < Int64(audioSampleRate) {
            return
        }

        let segment = ringBuffer.snapshot(from: start, to: end)
        guard !segment.isEmpty else { return }

        // 1. Check for Silence / Chunking
        var processRange = 0..<segment.count
        var isChunk = false
        var nextStartIndex = start

        if !isFinal {
            // Try to find a silence boundary to commit a chunk
            if let silence = findFirstSilence(in: segment, sampleRate: audioSampleRate, minDuration: minSilenceDuration, threshold: silenceThreshold) {
                // Found silence! We can commit up to silence.start
                processRange = 0..<silence.start
                isChunk = true

                // We advance our pointer to the END of the silence (or we could just skip the speech part)
                // Let's skip the silence too to avoid processing it next time
                nextStartIndex = start + Int64(silence.end)

                print("✂️ DictationEngine: Chunking at \(String(format: "%.2f", Double(silence.start)/Double(audioSampleRate)))s (Silence: \(Double(silence.end-silence.start)/Double(audioSampleRate))s)")
            } else {
                // No silence found.
                // If the buffer is getting too huge (> 30s), we MUST chunk or we lose data.
                // But let's hope VAD catches it. If > 30s, we might need to force chunk, but that risks cutting words.
                // For now, let the sliding window grow (but Whisper clips at 30s).
                // If segment > 29s, maybe just commit the first 25s?
                // Let's rely on VAD for now as per plan.
            }
        } else {
            // Final pass: process everything remaining
            isChunk = true
            nextStartIndex = end
        }
        
        let audioToTranscribe = Array(segment[processRange])
        
        guard !audioToTranscribe.isEmpty else {
            // Just silence?
            if isChunk {
                lastChunkEndSampleIndex = nextStartIndex
            }
            return
        }

        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: audioToTranscribe, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 2. Get Context from Accumulator
        let contextTokens = await accumulator.getContext()
        
        // 3. Transcribe
        guard let result = await transcriptionManager.transcribe(buffer: buffer, prompt: activeWindowContext, promptTokens: contextTokens) else {
            return
        }
        
        let (text, tokens) = result

        // 4. Update Accumulator / State
        if isChunk {
            await accumulator.append(text: text, tokens: tokens ?? [])
            lastChunkEndSampleIndex = nextStartIndex

            // If we chunked, we might want to trigger another pass immediately if there's remaining audio?
            // But the timer will catch it in 500ms.
        }

        // 5. Construct Display Text
        let accumulated = await accumulator.getFullText()
        let displayText: String
        if isChunk {
             // If we just chunked, the text is fully in accumulator
             displayText = accumulated
        } else {
             // We are provisional, so we show accumulated + current provisional text
             displayText = accumulated + (accumulated.isEmpty ? "" : " ") + text
        }
        
        // Emit result
        self.callbackQueue.async {
            self.onPartialRawText?(displayText)
            if isFinal {
                self.onFinalText?(displayText)
            }
        }
    }

    // Simple silence detector
    private func findFirstSilence(in samples: [Float], sampleRate: Int, minDuration: TimeInterval, threshold: Float) -> (start: Int, end: Int)? {
        let minSamples = Int(minDuration * Double(sampleRate))
        let windowSize = Int(0.1 * Double(sampleRate)) // 100ms
        let step = windowSize / 2

        var silenceStart: Int?

        // Loop through windows
        for i in stride(from: 0, to: samples.count - windowSize, by: step) {
            // Check RMS
            // Manually calc for simplicity or use vDSP
            var sum: Float = 0
            for j in 0..<windowSize {
                let val = samples[i+j]
                sum += val * val
            }
            let rms = sqrt(sum / Float(windowSize))

            if rms < threshold {
                if silenceStart == nil {
                    silenceStart = i
                }
                // Check duration
                if let start = silenceStart, (i + windowSize - start) >= minSamples {
                    // Found valid silence
                    // Backtrack start to capture natural decay? No, simple cut is fine for now.
                    return (start, i + windowSize)
                }
            } else {
                silenceStart = nil
            }
        }

        return nil
    }
}
