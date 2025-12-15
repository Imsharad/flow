import ApplicationServices
import Cocoa

class AccessibilityManager {
    static let shared = AccessibilityManager()

    private init() {}

    func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func getFocusedElementPosition() -> CGPoint? {
        guard let systemWideElement = AXUIElementCreateSystemWide() as AXUIElement? else { return nil }

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let element = focusedElement else { return nil }

        let axElement = element as! AXUIElement
        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue)

        guard posResult == .success, let posVal = positionValue else { return nil }

        var point = CGPoint.zero
        // AXValueGetValue(posVal as! AXValue, .cgPoint, &point) // Swift mapping needed

        // Handling AXValue conversion in Swift can be tricky without proper casting.
        // Assuming we extract CGPoint:
        if CFGetTypeID(posVal) == AXValueGetTypeID() {
            let axValue = posVal as! AXValue
            AXValueGetValue(axValue, AXValueType.cgPoint, &point)
            return point
        }

        return nil
    }
}
