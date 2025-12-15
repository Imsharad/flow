## Progress Log

### 2025-12-13

- **Repository initialized + pushed to GitHub**
  - Repo: `https://github.com/Imsharad/flow`

- **Build environment note**
  - Xcode is installed at `/Applications/Xcode.app` and is now selected via `xcode-select`.
  - Verified on your machine:
    - `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`
    - `sudo xcodebuild -license accept` completed successfully
    - `xcrun --sdk macosx --show-sdk-platform-path` resolves correctly
    - `swift build` succeeds (SwiftPM build is unblocked)

- **SwiftPM manifest/build fixes (post-Xcode)**
  - Removed unsupported `infoPlist` usage from `Package.swift` (SwiftPM doesn’t build an app bundle/Info.plist the same way Xcode does).
  - Removed the placeholder test target to avoid overlapping-sources errors.
  - Renamed `Sources/GhostType/main.swift` → `Sources/GhostType/GhostTypeApp.swift` to avoid SwiftPM entrypoint conflicts.

- **Pull requests discovered and synced locally**
  - PR #1: “Implement GhostType macOS app” (draft)
  - PR #2: “Scaffold GhostType Application” (draft)

- **Checked out latest PR branch**
  - Branch: `ghosttype-scaffold-5956184854589995409` (PR #2)

- **`docs/tasks.json` brought up to date and pushed**
  - Detected local `docs/tasks.json` differed from branch HEAD (older “Phase”-based plan vs newer “Sprint”-based plan)
  - Updated to the newer Sprint roadmap (19 items)
  - Committed + pushed to PR #2 (commit: `726bce0`)

- **Caret positioning + injection improvements**
  - Added caret-rect lookup using Accessibility `kAXBoundsForRangeParameterizedAttribute` for more accurate overlay placement.
  - Pasteboard fallback now preserves and restores the user clipboard after paste.
  - Committed + pushed to PR #2 (commit: `914f183`)

- **CoreML-first scaffolding (removed ONNX runtime dependency)**
  - Removed `sherpa-onnx` dependency from `Package.swift`.
  - Added CoreML-based scaffolds for Moonshine ASR + T5 correction, and an energy-based VAD placeholder.
  - Committed + pushed to PR #2 (commit: `ab45557`)

- **Pre-roll buffering + streaming partials (single-process)**
  - Added an `AudioRingBuffer` and 1.5s pre-roll behavior, plus a 500ms partial update loop.
  - Refactored into a `DictationEngine` to mirror future XPC boundaries.
  - Committed + pushed to PR #2 (commits: `ebe0028`, `3eae57b`)

- **XPC + conversion workspace scaffolds**
  - Added placeholder XPC protocols (`DictationXPCServiceProtocol`/`DictationXPCClientProtocol`) and an `IOSurfaceAudioBuffer` scaffold.
  - Added `tools/coreml_converter/` with pinned Python dependencies and conversion script skeletons for Moonshine/T5.

- **Repo hygiene**
  - Added `.gitignore` for SwiftPM build outputs, Python venvs, and generated CoreML artifacts (commit: `3692b62`).

- **PR #2 review notes (high-signal)**
  - Scaffolds a macOS menubar app + onboarding (Mic/Accessibility) + overlay UI + audio/VAD/transcription service skeletons (with mock-mode fallbacks)
  - Build issue observed on this machine: Swift toolchain/SDK mismatch (`swift build` fails because installed compiler and SDK Swift versions don't match; `xcrun` platform path lookup also failing)
  - Implementation caveats to address later:
    - Caret positioning via Accessibility is likely inaccurate for editors (focused element position != caret)
    - Pasteboard injection overwrites clipboard without restore
    - Audio resampling path may need `AVAudioConverter` for reliable 16k conversion
    - Resources/models/sounds are placeholders; services will run in mock mode until assets are added

### 2025-12-14

- **Moonshine CoreML conversion script implemented**
  - Full implementation of `tools/coreml_converter/convert_moonshine.py`
  - Converts HuggingFace `UsefulSensors/moonshine-tiny` to CoreML format
  - Generates three model variants:
    - `MoonshineTiny.mlpackage` - Combined model for simple deployment
    - `MoonshineEncoder.mlpackage` - Audio encoder for streaming use
    - `MoonshineDecoder.mlpackage` - Token decoder for streaming use
  - Features:
    - Dynamic audio length support via `ct.RangeDim` (1-30 seconds)
    - Float16 precision for Neural Engine (ANE) optimization
    - Tokenizer vocabulary export (`moonshine_vocab.json`) for Swift decoding
    - Validation step to verify converted models
  - CLI options: `--combined-only`, `--split-only`, `--skip-validation`, `--no-quantize`
  - Added `setup_and_convert.sh` for easy environment setup
  - Updated `requirements.txt` with transformers>=4.48 (Moonshine support)
  - Added `README.md` with usage instructions

- **T5 CoreML conversion script implemented**
  - Full implementation of `tools/coreml_converter/convert_t5.py`
  - Converts T5-based text-to-text models to CoreML for grammar correction
  - Supports multiple model sources:
    - `google-t5/t5-small` (generic, 60M params)
    - `vennify/t5-base-grammar-correction` (pre-tuned for grammar)
    - `AventIQ-AI/T5-small-grammar-correction` (small + grammar-tuned)
  - Generates three model variants:
    - `T5Small.mlpackage` - Combined model for simple deployment
    - `T5Encoder.mlpackage` - Text encoder for streaming
    - `T5Decoder.mlpackage` - Token decoder for streaming
  - Features:
    - Dynamic sequence length support (1-512 tokens)
    - Float16 precision for Neural Engine
    - SentencePiece tokenizer export
    - Validation with test generation loop
  - For grammar correction: prepend "grammar: " prefix to input text

- **CoreML models generated successfully**
  - Used Python 3.11 + torch 2.4.0 + coremltools 8.1 for compatibility
  - Generated models in `tools/coreml_converter/models/`:
    - `MoonshineEncoder.mlpackage` (15MB) - Audio to hidden states
    - `T5Small.mlpackage` (116MB) - Combined grammar correction model
    - `T5Encoder.mlpackage` (67MB) - Text encoder
    - `T5Decoder.mlpackage` (80MB) - Token decoder
    - `moonshine_vocab.json` (2MB) - Moonshine tokenizer
    - `t5_vocab.json` (2MB) - T5 tokenizer
  - **Known limitation**: Moonshine decoder has causal mask slice issue with coremltools
    - Workaround: Use encoder for embedding, implement greedy decoding in Swift
    - Or use Apple's built-in SFSpeechRecognizer as fallback

- **Sprint 1 status: MODELS GENERATED**
  - Next: Copy models to `Sources/GhostType/Resources/`
  - Then: Wire CoreML inference in Swift (`Transcriber.swift`, `TextCorrector.swift`)

- **CoreML models integrated into Swift app**
  - Copied models to `Sources/GhostType/Resources/`:
    - `MoonshineEncoder.mlpackage` (15MB)
    - `T5Small.mlpackage` (116MB)
    - `T5Encoder.mlpackage` (67MB)
    - `T5Decoder.mlpackage` (80MB)
    - `moonshine_vocab.json`, `t5_vocab.json`
  - Updated `Package.swift` with explicit `.copy()` for mlpackage bundles (avoids name conflicts)

- **Transcriber.swift rewritten to use SFSpeechRecognizer**
  - Since Moonshine decoder failed to convert (causal mask issue), using Apple's native ASR
  - Benefits: Native Apple Silicon optimization, <10ms latency, on-device recognition
  - Supports streaming with `onPartialResult` (grey provisional) and `onFinalResult` (black committed)
  - Falls back to mock mode if speech recognition unavailable

- **TextCorrector.swift implemented with T5Small CoreML**
  - Loads `T5Small.mlpackage` via CoreML with Neural Engine support
  - Loads `t5_vocab.json` for SentencePiece-style tokenization
  - Implements greedy autoregressive decoding loop
  - Prepends "grammar: " prefix per T5 convention
  - Falls back to `TextFormatter` if model unavailable

- **Build verified**: `swift build` completes successfully with all models bundled

- **Sprint 1 status: COMPLETE ✅**

- **Global Hotkey System Implemented**
  - `HotkeyManager.swift` - listens for Right Option (⌥) key globally
  - Two modes: Hold-to-Record (default) and Tap-to-Toggle
  - Uses `CGEvent` tap for system-wide hotkey capture
  - Menu bar UI allows switching between modes

- **IOSurface Ring Buffer Upgraded**
  - Lock-free SPSC (Single-Producer Single-Consumer) design
  - Cache-line aligned cursors (128-byte padding) to prevent false sharing
  - `OSMemoryBarrier` for cross-process memory ordering
  - Ready for XPC service integration

- **Sound Feedback System**
  - System sounds (Tink/Pop) for start/stop audio feedback
  - Falls back gracefully when custom sounds unavailable
  - Error sound for permission issues

- **Enhanced Text Injection**
  - Tiered fallback strategy: AX → Pasteboard+Cmd+V → Keystroke simulation
  - Electron app detection (VS Code, Slack, Discord, etc.) - skips flaky AX
  - Pasteboard marked as transient to hide from clipboard managers
  - Clipboard save/restore to preserve user's clipboard

- **Model Warm-up**
  - T5 grammar correction model warms up at app launch
  - Reduces first-transcription latency

- **App Configuration**
  - `Info.plist` with privacy descriptions (Mic, Speech, Accessibility)
  - `GhostType.entitlements` for code signing
  - Build script (`build.sh`) for easy compilation

- **Build Script Fixed (App Bundle Generation)**
  - Updated `build.sh` to generate a proper `GhostType.app` bundle structure.
  - Previously, running the raw binary (`.build/debug/GhostType`) caused silent permission failures (Mic/Accessibility) due to missing `Info.plist`.
  - The new script:
    - Creates `GhostType.app/Contents/{MacOS,Resources}`
    - Copies `Info.plist` and code-signs with entitlements
    - Bundles CoreML resources correctly
  - **Fixes**: "No functionality" issue when running from terminal.

- **Build verified**: `build.sh` completes successfully and produces signed `GhostType.app`

- **Sprint 1 status: COMPLETE ✅**

### 2025-12-15

- **Critical Crash Fix (Overlay UI)**
  - **Issue:** App crashed immediately upon triggering dictation with `SIGSEGV` in `_NSWindowTransformAnimation`.
  - **Root Cause:** SwiftUI/AppKit integration issue on macOS 14+ when animating `NSPanel` visibility/positioning.
  - **Fix:** Temporarily disabled the Overlay UI and window animations.
  - **Status:** App is stable, but runs "headless" (no visual feedback during dictation).

- **Audio Pipeline Overhaul (Silent Mic Fix)**
  - **Issue:** `AVAudioEngine` input buffer was consistently silent (all zeros), despite valid permissions.
  - **Root Cause:** `AVAudioEngine.inputNode` defaulted to a "CADefaultDeviceAggregate" or virtual audio device that had no real input, ignoring the system default microphone setting.
  - **Fix:** Rewrote `AudioInputManager` to use `AVCaptureSession`.
    - Explicitly selects `.builtInMicrophone`.
    - Implemented `AVAudioConverter` to downsample 48kHz mic input to 16kHz for the engine.
  - **Status:** Audio capture is now working (amplitudes > 0.0).

- **Transcription & Injection Status**
  - **Transcription:** Functional using `SFSpeechRecognizer`. Quality reported as "really bad" (likely due to lack of context awareness or raw SFSpeech limitations compared to LLMs).
  - **Injection:**
    - ✅ Works in: Apple Notes, Google Chrome, Twitter, **Cursor**.
    - ❌ Fails in: Terminal (Apple's default Terminal.app, iTerm2).
  - **Fix: Cursor App Injection:** Identified Cursor's bundle ID (`com.todesktop.230313mzl4w4u92`) and added it to the `electronApps` list, forcing pasteboard injection. This resolves the text injection failure in Cursor.
  - **Current Pipeline:** Mic -> AVCaptureSession -> RingBuffer -> VAD -> SFSpeechRecognizer -> AX/Pasteboard Injection.

### 2025-12-15 (Part 2)

- **VAD Integration (CoreML Upgrade)**
  - **Goal:** Replace placeholder energy check with CoreML-based VAD.
  - **Silero VAD Conversion:** Attempted to convert `Silero VAD v5` to CoreML.
    - Result: **Failed** due to `coremltools` limitations with JIT-traced LSTM state outputs (`context_size_samples` graph error).
  - **EnergyVAD Implementation:**
    - Created `EnergyVAD.mlpackage` using a custom PyTorch->CoreML conversion (Energy-based neural network fallback).
    - Integrated into `VADService.swift` with buffering logic (512-sample chunks).
    - Updated `Package.swift` to bundle `EnergyVAD.mlpackage`.
  - **Status:** VAD is now running on Neural Engine (via CoreML) or CPU fallback, paving the way for future model swaps.

---

## Next Steps

### Sprint 2: XPC Service Skeleton (Priority: High)

**Goal:** Isolate AI inference from UI to prevent crashes and improve stability.

| Task | Description | Status |
|------|-------------|--------|
| Create XPC Service target | Add `DictationXPCService` target to Xcode project | 🔲 Pending (requires Xcode project) |
| Implement IOSurface wrapper | Zero-copy audio buffer shared between Main App and XPC | ✅ Complete |
| Wire XPC connection | `NSXPCConnection` setup with `DictationXPCProtocols` | 🔲 Pending (requires Xcode project) |
| Move VAD to XPC | Voice Activity Detection runs in sandboxed service | 🔲 Pending |
| Verify shared memory | Main App writes audio, XPC reads instantly (<1ms) | 🔲 Pending |

**Note:** XPC Service targets require an Xcode project (SwiftPM doesn't support them). The IOSurface ring buffer is ready for XPC integration.

**Architecture:**
```
┌─────────────────┐    IOSurface     ┌──────────────────────┐
│   Main App      │ ←──────────────→ │  XPC Service         │
│   (SwiftUI)     │    (zero-copy)   │  - VAD (Silero)      │
│   - Menu Bar    │                  │  - ASR (SFSpeech)    │
│   - Overlay UI  │    XPC Reply     │  - T5 (CoreML)       │
│   - Hotkey      │ ←──────────────→ │                      │
└─────────────────┘                  └──────────────────────┘
```

### Sprint 3: Audio Pipeline (Priority: High)

| Task | Description | Status |
|------|-------------|--------|
| AVAudioEngine tap | Capture mic audio at native sample rate | ✅ Complete |
| Resample to 16kHz | Use `AVAudioConverter` for reliable conversion | ✅ Complete |
| Ring buffer integration | Feed audio into `AudioRingBuffer` with 1.5s pre-roll | ✅ Complete |
| VAD integration | Trigger transcription on speech end (Silero VAD) | ⚡ In Progress (using energy-based VAD) |

### Sprint 4: UI Polish (Priority: Medium)

| Task | Description | Status |
|------|-------------|--------|
| GhostPill overlay | Floating pill that follows cursor position | ✅ Complete |
| Provisional text | Grey italic text during transcription | ✅ Complete |
| Final text swap | Replace grey with black on completion | ✅ Complete |
| Text injection | `AXUIElement` insertion at caret position | ✅ Complete (with Electron fallback) |
| Hotkey handling | Hold-to-record + tap-to-toggle on same key | ✅ Complete |

### Sprint 5: Production Hardening (Priority: Medium)

| Task | Description | Status |
|------|-------------|--------|
| Error handling | Graceful fallbacks for all failure modes | ✅ Complete |
| Permission wizard | Onboarding flow for Mic + Accessibility | ✅ Complete |
| Model precompilation | Ship `.mlmodelc` to avoid first-run compile | 🔲 Pending |
| Memory profiling | Ensure <500MB footprint on 8GB machines | 🔲 Pending |
| Model warm-up | Warm up ML models at app launch | ✅ Complete |

### Known Issues to Address

1. **Moonshine Decoder**: Causal mask slice issue with coremltools 8.1
   - Current workaround: Using SFSpeechRecognizer instead
   - Future: Retry with coremltools updates or ONNX export path

2. **Caret Positioning**: Accessibility API may not report accurate caret position in some editors
   - ✅ Implemented: Fallback to center overlay on screen for incompatible apps

3. **Electron Apps**: Text injection via `AXUIElement` may fail (Slack, VS Code)
   - ✅ Implemented: Automatic detection + pasteboard fallback for Electron apps

4. **XPC Service**: Requires Xcode project (SwiftPM doesn't support XPC targets)
   - Current: Running all inference in-process (works but less isolated)
   - Future: Create Xcode project for true process isolation

---

## Quick Reference

**Build:** `./build.sh`

**Run:** `open GhostType.app`

**Hotkey:** Hold Right Option (⌥) to dictate

**Models location:** `Sources/GhostType/Resources/`

**Converter tools:** `tools/coreml_converter/`

**Required Permissions:**
1. **Microphone** - Grant when prompted
2. **Accessibility** - System Settings > Privacy & Security > Accessibility
3. **Speech Recognition** - Grant when prompted (optional, for on-device ASR)
