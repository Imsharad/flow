import Foundation
import AVFoundation
import AppKit

@MainActor
class PermissionsManager: ObservableObject {
    @Published var microphoneAccess: Bool = false
    @Published var accessibilityAccess: Bool = false

    static let shared = PermissionsManager()

    private init() {
        checkCurrentPermissions()
    }

    func checkCurrentPermissions() {
        microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAccess = AXIsProcessTrusted()
    }

    func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAccess = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneAccess = granted
                }
            }
        case .denied, .restricted:
            openSystemPreferences(for: "Privacy_Microphone")
        @unknown default:
            break
        }
    }

    func requestAccessibilityAccess() {
        if !AXIsProcessTrusted() {
             let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
             AXIsProcessTrustedWithOptions(options)
             // Accessibility changes usually require app restart or user manual toggle,
             // so we just open settings if the prompt doesn't work or as a fallback.
             openSystemPreferences(for: "Privacy_Accessibility")
        } else {
            accessibilityAccess = true
        }
    }

    private func openSystemPreferences(for pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
