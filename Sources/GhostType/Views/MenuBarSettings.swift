import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    
    // Add Settings Window Access
    @Environment(\.openSettings) var openSettings // Standard macOS 14+ way?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GhostType")
                .font(.headline)
            
            Picker("Mode", selection: $manager.currentMode) {
                Text("Cloud ☁️").tag(TranscriptionMode.cloud)
                Text("Local ⚡️").tag(TranscriptionMode.local)
            }
            .pickerStyle(.segmented)
            
            if manager.currentMode == .cloud {
                CloudSettingsView(manager: manager)
            } else {
                Text("Using on-device WhisperKit model.\nPrivacy prioritized. No internet required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            if let error = manager.lastError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Divider()
            
            Button("Advanced Settings...") {
                 // Trigger AppDelegate to open settings window
                 NSApp.sendAction(#selector(AppDelegate.openSettingsWindow), to: nil, from: nil)
            }

            Button("Quit GhostType") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
