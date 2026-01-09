import SwiftUI
import AppKit

class OverlayWindowManager {
    var window: NSPanel?
    var hostingController: NSHostingController<GhostPill>?

    init() {
        let ghostPill = GhostPill()
        hostingController = NSHostingController(rootView: ghostPill)

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window?.backgroundColor = .clear
        window?.level = .floating
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.contentViewController = hostingController
        window?.isOpaque = false
    }

    func showWindow() {
        window?.orderFrontRegardless()
        updatePosition()
    }

    func updatePosition() {
        // In real app, we get cursor position.
        // For now, center of screen or fixed position
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window?.setFrameOrigin(NSPoint(x: frame.midX - 100, y: frame.midY))
        }
    }

    func updateText(_ text: String, isFinal: Bool) {
        // Update SwiftUI view
        // Ideally we use an ObservableObject for the view model
        hostingController?.rootView = GhostPill(text: text, isFinal: isFinal, isListening: true)
    }
}
