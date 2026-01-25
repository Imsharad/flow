import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager

    @AppStorage("micSensitivity") private var micSensitivity: Double = 0.005
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    @State private var apiKeyInput: String = ""
    @State private var isValidating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GhostType Settings")
                .font(.headline)

            Divider()

            VStack(alignment: .leading) {
                Text("Transcription Model")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $selectedModel) {
                    Text("Distil-Whisper Large v3").tag("distil-whisper_distil-large-v3")
                    Text("Whisper Large v3 Turbo").tag("openai_whisper-large-v3-turbo")
                    Text("Whisper Base").tag("openai_whisper-base")
                }
                .labelsHidden()
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Mic Sensitivity")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.3f", micSensitivity))
                        .font(.caption)
                        .monospacedDigit()
                }

                Slider(value: $micSensitivity, in: 0.001...0.1)
                Text("Higher = less sensitive to background noise")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading) {
                Text("Groq API Key (Optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    SecureField("sk-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            validateAndSave()
                        }

                    if isValidating {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        Button("Save") {
                            validateAndSave()
                        }
                        .disabled(apiKeyInput.isEmpty)
                    }
                }

                if manager.hasStoredKey {
                    Text("✅ API Key configured")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else {
                    Text("Enter key to enable Cloud mode")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Divider()

            HStack {
                Text("Mode:")
                Spacer()
                Text(manager.currentMode == .cloud ? "Cloud (Groq)" : "Local (WhisperKit)")
                    .foregroundColor(manager.currentMode == .cloud ? .blue : .green)
                    .bold()
            }
            .font(.caption)

            HStack {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")

                Spacer()
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func validateAndSave() {
        guard !apiKeyInput.isEmpty else { return }
        isValidating = true
        Task {
            let success = await manager.updateAPIKey(apiKeyInput)
            isValidating = false
            if success {
                apiKeyInput = ""
            }
        }
    }
}
