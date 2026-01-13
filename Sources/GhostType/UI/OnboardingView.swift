import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    // Permission States
    @State private var accessibilityStatus: Bool = false
    @State private var micStatus: Bool = false

    var body: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 10) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 80, height: 80)
                Text("Welcome to GhostType")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Let's get you set up.")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)

            // Steps
            VStack(alignment: .leading, spacing: 20) {
                // Step 1: Accessibility
                HStack {
                    Image(systemName: accessibilityStatus ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(accessibilityStatus ? .green : .secondary)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("Enable Accessibility")
                            .font(.headline)
                        Text("Required to type text into other apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !accessibilityStatus {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)

                // Step 2: Microphone
                HStack {
                    Image(systemName: micStatus ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(micStatus ? .green : .secondary)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("Microphone Access")
                            .font(.headline)
                        Text("Required to hear your dictation.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if !micStatus {
                        Button("Allow Access") {
                            requestMicAccess()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
            .padding(.horizontal, 40)

            Spacer()

            // Footer
            Button("Start Typing") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!accessibilityStatus || !micStatus)
            .padding(.bottom, 40)
        }
        .frame(width: 500, height: 600)
        .onAppear {
            checkPermissions()
            // Poll for changes (especially Accessibility which changes externally)
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                checkPermissions()
            }
        }
    }

    private func checkPermissions() {
        // Check Accessibility
        accessibilityStatus = AXIsProcessTrusted()

        // Check Mic
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micStatus = (status == .authorized)
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)

        // Prompt system to ask (by trying to use it)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micStatus = granted
            }
        }
    }
}
