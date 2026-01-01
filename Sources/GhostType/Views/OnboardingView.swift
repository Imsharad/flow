import SwiftUI
import AppKit
import AVFoundation

struct OnboardingView: View {
    @State private var hasMicPermission = false
    @State private var hasAccessibilityPermission = false

    // Callback to notify parent (AppDelegate) to close the window
    var onComplete: (() -> Void)?

    // Check permissions on appear
    private func checkPermissions() {
        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicPermission = true
        default:
            hasMicPermission = false
        }

        // Accessibility
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.hasMicPermission = granted
            }
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if trusted {
             self.hasAccessibilityPermission = true
        }
        // If not trusted, the system prompt will appear.
        // We can poll or wait for user to click "Done" in a real flow, but for now we'll just check again on refresh.
    }

    var body: some View {
        VStack(spacing: 30) {
            Text("Welcome to GhostType")
                .font(.system(size: 32, weight: .bold))
                .padding(.top, 40)

            Text("To provide magical dictation, GhostType needs a few permissions.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 20) {
                // Microphone Step
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundColor(hasMicPermission ? .green : .orange)
                        .frame(width: 40)

                    VStack(alignment: .leading) {
                        Text("Microphone Access")
                            .font(.headline)
                        Text("Required to hear your voice.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    if hasMicPermission {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            requestMicPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                // Accessibility Step
                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.title2)
                        .foregroundColor(hasAccessibilityPermission ? .green : .orange)
                        .frame(width: 40)

                    VStack(alignment: .leading) {
                        Text("Accessibility Access")
                            .font(.headline)
                        Text("Required to type text into other apps.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    if hasAccessibilityPermission {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Open Settings") {
                            requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(30)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(12)
            .padding(.horizontal)

            Spacer()

            if hasMicPermission && hasAccessibilityPermission {
                Button("Start GhostType") {
                     // Notify AppDelegate to close window and start app
                     onComplete?()
                }
                .font(.headline)
                .padding()
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
            } else {
                Text("Please grant all permissions to continue.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.bottom, 40)
            }
        }
        .frame(width: 500, height: 600)
        .onAppear {
            checkPermissions()

            // Poll for changes (esp Accessibility)
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                checkPermissions()
            }
        }
    }
}
