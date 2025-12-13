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
}
