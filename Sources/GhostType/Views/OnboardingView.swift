import SwiftUI

struct OnboardingView: View {
    @State private var micStatus: PermissionsManager.PermissionStatus = .notDetermined
    @State private var axStatus: PermissionsManager.PermissionStatus = .denied

    var onComplete: () -> Void

    private let permissions = PermissionsManager.shared

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .frame(width: 64, height: 64)
                .foregroundColor(.blue)

            Text("Welcome to GhostType")
                .font(.title)
                .fontWeight(.bold)

            Text("To provide seamless voice typing, GhostType needs a few permissions.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 20) {
                // Microphone
                HStack {
                    Image(systemName: "mic.fill")
                        .frame(width: 24)
                        .foregroundColor(micStatus == .authorized ? .green : .primary)

                    VStack(alignment: .leading) {
                        Text("Microphone")
                            .fontWeight(.semibold)
                        Text("To listen to your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    if micStatus == .authorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            permissions.requestMicrophone { granted in
                                micStatus = granted ? .authorized : .denied
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(micStatus != .notDetermined)
                    }
                }

                // Accessibility
                HStack {
                    Image(systemName: "keyboard.fill")
                        .frame(width: 24)
                        .foregroundColor(axStatus == .authorized ? .green : .primary)

                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .fontWeight(.semibold)
                        Text("To type text into other apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    if axStatus == .authorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button(axStatus == .denied ? "Open Settings" : "Allow") {
                            permissions.requestAccessibility()
                            // Poll for change or wait for user to come back
                            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                                if permissions.accessibilityStatus == .authorized {
                                    axStatus = .authorized
                                    timer.invalidate()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
            .padding(.horizontal)

            Button("Get Started") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(micStatus != .authorized || axStatus != .authorized)
        }
        .padding()
        .onAppear {
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        micStatus = permissions.microphoneStatus
        axStatus = permissions.accessibilityStatus
    }
}
