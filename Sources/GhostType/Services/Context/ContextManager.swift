import Cocoa
import ApplicationServices

struct WindowContext: Sendable {
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String

    var description: String {
        return "App: \(appName), Window: \(windowTitle)"
    }
}

actor ContextManager {

    func getCurrentContext() async -> WindowContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appName = app.localizedName ?? "Unknown App"
        let bundleId = app.bundleIdentifier ?? ""
        let windowTitle = getWindowTitle(pid: app.processIdentifier)

        return WindowContext(
            appName: appName,
            bundleIdentifier: bundleId,
            windowTitle: windowTitle
        )
    }

    private func getWindowTitle(pid: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: AnyObject?

        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        guard result == .success, let window = focusedWindow else {
            return ""
        }

        var title: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &title
        )

        if titleResult == .success, let titleString = title as? String {
            return titleString
        }

        return ""
    }
}
