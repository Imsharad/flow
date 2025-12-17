# GhostType Architecture (Current)

**Last Updated:** 2025-12-16  
**Status:** Implementation Complete (Phase 3)

---

## Executive Summary

GhostType is a local-first, privacy-preserving macOS dictation application that transcribes speech to text in real-time. The application runs entirely on-device using WhisperKit (CoreML) for inference, achieving excellent accuracy with the `openai_whisper-large-v3-turbo` model.

### Key Metrics (Verified 2025-12-16)

| Metric | Value | Notes |
|:-------|:------|:------|
| **End-to-End Latency** | ~1.5-2.5s | For 5-6s speech segments |
| **Real-Time Factor** | 0.25-0.4x | Excellent throughput |
| **Accuracy** | High | Clean transcriptions verified |
| **Max Recording** | 180s | Ring buffer capacity |

---

## Architecture Decision: MLX → WhisperKit Pivot

> **Date:** 2025-12-16  
> **Decision:** Abandoned MLX in favor of WhisperKit (CoreML)

### Rationale

| Factor | MLX | WhisperKit | Winner |
|:-------|:----|:-----------|:-------|
| Build Stability | ❌ Missing Metal toolchain on Tahoe | ✅ System-provided CoreML | WhisperKit |
| Runtime Stability | ❌ Custom shader compilation | ✅ Pre-compiled CoreML models | WhisperKit |
| ANE Optimization | ⚠️ Custom implementation needed | ✅ Argmax-optimized models | WhisperKit |
| Streaming Support | ⚠️ Manual KV-cache management | ✅ Built-in streaming API | WhisperKit |

### Trade-offs Accepted

- **Slightly less granular control** over KV-cache for streaming
- **WhisperKit v0.9+** supports sufficiently low latency for production use

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GhostType.app                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────────────┐   │
│  │   HotKey    │────▶│  Dictation  │────▶│   WhisperKit        │   │
│  │   Manager   │     │   Engine    │     │   Service           │   │
│  └─────────────┘     └─────────────┘     └─────────────────────┘   │
│        │                   │                       │               │
│        │                   │                       │               │
│  ┌─────▼─────┐     ┌──────▼──────┐     ┌─────────▼─────────┐       │
│  │  System   │     │    Audio    │     │    WhisperKit     │       │
│  │  Audio    │────▶│    Ring     │────▶│    (CoreML)       │       │
│  │   Tap     │     │   Buffer    │     │  large-v3-turbo   │       │
│  └───────────┘     └─────────────┘     └───────────────────┘       │
│        │                                       │                   │
│        │                                       │                   │
│  └───────────┘                         └─────────────┘             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. Audio Pipeline

| Component | Implementation | Purpose |
|:----------|:---------------|:--------|
| **SystemAudioTap** | ScreenCaptureKit / AVAudioEngine | Captures system audio |
| **AudioRingBuffer** | Lock-free circular buffer | 180s capacity, ~11.5MB |

#### Audio Ring Buffer Configuration

```swift
// DictationEngine.swift:17
let ringBuffer = AudioRingBuffer(capacity: 180 * 16000)  // 180 seconds @ 16kHz
```

**Why 180s?**
- Original 30s buffer caused clipping for long recordings
- 180s = 11.52 MB (trivial memory footprint)
- Matches production dictation app standards

### 2. Inference Engine

| Component | Implementation | Notes |
|:----------|:---------------|:------|
| **WhisperKitService** | Swift Actor | Thread-safe inference wrapper |
| **Model** | `openai_whisper-large-v3-turbo` | Auto-downloaded on first launch |
| **Compute** | `cpuAndGPU` | Bypasses ANE to avoid M1 Pro issues |

#### Compute Options (Critical Fix)

```swift
// WhisperKitService.swift
let config = WhisperKitConfig(
    computeOptions: ModelComputeOptions(
        audioEncoderCompute: .cpuAndGPU,  // ← Bypass ANE
        textDecoderCompute: .cpuAndGPU    // ← Bypass ANE
    )
)
```

**Why bypass ANE?**
See [whisper-inference-deadlock.md](./whisper-inference-deadlock.md) for detailed analysis. Summary:
- M1 Pro's A14-generation ANE has issues with large Transformer models
- ANECompilerService enters livelock when compiling large-v3-turbo
- GPU execution is stable and sufficiently fast



### 4. Text Injection

| Component | Implementation | Fallback |
|:----------|:---------------|:---------|
| **AXInjector** | Accessibility API | Primary method |
| **CGEvent** | Keyboard simulation | For Electron apps |
| **Pasteboard** | Cmd+V simulation | Last resort |

---

## State Machine

```
     ┌──────────┐
     │   IDLE   │◀────────────────────────────────┐
     └────┬─────┘                                 │
          │ Hotkey Press                          │
          ▼                                       │
     ┌──────────┐                                 │
     │ LISTENING/ │                                 │
     │ SPEAKING │◀───┐                            │
     └────┬─────┘    │                            │
          │          │                            │
          │          │                            │
          │ Hotkey Release                        │
          ▼          │                            │
     ┌──────────┐    │                            │
     │ THINKING │────┘                            │
     └────┬─────┘                                 │
          │ Transcription complete                │
          ▼                                       │
     ┌──────────┐                                 │
     │ INJECTING│                                 │
     └────┬─────┘                                 │
          │ Text pasted                           │
          └───────────────────────────────────────┘
```

---

## Known Issues & Next Steps

### ⚠️ Long Audio Accuracy Degradation (>60s)

**Symptom:** Phrases dropped/garbled in middle of very long recordings  
**Cause:** Whisper processes all audio at once at end; loses coherence after ~30-60s  
**Test Result:** 142s speech → 11.37s transcription (RTF=0.08x) but ~15% phrase loss



---

## File Structure

```
Sources/GhostType/
├── GhostTypeApp.swift           # App entry point
├── Services/
│   ├── DictationEngine.swift    # Main orchestrator
│   ├── WhisperKitService.swift  # Inference wrapper (actor)
│   ├── AudioRingBuffer.swift    # Lock-free ring buffer
│   ├── SystemAudioTap.swift     # Audio capture
│   └── AXInjector.swift         # Text injection
├── UI/
│   ├── FloatingPanel.swift      # Overlay window
│   └── BlobView.swift           # Animated indicator
└── Resources/
    └── GhostType.entitlements   # Permissions
```

---

## Dependencies

| Package | Version | Purpose |
|:--------|:--------|:--------|
| **WhisperKit** | 0.9+ | CoreML Whisper inference |

---

## Build & Run

```bash
# Build with stable signing (preserves TCC permissions)
./build.sh

# Run
open GhostType.app
```

See [TCC_FIX_README.md](./TCC_FIX_README.md) for code signing setup.

---

## References

- [progress.md](./progress.md) — Development progress tracker
- [whisper-chunking.md](./whisper-chunking.md) — Chunking strategy for long audio
- [whisper-inference-deadlock.md](./whisper-inference-deadlock.md) — M1 Pro ANE issues (historical)
- [TCC_FIX_README.md](./TCC_FIX_README.md) — Code signing for persistent permissions
