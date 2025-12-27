import SwiftUI

struct SettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @StateObject private var audioManager = AudioInputManager.shared
    @AppStorage("GhostType.GroqAPIKey") private var apiKey: String = ""
    @AppStorage("GhostType.SelectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    // UI State
    @State private var isValidatingKey = false
    @State private var keyValidationStatus: Bool? = nil

    var body: some View {
        TabView {
            // MARK: - General
            Form {
                Section(header: Text("Model Selection (Local)")) {
                    Picker("Whisper Model", selection: $selectedModel) {
                        Text("Distil-Large-v3 (Recommended)").tag("distil-whisper_distil-large-v3")
                        Text("Base (Fast)").tag("openai_whisper-base")
                        Text("Turbo (High Quality)").tag("openai_whisper-large-v3-turbo")
                    }
                    Text("Models are downloaded automatically on first use.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("App Behavior")) {
                    Toggle("Launch at Login", isOn: .constant(false)) // Placeholder
                        .disabled(true)
                }
            }
            .tabItem {
                Label("General", systemImage: "gear")
            }
            .padding()

            // MARK: - Cloud
            Form {
                Section(header: Text("Groq Cloud API")) {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Validate Key") {
                            validateKey()
                        }
                        .disabled(apiKey.isEmpty || isValidatingKey)

                        if isValidatingKey {
                            ProgressView()
                                .scaleEffect(0.5)
                        } else if let status = keyValidationStatus {
                            Image(systemName: status ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(status ? .green : .red)
                        }
                    }

                    Text("Using Cloud API reduces battery usage and improves speed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tabItem {
                Label("Cloud", systemImage: "cloud")
            }
            .padding()

            // MARK: - Audio
            Form {
                Section(header: Text("Microphone")) {
                    // Placeholder for volume meter if we can expose it
                    Text("Input Level")
                    ProgressView(value: 0.5) // Mock
                }
            }
            .tabItem {
                Label("Audio", systemImage: "mic")
            }
            .padding()
        }
        .frame(width: 450, height: 300)
    }

    private func validateKey() {
        isValidatingKey = true
        Task {
            let isValid = await transcriptionManager.updateAPIKey(apiKey)
            await MainActor.run {
                self.keyValidationStatus = isValid
                self.isValidatingKey = false
            }
        }
    }
}
