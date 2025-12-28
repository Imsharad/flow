import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var audioManager = AudioInputManager.shared

    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var validationStatus: ValidationStatus = .idle
    @State private var isEditingKey: Bool = false
    @State private var selectedModel: String = UserDefaults.standard.string(forKey: "GhostType.SelectedModel") ?? "distil-whisper_distil-large-v3"

    let availableModels = [
        "distil-whisper_distil-large-v3": "Distil-Large-v3 (Recommended)",
        "openai_whisper-large-v3-turbo": "Large-v3 Turbo",
        "openai_whisper-base": "Base (Faster)",
        "openai_whisper-tiny": "Tiny (Fastest)"
    ]
    
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model Selection")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Picker("Model", selection: $selectedModel) {
                        ForEach(availableModels.keys.sorted(), id: \.self) { key in
                            Text(availableModels[key] ?? key).tag(key)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "GhostType.SelectedModel")
                        // Note: Requires restart or explicit reload to take effect fully in current architecture
                    }

                    Text("Restart app to apply model changes.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Mic Sensitivity: \(String(format: "%.1fx", audioManager.micSensitivity))")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Slider(value: $audioManager.micSensitivity, in: 0.5...3.0, step: 0.1)
                        .accentColor(audioManager.micSensitivity > 1.0 ? .orange : .blue)
                }

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
            
            Button("Quit GhostType") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
