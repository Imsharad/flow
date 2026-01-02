import SwiftUI

struct SettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var audioInputManager = AudioInputManager.shared

    // Local state for model selection if not in manager
    @AppStorage("GhostType.SelectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    var body: some View {
        Form {
            Section(header: Text("Transcription")) {
                Picker("Mode", selection: $transcriptionManager.currentMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if transcriptionManager.currentMode == .local {
                    Picker("Model", selection: $selectedModel) {
                        Text("Distil Large v3 (Recommended)").tag("distil-whisper_distil-large-v3")
                        Text("Large v3 Turbo (Fast)").tag("openai_whisper-large-v3-turbo")
                        Text("Base (Low Memory)").tag("openai_whisper-base")
                    }
                }
            }

            Section(header: Text("Microphone")) {
                HStack {
                    Text("Sensitivity")
                    Slider(value: $audioInputManager.micSensitivity, in: 0.1...5.0, step: 0.1)
                    Text("\(audioInputManager.micSensitivity, specifier: "%.1f")x")
                }
            }

            Section(header: Text("About")) {
                Text("GhostType v0.2.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
