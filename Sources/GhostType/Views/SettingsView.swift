import SwiftUI

struct SettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var audioManager = AudioInputManager.shared

    var body: some View {
        Form {
            Section(header: Text("Transcription Mode")) {
                Picker("Mode", selection: $transcriptionManager.currentMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())

                if transcriptionManager.currentMode == .cloud {
                    Text("Cloud mode uses Groq for faster inference.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Local mode uses WhisperKit on-device (Privacy focused).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Microphone Sensitivity")) {
                Slider(value: $audioManager.micSensitivity, in: 0.1...5.0, step: 0.1) {
                    Text("Gain")
                }
                Text("Current Gain: \(String(format: "%.1fx", audioManager.micSensitivity))")
                    .font(.caption)
            }

            Section(header: Text("About")) {
                Text("GhostType v0.1.0")
                Text("Engine: \(transcriptionManager.currentMode == .cloud ? "Groq (LPU)" : "WhisperKit (CoreML)")")
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
