import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var audioManager = AudioInputManager.shared
    
    // Simplified Menu Bar View - just showing status and quick toggles
    // Full settings are in the separate window
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GhostType")
                    .font(.headline)
                Spacer()
                if manager.isTranscribing {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }
            
            // Mode Toggle
            Picker("Mode", selection: $manager.currentMode) {
                Text("Cloud ☁️").tag(TranscriptionMode.cloud)
                Text("Local ⚡️").tag(TranscriptionMode.local)
            }
            .pickerStyle(.segmented)
            
            // Mic Gain Slider (Quick Access)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mic Gain: \(String(format: "%.1f", audioManager.micSensitivity))x")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: $audioManager.micSensitivity, in: 0.5...3.0)
                    .controlSize(.mini)
            }
            
            if let error = manager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            
            Divider()
            
            Button("Settings...") {
                NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil)
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(width: 220)
    }
}
