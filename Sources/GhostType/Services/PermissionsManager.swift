import Foundation
import AVFoundation
import ApplicationServices
import SwiftUI

class PermissionsManager: ObservableObject {
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var accessibilityStatus: Bool = false

    static let shared = PermissionsManager()

    private init() {
        checkStatuses()
    }

    func checkStatuses() {
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.accessibilityStatus = AXIsProcessTrusted()
    }

    func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.micStatus = granted ? .authorized : .denied
            }
        }
    }

    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        self.accessibilityStatus = accessEnabled

        if !accessEnabled {
            // Poll for change or wait for user to switch back
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                let enabled = AXIsProcessTrusted()
                if enabled {
                    DispatchQueue.main.async {
                        self?.accessibilityStatus = true
                    }
                    timer.invalidate()
                }
            }
        }
    }
}
