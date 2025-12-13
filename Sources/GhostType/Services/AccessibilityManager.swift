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
}
