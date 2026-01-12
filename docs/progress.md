# GhostType Development Progress

## 🚨 Critical Architecture Pivot (2025-12-16)
**Decision**: Abandoned **MLX** → Pivoted to **WhisperKit (CoreML)**.
**Reason**: Irresolvable build environment issues on macOS Tahoe Beta (missing Metal Toolchain for compiling custom shaders).
**Implication**:
- **Pros**: Guaranteed runtime stability (uses system CoreML), zero compilation of custom shaders, highly optimized for ANE.
- **Cons**: Slightly less granular control over KV-cache for streaming, but WhisperKit v0.9+ supports extremely low latency streaming.

---

## 📚 Documentation Overview

| Document | Status | Description |
|:---------|:-------|:------------|
| **[architecture.md](./architecture.md)** | ✅ Current | Complete system architecture reference |
| **[progress.md](./progress.md)** | ✅ Current | This file - development progress tracker |
| **[whisper-chunking.md](./whisper-chunking.md)** | ✅ Current | Chunking guide for long audio (next step) |
| **[tasks.json](./tasks.json)** | ✅ Current | Machine-readable task list |
| **[user_stories.md](./user_stories.md)** | ✅ Updated | User requirements with status |
| **[TCC_FIX_README.md](./TCC_FIX_README.md)** | ✅ Current | Code signing for persistent permissions |
| **[bugs.md](./bugs.md)** | ⚠️ **Active** | Known issues and investigations |
| **[whisper-inference-deadlock.md](./whisper-inference-deadlock.md)** | ⚠️ Historical | Why M1 Pro ANE hangs (resolved) |
| **[archive/](./archive/)** | 🗄️ Archived | Obsolete MLX/XPC research |

---

## 📅 Roadmap Overview

| Phase | Description | Status |
| :--- | :--- | :--- |
| **Phase 1** | **Core Pipeline & Audio Tap** | ✅ **Completed** |
| **Phase 2** | **The Floating UI** | ✅ **Completed** |
| **Phase 3** | **Real Inference (WhisperKit)** | ✅ **Completed** |
| **Phase 4** | **Context & RAG** | ✅ **Completed** |
| **Phase 5** | **Polish & Ship** | ✅ **Completed** |

---

## 🟢 Phase 1: Core Pipeline & Audio Tap
*Goal: Capture system audio reliably without crashes.*
- [x] **Step 1: Audio Engine (Tap)**
    - Implemented `AudioRingBuffer` (lock-free, circular).
    - Integrated `SystemAudioTap` (ScreenCaptureKit/AVAudioEngine).
    - Verified: Audio buffers are captured and logged (RMS values).
- [x] **Step 2: VAD (Voice Activity Detection)**
    - Integrated **TEN.AI** (C++ VAD) bridging.
    - Tuning: Adjusted thresholds (300ms silence) for "Ghost Style" rapid interactions.
    - Verified: "Speech Start" and "Speech End" logs trigger correctly.

## 🟢 Phase 2: The Floating UI
*Goal: Minimalist, "Ghost-like" overlay that feels native.*
- [x] **Step 1: Window Management**
    - Created `OverlayWindow` (NSPanel, non-activating).
    - Solved "Mission Control" visibility issues (collectionBehavior).
    - Implemented "Follow Focus" (tracks active text caret).
- [x] **Step 2: SwiftUI Views**
    - `FloatingPanel`: animated state transitions (Idle -> Listening -> Thinking).
    - `BlobView`: Metal-like organic shader (simulated with Canvas/MeshGradient).
- [x] **Step 3: Text Injection**
    - Implemented `AXInjector` using Accessibility APIs.
    - Verified: Inserts text into Notes, Chrome, VS Code.

## 🟢 Phase 3: Real Inference (WhisperKit Pivot)
*Goal: Replace "Streaming..." mock with real-time text using WhisperKit.*
- [x] **Step 1: Integration**
    - [x] Add `WhisperKit` dependency (SPM).
    - [x] Create `WhisperKitService` actor.
    - [x] Wire up `Autodownload` of optimized `openai_whisper-large-v3-turbo`.
- [x] **Step 2: Streaming Logic**
    - [x] Connect `AudioRingBuffer` -> `WhisperKitService`.
    - [x] Implement `transcribe(stream: ...)` logic.
    - [x] Handle partial results vs. finalized segments.
- [x] **Step 3: Verification** ✅
    - [x] **Resolved**: Hotkey Logic (Tap vs Hold fixed).
    - [x] **Resolved**: Premature Pasting (Manual flag added).
    - [x] **Resolved**: Startup/Model Loading (Environment stable).
    - [x] **Resolved**: `WhisperKit` CoreML inference hang (M1 Pro).
        - **Fix**: `cpuAndGPU` compute options (bypass ANE).
        - **Fix**: `Task.detached` for model loading (prevent MainActor deadlock).
    - [x] **Verified**: Streaming Output (2025-12-16)
        - **Latency**: ~1.5-2.5s end-to-end for 5-6s speech
        - **RTF**: 0.25-0.4x realtime (excellent)
        - **Accuracy**: Clean transcriptions verified
    - [x] ✅ **Resolved**: Long Audio Clipping (>30s)
        - **Was**: First ~5-7s of speech missing for recordings >30s (ring buffer capped at 30s)
        - **Fix**: Increased `AudioRingBuffer` to 180s (3 min) in `DictationEngine.swift:17`
        - **Memory**: 11.52 MB (trivial) — battle-tested approach used by most production dictation apps
        - **Verified**: 142s recording captured fully (2025-12-16)
    - [x] ✅ **Resolved**: Long Audio Accuracy Degradation (>60s)
        - **Symptom**: Phrases dropped/garbled in middle of very long recordings (tested 142s)
        - **Cause**: Whisper processes all audio at once at end; loses coherence after ~30-60s
        - **Test Result** (2025-12-16): 142s speech, 11.37s transcription, RTF=0.08x, but ~15% phrase loss
        - **Fix**: VAD-based chunked streaming
            - Processed audio in natural speech segments (on each VAD silence > 0.7s)
            - Concatenated transcriptions incrementally
            - Leveraged existing VAD infrastructure (`minSilenceDurationSeconds: 0.7`)
        - **Files Modified**:
            - `DictationEngine.swift` — accumulate transcriptions across VAD segments
            - `WhisperKitService.swift` — added context conditioning between chunks
            - `TranscriptionManager.swift` — updated to pass tokens
            - `LocalTranscriptionService.swift` — updated to return tokens

## 🟢 Phase 4: Context & RAG
*Goal: "It knows what I'm looking at."*
- [x] **Step 1: Active Window Context**
    - [x] Capture window titles and bundle IDs (`AccessibilityManager`).
    - [x] Inject context into `DictationEngine` prompts.
- [ ] **Step 2: Local RAG (Ollama/Embeddings)**
    - [ ] *Deferred to v2.1 for simplicity.*

## 🟢 Phase 5: Polish & Ship
*Goal: Production-ready reliability.*
- [x] **Step 1: Installer & Permissions**
    - [x] Onboarding flow for "Accessibility Permissions".
    - [x] Onboarding for "Screen Recording" (Audio Tap).
    - [x] `OnboardingView` created and integrated into `GhostTypeApp`.
- [x] **Step 2: Settings UI**
    - [x] Model selection (Distil-Large vs Turbo vs Base).
    - [x] Mic sensitivity sliders (0.5x - 3.0x).
    - [x] `MenuBarSettings` updated and integrated.
- [ ] **Step 3: Signed Release**
    - [ ] Notarization automation.
