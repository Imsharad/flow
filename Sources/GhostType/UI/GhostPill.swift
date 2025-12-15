import SwiftUI

struct GhostPill: View {
    @State private var phase = 0.0
    var isListening: Bool
    var text: String

    var body: some View {
        HStack {
            if isListening {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .scaleEffect(1 + CGFloat(sin(phase)) * 0.2)
                    .onAppear {
                        withAnimation(Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            phase = .pi
                        }
                    }
            } else {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 8, height: 8)
            }

            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.8))
        .cornerRadius(16)
        .shadow(radius: 4)
    }
}
