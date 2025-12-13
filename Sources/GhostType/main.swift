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

    // Audio Buffering
    var accumulatedAudio: [Float] = []
    var isAccumulating = false
    let audioLock = NSLock() // Thread safety for audio buffer

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

            // Accumulate if speaking (Protected by Lock)
            self.audioLock.lock()
            if self.isAccumulating {
                self.accumulatedAudio.append(contentsOf: floatArray)
            }
            self.audioLock.unlock()

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

        audioLock.lock()
        isAccumulating = true
        accumulatedAudio.removeAll()
        audioLock.unlock()

        soundManager.playStart()
        ghostPillState.isListening = true
        ghostPillState.isProcessing = false
        ghostPillState.text = "Listening..."

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

        audioLock.lock()
        isAccumulating = false
        let bufferToProcess = accumulatedAudio // Copy buffer
        accumulatedAudio.removeAll()
        audioLock.unlock()

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
