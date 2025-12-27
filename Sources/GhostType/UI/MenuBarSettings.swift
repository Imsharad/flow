import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GhostType Settings")
                .font(.headline)
                .padding(.bottom, 4)

            // Mode Switcher
            Picker("Mode", selection: $manager.currentMode) {
                ForEach(TranscriptionMode.allCases) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if manager.currentMode == .local {
                Text("Using on-device WhisperKit. Privacy focused, higher battery usage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Using Groq Cloud. Ultra-fast, requires API Key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button("Open Preferences...") {
                NSApp.sendAction(#selector(AppDelegate.openPreferences), to: nil, from: nil)
            }
            .buttonStyle(.link)
            .padding(.leading, -4)

            Button("Quit GhostType") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 260)
    }
}
