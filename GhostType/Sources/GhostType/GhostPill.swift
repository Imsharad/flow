import SwiftUI

struct GhostPill: View {
    @State var text: String = ""
    @State var isFinal: Bool = false
    @State var isListening: Bool = false

    var body: some View {
        HStack {
            Image(systemName: isListening ? "waveform.circle.fill" : "mic.circle.fill")
                .symbolEffect(.pulse, isActive: isListening)
                .foregroundStyle(.blue)

            Text(text.isEmpty ? "Listening..." : text)
                .foregroundStyle(isFinal ? .primary : .secondary)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .italic(!isFinal)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 4)
    }
}
