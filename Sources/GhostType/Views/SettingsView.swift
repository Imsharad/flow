import SwiftUI

struct SettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var audioManager: AudioInputManager

    // Tab selection
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(manager: transcriptionManager)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            AudioSettingsView(audioManager: audioManager)
                .tabItem {
                    Label("Audio", systemImage: "mic")
                }
                .tag(1)

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(2)
        }
        .padding()
        .frame(width: 450, height: 350)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var manager: TranscriptionManager
    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var validationStatus: ValidationStatus = .idle

    enum ValidationStatus {
        case idle
        case validating
        case success
        case failure
    }

    var body: some View {
        Form {
            Section(header: Text("Transcription Mode")) {
                Picker("Mode", selection: $manager.currentMode) {
                    Text("Cloud (Groq) ☁️").tag(TranscriptionMode.cloud)
                    Text("Local (On-Device) ⚡️").tag(TranscriptionMode.local)
                }
                .pickerStyle(.segmented)

                if manager.currentMode == .cloud {
                    Text("Cloud mode uses Groq for ultra-fast inference.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Groq API Key")
                            .font(.headline)

                        HStack {
                            if isKeyVisible {
                                TextField("gsk_...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("gsk_...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button(action: { isKeyVisible.toggle() }) {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }

                        HStack {
                            if manager.hasStoredKey {
                                Text("Key saved locally in Keychain.")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else {
                                Text("No key saved.")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }

                            Spacer()

                            Button("Save & Verify") {
                                validationStatus = .validating
                                Task {
                                    let isValid = await manager.updateAPIKey(apiKeyInput)
                                    validationStatus = isValid ? .success : .failure
                                }
                            }
                            .disabled(apiKeyInput.isEmpty)
                        }

                        if validationStatus == .success {
                            Text("Validation Successful!")
                                .foregroundColor(.green)
                                .font(.caption)
                        } else if validationStatus == .failure {
                            Text("Validation Failed. Check your key.")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                } else {
                    Text("Local mode uses WhisperKit on your Mac's Neural Engine.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Model: Distil-Whisper Large v3 (Default)")
                        .font(.caption)
                        .padding(.top, 4)
                }
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
                Text("Input Device: Built-in Microphone")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading) {
                    Text("Sensitivity (Gain): \(String(format: "%.1f", audioManager.micSensitivity))x")
                    Slider(value: $audioManager.micSensitivity, in: 0.1...5.0, step: 0.1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Text("Low")
                    } maximumValueLabel: {
                        Text("High")
                    }
                }

                Text("Adjust this if dictation is too quiet or too loud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct AdvancedSettingsView: View {
    var body: some View {
        Form {
            Section(header: Text("Model Configuration")) {
                Text("Model Selection is currently fixed to 'Distil-Whisper Large v3' for optimal stability on M1/M2/M3 chips.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom)

                Link("Visit WhisperKit on GitHub", destination: URL(string: "https://github.com/argmax-inc/WhisperKit")!)
            }

            Section(header: Text("Debug")) {
                Button("Open Log File") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/ghosttype_debug.log"))
                }
            }
        }
        .padding()
    }
}
