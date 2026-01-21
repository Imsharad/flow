import SwiftUI
import AppKit

// Singleton to manage the settings window lifecycle
class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func open() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        newWindow.center()
        newWindow.title = "GhostType Settings"
        newWindow.contentView = NSHostingView(rootView: SettingsView())
        newWindow.isReleasedWhenClosed = false // Important: keep it alive if we want to reuse reference, but actually standard is to let it close and set to nil.

        // Better: Detect close to set window = nil
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: newWindow)

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        self.window = nil
    }
}

struct MenuBarSettings: View {
    @ObservedObject var manager: TranscriptionManager
    @State private var apiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var validationStatus: ValidationStatus = .idle
    @State private var isEditingKey: Bool = false
    @State private var showSettingsWindow: Bool = false // Toggle for new window
    
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
            
            Button("Settings...") {
               openSettingsWindow()
            }
            .buttonStyle(.borderless)

            Divider()

            Button("Quit GhostType") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(width: 260)
    }

    private func openSettingsWindow() {
        SettingsWindowController.shared.open()
    }
}
