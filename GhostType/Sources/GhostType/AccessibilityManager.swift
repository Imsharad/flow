import ApplicationServices
import Carbon

class AccessibilityManager {
    func injectText(_ text: String) {
        // Method 1: AXUIElement (Primary)
        if let systemWide = AXUIElementCreateSystemWide() as AXUIElement? {
            var focusedElement: AnyObject?
            let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

            if result == .success, let focusedElement = focusedElement {
                let element = focusedElement as! AXUIElement
                var selectedTextValue: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextValue)

                // Try to set value
                // Note: Setting kAXSelectedTextAttribute usually replaces selection or inserts at cursor
                let setWithError = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)

                if setWithError != .success {
                    // Fallback to Pasteboard
                    injectTextViaPasteboard(text)
                }
            } else {
                injectTextViaPasteboard(text)
            }
        }
    }

    func injectTextViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore pasteboard after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let oldString = oldString {
                pasteboard.clearContents()
                pasteboard.setString(oldString, forType: .string)
            }
        }
    }

    func getCursorPosition() -> CGPoint? {
        // Implementation for getting cursor position via AX
        return nil
    }
}
