import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var audioInput = AudioInputManager.shared

    @State private var tempKey: String = ""
    @State private var isValidating: Bool = false
    @State private var validationResult: Bool? = nil
    @State private var selectedModel: String = "Distil-Large-v3"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack {
                Text("GhostType Settings")
                    .font(.headline)
                Spacer()
                if manager.currentMode == .cloud {
                    Label("Cloud", systemImage: "cloud.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                } else {
                    Label("Local", systemImage: "laptopcomputer")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            Divider()

            // Microphone Sensitivity
            VStack(alignment: .leading, spacing: 5) {
                Text("Microphone Sensitivity")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                    Slider(value: $audioInput.micSensitivity, in: 0.5...5.0, step: 0.1)
                    Text(String(format: "%.1fx", audioInput.micSensitivity))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            }

            Divider()

            // Cloud / API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Cloud Transcription (Groq)")
                    .font(.caption)
                    .bold()

                Text("Enter API Key to enable cloud mode (faster).")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                SecureField("gsk_...", text: $tempKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(isValidating)

                HStack {
                    if isValidating {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else if let result = validationResult {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result ? .green : .red)
                        Text(result ? "Valid Key Saved" : "Invalid Key")
                            .font(.caption)
                            .foregroundColor(result ? .green : .red)
                    }

                    Spacer()

                    if !tempKey.isEmpty {
                        Button("Save & Validate") {
                            validateKey()
                        }
                        .disabled(isValidating)
                    } else if manager.hasStoredKey {
                        Text("Key Stored")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Model Selection
             VStack(alignment: .leading) {
                Text("Local Model")
                    .font(.caption)
                    .bold()

                Picker("Model", selection: $selectedModel) {
                    Text("Distil-Large-v3").tag("Distil-Large-v3")
                    Text("Large-v3 (Turbo)").tag("Large-v3-Turbo")
                    Text("Base (English)").tag("Base-En")
                }
                .pickerStyle(MenuPickerStyle())
                .disabled(true) // Disabled until dynamic model loading is implemented

                Text("Currently fixed to optimized Distil-Large-v3 for M-Series.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
             }

             Spacer()
        }
        .padding()
        .frame(width: 260)
        .onAppear {
             // Pre-fill key if needed? No, keep it secure.
        }
    }

    private func validateKey() {
        isValidating = true
        validationResult = nil

        Task {
            let success = await manager.updateAPIKey(tempKey)
            await MainActor.run {
                isValidating = false
                validationResult = success
                if success {
                    tempKey = "" // Clear field on success
                }
            }
        }
    }
}
