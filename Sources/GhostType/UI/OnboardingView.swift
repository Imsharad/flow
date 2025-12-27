import SwiftUI

struct OnboardingView: View {
    @StateObject private var permissions = PermissionsManager.shared
    @Binding var isCompleted: Bool

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "ghost.fill")
                .font(.system(size: 60))
                .foregroundColor(.white)
                .shadow(color: .cyan, radius: 10)

            Text("Welcome to GhostType")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("To work its magic, GhostType needs a few permissions.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 20) {
                // 1. Microphone
                HStack {
                    Image(systemName: "mic.fill")
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text("Microphone")
                            .fontWeight(.semibold)
                        Text("To hear your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if permissions.micStatus == .authorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            permissions.requestMicPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                // 2. Accessibility
                HStack {
                    Image(systemName: "hand.point.up.left.fill")
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .fontWeight(.semibold)
                        Text("To type text for you.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if permissions.accessibilityStatus {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Allow") {
                            permissions.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            Button("Start Dictating") {
                isCompleted = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(permissions.micStatus != .authorized || !permissions.accessibilityStatus)
        }
        .padding(40)
        .frame(width: 500, height: 600)
    }
}
