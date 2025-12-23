import SwiftUI
import AVFoundation
import ApplicationServices

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var micAuthorized = false
    @State private var accessibilityAuthorized = false

    // Timer for checking accessibility polling
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 30) {
            Text("GhostType Setup")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("GhostType needs a few permissions to work its magic.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 20) {
                // Microphone
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .frame(width: 40)

                    VStack(alignment: .leading) {
                        Text("Microphone")
                            .font(.headline)
                        Text("To hear your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if micAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                    } else {
                        Button("Allow") {
                            requestMicPermission()
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)

                // Accessibility
                HStack {
                    Image(systemName: "keyboard.fill")
                        .font(.title2)
                        .frame(width: 40)

                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .font(.headline)
                        Text("To type into your apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if accessibilityAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                    } else {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            }
            .padding(.horizontal)

            Button(action: onComplete) {
                Text("Start Dictating")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isReady ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(!isReady)
        }
        .padding()
        .frame(width: 400, height: 400)
        .onAppear {
            checkPermissions()
        }
        .onReceive(timer) { _ in
            checkPermissions()
        }
    }

    var isReady: Bool {
        return micAuthorized && accessibilityAuthorized
    }

    func checkPermissions() {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
