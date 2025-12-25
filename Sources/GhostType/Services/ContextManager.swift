import Cocoa
import ApplicationServices

struct AppContext: Sendable {
    let appName: String
    let bundleId: String
    let windowTitle: String?
}

class ContextManager {
    static let shared = ContextManager()

    private init() {}

    func getActiveContext() -> AppContext? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appName = frontApp.localizedName ?? "Unknown App"
        let bundleId = frontApp.bundleIdentifier ?? "unknown.bundle.id"
        var windowTitle: String?

        // Use AX API to get window title
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        if result == .success, let window = focusedWindow {
            let axWindow = window as! AXUIElement
            var titleValue: AnyObject?
            let titleResult = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)

            if titleResult == .success, let title = titleValue as? String {
                windowTitle = title
            }
        }

        return AppContext(appName: appName, bundleId: bundleId, windowTitle: windowTitle)
    }
}
