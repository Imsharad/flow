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
    private let vad: VAD
    private let accessibilityManager: AccessibilityManager
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    private var lastSegmentEndIndex: Int64 = 0 // End of last finalized segment
    
    // VAD Tracking
    private var lastVADSampleIndex: Int64 = 0 // End of samples processed by VAD
    private var isFinalizing: Bool = false // Lock to prevent partial updates during finalization

    // Context
    private var activeWindowContext: String = ""

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180)
        self.vad = VAD()
        self.accessibilityManager = AccessibilityManager()

        setupVAD()
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
        self.vad = VAD()
        self.accessibilityManager = AccessibilityManager()

        setupVAD()
    }

    private func setupVAD() {
        vad.onSpeechStart = { [weak self] in
            // VAD Start logic if needed
        }

        vad.onSpeechEnd = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.finalizeCurrentSegment()
            }
        }
    }

    nonisolated func pushAudio(samples: [Float]) {
        ringBuffer.write(samples)
    }

    // New: Update VAD with *only new* samples.
    private func updateVAD() {
        let currentEnd = ringBuffer.totalSamplesWritten
        let newSamplesCount = currentEnd - lastVADSampleIndex

        guard newSamplesCount > 0 else { return }

        // Snapshot only the new part
        let newSegment = ringBuffer.snapshot(from: lastVADSampleIndex, to: currentEnd)
        lastVADSampleIndex = currentEnd

        vad.process(buffer: newSegment, currentTime: Date().timeIntervalSince1970)
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
        completion?()
    }

    // MARK: - Internals

    private func handleSpeechStart() {
        guard !isRecording else { return }
        
        // Capture Context
        if let context = accessibilityManager.getActiveWindowContext() {
            self.activeWindowContext = "I am using the app \(context.appName) in a window titled \(context.windowTitle). "
            print("🧠 DictationEngine: Context Captured: \(self.activeWindowContext)")
        } else {
            self.activeWindowContext = ""
        }

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten
        lastSegmentEndIndex = sessionStartSampleIndex
        lastVADSampleIndex = sessionStartSampleIndex

        vad.reset()
        Task { await accumulator.reset() }
        
        // Start audio capture
        do {
            try audioManager.start()
        } catch {
            print("❌ DictationEngine: Failed to start audio manager: \(error)")
            return
        }
        
        isRecording = true
        
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
            
            // Finalize whatever is left
            await self.finalizeCurrentSegment()
            
            // Get full text
            let fullText = await self.accumulator.getFullText()
            
            DispatchQueue.main.async { [weak self] in
                self?.onFinalText?(fullText)
                self?.onSpeechEnd?()
            }
        }
    }

    // MARK: - Sliding Window Logic
    
    private func startSlidingWindow() {
        stopSlidingWindow()
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
        // Prevent partial updates if we are in the middle of finalizing a segment
        if isFinalizing { return }

        // Update VAD with new samples since last check
        updateVAD()

        // If VAD triggered finalization inside updateVAD, isFinalizing might have flipped to true?
        // No, VAD callbacks run on MainActor (because DictationEngine is MainActor).
        // Wait, `vad.onSpeechEnd` spawns a Task.
        // So `updateVAD` returns synchronously, but the task might be scheduled.
        // But since we are already in an async Task (processWindow), we are safe?
        // Not necessarily. `updateVAD` calls `vad.process` synchronously.
        // If `vad` triggers `onSpeechEnd`, that callback is synchronous.
        // Inside the callback, we spawn a Task to `finalizeCurrentSegment`.
        // That Task will run later.
        
        // So we might proceed here.

        let end = ringBuffer.totalSamplesWritten
        let start = lastSegmentEndIndex
        let segment = ringBuffer.snapshot(from: start, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Check for feedback only
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        guard rms > 0.005 else { return }
        
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }
        
        // Transcribe current pending segment
        // Note: transcriptionManager.transcribe handles cancellation of previous partials
        guard let partialText = await transcriptionManager.transcribe(buffer: buffer, prompt: activeWindowContext) else { return }

        // If finalization started while we were transcribing (race condition), abort update
        if isFinalizing { return }

        let previousText = await accumulator.getFullText()
        let combinedText = previousText + " " + partialText

        self.callbackQueue.async {
            self.onPartialRawText?(combinedText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func finalizeCurrentSegment() async {
        isFinalizing = true
        defer { isFinalizing = false }

        let end = ringBuffer.totalSamplesWritten
        let start = lastSegmentEndIndex
        
        // Snapshot the segment
        let segment = ringBuffer.snapshot(from: start, to: end)
        guard !segment.isEmpty else { return }
        
        // Update pointers immediately to start fresh for next segment
        lastSegmentEndIndex = end

        // Also update VAD pointer if it lagged behind (unlikely if processWindow called updateVAD, but safe)
        if lastVADSampleIndex < end {
            lastVADSampleIndex = end
        }
        
        // Transcribe finalized segment
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }
        
        if let text = await transcriptionManager.transcribe(buffer: buffer, prompt: activeWindowContext) {
             await accumulator.append(text: text, tokens: [])
             // We finalized this text, so the partial display needs to catch up?
             // UI updates on partials, but next partial will include this accumulated text.

             // Optionally trigger a UI update here to show "committed" text state
             let fullText = await accumulator.getFullText()
             self.callbackQueue.async {
                 self.onPartialRawText?(fullText)
             }
        }
    }
}
