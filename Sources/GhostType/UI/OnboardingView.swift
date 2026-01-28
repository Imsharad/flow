import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation

struct OnboardingView: View {
    @State private var microphoneAccess = false
    @State private var accessibilityAccess = false
    @State private var screenRecordingAccess = false
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to GhostType")
                .font(.largeTitle)

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

                HStack {
                    Image(systemName: screenRecordingAccess ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(screenRecordingAccess ? .green : .gray)
                    Text("Screen Recording (Audio Tap)")
                    Spacer()
                    if !screenRecordingAccess {
                        Button("Request") {
                            requestScreenRecordingAccess()
                        }
                    }
                }
            }
            .padding()

            Button("Get Started") {
                onComplete()
            }
            .disabled(!microphoneAccess || !accessibilityAccess || !screenRecordingAccess)
        }
        .padding()
        .frame(width: 400, height: 350)
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
        screenRecordingAccess = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAccess() {
        // CGRequestScreenCaptureAccess returns true if ALREADY granted.
        // If not granted, it returns false and prompts the user.
        _ = CGRequestScreenCaptureAccess()

        // Open Settings to help user if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !CGPreflightScreenCaptureAccess() {
                 let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                 NSWorkspace.shared.open(url)
            }
        }
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
