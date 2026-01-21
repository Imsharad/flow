import SwiftUI

struct SettingsView: View {
    @AppStorage("micSensitivity") private var micSensitivity: Double = 0.5
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    // Model options (keys for WhisperKit)
    let models = [
        "distil-whisper_distil-large-v3": "Distil-Large-v3 (Balanced)",
        "openai_whisper-large-v3-turbo": "Turbo (Fastest)",
        "openai_whisper-large-v3": "Large-v3 (High Accuracy)"
    ]

    var body: some View {
        Form {
            Section(header: Text("Microphone")) {
                VStack(alignment: .leading) {
                    Text("Sensitivity Threshold: \(String(format: "%.2f", micSensitivity))")
                    Slider(value: $micSensitivity, in: 0.0...1.0) {
                        Text("Sensitivity")
                    }
                    Text("Adjust to filter out background noise.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Transcription Model")) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(models.keys.sorted(), id: \.self) { key in
                        Text(models[key] ?? key).tag(key)
                    }
                }
                .pickerStyle(MenuPickerStyle())

                Text("Changes require app restart or model reload.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Cloud API")) {
                 // Placeholder for API Key management (currently in MenuBarSettings/APIKeySheet)
                 // We could migrate it here later.
                 Text("API Key managed via Menu Bar > API Key")
                     .font(.caption)
                     .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
