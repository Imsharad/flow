import SwiftUI
import AVFoundation
import AppKit

struct OnboardingView: View {
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var axStatus: Bool = false

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "ghost.circle.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(.purple)

            Text("Welcome to GhostType")
                .font(.largeTitle)
                .bold()

            Text("To start dictating, GhostType needs a few permissions.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 20) {
                // Microphone Step
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .frame(width: 30)

                    VStack(alignment: .leading) {
                        Text("Microphone Access")
                            .font(.headline)
                        Text("Required to hear your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if micStatus == .authorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Grant") {
                            requestMicPermission()
                        }
                    }
                }

                Divider()

                // Accessibility Step
                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.title2)
                        .frame(width: 30)

                    VStack(alignment: .leading) {
                        Text("Accessibility Access")
                            .font(.headline)
                        Text("Required to type text into other apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if axStatus {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Open Settings") {
                            openAXSettings()
                        }
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .padding(.horizontal)

            Button("Start GhostType") {
                onComplete()
            }
            .disabled(micStatus != .authorized || !axStatus)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(width: 500, height: 500)
        .onAppear {
            checkPermissions()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        axStatus = AXIsProcessTrusted()
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                self.checkPermissions()
            }
        }
    }

    private func openAXSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
