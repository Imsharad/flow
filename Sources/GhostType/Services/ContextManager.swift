import Cocoa
import ApplicationServices

struct ActiveContext: Sendable {
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String?

    var promptDescription: String {
        var desc = "User is typing in \(appName)"
        if let title = windowTitle, !title.isEmpty {
            desc += " (Window: \(title))"
        }
        desc += "."
        return desc
    }
}

actor ContextManager {
    static let shared = ContextManager()

    func getCurrentContext() async -> ActiveContext? {
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        guard let app = frontmost else { return nil }

        let appName = app.localizedName ?? "Unknown App"
        let bundleID = app.bundleIdentifier ?? ""

        // AX calls can be slow/blocking, so running in this actor (bg thread) is good.
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowTitle: String? = nil

        // 1. Get Focused Window
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        if result == .success, let window = focusedWindow {
            let windowElement = window as! AXUIElement

            // 2. Get Window Title
            var title: AnyObject?
            let titleResult = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title)
            if titleResult == .success, let titleStr = title as? String {
                windowTitle = titleStr
            }
        }

        return ActiveContext(appName: appName, bundleIdentifier: bundleID, windowTitle: windowTitle)
    }
}
