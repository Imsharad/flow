import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation

struct OnboardingView: View {
    @State private var microphoneAccess = false
    @State private var accessibilityAccess = false
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Text("Welcome to GhostType")
                .font(.system(size: 24, weight: .bold))
                .padding(.top)

            VStack(alignment: .leading, spacing: 20) {
                // Microphone Step
                HStack(spacing: 15) {
                    Image(systemName: microphoneAccess ? "mic.fill" : "mic.slash")
                        .font(.system(size: 24))
                        .foregroundColor(microphoneAccess ? .green : .red)
                        .frame(width: 30)

                    VStack(alignment: .leading) {
                        Text("Microphone Access")
                            .font(.headline)
                        Text("Required to capture your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !microphoneAccess {
                        Button("Request") {
                            requestMicrophoneAccess()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }

                Divider()

                // Accessibility Step
                HStack(spacing: 15) {
                    Image(systemName: accessibilityAccess ? "hand.point.up.left.fill" : "hand.slash.fill")
                        .font(.system(size: 24))
                        .foregroundColor(accessibilityAccess ? .green : .red)
                        .frame(width: 30)

                    VStack(alignment: .leading) {
                        Text("Accessibility Access")
                            .font(.headline)
                        Text("Required to type text into apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !accessibilityAccess {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .shadow(radius: 2)

            Spacer()

            Button(action: {
                onComplete()
            }) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!microphoneAccess || !accessibilityAccess)
        }
        .padding(30)
        .frame(width: 480, height: 400)
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
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
