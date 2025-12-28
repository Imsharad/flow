import SwiftUI
import ApplicationServices
import AppKit
import AVFoundation
import Speech

@main
struct GhostTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!

    // Services
    var audioManager: AudioInputManager!
    var dictationEngine: DictationEngine!
    var accessibilityManager: AccessibilityManager!
    var soundManager: SoundManager!
    var hotkeyManager: HotkeyManager!
    
    // The explicit resource bundle that contains models, sounds, etc.
    var resourceBundle: Bundle = Bundle.main

    // UI
    var overlayWindow: OverlayWindow!
    var onboardingWindow: NSWindow?
    var ghostPillState = GhostPillState()
    
    // State
    var isHotkeyRecording = false
    
    override init() {
        // Redirect logs to file in /tmp (universally writable)
        let logPath = "/tmp/ghosttype_debug.log"
        freopen(logPath, "w", stdout)
        freopen(logPath, "w", stderr)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        
        print("--- GhostType Log Started ---")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon initially
        NSApp.setActivationPolicy(.accessory)
        
        // --- Load the nested resource bundle if it exists (optional) ---
        if let bundlePath = Bundle.main.url(forResource: "GhostType_GhostType", withExtension: "bundle"),
           let loadedBundle = Bundle(url: bundlePath) {
            self.resourceBundle = loadedBundle
            print("AppDelegate: ✅ Loaded GhostType_GhostType.bundle")
        } else {
            // Fall back to main bundle - works with system sounds
            print("AppDelegate: Using Bundle.main (no resource bundle)")
        }

        setupStatusBar()
        checkPermissions()
    }

    func checkPermissions() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibilityGranted = AXIsProcessTrusted()

        print("=== GhostType Permission Check ===")
        print("Microphone: \(micStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
        print("Accessibility: \(accessibilityGranted)")

        // Request Microphone permission if not determined
        if micStatus == .notDetermined {
            print("Requesting Microphone authorization...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Microphone authorization: \(granted)")
                DispatchQueue.main.async {
                    self.finalizePermissionCheck(accessibilityGranted: accessibilityGranted)
                }
            }
        } else {
            finalizePermissionCheck(accessibilityGranted: accessibilityGranted)
        }
    }

    private func finalizePermissionCheck(accessibilityGranted: Bool) {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        print("=== Final Permission Check ===")
        print("Microphone: \(micStatus.rawValue) - \(micStatus == .authorized ? "✅" : "❌")")
        print("Accessibility: \(accessibilityGranted ? "✅" : "❌")")

        // Trigger Onboarding if permissions are missing
        if micStatus != .authorized || !accessibilityGranted {
             print("⚠️ Permissions missing. Showing Onboarding...")
             showOnboarding()
             return
        }

        // Proceed if authorized
        if micStatus == .authorized {
            print("✅ Essential permissions granted (Mic) - initializing services...")
            
            initializeServices(resourceBundle: resourceBundle)
            setupUI()
            startAudioPipeline()
            warmUpModels()
        }
    }

    func promptForAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        if !accessEnabled {
            print("Accessibility prompt triggered. Waiting for user...")
        }
    }

    func showOnboarding() {
        // Bring app to foreground for onboarding
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let onboardingView = OnboardingView(onComplete: { [weak self] in
            self?.onboardingComplete()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Welcome to GhostType"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)
        self.onboardingWindow = window
    }

    func onboardingComplete() {
        // Hide dock icon again
        NSApp.setActivationPolicy(.accessory)

        initializeServices(resourceBundle: resourceBundle)
        setupUI()
        startAudioPipeline()
        warmUpModels()
        
        // Close window AFTER everything is initialized (avoid animation crash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
    }
    
    // MARK: - Model Warm-up
    
    private func warmUpModels() {
        print("Skipping model warm-up (disabled due to crash)")
        // TODO: Fix T5 model loading crash
    }

    func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "GhostType")
        }
        
        rebuildMenu()
    }
    
    private func rebuildMenu() {
        let menu = NSMenu()

        // Status header
        let statusItem = NSMenuItem(title: "GhostType - Ready", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        if let dictationEngine = dictationEngine {
            // Settings UI (SwiftUI Hosting)
            let settingsView = MenuBarSettings(manager: dictationEngine.transcriptionManager)
            let hostingView = NSHostingView(rootView: settingsView)
            
            // Set a frame for the hosting view. SwiftUI calculates content size, but NSMenuItem needs explicit frame sometimes.
            // Using a fixed width matching the View, height slightly arbitrary but hosting view should autoresize?
            // Safer to set a frame that accommodates the likely content.
            hostingView.frame = NSRect(x: 0, y: 0, width: 260, height: 280)
            
            let settingsItem = NSMenuItem()
            settingsItem.view = hostingView
            menu.addItem(settingsItem)
            
            menu.addItem(NSMenuItem.separator())
        }

        // Hotkey mode submenu (only show if services are initialized)
        if let hotkeyManager = hotkeyManager {
            let modeMenu = NSMenu()

            let holdItem = NSMenuItem(title: "Hold to Record", action: #selector(setHoldMode), keyEquivalent: "")
            holdItem.state = hotkeyManager.mode == .holdToRecord ? .on : .off
            modeMenu.addItem(holdItem)

            let tapItem = NSMenuItem(title: "Tap to Toggle", action: #selector(setTapMode), keyEquivalent: "")
            tapItem.state = hotkeyManager.mode == .tapToToggle ? .on : .off
            modeMenu.addItem(tapItem)

            let modeMenuItem = NSMenuItem(title: "Hotkey Mode", action: nil, keyEquivalent: "")
            modeMenuItem.submenu = modeMenu
            menu.addItem(modeMenuItem)

            // Hotkey hint
            let hotkeyHint = NSMenuItem(title: "Hotkey: Right Option (⌥)", action: nil, keyEquivalent: "")
            hotkeyHint.isEnabled = false
            menu.addItem(hotkeyHint)

            menu.addItem(NSMenuItem.separator())

            // Debug/test options
            menu.addItem(NSMenuItem(title: "Test Dictation", action: #selector(testTrigger), keyEquivalent: "t"))
        } else {
            // Services not initialized yet (waiting for permissions)
            let permItem = NSMenuItem(title: "Waiting for permissions...", action: nil, keyEquivalent: "")
            permItem.isEnabled = false
            menu.addItem(permItem)
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "About GhostType", action: #selector(about), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusBarItem.menu = menu
    }
    
    @objc func setHoldMode() {
        hotkeyManager?.mode = .holdToRecord
        rebuildMenu()
    }

    @objc func setTapMode() {
        hotkeyManager?.mode = .tapToToggle
        rebuildMenu()
    }

    func initializeServices(resourceBundle: Bundle) {
        print("Initializing services...")
        audioManager = AudioInputManager.shared
        dictationEngine = DictationEngine(callbackQueue: .main)
        accessibilityManager = AccessibilityManager()
        soundManager = SoundManager(resourceBundle: resourceBundle)
        hotkeyManager = HotkeyManager()

        // Wire dictation engine callbacks to UI/injection behavior.
        dictationEngine.onSpeechStart = { [weak self] in
            self?.handleSpeechStartUI()
        }
        dictationEngine.onSpeechEnd = { [weak self] in
            self?.handleSpeechEndUI()
        }
        dictationEngine.onPartialRawText = { [weak self] text in
            guard let self = self else { return }
            self.ghostPillState.text = text
            self.ghostPillState.isProcessing = false
            self.ghostPillState.isProvisional = true
        }
        dictationEngine.onFinalText = { [weak self] text in
            self?.handleFinalText(text)
        }
        
        // Wire hotkey manager for hold-to-record
        hotkeyManager.mode = .tapToToggle
        hotkeyManager.onRecordingStart = { [weak self] in
            self?.handleHotkeyStart()
        }
        hotkeyManager.onRecordingStop = { [weak self] in
            self?.handleHotkeyStop()
        }

        // Rebuild menu now that services are initialized
        rebuildMenu()
    }

    func setupUI() {
        // Re-enabling overlay with safety checks
        print("Initializing Overlay UI...")
        
        // Create the window
        overlayWindow = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50))
        
        // Set up the view
        let ghostPill = GhostPill(state: ghostPillState)
        overlayWindow.contentView = NSHostingView(rootView: ghostPill)
        
        print("Overlay UI initialized")
    }

    func startAudioPipeline() {
        print("=== Starting Audio Pipeline ===")

        // Link Audio -> Dictation Engine
        audioManager.onAudioBuffer = { [weak self] buffer in
            guard let self = self else { return }

            // Thread-safe read of isHotkeyRecording (set on main, read on audio queue)
            var isRecording = false
            DispatchQueue.main.sync {
                isRecording = self.isHotkeyRecording
            }
            guard isRecording else { return }

            // Convert buffer to [Float] array
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            let floatArray = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            // DEBUG: Check audio level
            let maxAmplitude = floatArray.max() ?? 0.0
            let avgAmplitude = floatArray.reduce(0.0, +) / Float(floatArray.count)
            if frameLength > 0 {
                // print("📊 Audio: \(frameLength) frames, max=\(String(format: "%.4f", maxAmplitude)), avg=\(String(format: "%.4f", abs(avgAmplitude)))")
            }

            self.dictationEngine.pushAudio(samples: floatArray)
        }

        do {
            try audioManager.start()
            print("✅ Audio engine started")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
        }

        // Start listening for global hotkey (Right Option)
        print("Starting hotkey listener...")
        if hotkeyManager.start() {
            print("✅ Hotkey listener started - Hold Right Option (⌥) to dictate")
        } else {
            print("❌ Could not start hotkey listener - Accessibility permission required!")
            soundManager.playError()
        }

        print("=== GhostType Ready ===")
    }
    
    // MARK: - Hotkey Handlers
    
    private func handleHotkeyStart() {
        print("🎤 RIGHT OPTION PRESSED - Starting recording (DEBUG: Hotkey handled)")
        isHotkeyRecording = true
        dictationEngine.manualTriggerStart()
    }

    private func handleHotkeyStop() {
        print("⏹️  RIGHT OPTION RELEASED - Stopping recording (DEBUG: Hotkey handled)")
        isHotkeyRecording = false
        dictationEngine.manualTriggerEnd()
    }

    private func handleSpeechStartUI() {
        print("Speech started")
        soundManager.playStart()
        ghostPillState.isListening = true
        ghostPillState.isProcessing = false
        ghostPillState.isProvisional = false
        ghostPillState.text = "Listening..."

        // Position UI near cursor (skip if overlay disabled)
        guard let window = overlayWindow else {
            print("Overlay window disabled - skipping UI update")
            return
        }

        var targetPoint = CGPoint.zero

        if let caretRect = accessibilityManager.getFocusedCaretRect() {
            // Place slightly above the caret rect.
            let x = caretRect.minX
            let y = caretRect.maxY + 12
            targetPoint = CGPoint(x: x, y: y)
        } else if let position = accessibilityManager.getFocusedElementPosition() {
            // Fallback: focused element position (often inaccurate for caret).
            targetPoint = CGPoint(x: position.x, y: position.y + 20)
        } else if let screen = NSScreen.main {
            // Final fallback: center screen.
            let x = screen.frame.midX - 100
            let y = screen.frame.midY
            targetPoint = CGPoint(x: x, y: y)
        }
        
        // Direct update to avoid NSAnimationContext crash
        window.setFrameOrigin(targetPoint)
        window.orderFront(nil)
    }

    private func handleSpeechEndUI() {
        print("Speech ended")
        ghostPillState.isListening = false
        ghostPillState.isProcessing = true
        ghostPillState.isProvisional = false
        ghostPillState.text = "Processing..."
    }

    private func handleFinalText(_ text: String) {
        print("📝 Final Transcript: \(text)")
        ghostPillState.text = text
        ghostPillState.isProcessing = false
        ghostPillState.isProvisional = false

        // Phase 4 (PRD): Inject final text.
        accessibilityManager.insertText(text)
        soundManager.playStop()
        
        // Hide overlay after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, let window = self.overlayWindow else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                window.orderOut(nil)
            }
        }
    }

    @objc func testTrigger() {
        // Manually trigger dictation for testing
        if ghostPillState.isListening {
            dictationEngine.manualTriggerEnd()
        } else {
            dictationEngine.manualTriggerStart()
        }
    }

    @objc func about() {
        print("About GhostType")
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

class GhostPillState: ObservableObject {
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var isProvisional = false
    @Published var text = ""
}