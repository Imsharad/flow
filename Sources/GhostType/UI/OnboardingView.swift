import SwiftUI
import AVFoundation
import ApplicationServices

struct OnboardingView: View {
    @Binding var isPresented: Bool

    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var axStatus: Bool = false

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "ghost.fill")
                .font(.system(size: 60))
                .foregroundColor(.white)
                .shadow(color: .purple.opacity(0.5), radius: 10, x: 0, y: 0)

            Text("Welcome to GhostType")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("To start typing with your voice, GhostType needs a few permissions.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.gray)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 20) {
                // Microphone Step
                HStack {
                    Image(systemName: "mic.fill")
                        .frame(width: 30)
                        .foregroundColor(micStatus == .authorized ? .green : .orange)

                    VStack(alignment: .leading) {
                        Text("Microphone Access")
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
                            requestMicPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Divider()

                // Accessibility Step
                HStack {
                    Image(systemName: "keyboard.fill")
                        .frame(width: 30)
                        .foregroundColor(axStatus ? .green : .orange)

                    VStack(alignment: .leading) {
                        Text("Accessibility Access")
                            .font(.headline)
                        Text("Required to type text into other apps.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    if axStatus {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Open Settings") {
                            requestAxPermission()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .background(Color.black.opacity(0.2))
            .cornerRadius(12)

            Button("Get Started") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(micStatus != .authorized || !axStatus)
        }
        .padding(40)
        .frame(width: 500)
        .onAppear {
            checkPermissions()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
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

    private func requestAxPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
