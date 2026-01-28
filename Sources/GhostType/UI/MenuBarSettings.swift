import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @AppStorage("micSensitivity") private var micSensitivity: Double = 0.005
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    @State private var apiKey: String = ""
    @State private var statusMessage: String = ""

    var body: some View {
        TabView {
            GeneralSettingsView(micSensitivity: $micSensitivity, selectedModel: $selectedModel)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AdvancedSettingsView(manager: manager, apiKey: $apiKey, statusMessage: $statusMessage)
                .tabItem {
                    Label("Advanced", systemImage: "lock")
                }
        }
        .padding()
        .frame(width: 320, height: 300)
    }
}

struct GeneralSettingsView: View {
    @Binding var micSensitivity: Double
    @Binding var selectedModel: String

    var body: some View {
        Form {
            Section(header: Text("Microphone")) {
                VStack(alignment: .leading) {
                    Text("Sensitivity Threshold: \(String(format: "%.4f", micSensitivity))")
                    Slider(value: $micSensitivity, in: 0.001...0.05) {
                        Text("Sensitivity")
                    }
                    Text("Adjust if silence is detected as speech")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Model")) {
                Picker("Local Model", selection: $selectedModel) {
                    Text("Distil-Large-v3").tag("distil-whisper_distil-large-v3")
                    Text("Large-v3-Turbo").tag("openai_whisper-large-v3-turbo")
                    Text("Base (Fast)").tag("openai_whisper-base")
                }
                .pickerStyle(MenuPickerStyle())

                Text("Changes require app restart")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @Binding var apiKey: String
    @Binding var statusMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud Transcription (Groq)")
                .font(.headline)

            Text("Enter your Groq API Key to enable ultra-low latency cloud transcription.")
                .font(.caption)
                .foregroundColor(.secondary)

            SecureField("Groq API Key", text: $apiKey)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack {
                if manager.hasStoredKey {
                    Text("✅ Key Stored")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                Spacer()

                Button("Save & Validate") {
                    validateAndSave()
                }
                .disabled(apiKey.isEmpty)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(statusMessage.contains("Success") ? .green : .red)
            }

            Divider()

            HStack {
                Text("Current Mode:")
                Spacer()
                Text(manager.currentMode == .cloud ? "Cloud ☁️" : "Local 💻")
                    .bold()
            }
        }
        .padding()
    }

    private func validateAndSave() {
        statusMessage = "Validating..."
        Task {
            let success = await manager.updateAPIKey(apiKey)
            if success {
                statusMessage = "Success! Cloud mode enabled."
                apiKey = "" // Clear field for security
            } else {
                statusMessage = "Validation failed. Check key."
            }
        }
    }
}
