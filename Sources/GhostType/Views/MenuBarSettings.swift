import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var validationStatus: ValidationStatus = .idle
    @State private var isEditingKey: Bool = false
    
    // New Settings
    @AppStorage("GhostType.MicSensitivity") private var micSensitivity: Double = 1.0
    @AppStorage("GhostType.SelectedModel") private var selectedModel: String = "distil-whisper_distil-large-v3"

    enum ValidationStatus {
        case idle
        case validating
        case success
        case failure
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GhostType")
                .font(.headline)
            
            Picker("Mode", selection: $manager.currentMode) {
                Text("Cloud ☁️").tag(TranscriptionMode.cloud)
                Text("Local ⚡️").tag(TranscriptionMode.local)
            }
            .pickerStyle(.segmented)
            .onChange(of: manager.currentMode) { newMode in
                if newMode == .cloud {
                    isEditingKey = false
                }
            }
            
            if manager.currentMode == .cloud {
                cloudSettingsView
            } else {
                localSettingsView
            }

            Divider()

            // Audio Settings
            VStack(alignment: .leading, spacing: 4) {
                Text("Microphone Sensitivity")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $micSensitivity, in: 0.1...2.0, step: 0.1)
                    Image(systemName: "speaker.wave.3.fill")
                }
                Text("Gain: \(String(format: "%.1f", micSensitivity))x")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if let error = manager.lastError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Divider()
            
            HStack {
                Button("Advanced Settings...") {
                    NSApp.sendAction(#selector(AppDelegate.openSettingsWindow), to: nil, from: nil)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 260)
    }

    var localSettingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Selection")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("", selection: $selectedModel) {
                Text("Distil-Large (Recommended)").tag("distil-whisper_distil-large-v3")
                Text("Turbo (Faster)").tag("openai_whisper-large-v3-turbo")
                Text("Base (Fastest)").tag("openai_whisper-base")
            }
            .pickerStyle(.menu)

            Text("Using on-device WhisperKit model.\nPrivacy prioritized. No internet required.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var cloudSettingsView: some View {
        Group {
            // Collapsed View: Key is saved
            if manager.hasStoredKey && !isEditingKey {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("API Key Saved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Change") {
                        isEditingKey = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            } else {
                // Expanded View: No key or editing
                VStack(alignment: .leading, spacing: 4) {
                    Text("Groq API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

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

                        // Paste Button
                        Button(action: {
                            if let clipboard = NSPasteboard.general.string(forType: .string) {
                                apiKeyInput = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }) {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                        .help("Paste from Clipboard")
                    }

                    HStack {
                        Button("Save & Verify") {
                            validationStatus = .validating
                            Task {
                                let isValid = await manager.updateAPIKey(apiKeyInput)
                                validationStatus = isValid ? .success : .failure

                                if isValid {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        apiKeyInput = ""
                                        validationStatus = .idle
                                        isEditingKey = false // Collapse after success
                                    }
                                }
                            }
                        }
                        .disabled(apiKeyInput.isEmpty || validationStatus == .validating)

                        if manager.hasStoredKey {
                            Button("Cancel") {
                                apiKeyInput = ""
                                isEditingKey = false
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }

                        Spacer()

                        if validationStatus == .validating {
                            ProgressView()
                                .scaleEffect(0.5)
                        } else if validationStatus == .success {
                            Text("Verified!")
                                .foregroundColor(.green)
                                .font(.caption)
                        } else if validationStatus == .failure {
                            Text("Invalid Key")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }
}
