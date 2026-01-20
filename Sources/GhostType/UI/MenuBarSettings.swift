import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager

    @AppStorage("micSensitivity") private var micSensitivity: Double = 0.005
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    // Model Options
    let models = [
        "distil-whisper_distil-large-v3": "Distil-Large-v3 (Recommended)",
        "openai_whisper-large-v3-turbo": "Large-v3 Turbo (Fast)",
        "openai_whisper-large-v3": "Large-v3 (Accurate)",
        "openai_whisper-tiny": "Tiny (Fastest)"
    ]

    var body: some View {
        TabView {
            // General Tab
            VStack(alignment: .leading, spacing: 20) {
                Text("Microphone")
                    .font(.headline)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Sensitivity Gate")
                        Spacer()
                        Text(String(format: "%.3f", micSensitivity))
                            .font(.mono(.caption)())
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $micSensitivity, in: 0.001...0.1, step: 0.001) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Image(systemName: "mic.slash")
                    } maximumValueLabel: {
                        Image(systemName: "mic.fill")
                    }

                    Text("Adjust this if GhostType is not hearing you or triggering randomly.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .tabItem {
                Label("General", systemImage: "gear")
            }

            // Advanced Tab
            VStack(alignment: .leading, spacing: 20) {
                Text("Transcription Model")
                    .font(.headline)

                Picker("Model", selection: $selectedModel) {
                    ForEach(models.keys.sorted(), id: \.self) { key in
                        Text(models[key] ?? key).tag(key)
                    }
                }
                .pickerStyle(.radioGroup) // or .menu

                Text("Changing models requires a restart or model reload.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if selectedModel.contains("large") {
                     HStack {
                         Image(systemName: "exclamationmark.triangle.fill")
                             .foregroundColor(.yellow)
                         Text("Large models require 4GB+ RAM.")
                             .font(.caption)
                     }
                }

                Divider()

                Text("API Key (Cloud)")
                    .font(.headline)

                // Placeholder for Cloud Key
                SecureField("Groq / OpenAI Key", text: .constant(""))
                    .disabled(true)
                Text("Cloud transcription coming in v2.0")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding()
            .tabItem {
                Label("Advanced", systemImage: "cpu")
            }
        }
        .frame(width: 350, height: 300)
    }
}
