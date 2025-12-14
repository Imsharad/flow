import Cocoa
import ApplicationServices

class TextInjector {

    func inject(text: String) {
        // 1. Try Accessibility Injection first
        if injectViaAccessibility(text: text) {
            print("[Injector] Injected via Accessibility")
            return
        }

        // 2. Fallback to Pasteboard
        print("[Injector] Falling back to Pasteboard")
        injectViaPasteboard(text: text)
    }

    private func injectViaAccessibility(text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let element = focusedElement else { return false }
        let axElement = element as! AXUIElement

        // Try setting selected text attribute (inserts at cursor)
        let error = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return error == .success
    }

    private func injectViaPasteboard(text: String) {
        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePasteCommand()

        // Restore pasteboard (delayed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let old = oldString {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }

    private func simulatePasteCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        let kVK_ANSI_V: CGKeyCode = 0x09
        let cmdKey: CGEventFlags = .maskCommand

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true)
        keyDown?.flags = cmdKey
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false)
        keyUp?.flags = cmdKey

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
