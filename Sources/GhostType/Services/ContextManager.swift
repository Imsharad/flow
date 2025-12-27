import Cocoa
import ApplicationServices

/// Captures the active window context to assist transcription.
class ContextManager {
    static let shared = ContextManager()

    private init() {}

    struct WindowContext {
        let appName: String
        let bundleIdentifier: String
        let windowTitle: String
    }

    func getCurrentContext() -> WindowContext? {
        // 1. Get frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appName = frontApp.localizedName ?? "Unknown App"
        let bundleID = frontApp.bundleIdentifier ?? "unknown.bundle.id"

        // 2. Get AXUIElement for the app
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // 3. Get focused window
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        var windowTitle = ""

        if result == .success, let window = focusedWindow {
            let axWindow = window as! AXUIElement
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title) == .success {
                windowTitle = title as? String ?? ""
            }
        }

        // print("ContextManager: Captured Context - App: \(appName), Title: \(windowTitle)")

        return WindowContext(appName: appName, bundleIdentifier: bundleID, windowTitle: windowTitle)
    }

    func getContextPrompt() -> String {
        guard let context = getCurrentContext() else { return "" }

        // Format a prompt string suitable for Whisper
        // "I am working in [App Name] on a window titled [Title]."
        var prompt = "I am using \(context.appName)."
        if !context.windowTitle.isEmpty {
            prompt += " The active window is titled \"\(context.windowTitle)\"."
        }
        return prompt
    }
}
