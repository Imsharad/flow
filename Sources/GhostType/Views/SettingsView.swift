import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var audioManager = AudioInputManager.shared

    @State private var apiKeyInput: String = ""
    @State private var isValidating: Bool = false
    @State private var validationMessage: String?
    @State private var selectedModel: String = UserDefaults.standard.string(forKey: "GhostType.SelectedModel") ?? "distil-whisper_distil-large-v3"

    let availableModels = [
        "distil-whisper_distil-large-v3": "Distil-Large v3 (Recommended)",
        "openai_whisper-large-v3-turbo": "Turbo Large v3 (Fastest)",
        "openai_whisper-base": "Base (Low Memory)"
    ]

    var body: some View {
        TabView {
            // MARK: - General
            VStack(alignment: .leading, spacing: 20) {
                Text("General Settings")
                    .font(.headline)

                // Transcription Mode
                Picker("Transcription Mode", selection: $manager.currentMode) {
                    Text("Local (On-Device)").tag(TranscriptionMode.local)
                    Text("Cloud (Groq API)").tag(TranscriptionMode.cloud)
                }
                .pickerStyle(.segmented)

                if manager.currentMode == .cloud {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Groq API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SecureField("gsk_...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                validateKey()
                            }

                        HStack {
                            if isValidating {
                                ProgressView()
                                    .scaleEffect(0.5)
                            }

                            if let msg = validationMessage {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundColor(msg.contains("Success") ? .green : .red)
                            }

                            Spacer()

                            Button("Save Key") {
                                validateKey()
                            }
                            .disabled(apiKeyInput.isEmpty || isValidating)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .transition(.opacity)
                } else {
                    // Local Model Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local Model")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Model", selection: $selectedModel) {
                            ForEach(availableModels.keys.sorted(), id: \.self) { key in
                                Text(availableModels[key] ?? key).tag(key)
                            }
                        }
                        .onChange(of: selectedModel) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "GhostType.SelectedModel")
                            // Note: Requires restart to take effect fully in current architecture
                        }

                        Text("Changes require app restart.")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding()
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            // MARK: - Audio
            VStack(alignment: .leading, spacing: 20) {
                Text("Audio Settings")
                    .font(.headline)

                VStack(alignment: .leading) {
                    Text("Microphone Sensitivity")
                    Slider(value: $audioManager.micSensitivity, in: 0.1...5.0, step: 0.1) {
                        Text("Gain")
                    } minimumValueLabel: {
                        Text("Low")
                    } maximumValueLabel: {
                        Text("High")
                    }

                    Text("Current Gain: \(String(format: "%.1f", audioManager.micSensitivity))x")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .tabItem {
                Label("Audio", systemImage: "mic")
            }
        }
        .frame(width: 450, height: 350)
        .padding()
    }

    private func validateKey() {
        guard !apiKeyInput.isEmpty else { return }
        isValidating = true
        validationMessage = nil

        Task {
            let success = await manager.updateAPIKey(apiKeyInput)
            await MainActor.run {
                isValidating = false
                if success {
                    validationMessage = "✅ Success! Switched to Cloud mode."
                    apiKeyInput = "" // Clear field for security (key is in keychain)
                } else {
                    validationMessage = "❌ Invalid Key. Please try again."
                }
            }
        }
    }
}
