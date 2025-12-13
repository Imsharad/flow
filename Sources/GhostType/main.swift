import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation

@main
struct GhostTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!

    // Services
    var audioManager: AudioInputManager!
    var vadService: VADService!
    var transcriber: Transcriber!
    var accessibilityManager: AccessibilityManager!
    var textFormatter: TextFormatter!
    var textCorrector: TextCorrector!
    var soundManager: SoundManager!

    // UI
    var overlayWindow: OverlayWindow!
    var onboardingWindow: NSWindow?
    var ghostPillState = GhostPillState()

    // Audio buffering (single-process stepping stone toward IOSurface/XPC)
    private let audioSampleRate: Int = 16000
    private let audioRingBuffer = AudioRingBuffer(capacitySamples: 16000 * 30) // ~30s @ 16kHz
    private var speechStartSampleIndex: Int64?
    private var partialTimer: DispatchSourceTimer?
    private var isPartialTranscriptionInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon initially
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()
        initializeServices()

        checkPermissions()
    }

    func checkPermissions() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibilityGranted = AXIsProcessTrusted()

        if micStatus == .authorized && accessibilityGranted {
            setupUI()
            startAudioPipeline()
        } else {
            showOnboarding()
        }
    }

    func showOnboarding() {
        // Bring app to foreground for onboarding
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let onboardingView = OnboardingView(onComplete: { [weak self] in
            self?.onboardingComplete()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Welcome to GhostType"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)
        self.onboardingWindow = window
    }

    func onboardingComplete() {
        onboardingWindow?.close()
        onboardingWindow = nil

        // Hide dock icon again
        NSApp.setActivationPolicy(.accessory)

        setupUI()
        startAudioPipeline()
    }

    func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "GhostType")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About GhostType", action: #selector(about), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Test VAD Trigger (Mock)", action: #selector(testTrigger), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusBarItem.menu = menu
    }

    func initializeServices() {
        print("Initializing services...")
        audioManager = AudioInputManager()
        vadService = VADService()
        transcriber = Transcriber()
        accessibilityManager = AccessibilityManager()
        textFormatter = TextFormatter()
        textCorrector = TextCorrector()
        soundManager = SoundManager()
    }

    func setupUI() {
        // Create the overlay window off-screen initially
        overlayWindow = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50))

        // Host the SwiftUI view
        let ghostPill = GhostPill(state: ghostPillState)
        overlayWindow.contentView = NSHostingView(rootView: ghostPill)
    }

    func startAudioPipeline() {
        print("Starting audio pipeline...")

        // Link Audio -> VAD
        audioManager.onAudioBuffer = { [weak self] buffer in
            guard let self = self else { return }

            // Convert buffer to [Float] array
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            let floatArray = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            // Persist into ring buffer for pre-roll + later snapshotting.
            self.audioRingBuffer.write(floatArray)

            self.vadService.process(buffer: floatArray)
        }

        // Link VAD -> Logic
        vadService.onSpeechStart = { [weak self] in
            DispatchQueue.main.async {
                self?.handleSpeechStart()
            }
        }

        vadService.onSpeechEnd = { [weak self] in
            DispatchQueue.main.async {
                self?.handleSpeechEnd()
            }
        }

        do {
            try audioManager.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    func handleSpeechStart() {
        print("Speech started")

        // Capture start with pre-roll (PRD suggests ~1.5s minimum buffer/pre-roll).
        let preRollSamples = Int64(Double(audioSampleRate) * 1.5)
        let current = audioRingBuffer.totalSamplesWritten
        speechStartSampleIndex = max(Int64(0), current - preRollSamples)

        soundManager.playStart()
        ghostPillState.isListening = true
        ghostPillState.isProcessing = false
        ghostPillState.isProvisional = false
        ghostPillState.text = "Listening..."

        startPartialTranscriptionTimer()

        // Position UI near cursor
        if let caretRect = accessibilityManager.getFocusedCaretRect() {
            // Place slightly above the caret rect.
            let x = caretRect.minX
            let y = caretRect.maxY + 12
            overlayWindow.setFrameOrigin(CGPoint(x: x, y: y))
        } else if let position = accessibilityManager.getFocusedElementPosition() {
            // Fallback: focused element position (often inaccurate for caret).
            overlayWindow.setFrameOrigin(CGPoint(x: position.x, y: position.y + 20))
        } else if let screen = NSScreen.main {
            // Final fallback: center screen.
            let x = screen.frame.midX - 100
            let y = screen.frame.midY
            overlayWindow.setFrameOrigin(CGPoint(x: x, y: y))
        }
        overlayWindow.orderFront(nil)
    }

    func handleSpeechEnd() {
        print("Speech ended")

        stopPartialTranscriptionTimer()

        let end = audioRingBuffer.totalSamplesWritten
        let minFinalizeSamples = Int64(Double(audioSampleRate) * 1.5)
        var start = speechStartSampleIndex ?? max(Int64(0), end - minFinalizeSamples)

        // Enforce minimum finalize buffer length when possible.
        if end - start < minFinalizeSamples {
            start = max(Int64(0), end - minFinalizeSamples)
        }
        let bufferToProcess = audioRingBuffer.snapshot(from: start, to: end)
        speechStartSampleIndex = nil

        ghostPillState.isListening = false
        ghostPillState.isProcessing = true
        ghostPillState.isProvisional = false
        ghostPillState.text = "Processing..."

        // Simulate processing delay for effect
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            // Get transcription using accumulated buffer
            let rawText = self.transcriber.transcribe(buffer: bufferToProcess)

            // Phase 1 (PRD): show raw (provisional) output immediately.
            DispatchQueue.main.async {
                self.ghostPillState.text = rawText
                self.ghostPillState.isProcessing = false
                self.ghostPillState.isProvisional = true
            }

            // Phase 2/3 (PRD): asynchronously correct, then swap to final.
            let correctedText = self.textCorrector.correct(text: rawText, context: nil)

            DispatchQueue.main.async {
                self.ghostPillState.text = correctedText
                self.ghostPillState.isProvisional = false

                // Phase 4 (PRD): Inject final text.
                self.accessibilityManager.insertText(correctedText)
                self.soundManager.playStop()

                // Hide after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.overlayWindow.orderOut(nil)
                }
            }
        }
    }

    @objc func testTrigger() {
        // Manually trigger VAD for testing
        if ghostPillState.isListening {
            vadService.manualTriggerEnd()
        } else {
            vadService.manualTriggerStart()
        }
    }

    private func startPartialTranscriptionTimer() {
        stopPartialTranscriptionTimer()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.emitPartialTranscription()
        }
        timer.resume()
        partialTimer = timer
    }

    private func stopPartialTranscriptionTimer() {
        partialTimer?.cancel()
        partialTimer = nil
        isPartialTranscriptionInFlight = false
    }

    private func emitPartialTranscription() {
        guard ghostPillState.isListening else { return }
        guard !isPartialTranscriptionInFlight else { return }
        guard let start = speechStartSampleIndex else { return }

        isPartialTranscriptionInFlight = true
        let end = audioRingBuffer.totalSamplesWritten
        let bufferToProcess = audioRingBuffer.snapshot(from: start, to: end)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let rawText = self.transcriber.transcribe(buffer: bufferToProcess)
            DispatchQueue.main.async {
                if self.ghostPillState.isListening {
                    self.ghostPillState.text = rawText
                    self.ghostPillState.isProvisional = true
                }
                self.isPartialTranscriptionInFlight = false
            }
        }
    }

    @objc func about() {
        print("About GhostType")
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

class GhostPillState: ObservableObject {
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var isProvisional = false
    @Published var text = ""
}
