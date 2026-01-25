import Cocoa
import SwiftUI

class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show(manager: TranscriptionManager) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = MenuBarSettings(manager: manager)
        let hostingView = NSHostingView(rootView: settingsView)

        // Create window with appropriate size (auto-size from content if possible, but hardcoded safety)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "GhostType Settings"
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.isReleasedWhenClosed = false

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Temporarily show in Dock
        NSApp.setActivationPolicy(.regular)

        // Observe window close to reset policy
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: newWindow)
    }

    @objc private func windowWillClose() {
        NSApp.setActivationPolicy(.accessory)
        self.window = nil
    }
}
