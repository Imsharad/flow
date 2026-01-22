import SwiftUI

struct SettingsView: View {
    @ObservedObject var dictationEngine: DictationEngine
    @ObservedObject var transcriptionManager: TranscriptionManager

    @AppStorage("micSensitivity") private var micSensitivity: Double = 0.005
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    // Model Options
    let models = [
        "distil-whisper_distil-large-v3",
        "openai_whisper-large-v3-turbo",
        "openai_whisper-base.en"
    ]

    var body: some View {
        TabView {
            GeneralSettingsView(
                micSensitivity: $micSensitivity,
                transcriptionManager: transcriptionManager
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }

            ModelSettingsView(
                selectedModel: $selectedModel,
                models: models
            )
            .tabItem {
                Label("Models", systemImage: "cpu")
            }
        }
        .padding()
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @Binding var micSensitivity: Double
    @ObservedObject var transcriptionManager: TranscriptionManager
    @State private var apiKey: String = ""

    var body: some View {
        Form {
            Section(header: Text("Microphone")) {
                VStack(alignment: .leading) {
                    Text("Silence Threshold: \(String(format: "%.4f", micSensitivity))")
                    Slider(value: $micSensitivity, in: 0.001...0.05) {
                        Text("Sensitivity")
                    }
                    Text("Adjust until background noise is ignored.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Cloud Transcription (Groq)")) {
                SecureField("Groq API Key", text: $apiKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button("Save Key") {
                    Task {
                        _ = await transcriptionManager.updateAPIKey(apiKey)
                    }
                }

                if transcriptionManager.hasStoredKey {
                    Text("✅ API Key Configured")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Text("Enter API Key to enable cloud mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

struct ModelSettingsView: View {
    @Binding var selectedModel: String
    let models: [String]

    var body: some View {
        Form {
            Picker("Local Model", selection: $selectedModel) {
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(MenuPickerStyle())

            Text("Note: Changing model requires restart.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
