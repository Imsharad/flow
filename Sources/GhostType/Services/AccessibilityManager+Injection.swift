import Cocoa
import ApplicationServices

/// Text injection strategies - tiered fallback system for maximum app compatibility.
///
/// Architecture (from PRD):
/// - Tier 1: Accessibility API (AXUIElement) - fastest, most native
/// - Tier 2: Pasteboard + Cmd+V simulation - reliable fallback
/// - Tier 3: Direct keystroke simulation - for problematic apps (Electron)
extension AccessibilityManager {
    
    /// Known problematic bundle IDs that require special handling
    private static let electronApps: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.spotify.client",
        "com.notion.id",
        "com.figma.Desktop",
        "com.linear",
        "com.obsidian",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]
    
    /// Terminal apps that prefer direct keystroke injection over AX or Pasteboard
    private static let terminalApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
    ]
    
    /// Apps where AX insertion works but needs delays
    private static let slowAXApps: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
    ]
    
    // MARK: - Public API
    
    /// Insert text at the current cursor position using the best available method
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        
        // Detect current frontmost app
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier ?? ""
        let appName = frontmost?.localizedName ?? "Unknown"
        
        print("Text injection: Target App = '\(appName)' (\(bundleID))")
        
        // Route to appropriate injection method
        if Self.terminalApps.contains(bundleID) {
            // Terminals: Simulate typing (keystrokes)
            print("Text injection: Using keystroke simulation for Terminal app (\(bundleID))")
            insertTextViaKeystrokes(text)
        } else if Self.electronApps.contains(bundleID) {
            // Electron apps: Skip AX entirely, use pasteboard
            print("Text injection: Using pasteboard fallback for Electron app (\(bundleID))")
            insertTextViaPasteboard(text, transient: true)
        } else {
            // Try Accessibility first, then fall back
            if !tryAccessibilityInsertion(text, bundleID: bundleID) {
                print("Text injection: AX failed, falling back to pasteboard")
                insertTextViaPasteboard(text, transient: true)
            }
        }
    }
    
    // MARK: - Tier 1: Accessibility API
    
    private func tryAccessibilityInsertion(_ text: String, bundleID: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        
        guard result == .success, let element = focusedElement else {
            print("Text injection: No focused element found")
            return false
        }
        
        let axElement = element as! AXUIElement
        
        // Strategy 1: Try kAXSelectedTextAttribute (insertion at cursor)
        let selectedTextError = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        
        if selectedTextError == .success {
            print("Text injection: Succeeded via kAXSelectedTextAttribute")
            return true
        }
        
        // Strategy 2: Try kAXValueAttribute with existing text + appended
        var existingValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            &existingValue
        )
        
        if valueResult == .success,
           let currentText = existingValue as? String {
            // Get current selection to insert at correct position
            if let insertionPoint = getInsertionPoint(for: axElement) {
                let newText = String(currentText.prefix(insertionPoint)) + text + String(currentText.dropFirst(insertionPoint))
                let setResult = AXUIElementSetAttributeValue(
                    axElement,
                    kAXValueAttribute as CFString,
                    newText as CFTypeRef
                )
                
                if setResult == .success {
                    // Move cursor to end of inserted text
                    setSelectionRange(for: axElement, location: insertionPoint + text.count, length: 0)
                    print("Text injection: Succeeded via kAXValueAttribute at position \(insertionPoint)")
                    return true
                }
            }
        }
        
        print("Text injection: AX methods failed with errors: selectedText=\(selectedTextError.rawValue)")
        return false
    }
    
    private func getInsertionPoint(for element: AXUIElement) -> Int? {
        var rangeValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        
        guard result == .success,
              let anyValue = rangeValue,
              CFGetTypeID(anyValue) == AXValueGetTypeID() else {
            return nil
        }
        
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(anyValue as! AXValue, .cfRange, &range) else {
            return nil
        }
        
        // Return end of selection (or cursor position if no selection)
        return range.location + max(range.length, 0)
    }
    
    private func setSelectionRange(for element: AXUIElement, location: Int, length: Int) {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return }
        
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
    }
    
    // MARK: - Tier 2: Pasteboard + Keyboard Simulation
    
    private func insertTextViaPasteboard(_ text: String, transient: Bool) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Mark as transient to hide from clipboard managers (Maccy, Paste, etc.)
        // Standard convention: org.nspasteboard.TransientType
        if transient {
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        
        // Simulate Cmd+V with proper event sequencing
        simulatePaste()
        
        // Restore clipboard after paste is processed
        // Use longer delay for slower apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            snapshot.restore(into: pasteboard)
        }
    }
    
    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key code for 'V' key
        let vKeyCode: CGKeyCode = 0x09
        
        // Create events
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            print("Text injection: Failed to create CGEvents")
            return
        }
        
        // Set Command modifier
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        
        // Post events with small delays for reliability
        vDown.post(tap: .cghidEventTap)
        usleep(10000)  // 10ms
        vUp.post(tap: .cghidEventTap)
    }
    
    // MARK: - Tier 3: Direct Keystroke Simulation (Future: for very problematic apps)
    
    /// Simulate typing each character individually (slowest but most compatible)
    /// Use this for apps where even pasteboard fails
    func insertTextViaKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        
        for char in text {
            // Create key event for the character
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            
            // Set the Unicode character
            var chars = [UniChar](String(char).utf16)
            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            
            // Post events
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            
            // Small delay between characters
            usleep(5000)  // 5ms
        }
    }
}

// MARK: - Pasteboard Snapshot

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let capturedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // Skip transient type markers
                if type.rawValue == "org.nspasteboard.TransientType" { continue }
                
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
        return PasteboardSnapshot(items: capturedItems)
    }
    
    func restore(into pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        
        // If there was nothing to restore, leave it empty
        guard !items.isEmpty else { return }
        
        let restoredItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }
}
