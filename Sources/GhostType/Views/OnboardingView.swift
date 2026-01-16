import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentStep = 0
    @State private var micAuthorized = false
    @State private var accessibilityAuthorized = false

    // Timer to poll permissions while window is open
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 20) {
            // Header Image or Icon
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(.accentColor)
                .padding(.top, 20)

            // Content based on step
            VStack(spacing: 16) {
                if currentStep == 0 {
                    welcomeStep
                } else if currentStep == 1 {
                    permissionsStep
                } else {
                    finalStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            // Footer Navigation
            HStack {
                if currentStep > 0 && currentStep < 2 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 20)
                }

                Spacer()

                if currentStep == 0 {
                    Button("Get Started") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.trailing, 20)
                } else if currentStep == 1 {
                    Button("Next") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!micAuthorized) // Mic is mandatory
                    .padding(.trailing, 20)
                } else {
                    Button("Start GhostType") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.trailing, 20)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 500, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            checkPermissions()
            // Poll permissions every second in case user changes them in System Settings
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                checkPermissions()
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    // MARK: - Steps

    var welcomeStep: some View {
        VStack(spacing: 12) {
            Text("Welcome to GhostType")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("A super-fast, local voice dictation tool for macOS.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "lock.shield", text: "100% Local & Private")
                FeatureRow(icon: "bolt.fill", text: "Lightning Fast (WhisperKit)")
                FeatureRow(icon: "keyboard", text: "Type Anywhere")
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 40)
    }

    var permissionsStep: some View {
        VStack(spacing: 24) {
            Text("Permissions")
                .font(.title2)
                .fontWeight(.bold)

            Text("GhostType needs access to your microphone to hear you, and accessibility features to type for you.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(spacing: 16) {
                // Microphone
                HStack {
                    Image(systemName: "mic.fill")
                        .frame(width: 24)
                        .foregroundColor(.blue)

                    VStack(alignment: .leading) {
                        Text("Microphone")
                            .font(.headline)
                        Text("Required for dictation")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if micAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            requestMicPermission()
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Accessibility
                HStack {
                    Image(systemName: "accessibility")
                        .frame(width: 24)
                        .foregroundColor(.purple)

                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .font(.headline)
                        Text("Required to insert text")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if accessibilityAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding(.horizontal, 30)
        }
    }

    var finalStep: some View {
        VStack(spacing: 20) {
            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)

            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(.green)

            Text("GhostType will run in your menu bar.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Tips:")
                    .font(.headline)
                Text("• Hold **Right Option (⌥)** to dictate.")
                Text("• Speak naturally.")
                Text("• Release to finish.")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Logic

    func checkPermissions() {
        // Check Mic
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = (status == .authorized)

        // Check Accessibility
        accessibilityAuthorized = AXIsProcessTrusted()
    }

    func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micAuthorized = granted
            }
        }
    }

    func openAccessibilitySettings() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
        AXIsProcessTrustedWithOptions(options)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
            Text(text)
        }
    }
}
