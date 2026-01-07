import SwiftUI
import AVFoundation

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var accessibilityStatus: Bool = false

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "waveform.circle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))

            Text("Welcome to GhostType")
                .font(.title)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 20) {
                // Microphone Permission
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .frame(width: 30)

                    VStack(alignment: .leading) {
                        Text("Microphone")
                            .font(.headline)
                        Text("Required to hear your voice.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    if micStatus == .authorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            requestMic()
                        }
                    }
                }

                // Accessibility Permission
                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.title2)
                        .frame(width: 30)

                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .font(.headline)
                        Text("Required to type text into apps.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    if accessibilityStatus {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)

            Button("Get Started") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(micStatus != .authorized || !accessibilityStatus)
        }
        .padding(40)
        .frame(width: 500, height: 500)
        .onAppear {
            checkPermissions()

            // Poll for accessibility changes
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                checkPermissions()
            }
        }
    }

    func checkPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityStatus = AXIsProcessTrusted()
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                checkPermissions()
            }
        }
    }

    func openAccessibilitySettings() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
        AXIsProcessTrustedWithOptions(options)
    }
}
