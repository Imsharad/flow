import SwiftUI
import AVFoundation

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @AppStorage("micSensitivity") private var sensitivity: Double = 0.5
    @AppStorage("selectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("GhostType Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)

            Divider()

            // Mode Selection
            VStack(alignment: .leading) {
                Text("Transcription Engine")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Mode", selection: $manager.currentMode) {
                    Text("Local (Privacy)").tag(TranscriptionMode.local)
                    Text("Cloud (Speed)").tag(TranscriptionMode.cloud)
                }
                .pickerStyle(SegmentedPickerStyle())
                .onChange(of: manager.currentMode) { newMode in
                    print("Settings: Mode changed to \(newMode)")
                }
            }

            if manager.currentMode == .cloud {
                // API Key Input
                VStack(alignment: .leading) {
                    Text("Groq API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    SecureField("gsk_...", text: Binding(
                        get: { "" }, // Don't show key
                        set: { key in
                            Task {
                                _ = await manager.updateAPIKey(key)
                            }
                        }
                    ))
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                    if manager.hasStoredKey {
                        Text("✅ API Key Saved")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else {
                         Text("Enter key to enable Cloud Mode")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            } else {
                // Local Model Selection
                VStack(alignment: .leading) {
                    Text("Model")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Model", selection: $selectedModel) {
                        Text("Distil-Large-v3 (Balanced)").tag("distil-whisper_distil-large-v3")
                        Text("Turbo (Fastest)").tag("openai_whisper-large-v3-turbo")
                    }
                    .labelsHidden()
                }
            }

            Divider()

            // Mic Sensitivity
            VStack(alignment: .leading) {
                HStack {
                    Text("Mic Sensitivity")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(sensitivity * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Slider(value: $sensitivity, in: 0.0...2.0, step: 0.1)
            }

            Spacer()

            // Footer
            HStack {
                Text("v1.0.0")
                    .font(.caption2)
                    .foregroundColor(.gray)
                Spacer()
                Button("Quit GhostType") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
