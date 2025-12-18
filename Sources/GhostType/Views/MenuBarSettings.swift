import SwiftUI

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @ObservedObject var dictationEngine: DictationEngine

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
            Text("GhostType Settings")
                .font(.headline)
            
            Divider()

            // --- Mode Selection ---
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
            
            // --- Local Model Settings ---
            if manager.currentMode == .local {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $manager.selectedModel) {
                        ForEach(manager.availableModels, id: \.self) { model in
                            Text(formatModelName(model)).tag(model)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: manager.selectedModel) { newModel in
                        manager.switchModel(newModel)
                    }

                    Text("Larger models are more accurate but slower.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // --- Cloud API Settings ---
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
            }

            Divider()

            // --- Mic Sensitivity ---
            VStack(alignment: .leading, spacing: 4) {
                Text("Mic Sensitivity (Silence Threshold)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Slider mapping 0-1 to 0.001 - 0.05 RMS roughly
                // Actually 0.005 is default.
                // Let's make slider 0.001 to 0.02
                Slider(value: $dictationEngine.silenceThresholdRMS, in: 0.001...0.02) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Image(systemName: "mic.fill") // Low threshold = High Sensitivity (picks up whispers)
                        .font(.caption)
                } maximumValueLabel: {
                    Image(systemName: "mic.slash") // High threshold = Low Sensitivity (needs loud voice)
                        .font(.caption)
                }

                Text("Adjust if dictation stops too early or picks up noise.")
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
                Button("About") {
                    // About action
                }
                Spacer()
                Button("Quit GhostType") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 300)
    }

    func formatModelName(_ name: String) -> String {
        if name.contains("distil") { return "Distil-Large v3 (Recommended)" }
        if name.contains("turbo") { return "Large v3 Turbo" }
        if name.contains("base") { return "Base (Faster)" }
        if name.contains("tiny") { return "Tiny (Fastest)" }
        return name
    }
}
