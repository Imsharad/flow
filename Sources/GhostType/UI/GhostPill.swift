import SwiftUI
import AppKit

struct GhostPill: View {
    @ObservedObject var state: GhostPillState

    var body: some View {
        HStack {
            if state.isListening {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .scaleEffect(state.isProcessing ? 1.2 : 1.0)
                    .animation(Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: state.isProcessing)
            } else {
                Image(systemName: "mic.slash")
                    .foregroundColor(.gray)
            }

            Group {
                if state.isProvisional {
                    Text(state.text).italic()
                } else {
                    Text(state.text)
                }
            }
            .font(.system(size: 14))
            .foregroundColor(state.isProcessing || state.isProvisional ? .gray : .primary)
            .lineLimit(1)
        }
        .padding(8)
        .background(VisualEffectView(material: .hud, blendingMode: .behindWindow))
        .cornerRadius(20)
        .shadow(radius: 5)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
