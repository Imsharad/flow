# Product Requirement Document: "GhostType" (macOS)

Project Codename: GhostType

Target Platform: macOS 14.0+ (Apple Silicon M1/M2/M3)

Primary Goal: Local-first, ultra-low latency voice dictation (<200ms) with semantic correction.

Core Architecture: Decoupled XPC Service Model using IOSurface for Zero-Copy Audio Transport.

---

## 1. Executive Summary

GhostType is a menu bar application that replaces standard keyboard input with high-speed voice dictation. Unlike competitors that rely on cloud APIs (Wispr Flow) or heavy monolithic local models (Superwhisper), GhostType achieves sub-200ms latency by using **Moonshine (CoreML)** for transcription and **T5-Small (CoreML)** for instant grammar correction, architected within a crash-resilient XPC service structure.

## 2. Technical Stack (The "Refined" Golden Path)

| **Component**        | **Technology**                        | **Rationale**                                                                                                               |
| -------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **App Shell**        | **SwiftUI**+**AppKit**          | Native macOS look & feel, menu bar management.                                                                                    |
| **Architecture**     | **XPC Services**                      | Isolates AI memory usage from the UI. Prevents "Heisenbug" crashes caused by C++ symbol conflicts.                                |
| **Audio Transport**  | **IOSurface**+**CVPixelBuffer** | **Zero-copy**audio transfer between Main App and XPC Service. Bypasses standard IPC serialization overhead (~10ms savings). |
| **ASR Model**        | **Moonshine Tiny**(Int8 CoreML)       | Variable-length encoder eliminates 30s padding latency. 5x faster than Whisper for short commands.                                |
| **Correction Model** | **T5-Small**(Float16 CoreML)          | "Good enough" grammar fixing at <50ms latency on Neural Engine. Llama 3.2 1B is reserved for "Pro" mode (optional async).         |
| **VAD**              | **Silero VAD v5**(CoreML)             | Aggressive silence detection (300ms threshold) to trigger end-of-utterance.                                                       |

---

## 3. System Architecture Diagram

**Code snippet**

```
graph TD
    User[User Voice] --> Mic[AVAudioEngine (Main App)]
    Mic -->|Raw Samples| IOSurface
  
    subgraph "Dictation XPC Service (Sandboxed)"
        IOSurface --> Reader
        Reader --> VAD
        VAD -- "Speech End" --> Moonshine
        Moonshine --> RawText
        RawText --> T5
    end
  
    T5 -->|XPC Reply| UI[UI Overlay]
    UI -->|AXAPI| ActiveApp
```

## 4. Detailed Functional Requirements

### 4.1 The "Zero-Copy" Audio Pipeline

* **Objective:** Eliminate CPU cycles wasted on copying audio bytes between processes.
* **Implementation:**
  * **Main App:** Allocates `IOSurface` (wrapping a `CVPixelBuffer` or raw memory block). Maps this memory into its address space.
  * **Audio Tap:** Writes microphone PCM data directly into the `IOSurface` via `unsafeMutableRawPointer`.
  * **IPC:** Sends the `IOSurface` object ID (xpc_object_t) to the XPC service *once* at startup.
  * **XPC Service:** Maps the same `IOSurface` into its memory. Reads directly from the shared buffer.

### 4.2 The "Moonshine" ASR Engine

* **Constraint:** Must not use `Sherpa-Onnx` or `WhisperKit` due to build instability.
* **Requirement:** Use a custom-converted CoreML model of Moonshine.
  * **Conversion:** `coremltools` script must utilize `ct.RangeDim` to allow dynamic input shapes (e.g., (1, 16000) to (1, 480000)).
  * **Execution:** Run on  **Neural Engine (ANE)** .
* **Behavior:**
  * **Streaming Simulation:** Transcribe audio every 500ms while user speaks (Partial Results).
  * **Finalization:** Transcribe full buffer on VAD silence trigger.

### 4.3 The "Provisional" UX Pattern

To mask the latency of the Correction Layer:

1. **Phase 1 (Immediate):** Display raw Moonshine output in **Grey** italic text immediately as it arrives.
   * *Example:* "heres the code for loop"
2. **Phase 2 (Corrected):** Asynchronously run T5-Small on the raw text.
3. **Phase 3 (Swap):** Replace Grey text with Black final text.
   * *Example:* "Here's the code for the loop:"
4. **Phase 4 (Inject):** Use Accessibility API to insert final text.

### 4.4 Build & Distribution

* **Tooling:** `swift-bundler` or standard Xcode Project (recommended for XPC complexity).
* **Entitlements:**
  * `com.apple.security.device.audio-input` (Main App Only).
  * `com.apple.security.app-sandbox` (Both).
  * `com.apple.security.inherit` (XPC Service).

---

## 5. Implementation Roadmap

### Sprint 1: The CoreML Converter (Python)

* **Goal:** Generate `.mlpackage` files for Moonshine and T5.
* **Tasks:**
  1. Write Python script using `coremltools` to convert `usefulsensors/moonshine-tiny` PyTorch model.
  2. Validate `ct.RangeDim` works for variable audio lengths.
  3. Convert `t5-small` for text-to-text generation.

### Sprint 2: The XPC Skeleton (Swift)

* **Goal:** Establish shared memory link.
* **Tasks:**
  1. Create Xcode project with Main App and XPC Service target.
  2. Implement `IOSurface` wrapper class.
  3. Verify Main App can write random bytes and XPC can read them instantly.

### Sprint 3: The Listener (Swift)

* **Goal:** Live audio processing.
* **Tasks:**
  1. Implement `AVAudioEngine` tap.
  2. Feed audio into `IOSurface`.
  3. Implement VAD logic inside XPC service (reading from surface).
  4. Trigger CoreML Moonshine inference on speech segments.

### Sprint 4: The Interface (SwiftUI)

* **Goal:** "Ghost" text overlay.
* **Tasks:**
  1. Create floating `NSPanel` following cursor.
  2. Implement the Grey/Black text swapping logic.
  3. Wire up `AXUIElement` for text insertion.

---

## 6. Risk Mitigation

| **Risk**               | **Impact**                 | **Mitigation**                                                                    |
| ---------------------------- | -------------------------------- | --------------------------------------------------------------------------------------- |
| **XPC Latency**        | Audio lag > 20ms                 | Use `IOSurface`(Shared Memory) strictly; avoid `NSXPCConnection`data passing.       |
| **Moonshine Accuracy** | Poor accuracy on <1s audio       | Enforce minimum buffer size of 1.5s (pre-roll buffer).                                  |
| **CoreML Compilation** | App startup slow (model compile) | Pre-compile models (`.mlmodelc`) during build phase or on first launch splash screen. |
| **Text Insertion**     | Fails in Electron apps (Slack)   | Fallback to `CGEvent`keyboard simulation for specific bundle IDs.                     |

This PRD represents the "Hard Road" of engineering, but it is the only path to a "Magical" user experience on Apple Silicon without cloud dependencies.
