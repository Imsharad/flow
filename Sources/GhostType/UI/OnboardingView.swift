import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation

struct OnboardingView: View {
    @StateObject private var permissionsManager = PermissionsManager.shared
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to GhostType")
                .font(.largeTitle)

            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: permissionsManager.microphoneAccess ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(permissionsManager.microphoneAccess ? .green : .gray)
                    Text("Microphone Access")
                    Spacer()
                    if !permissionsManager.microphoneAccess {
                        Button("Request") {
                            permissionsManager.requestMicrophoneAccess()
                        }
                    }
                }

                HStack {
                    Image(systemName: permissionsManager.accessibilityAccess ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(permissionsManager.accessibilityAccess ? .green : .gray)
                    Text("Accessibility Access")
                    Spacer()
                    if !permissionsManager.accessibilityAccess {
                        Button("Open Settings") {
                            permissionsManager.requestAccessibilityAccess()
                        }
                    }
                }
            }
            .padding()

            Button("Get Started") {
                onComplete()
            }
            .disabled(!permissionsManager.microphoneAccess || !permissionsManager.accessibilityAccess)
        }
        .padding()
        .frame(width: 400, height: 300)
        .onAppear {
            permissionsManager.checkCurrentPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionsManager.checkCurrentPermissions()
        }
    }
}
