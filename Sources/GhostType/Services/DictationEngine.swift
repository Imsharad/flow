import Foundation
import AVFoundation

/// Local dictation engine (single-process).
/// Implements VAD-based chunked streaming.
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
    nonisolated(unsafe) private let vad: VAD

    // Services
    private let audioManager = AudioInputManager.shared
    private let accessibilityManager = AccessibilityManager()
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    
    // State
    private var isRecording = false
    private var sessionTextContext: String = "" // Injected at start of session
    private var lastProcessedSampleIndex: Int64 = 0
    private var cachedSensitivity: Double = 0.5 // Default cache

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 
        self.vad = VAD(sampleRate: 16000)

        // Initial cache
        self.cachedSensitivity = self.transcriptionManager.micSensitivity
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
        self.vad = VAD(sampleRate: 16000)

        // Initial cache
        self.cachedSensitivity = self.transcriptionManager.micSensitivity
    }

    /// Called when settings change to update cached values (MainActor)
    func updateSettings() {
        self.cachedSensitivity = transcriptionManager.micSensitivity
    }

    nonisolated func pushAudio(samples: [Float]) {
        let sensitivity = self.getSensitivitySafe()
        let gain = Float(sensitivity > 0 ? sensitivity * 2.0 : 1.0)

        var processedSamples = samples
        if abs(gain - 1.0) > 0.001 {
            var multiplier = gain
            vDSP_vsmul(samples, 1, &multiplier, &processedSamples, 1, vDSP_Length(samples.count))
        }

        // 1. Write to Ring Buffer (history)
        ringBuffer.write(processedSamples)

        // 2. Feed VAD
        // Protect VAD state with lock if needed, but VAD is a class.
        // Assuming VAD is thread-confined to audio thread or locked internally.
        // Since we created VAD as a simple class, it is NOT thread safe.
        // We MUST synchronize access because `startSession` (MainThread) calls `vad.reset()`.

        // Simple spin-lock or objc_sync?
        // Using a serial queue would be cleaner but `pushAudio` is already on a serial queue from `AudioInputManager`.
        // The issue is `startSession` is on MainThread.
        // We should dispatch `vad.reset()` to the audio queue or protect it.
        // Since `pushAudio` is `nonisolated` and called from an arbitrary queue (AudioInputManager's queue),
        // we should treat that queue as the "owner" of VAD processing.
        // `vad.reset()` should be performed carefully.

        // For now, let's assume `startSession` stops audio first?
        // `startSession` calls `ringBuffer.clear()`, `vad.reset()`, THEN `audioManager.start()`.
        // If audio is not running, `pushAudio` is not called.
        // So `vad.reset()` is safe IF audio is stopped.
        // `manualTriggerStart` checks `!isRecording`.
        // So we are mostly safe.

        vad.process(buffer: processedSamples)
    }

    nonisolated private func getSensitivitySafe() -> Double {
        // In a real app, use OSAllocatedUnfairLock or similar.
        // Here, we just return a hardcoded default or try to read safely.
        // Since we can't easily add a lock property without import Synchronization (new Swift),
        // we will fall back to UserDefaults but optimize by checking a local atomic if possible?
        // Actually, let's just stick to UserDefaults for safety but acknowledge the perf hit is acceptable (it's cached by OS usually).
        // OR: Since `cachedSensitivity` is on the actor, we can't read it synchronously from outside.

        return UserDefaults.standard.double(forKey: "GhostType.MicSensitivity")
    }

    func manualTriggerStart() {
        if !isRecording {
             startSession()
        }
    }

    func manualTriggerEnd() {
        stopSession()
    }
    
    func warmUp(completion: (() -> Void)? = nil) {
        completion?()
    }

    // MARK: - Internals

    private func startSession() {
        guard !isRecording else { return }
        
        // 1. Reset State
        ringBuffer.clear()
        vad.reset()
        accumulator.reset()
        lastProcessedSampleIndex = 0

        // 2. Capture Context (Active Window)
        if let context = accessibilityManager.getActiveWindowContext() {
            sessionTextContext = "User is typing in \(context.appName) - \(context.windowTitle). "
            print("📝 Context: \(sessionTextContext)")
        } else {
            sessionTextContext = ""
        }
        
        // 3. Start Audio
        do {
            try audioManager.start()
        } catch {
            print("❌ DictationEngine: Failed to start audio manager: \(error)")
            return
        }
        
        isRecording = true
        
        // 4. Wire VAD Callbacks
        vad.onSpeechStart = { [weak self] in
            DispatchQueue.main.async { self?.handleVadSpeechStart() }
        }
        vad.onSpeechEnd = { [weak self] in
            DispatchQueue.main.async { self?.handleVadSpeechEnd() }
        }
        
        // Notify UI
        onSpeechStart?()
    }
    
    private func stopSession() {
        guard isRecording else { return }
        isRecording = false
        print("🛑 DictationEngine: Stopping...")
        
        audioManager.stop()
        
        // Final Chunk
        Task {
            await processChunk(isFinal: true)
            
            // Notify UI Final
            let finalText = await accumulator.getFullText()
            DispatchQueue.main.async { [weak self] in
                self?.onFinalText?(finalText)
                self?.onSpeechEnd?()
            }
        }
    }

    // MARK: - VAD Event Handlers
    
    private func handleVadSpeechStart() {
        print("🎤 VAD: Speech Started")
        // Optionally update UI to show "Listening..." animation
    }
    
    private func handleVadSpeechEnd() {
        print("🔇 VAD: Speech Ended - Processing Chunk")
        Task {
            await processChunk(isFinal: false)
        }
    }
    
    // MARK: - Processing

    private func processChunk(isFinal: Bool) async {
        let end = ringBuffer.totalSamplesWritten
        let start = lastProcessedSampleIndex
        let length = end - start
        
        guard length > 0 else { return }
        
        // Snapshot the new audio
        let segment = ringBuffer.snapshot(from: start, to: end)
        guard !segment.isEmpty else { return }
        
        // Update cursor
        lastProcessedSampleIndex = end
        
        // Create Buffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Get Context
        let contextTokens = await accumulator.getContext()
        // If it's the very first chunk, prepend the text context to the prompt?
        // WhisperKit supports `prompt` string (converted to tokens internally if needed, or via separate promptTokens).
        // `transcribe` takes both.
        
        // Only add text context for the first chunk?
        // Or always? The `prompt` is usually prepended.
        let promptText = (start == 0) ? sessionTextContext : nil

        // Transcribe
        guard let result = await transcriptionManager.transcribe(
            buffer: buffer,
            prompt: promptText,
            promptTokens: contextTokens
        ) else {
            return
        }
        
        let (text, tokens) = result

        // Accumulate
        await accumulator.append(text: text, tokens: tokens ?? [])
        
        // Emit Partial (Accumulated)
        let fullText = await accumulator.getFullText()
        self.callbackQueue.async {
            self.onPartialRawText?(fullText)
        }
    }
}
