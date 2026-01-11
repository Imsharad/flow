import Cocoa
import ApplicationServices

class AccessibilityManager {
    func getFocusedElementPosition() -> CGPoint? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let element = focusedElement {
            // Safe cast
            let axElement = element as! AXUIElement
            // Note: AXUIElement is a CFTypeRef, usually bridged to AnyObject.
            // In Swift, casting CFTypeRef to specific CF type is standard if we know the API returns it.
            // However, `focusedElement` is returned as `AnyObject?` from `AXUIElementCopyAttributeValue`.
            // The underlying type IS AXUIElement.

            var positionValue: AnyObject?
            let posResult = AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue)

            if posResult == .success, let value = positionValue {
                var point = CGPoint.zero
                // Safe checking of AXValue type not strictly needed if we trust the attribute,
                // but checking success is good.
                if CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(value as! AXValue, .cgPoint, &point)
                    return point
                }
            }
        }
        return nil
    }

    /// Attempts to compute the caret rect (global screen coordinates) for the focused element.
    func getFocusedCaretRect() -> CGRect? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let focusResult = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return nil }

        // Although `as! AXUIElement` is usually safe here because accessibility APIs return AXUIElementRef,
        // we can't conditionally cast to CF types easily in Swift without bridging.
        // But let's assume standard behavior.
        let axElement = element as! AXUIElement

        // Get selected range
        var selectedRangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)
        guard rangeResult == .success, let anyValue = selectedRangeValue else { return nil }

        if CFGetTypeID(anyValue) != AXValueGetTypeID() { return nil }
        let rangeAXValue = anyValue as! AXValue

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeAXValue, .cfRange, &range) else { return nil }

        // Collapse selection to the end
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
        if CFGetTypeID(anyBounds) != AXValueGetTypeID() { return nil }
        let boundsAXValue = anyBounds as! AXValue

        var rect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Retrieves the title of the active window and the name of the application.
    func getActiveWindowContext() -> (appName: String, windowTitle: String)? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        // 1. Get Focused Element
        var result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement else { return nil }
        let axElement = element as! AXUIElement

        // 2. Get Window (Parent of element)
        var windowElement: AnyObject?
        result = AXUIElementCopyAttributeValue(axElement, kAXWindowAttribute as CFString, &windowElement)

        guard let finalWindow = windowElement else { return nil }
        let axWindow = finalWindow as! AXUIElement

        // 3. Get Window Title
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
        let windowTitle = titleValue as? String ?? ""

        // 4. Get App Name (PID)
        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown App"

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

    private func tryInsertAX(_ text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard result == .success, let element = focusedElement else {
            print("AX Injection: No focused element found")
            return false
        }
        
        let axElement = element as! AXUIElement
        
        // Step 1: Attempt to Set
        let paramError = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard paramError == .success else {
             print("AX Injection: Set Failed with error: \(paramError.rawValue)")
             return false
        }
        
        // Step 2: Verification
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
    }
}
