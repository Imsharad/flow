# GhostType Architecture

**Last Updated:** 2025-12-18  
**Status:** Cloud/Local Hybrid Implementation Complete

---

## Executive Summary

GhostType is a macOS menu bar dictation app using a **hybrid cloud/local architecture**:
- **Cloud (Primary):** Groq Whisper API — ultra-low latency (~200-500ms)
- **Local (Fallback):** WhisperKit (CoreML) — offline-capable, privacy-preserving

### Key Metrics

| Mode | Latency | Accuracy | Offline |
|:-----|:--------|:---------|:--------|
| **Cloud (Groq)** | ~200-500ms | Excellent | ❌ |
| **Local (WhisperKit)** | ~1.5-2.5s | High | ✅ |

---

## System Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                            GhostType.app                                   │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  ┌─────────────┐     ┌─────────────┐     ┌──────────────────────────────┐  │
│  │   HotKey    │────▶│  Dictation  │────▶│   TranscriptionManager       │  │
│  │   Manager   │     │   Engine    │     │   (Provider Selection)       │  │
│  └─────────────┘     └─────────────┘     └──────────────────────────────┘  │
│        │                   │                          │                    │
│        │                   │              ┌───────────┴───────────┐        │
│        │                   │              │                       │        │
│  ┌─────▼─────┐     ┌──────▼──────┐  ┌────▼────────────┐  ┌───────▼──────┐  │
│  │  Audio    │     │    Audio    │  │ Cloud Service   │  │ Local Service │  │
│  │  Input    │────▶│    Ring     │  │ (Groq API)      │  │ (WhisperKit)  │  │
│  │  Manager  │     │   Buffer    │  └─────────────────┘  └──────────────┘  │
│  └───────────┘     └─────────────┘                                         │
│                                                                            │
│                    ┌─────────────────────────────────────────────────────┐ │
│                    │              AccessibilityManager                   │ │
│                    │              (Text Injection)                       │ │
│                    └─────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. Transcription Layer

| Component | Purpose | File |
|:----------|:--------|:-----|
| **TranscriptionManager** | Provider selection, fallback logic | `TranscriptionManager.swift` |
| **TranscriptionProvider** | Protocol for cloud/local providers | `TranscriptionProvider.swift` |
| **CloudTranscriptionService** | Groq Whisper API integration | `Cloud/CloudTranscriptionService.swift` |
| **LocalTranscriptionService** | WhisperKit wrapper with memory mgmt | `Local/LocalTranscriptionService.swift` |
| **WhisperKitService** | Low-level WhisperKit interface | `Whisper/WhisperKitService.swift` |

### 2. Audio Pipeline

| Component | Purpose | File |
|:----------|:--------|:-----|
| **AudioInputManager** | 16kHz mono mic capture | `AudioInputManager.swift` |
| **AudioRingBuffer** | 180s lock-free circular buffer | `Audio/AudioRingBuffer.swift` |
| **AudioBufferBridge** | `[Float]` → `AVAudioPCMBuffer` | `Audio/AudioBufferBridge.swift` |

### 3. Text Injection

| Method | Implementation | Use Case |
|:-------|:---------------|:---------|
| **AXUIElement** | Accessibility API | Primary (native apps) |
| **CGEvent** | Keyboard simulation | Electron apps |
| **Pasteboard** | Cmd+V simulation | Last resort |

### 4. Security

| Component | Purpose | File |
|:----------|:--------|:-----|
| **KeychainManager** | Secure API key storage | `Security/KeychainManager.swift` |

---

## Provider Selection Logic

```swift
// TranscriptionManager.swift
func transcribe(audio: AVAudioPCMBuffer) async -> String? {
    // 1. Try cloud if API key is valid
    if hasValidAPIKey {
        if let result = try? await cloudService.transcribe(audio) {
            return result  // ~200-500ms
        }
    }
    
    // 2. Fall back to local
    return try? await localService.transcribe(audio)  // ~1.5-2.5s
}
```

---

## Memory Management (Local Mode)

LocalTranscriptionService implements smart memory management:

1. **Lazy Loading:** WhisperKit model loads on first transcription request
2. **Cooldown Timer:** Unloads model after 5 minutes of inactivity
3. **Memory Pressure:** Responds to system memory warnings by unloading

This keeps the menu bar app lightweight when using cloud mode.

---

## Configuration

### Compute Options (WhisperKit)

```swift
// WhisperKitService.swift - ANE disabled due to M1 Pro deadlock
let computeOptions = ModelComputeOptions(
    audioEncoderCompute: .cpuAndGPU,  // Bypass ANE
    textDecoderCompute: .cpuAndGPU
)
```

### API Key Storage

```swift
// KeychainManager.swift
KeychainManager.shared.saveAPIKey(key)  // Stores in Keychain
KeychainManager.shared.getAPIKey()      // Retrieves from Keychain
```

---

## File Structure

```
Sources/GhostType/
├── GhostTypeApp.swift              # App entry point
├── Services/
│   ├── Audio/
│   │   ├── AudioRingBuffer.swift   # Lock-free circular buffer
│   │   ├── AudioBufferBridge.swift # Float → AVAudioPCMBuffer
│   │   └── AudioUtils.swift        # WAV encoding
│   ├── Cloud/
│   │   ├── CloudTranscriptionService.swift
│   │   ├── MultipartFormData.swift
│   │   └── NetworkResilienceManager.swift
│   ├── Local/
│   │   └── LocalTranscriptionService.swift
│   ├── Security/
│   │   └── KeychainManager.swift
│   ├── Whisper/
│   │   └── WhisperKitService.swift
│   ├── AccessibilityManager.swift
│   ├── AudioInputManager.swift
│   ├── DictationEngine.swift
│   ├── HotkeyManager.swift
│   ├── TranscriptionManager.swift
│   └── TranscriptionProvider.swift
├── UI/
│   └── GhostPill.swift
└── Resources/
    ├── GhostType.entitlements
    └── Info.plist
```

---

## Dependencies

| Package | Version | Purpose |
|:--------|:--------|:--------|
| **WhisperKit** | 0.9+ | Local CoreML inference |

---

## Build & Run

```bash
./build.sh          # Build with stable signing
open GhostType.app  # Launch
```

See [TCC_FIX_README.md](./TCC_FIX_README.md) for code signing setup.

---

## References

- [hybrid-architecture.md](./hybrid-architecture.md) — Detailed cloud/local design
- [benchmarking_guide.md](./benchmarking_guide.md) — Latency testing protocol
- [bugs.md](./bugs.md) — Known issues tracker
- [progress.md](./progress.md) — Development history
