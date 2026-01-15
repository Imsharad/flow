import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var audioManager = AudioInputManager.shared

    @State private var apiKey: String = ""
    @State private var isValidating: Bool = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("GhostType Settings")
                .font(.headline)

            Divider()

            // Mode Selection
            VStack(alignment: .leading) {
                Text("Transcription Mode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Mode", selection: $manager.currentMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())

                Text(manager.currentMode == .cloud ? "Uses Groq Cloud API (Low Latency)" : "Uses On-Device Model (Privacy + Offline)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Divider()

            // Microphone Sensitivity
            VStack(alignment: .leading) {
                Text("Microphone Sensitivity: \(String(format: "%.1f", audioManager.micSensitivity))x")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Slider(value: $audioManager.micSensitivity, in: 0.1...3.0, step: 0.1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("0.1x")
                } maximumValueLabel: {
                    Text("3.0x")
                }
            }

            Divider()

            // API Key
            VStack(alignment: .leading) {
                Text("Groq API Key")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    SecureField("gsk_...", text: $apiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    if isValidating {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        Button("Save") {
                            validateAndSave()
                        }
                        .disabled(apiKey.isEmpty)
                    }
                }

                if let message = validationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(message.contains("Success") ? .green : .red)
                }

                if manager.hasStoredKey {
                     Text("✅ Key stored securely in Keychain")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Text("v1.0.0")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func validateAndSave() {
        isValidating = true
        validationMessage = nil

        Task {
            let success = await manager.updateAPIKey(apiKey)
            await MainActor.run {
                isValidating = false
                if success {
                    validationMessage = "Success! Switched to Cloud Mode."
                    apiKey = "" // Clear field for security
                } else {
                    validationMessage = "Invalid Key. Please check and try again."
                }
            }
        }
    }
}
