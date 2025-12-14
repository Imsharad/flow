import Cocoa
import SwiftUI

@main
class GhostTypeApp: NSObject, NSApplicationDelegate {

    // Core Components
    var audioManager: AudioInputManager!
    var vadService: VADService!
    var transcriber: Transcriber!
    var textInjector: TextInjector!
    var soundManager: SoundManager!

    // UI Components
    var overlayWindow: OverlayWindow!
    var menuBarManager: MenuBarManager!
    var accessibilityManager: AccessibilityManager!

    // State
    var appState = AppState()

    static func main() {
        let app = NSApplication.shared
        let delegate = GhostTypeApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory (hides from Dock, doesn't steal focus on launch)
        NSApplication.shared.setActivationPolicy(.accessory)

        print("GhostType started...")

        // Check Permissions
        Task {
            let micGranted = await PermissionManager.requestMicrophoneAccess()
            if !micGranted {
                print("Microphone permission denied.")
            }

            let axGranted = PermissionManager.checkAccessibilityPermissions()
            if !axGranted {
                print("Accessibility permission denied. Please grant in System Settings.")
            }

            setupComponents()
            setupUI()
            startPipeline()
        }
    }

    func setupComponents() {
        audioManager = AudioInputManager()
        vadService = VADService()
        transcriber = Transcriber()
        textInjector = TextInjector()
        soundManager = SoundManager()
        accessibilityManager = AccessibilityManager()
    }

    func setupUI() {
        // Initialize Overlay Window with GhostPill and AppState
        let ghostPillView = GhostPill(appState: appState)
        overlayWindow = OverlayWindow(view: AnyView(ghostPillView))

        // Initialize Menu Bar
        menuBarManager = MenuBarManager()
    }

    func startPipeline() {
        // Audio -> VAD -> Transcriber -> UI/Injection Pipeline

        audioManager.onAudioBuffer = { [weak self] buffer in
            guard let self = self else { return }
            self.vadService.process(samples: buffer)

            if self.appState.ghostPillState == .listening {
                 self.transcriber.processAudioBatch(buffer)
            }
        }

        vadService.onSpeechStart = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.appState.ghostPillState = .listening
                self.soundManager.playStartSound()

                // Move window to cursor
                if let point = self.accessibilityManager.getFocusedElementPosition() {
                    self.overlayWindow.updatePosition(to: point)
                    // Use orderFront instead of makeKeyAndOrderFront to avoid stealing focus
                    self.overlayWindow.orderFront(nil)
                }
            }
        }

        vadService.onSpeechEnd = { [weak self] in
            DispatchQueue.main.async {
                self?.appState.ghostPillState = .processing
                self?.soundManager.playStopSound()
            }
        }

        transcriber.onTranscriptionResult = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let formattedText = self.formatText(text)
                self.appState.transcribedText = formattedText // Update preview
                print("Transcribed: \(formattedText)")

                // Inject Text
                self.textInjector.inject(text: formattedText)

                // Reset UI after short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.appState.ghostPillState = .idle
                    self.appState.transcribedText = ""
                    self.overlayWindow.orderOut(nil)
                }
            }
        }

        do {
            try audioManager.start()
            print("Listening pipeline active.")
        } catch {
            print("Failed to start audio manager: \(error)")
        }
    }

    func formatText(_ text: String) -> String {
        // Sentence case logic
        guard !text.isEmpty else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
