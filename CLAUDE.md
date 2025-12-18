# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**GhostType** is a macOS menu bar app for voice-to-text dictation using a **hybrid cloud/local architecture**. It captures audio via hotkey (Right Option key), transcribes speech using either **Cloud (Groq Whisper API)** or **Local (WhisperKit)**, and injects text into any app using Accessibility APIs.

**Key Technologies:**
- Swift 5.9+ (SwiftPM for build)
- WhisperKit for local on-device inference
- Groq API for cloud transcription
- AVAudioEngine for 16kHz audio capture
- Accessibility API (AXUIElement) for text injection
- SwiftUI for menu bar UI

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
3. Code signs with "GhostType Development" certificate (or ad-hoc if missing)

### Running
```bash
./run.sh --build --open      # Build + launch (use on first run)
./run.sh --open              # Launch only
./run.sh --debug             # Run with stdout/stderr
./run.sh --reset-tcc         # Reset macOS permissions
```

### Monitoring Logs
```bash
tail -f /tmp/ghosttype.log    # Live monitoring
tail -n 50 /tmp/ghosttype.log # Last 50 lines
```

### Quick Development Loop
```bash
./build.sh && pkill GhostType && open GhostType.app
```

## Architecture

### Service Layer (`Sources/GhostType/Services/`)

**Core Pipeline:**
```
HotkeyManager → AudioInputManager → DictationEngine → TranscriptionManager → AccessibilityManager
                                                              ↓
                                          ┌─────────────────────────────────┐
                                          │                                 │
                                    CloudTranscription            LocalTranscription
                                      (Groq API)                    (WhisperKit)
```

**Key Components:**

1. **HotkeyManager**: Global event tap for Right Option key detection. Uses `CGEvent.tapCreate()` with `.flagsChanged` events.

2. **AudioInputManager**: Captures mic input via `AVAudioEngine` at 16kHz mono. Outputs `[Float]` samples.

3. **DictationEngine**: Orchestrates audio capture → transcription → text injection pipeline.

4. **TranscriptionManager**: Manages cloud/local provider selection with automatic fallback:
   - Primary: Cloud (Groq) when API key is configured
   - Fallback: Local (WhisperKit) if cloud fails or no API key

5. **CloudTranscriptionService**: Sends audio to Groq's Whisper API. Uses `NetworkResilienceManager` for retry logic.

6. **LocalTranscriptionService**: Wraps WhisperKit with memory management (lazy loading, cooldown timer, memory pressure response).

7. **WhisperKitService**: Low-level WhisperKit integration. Uses `cpuAndGPU` compute (ANE disabled due to M1 Pro deadlock).

8. **AccessibilityManager**: Text injection via `AXUIElement` API. Falls back to pasteboard for Electron apps.

9. **KeychainManager**: Securely stores Groq API key.

### UI Layer (`Sources/GhostType/UI/`)

- **GhostPill**: SwiftUI view showing transcription status (clouds/local mode indicator)
- **APIKeySheet**: Settings panel for API key configuration

## Permissions & Code Signing

**Required Permissions:**
- Microphone (`com.apple.security.device.audio-input`)
- Accessibility (TCC prompt, user must grant in System Settings)

**Entitlements:** `Sources/GhostType/Resources/GhostType.entitlements`

**Development Certificate:** Run `tools/setup-dev-signing.sh` once to create "GhostType Development" certificate. This prevents TCC permission invalidation on rebuilds.

## File Structure

```
/Users/sharad/Projects/GhostType/
├── build.sh                    # Build script
├── run.sh                      # Run script
├── Package.swift               # SwiftPM manifest
├── Sources/GhostType/
│   ├── GhostTypeApp.swift     # Main app entry point
│   ├── Services/
│   │   ├── Audio/             # Audio utilities
│   │   │   ├── AudioBufferBridge.swift
│   │   │   ├── AudioRingBuffer.swift
│   │   │   └── AudioUtils.swift
│   │   ├── Cloud/             # Cloud transcription
│   │   │   ├── CloudTranscriptionService.swift
│   │   │   ├── MultipartFormData.swift
│   │   │   └── NetworkResilienceManager.swift
│   │   ├── Local/             # Local transcription
│   │   │   └── LocalTranscriptionService.swift
│   │   ├── Security/
│   │   │   └── KeychainManager.swift
│   │   ├── Whisper/
│   │   │   └── WhisperKitService.swift
│   │   ├── AccessibilityManager.swift
│   │   ├── AudioInputManager.swift
│   │   ├── ConsensusService.swift
│   │   ├── DictationEngine.swift
│   │   ├── HotkeyManager.swift
│   │   ├── SoundManager.swift
│   │   ├── TranscriptionManager.swift
│   │   └── TranscriptionProvider.swift
│   ├── UI/
│   └── Resources/
│       ├── GhostType.entitlements
│       └── Info.plist
├── Tests/GhostTypeTests/
├── tools/
│   ├── setup-dev-signing.sh   # Dev certificate setup
│   └── cleanup_certs.sh       # Certificate cleanup
└── docs/
    ├── architecture.md        # System design
    ├── hybrid-architecture.md # Cloud/local implementation
    ├── bugs.md               # Bug tracker
    ├── benchmarking_guide.md # Latency testing
    └── progress.md           # Development log
```

## Important Notes

1. **Hybrid Architecture:** Cloud (Groq) is preferred for lower latency (~200-500ms). Local (WhisperKit) serves as fallback (~1.5-2s latency).

2. **API Key:** Stored in Keychain, not in code. Configure via app's settings menu.

3. **ANE Disabled:** WhisperKit uses `cpuAndGPU` compute options due to ANE deadlock issues on M1 Pro with large models.

4. **Memory Management:** LocalTranscriptionService auto-unloads WhisperKit model after 5 minutes of inactivity to reduce memory footprint.

5. **Logging:** All `print()` statements go to `/tmp/ghosttype.log`.

6. **Text Injection:** Uses AXUIElement API first, falls back to pasteboard for Electron apps.

## Reference Documentation

- Architecture: `docs/architecture.md`
- Cloud/Local Hybrid: `docs/hybrid-architecture.md`
- Bug Tracker: `docs/bugs.md`
- Progress Log: `docs/progress.md`
