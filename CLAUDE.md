# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**GhostType** is a macOS menu bar app for local voice-to-text dictation using on-device AI models. It captures audio via hotkey (Right Option key), transcribes speech using CoreML models (Moonshine ASR), applies grammar correction (T5), and injects text into any app using Accessibility APIs.

**Key Technologies:**
- Swift 5.9+ (SwiftPM for build)
- CoreML for on-device inference (Moonshine, T5 models)
- AVAudioEngine for 48kHz → 16kHz audio capture
- Accessibility API (AXUIElement) for text injection
- SwiftUI for overlay UI

## Build & Development Commands

### Building
```bash
./build.sh              # Incremental build (debug)
./build.sh --clean      # Clean build
./build.sh --release    # Release build
```

The build script:
1. Compiles Swift code with `swift build`
2. Creates `.app` bundle at `GhostType.app/`
3. Copies resource bundle (`GhostType_GhostType.bundle`) containing CoreML models
4. Code signs with "GhostType Development" certificate (or ad-hoc if missing)

### Running
```bash
./run.sh --build --open      # Build + launch (use on first run or after model changes)
./run.sh --open              # Launch only
./run.sh --debug             # Run with stdout/stderr (requires permissions already granted)
./run.sh --reset-tcc         # Reset macOS permissions
```

**Important:** Always use `--open` flag when launching after a build. The `--debug` flag only works if permissions are already granted.

### Monitoring Logs
All app logs redirect to `/tmp/ghosttype.log`:
```bash
tail -f /tmp/ghosttype.log    # Live monitoring
tail -n 50 /tmp/ghosttype.log # Last 50 lines
```

### Quick Development Loop
```bash
# Make code changes, then:
./build.sh && pkill GhostType && open GhostType.app
```

## Architecture

### Service Layer (`Sources/GhostType/Services/`)

**Core Pipeline:**
```
HotkeyManager → AudioInputManager → DictationEngine → AccessibilityManager
                                          ↓
                                    Transcriber (Moonshine)
                                    TextCorrector (T5)
```

**Key Components:**

1. **HotkeyManager**: Global event tap for Right Option key detection. Uses `CGEvent.tapCreate()` with `.flagsChanged` events. Supports tap-to-toggle and hold-to-record modes.

2. **AudioInputManager**: Captures mic input via `AVAudioEngine`. Converts 48kHz → 16kHz mono. Calls `onAudioBuffer` callback with `AVAudioPCMBuffer`.

3. **DictationEngine**: Orchestrates the pipeline. Uses `AudioRingBuffer` for buffering. Coordinates Transcriber → Corrector sequence. Implements pre-roll capture (1.5s before speech detection).

4. Triggers `onSpeechStart`/`onSpeechEnd` callbacks based on manual interaction.

5. **Transcriber**: ASR using Moonshine CoreML model. Currently uses **MoonshineTiny.mlpackage** (combined encoder+decoder). Implements autoregressive decoding loop (max 128 tokens). Has fallback to Apple's `SFSpeechRecognizer`.

6. **TextCorrector**: Grammar correction using T5Small CoreML model. Prepends "grammar: " prefix to input.

7. **AccessibilityManager**: Text injection via `AXUIElement` API. Falls back to pasteboard (Cmd+V simulation) for Electron apps. Saves/restores clipboard state.

### Resource Loading Pattern

**Critical:** Models and resources are loaded from the **nested bundle** `GhostType_GhostType.bundle`, not `Bundle.main`:

```swift
// AppDelegate.swift line 55-60
guard let bundlePath = Bundle.main.url(forResource: "GhostType_GhostType", withExtension: "bundle"),
      let loadedBundle = Bundle(url: bundlePath) else {
    fatalError("Could not find or load GhostType_GhostType.bundle")
}
self.resourceBundle = loadedBundle
```

All services receive `resourceBundle` in their initializer. Use `resourceBundle.url(forResource:...)` to load models/files.

### UI Layer (`Sources/GhostType/UI/`)

- **OverlayWindow**: Borderless, transparent window that follows cursor. Uses `NSPanel` with `.nonactivatingPanel` level.
- **GhostPill**: SwiftUI view showing transcription status. Animates near text insertion point.
- **GhostPillState**: `@Published` state object for reactive UI updates.

### AppDelegate Lifecycle

```
applicationDidFinishLaunching
  → Load GhostType_GhostType.bundle
  → checkPermissions (Mic, Accessibility, Speech Recognition)
  → initializeServices (pass resourceBundle to each)
  → setupUI
  → startAudioPipeline
    → audioManager.start()
    → hotkeyManager.start()
```

## Permissions & Code Signing

**Required Permissions:**
- Microphone (`com.apple.security.device.audio-input`)
- Accessibility (TCC prompt, user must grant in System Settings)
- Speech Recognition (`SFSpeechRecognizer.requestAuthorization`)

**Entitlements:** `Sources/GhostType/Resources/GhostType.entitlements`

**Development Certificate:** Run `./setup-dev-signing.sh` once to create "GhostType Development" certificate. This prevents TCC permission invalidation on rebuilds (avoids macOS treating each build as a new app).

## CoreML Model Conversion

Models live in `tools/coreml_converter/`:

```bash
cd tools/coreml_converter
source venv/bin/activate

# Moonshine ASR
python convert_moonshine.py --out ./models --combined-only  # Creates MoonshineTiny.mlpackage

# T5 Grammar Correction
python convert_t5.py --out ./models

# Copy to app resources
cp -r models/*.mlpackage ../../Sources/GhostType/Resources/
cp models/*.json ../../Sources/GhostType/Resources/
```

**Important:** After model changes, rebuild with `./build.sh --clean` to ensure bundle updates.

## Known Issues & Workarounds

### Current Issue: Moonshine Transcription Quality

**Problem:** MoonshineTiny model produces gibberish output (hallucinations, excessive `<unk>` tokens, no EOS generation).

**Root Cause:** Vocabulary file has `special_tokens` all set to `None`. Model may be incorrectly converted or undertrained.

**Workaround Options:**
1. **Quick Fix:** Disable Moonshine in `Transcriber.swift` by setting `isMoonshineEnabled = false` (line 96). This uses Apple's `SFSpeechRecognizer` fallback.
2. **Re-convert:** Run `python convert_moonshine.py --out ./models --combined-only` to regenerate with proper special tokens.
3. **Use Split Models:** Convert to `MoonshineEncoder.mlpackage` + `MoonshineDecoder.mlpackage` instead of combined model.

### TCC Permission Issues

If permissions are lost after rebuild:
```bash
./run.sh --reset-tcc              # Reset permissions
./setup-dev-signing.sh            # Create stable certificate
./build.sh --clean && ./run.sh --open
```

## Testing

```bash
# Kill running instance
pkill -9 GhostType

# Check if running
ps aux | grep GhostType | grep -v grep

# View crash logs
ls -lt ~/Library/Logs/DiagnosticReports/GhostType*.ips | head -1 | xargs cat

# Verify code signing
codesign -dv GhostType.app

# List resources in bundle
ls -lh GhostType.app/Contents/Resources/GhostType_GhostType.bundle/
```

## File Structure

```
/Users/sharad/flow/
├── build.sh                    # Build script
├── run.sh                      # Run script
├── setup-dev-signing.sh        # Certificate setup
├── Package.swift               # SwiftPM manifest
├── Sources/GhostType/
│   ├── GhostTypeApp.swift     # Main app + AppDelegate
│   ├── Services/              # Core business logic
│   │   ├── AudioInputManager.swift
│   │   ├── DictationEngine.swift
│   │   ├── HotkeyManager.swift
│   │   ├── Transcriber.swift
│   │   ├── TextCorrector.swift
│   │   ├── HotkeyManager.swift
│   │   └── AccessibilityManager.swift
│   ├── UI/                    # SwiftUI views
│   └── Resources/             # Models, entitlements, Info.plist
│       ├── *.mlpackage
│       ├── *.json
│       └── GhostType.entitlements
├── tools/coreml_converter/    # Python model conversion scripts
└── docs/
    ├── progress.md            # Development log (READ THIS FIRST)
    └── commands.md            # Quick reference commands
```

## Important Notes

1. **Resource Bundle Pattern:** Never use `Bundle.main` directly for models. Always use the `resourceBundle` passed to services.

2. **Logging:** All `print()` statements go to `/tmp/ghosttype.log` (configured in `AppDelegate.init()`).

3. **Hotkey Mode:** Default is tap-to-toggle (press once to start, press again to stop). Change via menu bar or `hotkeyManager.mode = .holdToRecord`.

4. **Text Injection:** Uses AXUIElement API first, falls back to pasteboard for Electron apps (Cursor, VS Code, Slack). Clipboard is saved/restored.

5. **Audio Format:** Input is 48kHz, converted to 16kHz mono for models. Buffer size is 30 seconds (ring buffer).

6. **Model Input Shapes:**
   - MoonshineTiny: `[1, 160000]` audio samples (10s @ 16kHz), `[1, 128]` decoder tokens
   - T5Small: `[1, 512]` input tokens max

## Reference Documentation

- Progress log: `docs/progress.md` (contains recent debugging history)
- Commands: `docs/commands.md` (quick command reference)
- Model conversion: `tools/coreml_converter/README.md`
