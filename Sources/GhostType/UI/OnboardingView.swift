import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation

struct OnboardingView: View {
    @State private var microphoneAccess = false
    @State private var accessibilityAccess = false
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to GhostType")
                .font(.largeTitle)

            Text("GhostType runs locally on your Mac using WhisperKit. Your voice data never leaves your device unless you enable Cloud Mode.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .foregroundColor(.secondary)

            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: microphoneAccess ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(microphoneAccess ? .green : .gray)
                    Text("Microphone Access")
                    Spacer()
                    if !microphoneAccess {
                        Button("Request") {
                            requestMicrophoneAccess()
                        }
                    }
                }

                HStack {
                    Image(systemName: accessibilityAccess ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(accessibilityAccess ? .green : .gray)
                    Text("Accessibility Access")
                    Spacer()
                    if !accessibilityAccess {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                    }
                }
            }
            .padding()

            Button("Get Started") {
                onComplete()
            }
            .disabled(!microphoneAccess || !accessibilityAccess)
        }
        .padding()
        .frame(width: 400, height: 300)
        .onAppear {
            checkCurrentPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkCurrentPermissions()
        }
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
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    microphoneAccess = granted
                }
            }
        default:
            // Instruct user to open settings
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
