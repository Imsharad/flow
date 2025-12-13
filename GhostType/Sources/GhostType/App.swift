import SwiftUI
import AppKit

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
    var statusItem: NSStatusItem?
    var overlayWindowManager: OverlayWindowManager?
    var audioInput: AudioInputManager?
    var vadService: VADService?
    var transcriber: Transcriber?
    var accessibilityManager: AccessibilityManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupServices()
        setupMenuBar()
        setupOverlay()

        // Request permissions and start
        PermissionsManager.requestMicrophoneAccess { granted in
            if granted {
                DispatchQueue.main.async {
                    do {
                        try self.audioInput?.start()
                        print("GhostType started.")
                    } catch {
                        print("Failed to start audio input: \(error)")
                    }
                }
            } else {
                print("Microphone access denied")
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "GhostType")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func setupServices() {
        accessibilityManager = AccessibilityManager()
        transcriber = Transcriber()
        vadService = VADService()
        audioInput = AudioInputManager()

        // Wire up dependencies
        if let audioInput = audioInput, let vadService = vadService, let transcriber = transcriber {
            audioInput.delegate = vadService
            vadService.delegate = transcriber
            vadService.audioDelegate = transcriber
            transcriber.delegate = self
        }
    }

    func setupOverlay() {
        overlayWindowManager = OverlayWindowManager()
        overlayWindowManager?.showWindow()
    }
}

extension AppDelegate: TranscriberDelegate {
    func didTranscribePartial(text: String) {
        DispatchQueue.main.async {
            self.overlayWindowManager?.updateText(text, isFinal: false)
        }
    }

    func didTranscribeFinal(text: String) {
        DispatchQueue.main.async {
            self.overlayWindowManager?.updateText(text, isFinal: true)
            // Inject text
            if let accessibilityManager = self.accessibilityManager {
                accessibilityManager.injectText(text)
            }
        }
    }
}
