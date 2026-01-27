import Foundation
import AVFoundation

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
    
    // VAD & Chunking State
    private var lastCommittedSampleIndex: Int64 = 0
    private var currentPromptTokens: [Int]? = nil
    private var silenceStartTime: Date? = nil

    // Config
    private var micSensitivity: Float {
        return UserDefaults.standard.float(forKey: "micSensitivity") == 0 ? 0.005 : UserDefaults.standard.float(forKey: "micSensitivity")
    }

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
        currentPromptTokens = nil
        silenceStartTime = nil
        accumulator.reset()
        
        // Inject Active Window Context
        Task {
            if let context = AccessibilityManager.shared.getActiveWindowContext() {
                print("🧠 DictationEngine: Injecting Context: \"\(context)\"")
                // Encode context to tokens
                self.currentPromptTokens = await transcriptionManager.encode(text: context)
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
        
        // Chunking Strategy:
        // We always look from `lastCommittedSampleIndex` to `end`.
        // If this segment is too long (>28s), we assume we missed a silence and force a commit.
        // If `isFinal` is true, we force commit whatever is left.
        
        let chunkStart = lastCommittedSampleIndex
        let uncommittedSamples = end - chunkStart

        // 1. Safety Check: Empty buffer
        guard uncommittedSamples > 0 else { return }

        // 2. Extract Audio
        let segment = ringBuffer.snapshot(from: chunkStart, to: end)
        guard !segment.isEmpty else { return }
        
        // 3. VAD / Silence Detection (on the last 0.5s or entire segment)
        // We check the last 0.5s for silence to determine if we should commit the PREVIOUS speech.
        // Or rather, if the *current* tail is silent, the speech *before* it is finished.
        
        let tailLength = min(Int(0.5 * Double(audioSampleRate)), segment.count)
        let tailSegment = segment.suffix(tailLength)
        let rms = sqrt(tailSegment.reduce(0) { $0 + $1 * $1 } / Float(tailSegment.count))

        // Logic:
        // If RMS < Threshold:
        //    Increment silence timer.
        //    If Silence > 0.7s AND segment.duration > 1.0s:
        //       COMMIT (Transcribe segment, append to accumulator, advance lastCommittedSampleIndex).
        // Else:
        //    Reset silence timer.
        //    Partial Transcribe (UI update).

        var shouldCommit = isFinal

        if rms < micSensitivity {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if let start = silenceStartTime, Date().timeIntervalSince(start) > 0.7 {
                // Silence threshold met
                // Ensure we have enough audio to be worth committing (>1s)
                if Double(uncommittedSamples) / Double(audioSampleRate) > 1.0 {
                    shouldCommit = true
                }
            }
        } else {
            silenceStartTime = nil
        }

        // Force commit if buffer is getting full (Whisper context limit ~30s)
        if Double(uncommittedSamples) / Double(audioSampleRate) > 28.0 {
            print("⚠️ DictationEngine: Force committing due to length (>28s)")
            shouldCommit = true
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        let processingStart = Date()
        
        guard let result = await transcriptionManager.transcribe(
            buffer: buffer,
            prompt: nil, // Cloud might use text prompt if we had it, but for now we rely on tokens for local
            promptTokens: currentPromptTokens
        ) else {
            // Processing cancelled or failed
            return
        }
        
        let partialText = result.text
        let newTokens = result.tokens

        let processingDuration = Date().timeIntervalSince(processingStart)
        
        // State Update
        if shouldCommit {
            print("✅ DictationEngine: Committing Chunk: \"\(partialText)\"")
            await accumulator.append(text: partialText, tokens: newTokens ?? [])

            lastCommittedSampleIndex = end
            currentPromptTokens = newTokens // Carry over tokens to next chunk
            silenceStartTime = nil

            // UI Update (Full Text)
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText) // Send full text as partial for immediate update
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
        } else {
            // UI Update (Accumulated + Partial)
            let previousText = await accumulator.getFullText()
            let combinedText = previousText.isEmpty ? partialText : previousText + " " + partialText

            self.callbackQueue.async {
                self.onPartialRawText?(combinedText)
                if isFinal {
                    self.onFinalText?(combinedText)
                }
            }
        }
    }
}
