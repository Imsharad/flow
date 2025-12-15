import ApplicationServices
import Cocoa

class TextInjector {
    static let shared = TextInjector()

    private init() {}

    func insertText(_ text: String) {
        // Primary Method: AXUIElementSetAttributeValue
        if !injectViaAccessibility(text) {
             // Fallback Method: Pasteboard
             injectViaPasteboard(text)
        }
    }

    private func injectViaAccessibility(_ text: String) -> Bool {
        guard let systemWideElement = AXUIElementCreateSystemWide() as AXUIElement? else { return false }

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let element = focusedElement else { return false }

        let axElement = element as! AXUIElement

        // Try to set selected text (inserts at cursor)
        let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)

        return setResult == .success
    }

    private func injectViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true) // Cmd
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        cmdDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        cmdUp?.flags = .maskCommand // keep flags for cmd up? usually cleared after.

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        // Restore pasteboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let old = oldString {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }
}
