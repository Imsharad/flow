import Cocoa
import Carbon.HIToolbox

/// Global hotkey manager for dictation control.
///
/// Supports two modes:
/// - **Hold-to-Record**: Hold the hotkey to record, release to stop
/// - **Tap-to-Toggle**: Press once to start, press again to stop
///
/// Default hotkey: Right Option (⌥) key - chosen because:
/// - Easy to reach with thumb
/// - Less commonly used than Left Option
/// - Works in most applications
final class HotkeyManager {
    
    enum Mode {
        case holdToRecord
        case tapToToggle
    }
    
    enum State {
        case idle
        case recording
    }
    
    // Configuration
    var mode: Mode = .holdToRecord
    var hotkey: UInt16 = UInt16(kVK_RightOption)  // Right Option key
    
    // State
    private(set) var state: State = .idle
    
    // Callbacks
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    
    // Internal
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDownTime: Date?
    private let holdThreshold: TimeInterval = 0.3  // 300ms to distinguish hold vs tap
    
    deinit {
        stop()
    }
    
    // MARK: - Public API
    
    func start() -> Bool {
        guard eventTap == nil else { return true }
        
        // Create event tap for key events
        // We need flagsChanged for modifier keys (Option, Command, etc.)
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        
        // Self-pointer for callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: selfPtr
        ) else {
            print("Failed to create event tap. Accessibility permission required.")
            return false
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        CGEvent.tapEnable(tap: tap, enable: true)
        print("HotkeyManager: Started listening for Right Option key")
        return true
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
    }
    
    // MARK: - Event Handling
    
    fileprivate func handleFlagsChanged(_ flags: CGEventFlags, keyCode: UInt16) {
        // DEBUG: Log all flag change events
        print("HotkeyManager: flagsChanged - keyCode=\(keyCode), kVK_RightOption=\(kVK_RightOption), maskAlternate=\(flags.contains(.maskAlternate))")

        // Detect key state from flags
        // When Right Option is pressed, maskAlternate is set
        // When released, maskAlternate is cleared
        let isPressed = flags.contains(.maskAlternate) && keyCode == kVK_RightOption

        print("HotkeyManager: isPressed=\(isPressed), state=\(state), mode=\(mode)")

        switch mode {
        case .holdToRecord:
            handleHoldMode(isPressed: isPressed)

        case .tapToToggle:
            handleTapMode(isPressed: isPressed)
        }
    }
    
    private func handleHoldMode(isPressed: Bool) {
        if isPressed && state == .idle {
            // Key pressed - start recording
            state = .recording
            keyDownTime = Date()
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingStart?()
            }
        } else if !isPressed && state == .recording {
            // Key released - stop recording
            state = .idle
            keyDownTime = nil
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingStop?()
            }
        }
    }
    
    private func handleTapMode(isPressed: Bool) {
        if isPressed && keyDownTime == nil {
            // Key pressed - record time
            keyDownTime = Date()
        } else if !isPressed, let downTime = keyDownTime {
            // Key released - check duration
            let holdDuration = Date().timeIntervalSince(downTime)
            keyDownTime = nil
            
            // Only toggle on quick tap (< threshold)
            if holdDuration < holdThreshold {
                if state == .idle {
                    state = .recording
                    DispatchQueue.main.async { [weak self] in
                        self?.onRecordingStart?()
                    }
                } else {
                    state = .idle
                    DispatchQueue.main.async { [weak self] in
                        self?.onRecordingStop?()
                    }
                }
            }
        }
    }
}

// MARK: - Event Tap Callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .flagsChanged:
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // DEBUG: Log ALL modifier key events to verify tap is working
        print("🔥 HotkeyManager: Callback fired - type=flagsChanged, keyCode=\(keyCode), kVK_RightOption=\(kVK_RightOption)")
        print("🔥 Flags - maskAlternate: \(flags.contains(.maskAlternate)), maskCommand: \(flags.contains(.maskCommand)), maskShift: \(flags.contains(.maskShift))")

        // Only process Right Option key
        if keyCode == kVK_RightOption {
            print("✅ HotkeyManager: Right Option MATCHED! Calling handleFlagsChanged")
            manager.handleFlagsChanged(flags, keyCode: keyCode)
        } else {
            print("⚠️  HotkeyManager: keyCode \(keyCode) != kVK_RightOption (\(kVK_RightOption))")
        }
        
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // Re-enable the tap if it gets disabled
        if let tap = manager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        
    default:
        break
    }
    
    // Pass the event through unchanged
    return Unmanaged.passUnretained(event)
}
