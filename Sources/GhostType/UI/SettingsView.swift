import SwiftUI

struct SettingsView: View {
    @AppStorage("GhostType.SelectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"
    @AppStorage("GhostType.MicSensitivity") private var micSensitivity: Double = 1.0

    let models = [
        "distil-whisper_distil-large-v3",
        "openai_whisper-large-v3-turbo",
        "openai_whisper-large-v3"
    ]

    var body: some View {
        Form {
            Section(header: Text("Model")) {
                Picker("Whisper Model", selection: $selectedModel) {
                    ForEach(models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(MenuPickerStyle())

                Text("Changes take effect after restart or model reload.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Microphone")) {
                HStack {
                    Text("Sensitivity (Gain)")
                    Slider(value: $micSensitivity, in: 0.5...3.0, step: 0.1)
                    Text(String(format: "%.1fx", micSensitivity))
                        .monospacedDigit()
                }
            }

            Section(header: Text("About")) {
                Text("GhostType v1.0")
                Text("Context-Aware Voice Dictation")
                    .font(.caption)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
