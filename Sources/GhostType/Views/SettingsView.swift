import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @AppStorage("GhostType.SelectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"
    @AppStorage("GhostType.MicSensitivity") private var micSensitivity: Double = 1.0

    let availableModels = [
        "distil-whisper_distil-large-v3",
        "openai_whisper-large-v3-turbo",
        "openai_whisper-large-v3",
        "openai_whisper-base",
        "openai_whisper-small"
    ]

    var body: some View {
        Form {
            Section(header: Text("Model Selection")) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Text("Requires restart to take effect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Microphone")) {
                VStack(alignment: .leading) {
                    Text("Sensitivity: \(String(format: "%.1f", micSensitivity))x")
                    Slider(value: $micSensitivity, in: 0.5...5.0, step: 0.1) {
                        Text("Sensitivity")
                    }
                }
            }

            Section(header: Text("Cloud")) {
                 CloudSettingsView(manager: manager)
            }
        }
        .padding()
        .frame(width: 450, height: 400)
    }
}
