import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation

struct OnboardingView: View {
    @State private var currentPage = 0
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    // Permission States
    @State private var micPermission: PermissionStatus = .unknown
    @State private var accessibilityPermission: PermissionStatus = .unknown

    enum PermissionStatus {
        case unknown
        case granted
        case denied
    }

    var body: some View {
        VStack {
            if currentPage == 0 {
                WelcomeSlide(nextAction: { currentPage += 1 })
            } else if currentPage == 1 {
                PermissionsSlide(
                    micPermission: $micPermission,
                    accessibilityPermission: $accessibilityPermission,
                    nextAction: { currentPage += 1 }
                )
            } else {
                CompletionSlide(finishAction: {
                    hasCompletedOnboarding = true
                    // Close window handled by App logic usually, or here
                    NSApp.windows.first(where: { $0.contentView is NSHostingView<OnboardingView> })?.close()
                })
            }
        }
        .frame(width: 600, height: 400)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
}

struct WelcomeSlide: View {
    var nextAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "ghost.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundColor(.white)

            Text("Welcome to GhostType")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("The invisible dictation assistant for macOS.\nType with your voice, anywhere.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)

            Spacer().frame(height: 20)

            Button("Get Started") {
                nextAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}

struct PermissionsSlide: View {
    @Binding var micPermission: OnboardingView.PermissionStatus
    @Binding var accessibilityPermission: OnboardingView.PermissionStatus
    var nextAction: () -> Void

    // Timer to check accessibility
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 30) {
            Text("Permissions")
                .font(.title)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 20) {
                // Microphone
                HStack {
                    Image(systemName: "mic.fill")
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text("Microphone")
                            .font(.headline)
                        Text("Required to hear your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if micPermission == .granted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Grant") {
                            requestMic()
                        }
                    }
                }

                Divider()

                // Accessibility
                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .font(.headline)
                        Text("Required to insert text into apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if accessibilityPermission == .granted {
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
            .background(Color.black.opacity(0.2))
            .cornerRadius(10)

            Button("Next") {
                nextAction()
            }
            .disabled(micPermission != .granted || accessibilityPermission != .granted)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .onAppear {
            checkPermissions()
        }
        .onReceive(timer) { _ in
            checkPermissions()
        }
    }

    func requestMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermission = .granted
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                micPermission = granted ? .granted : .denied
            }
        case .denied, .restricted:
            micPermission = .denied
        @unknown default:
            break
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func checkPermissions() {
        // Mic
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            micPermission = .granted
        }

        // Accessibility
        if AXIsProcessTrusted() {
            accessibilityPermission = .granted
        }
    }
}

struct CompletionSlide: View {
    var finishAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            VStack(spacing: 10) {
                Text("Hold the **Right Option** key to speak.")
                Text("Release to stop.")
                Text("GhostType will type for you.")
            }
            .font(.title3)
            .padding()

            Spacer().frame(height: 20)

            Button("Start Using GhostType") {
                finishAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}

// Helper for blur background
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
