import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics

struct OnboardingView: View {
    @State private var microphoneAccess = false
    @State private var accessibilityAccess = false
    @State private var screenRecordingAccess = false

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 10) {
                // Using "sparkles" because "ghost.fill" is not a standard SF Symbol.
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(.linearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))

                Text("Welcome to GhostType")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Please grant permissions to enable AI dictation.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                // 1. Microphone
                PermissionRow(
                    title: "Microphone",
                    description: "Required to hear your voice.",
                    icon: "mic.fill",
                    isGranted: microphoneAccess,
                    action: requestMicrophoneAccess
                )

                // 2. Accessibility
                PermissionRow(
                    title: "Accessibility",
                    description: "Required to type text into other apps.",
                    icon: "keyboard.fill",
                    isGranted: accessibilityAccess,
                    action: openAccessibilitySettings
                )

                // 3. Screen Recording
                PermissionRow(
                    title: "Screen Recording",
                    description: "Required to capture system audio (Audio Tap).",
                    icon: "rectangle.dashed.badge.record",
                    isGranted: screenRecordingAccess,
                    action: openScreenRecordingSettings
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            Button(action: onComplete) {
                Text("Start Dictating")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!microphoneAccess || !accessibilityAccess || !screenRecordingAccess)
        }
        .padding(40)
        .frame(width: 500)
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
            openMicrophoneSettings()
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        // Trigger a fake stream or just open settings
        // To properly trigger the prompt, we often need to try to record.
        // But for now, just directing them is safer.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)

        // Polling check might be needed as CGPreflightScreenCaptureAccess doesn't update instantly in some OS versions without app restart,
        // but it's the standard API.
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let icon: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 30, height: 30)
                .foregroundColor(isGranted ? .green : .blue)

            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
