# Deep Research Prompt: Cloud/Local Hybrid Transcription Architecture

## Context Injection: GhostType Project

### What is GhostType?
GhostType is a macOS menu bar application for **push-to-talk dictation**. Users press a hotkey (Right Option ⌥), speak, and the transcribed text is injected into any focused application via Accessibility APIs.

### Current Architecture (Local-Only)

```
┌─────────────────────────────────────────────────────────────────┐
│                         GhostTypeApp                             │
│  (Menu Bar App - NSStatusItem)                                   │
└─────────────────────┬───────────────────────────────────────────┘
                      │
         ┌────────────▼────────────┐
         │      HotkeyManager      │ ← Right Option (⌥) listener
         │  (CGEventTap)           │
         └────────────┬────────────┘
                      │ onRecordingStart / onRecordingStop
         ┌────────────▼────────────┐
         │    DictationEngine      │ ← Orchestrates audio → text
         │  - useMLX: Bool (flag)  │
         │  - 500ms sliding window │
         └────────────┬────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    ▼                 ▼                 ▼
┌────────────┐  ┌─────────────┐  ┌─────────────┐
│AudioInput  │  │MLXService   │  │WhisperKit   │
│Manager     │  │(Broken)     │  │Service      │
│(16kHz tap) │  │             │  │(Works!)     │
└────────────┘  └─────────────┘  └─────────────┘
                                        │
                                        ▼
                                 ┌─────────────┐
                                 │Accessibility│
                                 │Manager      │
                                 │(Text Inject)│
                                 └─────────────┘
```

### Key Files

| File | Role |
|------|------|
| `DictationEngine.swift` | Orchestrates audio capture → transcription → text injection. Has `useMLX: Bool` flag. |
| `WhisperKitService.swift` | CoreML-based local transcription (works, ~1.5-2s latency). |
| `MLXService.swift` | Apple MLX-based transcription (broken, outputs garbage). |
| `GhostTypeApp.swift` | Menu bar UI, hotkey setup, permission handling. |
| `AudioInputManager.swift` | Real-time 16kHz audio capture from microphone. |
| `AccessibilityManager.swift` | Injects text into focused application via AX APIs. |

### Current State

| Aspect | Status |
|--------|--------|
| **Audio Capture** | ✅ Working (16kHz, ring buffer) |
| **WhisperKit Local** | ✅ Working (~1.5-2s latency, 0.25x RTF) |
| **MLX Local** | ❌ Broken (garbage output, decoder issues) |
| **Text Injection** | ✅ Working (Accessibility + Pasteboard fallback) |
| **Menu Bar UI** | ✅ Working (mode toggle, status display) |

### The Problem

1. **MLX Decoder produces garbage output** (repeating tokens, dots, wrong special tokens).
2. **Local-only architecture** limits reliability while Apple Silicon / MLX tech matures.
3. **No fallback** if local inference fails.

---

## Goal

Design a **Cloud/Local Hybrid Architecture** that:

1. **Works Today**: Cloud transcription (OpenAI Whisper API) for reliable, fast results.
2. **Works Tomorrow**: Easy swap to local (WhisperKit/MLX) when tech improves.
3. **User Choice**: Toggle between modes via menu bar.
4. **Graceful Degradation**: Auto-fallback if one mode fails.

---

## Research Questions

### 1. Protocol Design
What should the `TranscriptionProvider` protocol look like?
- What methods are essential? (`transcribe`, `isReady`, `cancel`?)
- How to handle streaming vs. one-shot transcription?
- How to expose provider metadata (name, latency estimate, cost)?

### 2. Cloud Service Implementation
For `CloudTranscriptionService` (OpenAI Whisper API):
- What audio format does the API accept? (WAV, MP3, FLAC?)
- How to convert `[Float]` PCM to uploadable format efficiently?
- What are the rate limits and error handling best practices?
- Should we use streaming API or one-shot?
- How to handle network failures gracefully?

### 3. Local Service Wrapper
For wrapping `WhisperKitService`:
- Should the wrapper be a thin adapter or add additional logic?
- How to handle model loading state (not-ready → loading → ready)?
- How to expose warm-up / preload functionality?

### 4. Manager Design
For `TranscriptionManager`:
- Should it hold both providers simultaneously or lazy-load?
- How to persist user preference (UserDefaults, Keychain for API key)?
- How to implement auto-fallback (local fails → cloud)?
- How to show visual indicator of active mode?

### 5. DictationEngine Integration
How to update `DictationEngine.swift`:
- Replace direct `whisperKitService` / `mlxService` calls with `TranscriptionManager`?
- How to handle provider switching mid-session?
- How to minimize code changes while maximizing flexibility?

### 6. UI/UX Considerations
For the menu bar toggle:
- Best macOS patterns for mode toggles in menu bar apps?
- How to show current mode visually (☁️ vs 🖥️)?
- Where to put API key settings (preferences window, inline prompt)?

### 7. Security
For API key management:
- Best practices for storing API keys in macOS apps (Keychain vs UserDefaults)?
- How to validate API key without exposing it in logs?

### 8. Cost Optimization
For cloud usage:
- How to minimize API calls (debounce, RMS gating)?
- How to estimate cost per session?
- How to warn user if approaching usage limits?

### 9. Cloud Provider Comparison ⭐ CRITICAL
**Compare the top 5 cloud speech-to-text providers for our use case:**

**Use Case Requirements:**
- Real-time dictation (short bursts, 2-30 seconds typically)
- Low latency is critical (<2s end-to-end preferred)
- High accuracy for conversational English
- macOS desktop app (Swift/native HTTP client)
- Volume: ~100-1000 requests/day per user

**Providers to Compare:**

| Provider | Evaluate |
|----------|----------|
| **OpenAI Whisper API** | Accuracy leader, Whisper Large-v3 |
| **Deepgram** | Known for ultra-low latency |
| **AssemblyAI** | Strong accuracy, good docs |
| **Google Cloud Speech-to-Text** | Enterprise reliability |
| **Groq** | Free tier, experimental Whisper on LPU |

**Comparison Criteria:**

1. **Latency**
   - Time-to-first-byte (TTFB)
   - Total processing time for 5s, 15s, 30s audio
   - Streaming vs. batch mode differences

2. **Reliability**
   - Uptime SLA guarantees
   - Rate limits (requests/min, concurrent)
   - Error handling / retry patterns
   - Geographic availability

3. **Pricing**
   - Cost per minute of audio
   - Free tier availability
   - Volume discounts
   - Hidden costs (e.g., storage, egress)

4. **API Ergonomics**
   - Audio format requirements (WAV, MP3, raw PCM?)
   - SDK availability for Swift/macOS
   - Response format (JSON, streaming events?)
   - Authentication method (API key, OAuth?)

5. **Accuracy**
   - WER (Word Error Rate) benchmarks
   - Performance on conversational speech
   - Punctuation and formatting quality

**Deliverable**: Recommendation matrix with top choice + backup.

---

## Constraints

1. **Swift-only**: No external dependencies beyond existing (WhisperKit, SwiftUI).
2. **macOS Menu Bar App**: Must remain lightweight, non-activating.
3. **Privacy-First Messaging**: Local should be the "preferred" mode in marketing.
4. **Minimal Refactor**: Changes should be additive, not rewrite existing working code.

---

## Deliverables Expected

1. **Protocol Definition**: `TranscriptionProvider.swift`
2. **Cloud Service**: `CloudTranscriptionService.swift`
3. **Local Wrapper**: `LocalTranscriptionService.swift`
4. **Manager**: `TranscriptionManager.swift`
5. **UI Updates**: Menu bar toggle, settings for API key
6. **Architecture Diagram**: Updated with new components

---

## Success Criteria

- [ ] Cloud mode works with OpenAI API key
- [ ] Local mode works with WhisperKit
- [ ] Toggle switches modes instantly
- [ ] API key stored securely in Keychain
- [ ] Fallback works if primary mode fails
- [ ] Latency for cloud: <2s end-to-end
- [ ] Code changes are minimal and additive

