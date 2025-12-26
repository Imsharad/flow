import Cocoa
import ApplicationServices

/// Captures context from the active window to assist transcription.
class ContextManager {
    static let shared = ContextManager()

    private init() {}

    struct WindowContext {
        let appName: String
        let windowTitle: String
        let bundleIdentifier: String
    }

    func getActiveWindowContext() -> WindowContext? {
        // 1. Get the frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appName = frontApp.localizedName ?? "Unknown App"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // 2. Try to get window title via Accessibility API
        var windowTitle = ""

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedWindow: AnyObject?

        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        if result == .success, let window = focusedWindow {
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success {
                windowTitle = title as? String ?? ""
            }
        }

        print("ContextManager: Captured context - App: \(appName), Title: \(windowTitle)")

        return WindowContext(appName: appName, windowTitle: windowTitle, bundleIdentifier: bundleID)
    }

    /// Generates a prompt string for the transcription model based on context.
    func generateContextPrompt() -> String {
        guard let context = getActiveWindowContext() else {
            return ""
        }

        // Simple prompt engineering
        // "I am writing in {App} about {Title}."
        var prompt = "I am using \(context.appName)."
        if !context.windowTitle.isEmpty {
            prompt += " The window title is \"\(context.windowTitle)\"."
        }
        return prompt
    }
}
