import SwiftUI
import AVFoundation
import ApplicationServices

struct OnboardingView: View {
    var onComplete: () -> Void
    @State private var currentPage = 0

    var body: some View {
        VStack {
            if currentPage == 0 {
                WelcomeSlide(next: { currentPage += 1 })
            } else if currentPage == 1 {
                PermissionsSlide(next: { currentPage += 1 })
            } else {
                ReadySlide(onComplete: onComplete)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}

struct WelcomeSlide: View {
    var next: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "ghost.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundColor(.blue)

            Text("Welcome to GhostType")
                .font(.largeTitle)
                .bold()

            Text("Your AI-powered ghostwriter for macOS.\nDictate anywhere with high accuracy.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer()

            Button("Get Started") { next() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }
}

struct PermissionsSlide: View {
    var next: () -> Void
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityStatus = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 20) {
            Text("Permissions")
                .font(.title)
                .bold()

            Text("GhostType needs access to your microphone to hear you, and accessibility features to type for you.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.bottom)

            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Image(systemName: "mic.fill")
                        .frame(width: 24)
                    Text("Microphone")
                    Spacer()
                    if micStatus == .authorized {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in
                                DispatchQueue.main.async {
                                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Image(systemName: "hand.raised.fill")
                        .frame(width: 24)
                    Text("Accessibility")
                    Spacer()
                    if accessibilityStatus {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(options)

                            // Poll for change
                            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                                if AXIsProcessTrusted() {
                                    accessibilityStatus = true
                                    timer.invalidate()
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            Spacer()

            Button("Continue") { next() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(micStatus != .authorized)
        }
        .padding()
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityStatus = AXIsProcessTrusted()
        }
    }
}

struct ReadySlide: View {
    var onComplete: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundColor(.green)

            Text("All Set!")
                .font(.largeTitle)
                .bold()

            Text("Hold the Right Option (⌥) key to start dictating.\nRelease to stop.")
                .multilineTextAlignment(.center)
                .font(.title3)
                .padding()

            Spacer()

            Button("Start Using GhostType") { onComplete() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }
}
