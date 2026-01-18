import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation

struct OnboardingView: View {
    @State private var microphoneAccess = false
    @State private var accessibilityAccess = false
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .frame(width: 64, height: 64)
                .foregroundColor(.blue)
                .padding(.top, 20)

            Text("Welcome to GhostType")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("To start dictating, GhostType needs a few permissions.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 16) {
                // Microphone
                HStack {
                    Image(systemName: "mic.fill")
                        .frame(width: 24)
                        .foregroundColor(.blue)

                    VStack(alignment: .leading) {
                        Text("Microphone Access")
                            .font(.headline)
                        Text("Required to hear your voice.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    if microphoneAccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            requestMicrophoneAccess()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)

                // Accessibility
                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .frame(width: 24)
                        .foregroundColor(.blue)

                    VStack(alignment: .leading) {
                        Text("Accessibility Access")
                            .font(.headline)
                        Text("Required to type text into apps.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    if accessibilityAccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
            .padding(.horizontal)

            Spacer()

            Button(action: {
                onComplete()
            }) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!microphoneAccess || !accessibilityAccess)
            .padding(.bottom, 20)
            .padding(.horizontal)
        }
        .frame(width: 450, height: 500)
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
