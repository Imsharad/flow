import Cocoa
import SwiftUI

class OverlayWindow: NSPanel {
    init(view: AnyView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.contentView = NSHostingView(rootView: view)
        self.ignoresMouseEvents = true // Let clicks pass through if needed, or false if we want interactions
    }

    func updatePosition(to point: CGPoint) {
        self.setFrameOrigin(point)
    }
}
