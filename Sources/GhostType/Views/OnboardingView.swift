import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices

struct OnboardingView: View {
    @State private var hasMicPermission = false
    @State private var hasAccessibilityPermission = false
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(spacing: 30) {
            Text("Welcome to GhostType")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("To start dictating like a ghost, we need a few permissions.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.title)
                        .foregroundColor(hasMicPermission ? .green : .red)
                        .frame(width: 40)

                    VStack(alignment: .leading) {
                        Text("Microphone Access")
                            .font(.headline)
                        Text("Required to hear your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !hasMicPermission {
                        Button("Grant") {
                            requestMicPermission()
                        }
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }

                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.title)
                        .foregroundColor(hasAccessibilityPermission ? .green : .red)
                        .frame(width: 40)

                    VStack(alignment: .leading) {
                        Text("Accessibility Access")
                            .font(.headline)
                        Text("Required to type text into your apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !hasAccessibilityPermission {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)

            Button("Start Using GhostType") {
                presentationMode.wrappedValue.dismiss()
            }
            .disabled(!hasMicPermission || !hasAccessibilityPermission)
            .padding()
        }
        .padding()
        .frame(width: 500, height: 400)
        .onAppear {
            checkPermissions()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        // Mic
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

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
