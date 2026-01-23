import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager

    @AppStorage("micSensitivity") private var micSensitivity: Double = 0.005
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    // Available models - this could be dynamic, but hardcoding the supported ones for now
    let models = [
        "distil-whisper_distil-large-v3",
        "openai_whisper-large-v3-turbo",
        "openai_whisper-base"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GhostType Settings")
                .font(.headline)
                .padding(.bottom, 4)

            // Transcription Mode
            VStack(alignment: .leading) {
                Text("Mode: \(manager.currentMode == .cloud ? "Cloud ☁️" : "Local 💻")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if manager.currentMode == .cloud {
                    Button("Switch to Local") {
                        // Logic to switch would ideally be in Manager, but it auto-selects based on Key.
                        // For now we just show state.
                    }
                    .disabled(true) // Manager auto-manages this
                }
            }

            Divider()

            // Model Selection
            VStack(alignment: .leading) {
                Text("Local Model")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.self) { model in
                        Text(model.replacingOccurrences(of: "_", with: " ").capitalized)
                            .tag(model)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            // Mic Sensitivity
            VStack(alignment: .leading) {
                HStack {
                    Text("Mic Sensitivity (VAD)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.3f", micSensitivity))
                        .font(.caption2)
                        .monospacedDigit()
                }

                Slider(value: $micSensitivity, in: 0.001...0.05)
            }

            Divider()

            // API Key (Simplified)
            VStack(alignment: .leading) {
                Text("Groq API Key (for Cloud)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SecureField("sk-...", text: Binding(
                    get: { "" }, // Don't show key
                    set: { newVal in
                        if !newVal.isEmpty {
                            Task {
                                _ = await manager.updateAPIKey(newVal)
                            }
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)

                if manager.hasStoredKey {
                    Text("✅ Key Stored")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Text("v0.9.0")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
