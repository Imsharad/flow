import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var audioManager = AudioInputManager.shared
    @AppStorage("selectedModel") var selectedModel: String = "distil-whisper_distil-large-v3"

    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var validationStatus: ValidationStatus = .idle
    @State private var isEditingKey: Bool = false
    
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
            } else {
                Text("Using on-device WhisperKit model.\nPrivacy prioritized. No internet required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            if let error = manager.lastError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Divider()
            
            // Audio Settings
            VStack(alignment: .leading, spacing: 4) {
                Text("Mic Sensitivity: \(Int(audioManager.micSensitivity * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: "mic.slash")
                        .font(.caption)
                    Slider(value: $audioManager.micSensitivity, in: 0.0...5.0)
                    Image(systemName: "mic.fill")
                        .font(.caption)
                }
            }

            if manager.currentMode == .local {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                     Picker("Model", selection: $selectedModel) {
                         Text("Distil-Large-v3").tag("distil-whisper_distil-large-v3")
                         Text("Large-v3-Turbo").tag("openai_whisper-large-v3-turbo")
                         Text("Base (English)").tag("openai_whisper-base.en")
                     }
                     .pickerStyle(.menu)
                     .labelsHidden()
                }
            }

            Divider()

            Button("Quit GhostType") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
