import SwiftUI

struct SettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @AppStorage("micSensitivity") private var micSensitivity: Double = 1.0
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    var body: some View {
        Form {
            Section(header: Text("Microphone")) {
                VStack(alignment: .leading) {
                    Text("Sensitivity Boost: \(String(format: "%.1fx", micSensitivity))")
                    Slider(value: $micSensitivity, in: 0.5...3.0, step: 0.1)
                }
                Text("Adjust this if the app has trouble hearing you.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Model")) {
                Picker("Transcription Model", selection: $selectedModel) {
                    Text("Distil-Large-v3 (Recommended)").tag("distil-whisper_distil-large-v3")
                    Text("Large-v3-Turbo (Fast)").tag("openai_whisper-large-v3-turbo")
                    Text("Base (Low Memory)").tag("openai_whisper-base")
                }
                Text("Changes require app restart or model reload.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Transcription Mode")) {
                Picker("Mode", selection: $transcriptionManager.currentMode) {
                    Text("Local (On-Device)").tag(TranscriptionMode.local)
                    Text("Cloud (Groq)").tag(TranscriptionMode.cloud)
                }
                .pickerStyle(.segmented)

                if transcriptionManager.currentMode == .cloud {
                    SecureField("Groq API Key", text: Binding(
                        get: { "" },
                        set: { key in
                            Task {
                                _ = await transcriptionManager.updateAPIKey(key)
                            }
                        }
                    ))
                    if transcriptionManager.hasStoredKey {
                        Text("API Key stored securely.")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            }

            Section {
                Button("Check for Updates") {
                    // Placeholder
                }
                Text("GhostType v0.1.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }
}
