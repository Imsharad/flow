import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var audioManager: AudioInputManager

    var body: some View {
        TabView {
            GeneralSettingsView(manager: manager)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelSettingsView(manager: manager)
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            AudioSettingsView(audioManager: audioManager)
                .tabItem {
                    Label("Audio", systemImage: "mic")
                }
        }
        .padding()
        .frame(width: 450, height: 250)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @State private var apiKeyInput: String = ""

    var body: some View {
        Form {
            Picker("Transcription Mode", selection: $manager.currentMode) {
                Text("Cloud (Groq)").tag(TranscriptionMode.cloud)
                Text("Local (On-Device)").tag(TranscriptionMode.local)
            }
            .pickerStyle(.inline)

            if manager.currentMode == .cloud {
                Section(header: Text("API Key")) {
                    SecureField("Groq API Key", text: $apiKeyInput)
                    Button("Update Key") {
                        Task {
                            _ = await manager.updateAPIKey(apiKeyInput)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct ModelSettingsView: View {
    @ObservedObject var manager: TranscriptionManager

    // Model Options
    let models = [
        ("distil-whisper_distil-large-v3", "Distil-Whisper Large v3 (Best Quality)"),
        ("openai_whisper-large-v3-turbo", "Whisper Large v3 Turbo (Fastest)")
    ]

    var body: some View {
        Form {
            Section(header: Text("Local Inference Model")) {
                Picker("Model", selection: Binding(
                    get: { manager.selectedModel },
                    set: { manager.switchLocalModel(to: $0) }
                )) {
                    ForEach(models, id: \.0) { model in
                        Text(model.1).tag(model.0)
                    }
                }
                .pickerStyle(.menu)

                Text("Note: Switching models may require a download and warm-up period.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct AudioSettingsView: View {
    @ObservedObject var audioManager: AudioInputManager

    var body: some View {
        Form {
            Section(header: Text("Microphone")) {
                VStack(alignment: .leading) {
                    Text("Sensitivity (Gain): \(Int(audioManager.micSensitivity * 100))%")
                    Slider(value: $audioManager.micSensitivity, in: 0.5...3.0, step: 0.1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("50%")
                    } maximumValueLabel: {
                        Text("300%")
                    }
                }

                Text("Increase if whisper is not detected. Decrease if background noise triggers transcription.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}
