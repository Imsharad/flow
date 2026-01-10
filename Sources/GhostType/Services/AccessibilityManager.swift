import Cocoa
import ApplicationServices

class AccessibilityManager {
    func getFocusedElementPosition() -> CGPoint? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let element = focusedElement {
            let axElement = element as! AXUIElement
            var positionValue: AnyObject?
            let posResult = AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue)

            if posResult == .success, let value = positionValue {
                var point = CGPoint.zero
                AXValueGetValue(value as! AXValue, .cgPoint, &point)
                return point
            }
        }
        return nil
    }

    /// Attempts to compute the caret rect (global screen coordinates) for the focused element.
    /// This is generally more accurate than `kAXPositionAttribute` for text editors.
    func getFocusedCaretRect() -> CGRect? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let focusResult = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return nil }
        let axElement = element as! AXUIElement

        // Get selected range (caret is typically a zero-length range).
        var selectedRangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)
        guard rangeResult == .success, let anyValue = selectedRangeValue else { return nil }
        // Some apps can return unexpected types; avoid crashing.
        guard CFGetTypeID(anyValue) == AXValueGetTypeID() else { return nil }
        let rangeAXValue = anyValue as! AXValue

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeAXValue, .cfRange, &range) else { return nil }

        // Collapse selection to the end so we get an insertion caret.
        let caretLocation = range.location + max(range.length, 0)
        var caretRange = CFRange(location: caretLocation, length: 0)
        guard let caretRangeAXValue = AXValueCreate(.cfRange, &caretRange) else { return nil }

        // Ask for bounds for that range.
        var boundsValue: AnyObject?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            axElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            caretRangeAXValue,
            &boundsValue
        )
        guard boundsResult == .success, let anyBounds = boundsValue else { return nil }
        guard CFGetTypeID(anyBounds) == AXValueGetTypeID() else { return nil }
        let boundsAXValue = anyBounds as! AXValue

        var rect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    // MARK: - Context Capture

    func getActiveWindowContext() -> (appName: String, windowTitle: String)? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let element = focusedElement else { return nil }
        let axElement = element as! AXUIElement

        // 1. Get PID and App Name
        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName else { return nil }

        // 2. Walk up to the window to get the title
        var currentElement = axElement
        var windowTitle = ""

        // Safety: Limit depth to avoid infinite loops
        for _ in 0..<10 {
            var roleValue: AnyObject?
            AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &roleValue)

            if let role = roleValue as? String, role == kAXWindowRole {
                var titleValue: AnyObject?
                AXUIElementCopyAttributeValue(currentElement, kAXTitleAttribute as CFString, &titleValue)
                if let title = titleValue as? String {
                    windowTitle = title
                }
                break
            }

            var parentValue: AnyObject?
            let parentResult = AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentValue)
            if parentResult == .success, let parent = parentValue {
                currentElement = parent as! AXUIElement
            } else {
                break
            }
        }

        return (appName, windowTitle)
    }

    func insertText(_ text: String) {
        print("TRANSCRIPTION_TEXT: \(text)")
        
        // 1. Try Accessibility API with Verification
        if tryInsertAX(text) {
            return
        }
        
        // 2. Fallback to Pasteboard (Cmd+V) if AX fails or is unverified
        print("Text injection: AX failed or unverified, falling back to pasteboard")
        insertViaPasteboard(text)
    }

    /// Tries to insert text via Accessibility API and verifies it was accepted.
    /// Returns true ONLY if the text was successfully set AND verified.
    private func tryInsertAX(_ text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard result == .success, let element = focusedElement else {
            print("AX Injection: No focused element found")
            return false
        }
        
        let axElement = element as! AXUIElement
        
        // DEBUG: Log focused element details
        var role: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        print("Target AX Role: \(role as? String ?? "unknown")")

        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)
        if let app = NSRunningApplication(processIdentifier: pid) {
            print("Target App: \(app.localizedName ?? "unknown") (PID: \(pid))")
        }

        // Step 1: Attempt to Set
        let paramError = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard paramError == .success else {
             print("AX Injection: Set Failed with error: \(paramError.rawValue)")
             return false
        }
        
        // Step 2: Verification (The "Jeff Dean" Check)
        // We read back the value immediately. If the app accepted it, it should be reflected.
        // Known Risk: If app auto-collapses selection immediately, this might fail (false positive for failure).
        // However, this is safer than a silent failure.
        var readValue: AnyObject?
        let readError = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &readValue)
        
        guard readError == .success, let readString = readValue as? String else {
            print("AX Injection: Verification Read Failed (Error: \(readError.rawValue)) - Assuming failure")
            return false
        }
        
        if readString == text {
            print("Text injection: AX Success (Verified)")
            return true
        } else {
            print("AX Injection: Silent Failure Detected! (Read: '\(readString.prefix(20))...', Expected: '\(text.prefix(20))...')")
            return false
        }
    }
    
    private func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Trigger Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9 // 'v'
        
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        cmdUp?.flags = .maskCommand
        
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        
        // Small delay to ensure paste happens before we might (optionally) restore clipboard
        // For now, we leave it dirty to ensure it works.
        print("Text injection: Pasteboard falling back triggered")
    }
}
