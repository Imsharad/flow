import SwiftUI

struct SettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager

    // User Defaults
    @AppStorage("GhostType.MicSensitivity") private var micSensitivity: Double = 0.5
    @AppStorage("GhostType.SelectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    var body: some View {
        TabView {
            GeneralSettingsView(micSensitivity: $micSensitivity, selectedModel: $selectedModel)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            CloudSettingsView(manager: transcriptionManager)
                .tabItem {
                    Label("Cloud", systemImage: "cloud")
                }
        }
        .padding()
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @Binding var micSensitivity: Double
    @Binding var selectedModel: String

    var body: some View {
        Form {
            Section(header: Text("Transcription Model")) {
                Picker("Model", selection: $selectedModel) {
                    Text("Distil-Whisper Large v3 (Fast)").tag("distil-whisper_distil-large-v3")
                    Text("Whisper Large v3 Turbo (Fastest)").tag("openai_whisper-large-v3-turbo")
                    Text("Whisper Large v3 (Accurate)").tag("openai_whisper-large-v3")
                }
                .pickerStyle(.menu)
                Text("Requires app restart to change model.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Audio")) {
                Slider(value: $micSensitivity, in: 0...1) {
                    Text("Mic Sensitivity")
                }
                Text("Adjust if background noise triggers recording.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct CloudSettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @State private var apiKey: String = ""
    @State private var statusMessage: String = ""

    var body: some View {
        Form {
            Section(header: Text("Groq Cloud API")) {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Verify & Save") {
                        Task {
                            statusMessage = "Verifying..."
                            let success = await manager.updateAPIKey(apiKey)
                            statusMessage = success ? "✅ Valid API Key Saved" : "❌ Invalid API Key"
                        }
                    }
                    .disabled(apiKey.isEmpty)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .foregroundColor(statusMessage.contains("✅") ? .green : .red)
                    }
                }

                Text("Use Cloud for faster inference on older Macs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Enable Cloud Transcription", isOn: Binding(
                    get: { manager.currentMode == .cloud },
                    set: { _ in /* managed by manager automatically based on key */ }
                ))
                .disabled(!manager.hasStoredKey)
            }
        }
        .padding()
    }
}
