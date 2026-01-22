import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GhostType Settings")
                .font(.headline)
                .padding(.bottom, 4)

            Divider()

            // Mode Selector
            HStack {
                Text("Mode:")
                Spacer()
                Picker("", selection: $manager.currentMode) {
                    Text("Cloud (Groq)").tag(TranscriptionMode.cloud)
                    Text("Local (WhisperKit)").tag(TranscriptionMode.local)
                }
                .labelsHidden()
                .frame(width: 140)
            }

            if manager.currentMode == .cloud {
                HStack {
                    Image(systemName: manager.hasStoredKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(manager.hasStoredKey ? .green : .yellow)
                    Text(manager.hasStoredKey ? "API Key Configured" : "Missing API Key")
                        .font(.caption)
                }
            } else {
                Text("Running locally on device")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button("Open Full Settings...") {
                NSApp.sendAction(#selector(SettingsWindowController.showSettings), to: nil, from: nil)
            }
            .buttonStyle(LinkButtonStyle())
        }
        .padding()
        .frame(width: 260)
    }
}

// Singleton Controller to manage the Settings Window
class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var settingsWindow: NSWindow?

    @objc func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Access dependencies via AppDelegate
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let dictationEngine = appDelegate.dictationEngine,
              let transcriptionManager = dictationEngine.transcriptionManager else {
            print("❌ Cannot open settings: Dependencies not ready")
            return
        }

        let settingsView = SettingsView(
            dictationEngine: dictationEngine,
            transcriptionManager: transcriptionManager
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "GhostType Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.isReleasedWhenClosed = false // Keep controller alive, but window?

        // Handle window close to nil out reference
        // Note: Using a delegate or notification would be cleaner, but simple check works.

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Temporarily switch activation policy to regular so window has menu bar and dock icon
        NSApp.setActivationPolicy(.regular)
    }
}
