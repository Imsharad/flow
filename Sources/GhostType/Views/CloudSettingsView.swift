import SwiftUI

struct CloudSettingsView: View {
    @ObservedObject var manager: TranscriptionManager
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
