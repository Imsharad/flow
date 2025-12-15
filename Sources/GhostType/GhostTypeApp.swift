import SwiftUI
import AppKit

@main
struct GhostTypeApp: App {
    // We use a delegate to handle NSApplication logic (like hiding from Dock)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We don't want a standard WindowGroup for a menu bar app / ghost overlay app
        // But SwiftUI App lifecycle requires at least one Scene.
        // We can use Settings or a hidden WindowGroup.
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusBarItem: NSStatusItem!
    var overlayWindow: OverlayWindow?

    // Services
    let audioManager = AudioInputManager.shared
    let vad = VADService()
    let transcriber = Transcriber()
    let textInjector = TextInjector.shared

    // State
    @Published var isListening = false
    @Published var currentText = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        // Setup Menu Bar
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "GhostType")
        }
        setupMenu()

        // Setup Overlay
        setupOverlay()

        // Wire up services
        setupServices()

        // Start listening (checking permissions first)
        Task {
            if await audioManager.requestPermission() {
                 try? audioManager.startRecording()
            }
        }
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About GhostType", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusBarItem.menu = menu
    }

    func setupOverlay() {
        // Create the SwiftUI view for the pill
        let pillView = GhostPill(isListening: false, text: "")

        // We need to wrap it in a hosting controller/view that updates based on our state
        // Using a functional approach to bind this delegate's state to the view
        let rootView = GhostPillWrapper(delegate: self)

        overlayWindow = OverlayWindow(view: AnyView(rootView))
        overlayWindow?.orderFront(nil)

        // Position it somewhere (e.g. center or near cursor)
        if let pos = AccessibilityManager.shared.getFocusedElementPosition() {
            overlayWindow?.updatePosition(to: pos)
        } else {
            // Default position
            if let screen = NSScreen.main {
                let rect = screen.visibleFrame
                overlayWindow?.updatePosition(to: CGPoint(x: rect.midX - 100, y: rect.midY))
            }
        }
    }

    func setupServices() {
        audioManager.onAudioBuffer = { [weak self] samples in
            self?.vad.process(audioSamples: samples)
            self?.transcriber.processAudio(samples: samples)
        }

        vad.onSpeechStart = { [weak self] in
            DispatchQueue.main.async {
                self?.isListening = true
                SoundManager.shared.playStart()
            }
            self?.transcriber.start()
        }

        vad.onSpeechEnd = { [weak self] in
            DispatchQueue.main.async {
                self?.isListening = false
                SoundManager.shared.playStop()
            }
            self?.transcriber.stop()
        }

        transcriber.onTranscriptionUpdate = { [weak self] text in
            DispatchQueue.main.async {
                self?.currentText = text
                self?.updateOverlay()
            }
        }

        transcriber.onTranscriptionFinal = { [weak self] text in
            DispatchQueue.main.async {
                self?.currentText = "" // Clear pill
                self?.updateOverlay()

                let formatted = TextFormatter.format(text: text)
                self?.textInjector.insertText(formatted)
            }
        }
    }

    func updateOverlay() {
        // The SwiftUI view observes this object, so it should update automatically.
        // We might need to update window position here if we want it to follow the cursor.
        if let pos = AccessibilityManager.shared.getFocusedElementPosition() {
             overlayWindow?.updatePosition(to: pos)
        }
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "GhostType"
        alert.informativeText = "Local Voice Dictation"
        alert.runModal()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

struct GhostPillWrapper: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        GhostPill(isListening: delegate.isListening, text: delegate.currentText)
    }
}
