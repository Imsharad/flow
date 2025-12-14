import SwiftUI

class AppState: ObservableObject {
    @Published var ghostPillState: GhostPill.GhostState = .idle
    @Published var transcribedText: String = ""
}

struct GhostPill: View {
    @ObservedObject var appState: AppState
    @State private var isPulsing = false

    enum GhostState {
        case idle
        case listening
        case processing
    }

    var body: some View {
        HStack(spacing: 8) {
            // Indicator Icon
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 1.2 : 1.0)
                .animation(appState.ghostPillState == .listening ? Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: isPulsing)

            // Text Preview
            if !appState.transcribedText.isEmpty {
                Text(appState.transcribedText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.8))
        .cornerRadius(20)
        .shadow(radius: 4)
        .onChange(of: appState.ghostPillState) { newState in
            isPulsing = (newState == .listening)
        }
    }

    var stateColor: Color {
        switch appState.ghostPillState {
        case .idle: return .gray
        case .listening: return .red
        case .processing: return .blue
        }
    }
}
