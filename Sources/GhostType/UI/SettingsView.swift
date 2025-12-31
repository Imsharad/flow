import SwiftUI

struct SettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var audioInputManager: AudioInputManager

    // Models available for download/use
    let availableModels = [
        "distil-whisper_distil-large-v3",
        "openai_whisper-large-v3-turbo",
        "openai_whisper-base.en",
        "openai_whisper-tiny.en"
    ]

    var body: some View {
        Form {
            Section(header: Text("Transcription Mode")) {
                Picker("Mode", selection: $transcriptionManager.currentMode) {
                    Text("Local (WhisperKit)").tag(TranscriptionMode.local)
                    Text("Cloud (Groq)").tag(TranscriptionMode.cloud)
                }
                .pickerStyle(SegmentedPickerStyle())
            }

            if transcriptionManager.currentMode == .local {
                Section(header: Text("Local Model")) {
                    Picker("Model", selection: $transcriptionManager.selectedModel) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Text("Note: Models are downloaded on first use. 'Distil-Large-v3' is recommended for M-Series chips.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                 Section(header: Text("Cloud API Key")) {
                     Text("API Key configured: \(transcriptionManager.hasStoredKey ? "Yes" : "No")")
                     // We could add a button to open the API Key sheet here if we wanted
                 }
            }

            Section(header: Text("Microphone")) {
                VStack(alignment: .leading) {
                    Text("Sensitivity: \(String(format: "%.1f", audioInputManager.micSensitivity))x")
                    Slider(value: $audioInputManager.micSensitivity, in: 0.5...5.0, step: 0.1)
                }
            }

            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
        }
        .padding()
        .frame(width: 400, height: 400)
    }
}
