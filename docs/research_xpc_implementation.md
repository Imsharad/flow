> [!WARNING]
> **PARTIALLY OUTDATED (2025-12-16)**
> 
> The XPC architecture described in this document was **never implemented**.
> The project uses a simpler monolithic architecture with WhisperKit.
> 
> **Still Relevant Sections:**
> - Accessibility API text injection patterns
> - NSPasteboard save/restore logic
> - CGEvent keyboard simulation fallbacks
> 
> See [`progress.md`](./progress.md) for current architecture.

---

# Research Plan: XPC Architecture & Implementation Strategy

**Date:** 2025-12-14
**Focus:** Sprint 2 (XPC Service, Shared Memory Audio, VAD, Text Injection)

This document contains a "Master Prompt" designed to be used with advanced reasoning models (Gemini 1.5 Pro, o1, Claude 3.5 Sonnet) or as a guide for deep technical documentation research. It packages the project's specific constraints and architectural challenges.

---

## The Master Prompt

**Context for the Researcher:**
Use the following block to query for expert-level implementation details.

```markdown
Act as a Principal macOS Systems Engineer and Core Audio Specialist. I am building "GhostType," a high-performance macOS dictation application that uses local LLMs (Moonshine for ASR, T5 for grammar correction) running on the Apple Neural Engine.

I need your deep technical expertise to help me architect the transition from a monolithic Swift prototype to a robust, sandboxed XPC architecture.

### 1. Project Context & Constraints
- **OS:** macOS 14+ (Sonoma/Sequoia).
- **Language:** Swift 5.10+.
- **Architecture:** 
  - **Main App (UI):** SwiftUI, Menu Bar, Overlay Window, Microphone Capture (AVAudioEngine), Accessibility Injection.
  - **XPC Service (Inference):** Sandboxed, runs CoreML models (Moonshine, T5, Silero VAD), processes Audio.
- **Current Status:** 
  - I have the models converted to CoreML (`.mlpackage`).
  - I have a basic monolithic app capturing audio and running SFSpeechRecognizer.
  - I have a scaffold for `IOSurface` but no ring buffer logic yet.

### 2. The Core Challenge
I am moving the "Brain" of the app into a separate XPC Service to prevent UI hangs and improve stability. I need to implement a **zero-copy audio pipeline** where the Main App writes microphone PCM data to shared memory, and the XPC Service reads it to run VAD and ASR.

### 3. Specific Research Tasks & Implementation Questions
Please analyze the following "In-Progress" and "Pending" tasks and provide architectural patterns, code snippets, or specific API warnings for each:

#### A. Shared Memory Audio Ring Buffer (Task #7, #8)
I plan to use `IOSurface` as a shared memory block between the App and XPC Service.
- **Question:** How do I implement a lock-free Ring Buffer over `IOSurface` in Swift? 
- **Requirements:** 
  - Needs `head` and `tail` atomic pointers.
  - Needs to handle raw PCM `Float32` samples.
  - How do I safely map the memory in both processes using `IOSurfaceLock`?
  - Please provide a Swift struct/class blueprint for `SharedAudioBuffer` that uses `UnsafeMutableRawPointer` and `OSAtomic` (or Swift Atomics).

#### B. The XPC Service Lifecycle (Task #6, #10)
- **Question:** How do I maintain a persistent stateful connection for streaming?
- **Scenario:** The user holds a hotkey. The XPC service needs to spin up (or wake up), receive audio, update VAD state, and stream partial text back.
- **Requirements:**
  - `NSXPCConnection` setup for bi-directional communication (Client <-> Service).
  - How to handle "keep-alive" so the XPC service doesn't terminate mid-dictation?
  - How to integrate **Silero VAD** (assumed ONNX or CoreML) efficiently in this loop?

#### C. Robust Text Injection (Task #16, #17)
- **Question:** What is the most reliable way to inject text into *any* macOS application in 2025?
- **Context:** `AXUIElement` (Accessibility API) is the preferred path, but Electron apps (Slack, VS Code) are flaky.
- **Requirements:**
  - Algorithm for detecting the caret position (`kAXFocusedUIElementAttribute` vs `kAXSelectedTextRangeAttribute`).
  - Fallback strategy: If AX fails, how do I seamlessly switch to `CGEvent` (keyboard simulation) or Pasteboard injection without losing the user's current clipboard content?

#### D. T5 Grammar Correction Pipeline (Task #15)
- **Question:** How to architect the async correction pipeline?
- **Scenario:** 
  1. ASR produces: "hello world" (Partial)
  2. ASR produces: "hello world how are you" (Final)
  3. T5 input: "grammar: hello world how are you"
  4. T5 output: "Hello, world. How are you?"
- **Issue:** If the user keeps speaking, how do I apply corrections to the *previous* sentence while capturing the *new* audio? Do I need a secondary queue?

### 4. Definition of Done
For each section above, I am looking for:
1. **Key Apple APIs** to use (and which deprecated ones to avoid).
2. **"Gotchas"**: Common pitfalls (e.g., Sandbox restrictions on XPC, TCC permission inheritance).
3. **Pseudo-code or Pattern**: A high-level Swift implementation strategy.

Here is my current Task List for reference:
```json
[
  { "id": "7", "title": "Implement IOSurface shared-buffer wrapper", "status": "in_progress" },
  { "id": "10", "title": "Implement VAD inside XPC service", "status": "in_progress" },
  { "id": "16", "title": "Text injection via Accessibility API", "status": "in_progress" },
  { "id": "6", "title": "Create Xcode project with Main App + XPC Service targets", "status": "pending" }
]
```

```

---

## Additional Project Context

**Current Directory Structure:**
```text
/Users/sharad/flow/
├───Sources/
│   └───GhostType/
│       ├───GhostTypeApp.swift
│       ├───Resources/ (Contains .mlpackage models)
│       ├───Services/
│       │   ├───AudioInputManager.swift (AVAudioEngine)
│       │   ├───IOSurfaceAudioBuffer.swift (Scaffold)
│       │   ├───DictationXPCProtocols.swift (Protocols)
│       │   └───Transcriber.swift (SFSpeechRecognizer)
│       └───UI/
│           └───OverlayWindow.swift
└───docs/
    ├───tasks.json
    └───progress.md
```

**Key Files Content:**

* **`IOSurfaceAudioBuffer.swift`**: Currently a basic wrapper around `IOSurfaceCreate` and `IOSurfaceLock`. Needs atomics for ring buffer logic.
* **`DictationXPCProtocols.swift`**: Defines `DictationXPCClientProtocol` (updates) and `DictationXPCServiceProtocol` (commands).

**Project Goals:**

* **Latency:** <200ms form speech to text.
* **Privacy:** All local, no network calls.
* **Stability:** App must never crash the UI thread.







`</prompt>`



`<reserach>`


# GhostType Architecture Migration Report: Monolithic to Distributed XPC Systems

## 1. Executive Summary and Strategic Architectural Vision

The "GhostType" project, currently a monolithic Swift prototype for local Large Language Model (LLM) dictation, stands at a critical juncture. While the prototype successfully demonstrates the core utility—transcribing voice to text and correcting grammar via a local T5 model—it is fundamentally unsuited for production deployment on macOS. The current architecture suffers from fragility; a single memory spike in the inference engine can crash the audio recorder, and the main thread is overburdened with audio processing, UI rendering, and accessibility interactions. This report serves as the definitive technical blueprint for re-architecting GhostType into a robust, distributed system leveraging the XPC (Inter-Process Communication) framework.

The proposed architecture decomposes the application into four distinct protection domains: the **GhostType Client** (UI), the  **Audio Engine Service** , the  **Inference Engine Service** , and the  **Injection Agent** . This separation is not merely organizational but structural, enforcing hard boundaries on memory usage, fault tolerance, and security privileges. By leveraging `IOSurface` for zero-copy shared memory audio transport, `os_transaction` for precise lifecycle management, and a tiered Accessibility/Event injection strategy, we aim to deliver a system that is resilient to the inherent instability of local AI workloads and the variability of the macOS desktop environment.

This comprehensive report details the engineering patterns required to achieve this transition. We will explore the theoretical underpinnings of lock-free ring buffers on Apple Silicon, the nuances of the Mach kernel messaging that powers XPC, and the intricate dance of simulating user input in a sandboxed environment. This document is intended for the systems engineering team and assumes a deep familiarity with macOS kernel primitives, Swift concurrency models, and Objective-C runtime mechanics.

---

## 2. Architectural Decomposition and XPC Topology

The migration from a monolith to a distributed system necessitates a rigorous definition of service boundaries. In the macOS environment, XPC Services provides the native mechanism for this decomposition, allowing the operating system to manage the lifecycle, security context, and resource allocation of each component independently.

### 2.1 The Case for Multi-Process Architecture

The primary driver for this architectural shift is  **Fault Isolation** . In the current monolithic prototype, the LLM inference (running T5 or Whisper) is the most volatile component. It competes for the same heap memory as the audio buffer and the SwiftUI render loop. A memory pressure event—common when loading large transformer models—triggers the kernel's Jetsam mechanism, which terminates the process consuming the most memory.^1^ In a monolith, this kills the recording session, resulting in data loss. By isolating inference into `com.ghosttype.InferenceService`, a crash or Jetsam event in that service leaves the `AudioService` (and the recording state) intact, allowing the UI to handle the failure gracefully (e.g., by restarting the inference engine or notifying the user) without losing the audio buffer.

The second driver is  **Privilege Separation** . The Principle of Least Privilege dictates that the component processing raw microphone input should not have access to the user's screen contents or accessibility capabilities. Conversely, the component injecting text into third-party apps requires extensive Accessibility permissions but does not need access to the microphone. The XPC architecture allows us to assign distinct entitlements to each service bundle, minimizing the blast radius of a potential security compromise.^2^

### 2.2 Service Topology and Responsibilities

The system is architected as a hub-and-spoke topology, with the main application acting as the orchestrator. However, high-volume data (audio) bypasses the hub to flow directly between services via shared memory.

| **Service Component**              | **Responsibility**                                                        | **Entitlements & Permissions**                                                                             | **Lifecycle Characteristics**                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **GhostType Client (Main App)**    | UI rendering, user session management, XPC orchestration, settings persistence. | `com.apple.security.app-sandbox`, User Selected File Read/Write.                                               | **User-Driven:**Launches on user interaction; terminates on user quit.                            |
| **com.ghosttype.AudioService**     | Microphone capture, Audio Unit graph management, Ring Buffer Producer.          | `com.apple.security.device.audio-input`,`com.apple.security.app-sandbox`.                                    | **Real-Time:**High priority, must never block. Controlled via `os_transaction`during recording. |
| **com.ghosttype.InferenceService** | Hosting CoreML models (Whisper, T5), VAD processing, Ring Buffer Consumer.      | `com.apple.security.app-sandbox`,`com.apple.security.assets.movies.read-only`(if external models).           | **On-Demand:**Heavy memory footprint. Subject to aggressive idle exit if not transacted.          |
| **com.ghosttype.InjectionService** | Text insertion via AX API, Pasteboard management, Event simulation.             | `com.apple.security.app-sandbox`,`com.apple.security.temporary-exception.apple-events`, Accessibility (TCC). | **Ephemeral:**Spun up for injection, terminates immediately after.                                |

### 2.3 The Inter-Process Communication (IPC) Strategy

The system utilizes a dual-plane IPC strategy to balance control requirements against performance constraints.

#### 2.3.1 The Control Plane: NSXPCConnection

The Control Plane handles state transitions (e.g., "Start Recording", "Load Model", "Inject Text"). We utilize `NSXPCConnection`, the high-level Objective-C/Swift wrapper around the C-based XPC Services API.^3^ This API manages the connection bootstrap, message serialization (via `NSSecureCoding`), and protocol validation. While `NSXPCConnection` adds a layer of object-oriented abstraction, it ultimately relies on Mach messages.^4^ The latency of a standard XPC message is non-deterministic and can range from microseconds to milliseconds depending on system load, making it unsuitable for raw audio streaming but ideal for command-and-control signaling.

#### 2.3.2 The Data Plane: IOSurface Shared Memory

The Data Plane handles the continuous stream of PCM audio data from the Audio Service to the Inference Service. Standard XPC messaging would require serializing the audio buffer into an `OS_xpc_data` object, triggering a memory copy into the kernel and another copy out to the receiving process. For 16kHz or 48kHz audio, this copy overhead introduces jitter and burns CPU cycles unnecessarily.^5^

Instead, we employ `IOSurface`. Originally designed for sharing GPU textures between processes (e.g., WindowServer and applications), `IOSurface` allows us to allocate a region of physical memory and map it into the virtual address space of multiple processes simultaneously.^6^ This enables a "Zero-Copy" architecture where the Audio Service writes samples to a memory address that the Inference Service reads from directly. This mechanism bypasses the kernel's message-passing path entirely for the data payload, relying on the kernel only for the initial setup and memory mapping.

---

## 3. High-Performance Audio Transport: The IOSurface Ring Buffer

The cornerstone of the distributed audio architecture is the shared memory ring buffer. Implementing this correctly in Swift requires a deep understanding of memory layout, atomic operations, and the specific cache coherence behaviors of Apple Silicon.

### 3.1 Theoretical Foundation: The Lock-Free SPSC Buffer

A Single-Producer Single-Consumer (SPSC) ring buffer allows one thread (Audio Service) to write data and another (Inference Service) to read data concurrently without mutual exclusion locks (mutexes). Locks are catastrophic in real-time audio threads because they can lead to priority inversion; if the lower-priority Inference Service holds a lock and gets preempted, the high-priority Audio Service blocks, causing audio dropouts.^7^

To achieve lock-free synchronization, we rely on **Atomic Operations** on the buffer's write and read indices (cursors). The Producer owns the `WriteCursor`, and the Consumer owns the `ReadCursor`. The "available space" for writing is derived from `Capacity - (WriteCursor - ReadCursor)`, and the "available data" for reading is `WriteCursor - ReadCursor`.^9^

### 3.2 Memory Layout and Cache Line False Sharing

When mapping an `IOSurface` into memory, we obtain a base address `UnsafeMutableRawPointer`. We must structure this raw memory carefully. A naive implementation might place the `WriteCursor` (UInt64) and `ReadCursor` (UInt64) immediately next to each other in the header.

The Problem of False Sharing:

Modern CPUs, including the Apple M-series, manage cache coherence at the granularity of a "cache line," typically 64 or 128 bytes. If the WriteCursor and ReadCursor reside in the same cache line, the core running the Audio Service (modifying WriteCursor) and the core running the Inference Service (modifying ReadCursor) will continually invalidate each other's L1/L2 cache lines.7 This phenomenon, known as false sharing, triggers excessive inter-core traffic and can degrade performance by orders of magnitude.

The Solution:

We must enforce padding between the atomic variables to ensure they occupy distinct cache lines. The layout of our shared IOSurface is therefore defined as follows:

| **Offset (Bytes)** | **Content**              | **Owner**  | **Description**                                                  |
| ------------------------ | ------------------------------ | ---------------- | ---------------------------------------------------------------------- |
| **0x00 - 0x07**    | `WriteCursor`(Atomic UInt64) | AudioService     | Monotonically increasing index of written samples.                     |
| **0x08 - 0x7F**    | Padding (120 bytes)            | N/A              | Ensures `ReadCursor`starts on a new cache line (128-byte alignment). |
| **0x80 - 0x87**    | `ReadCursor`(Atomic UInt64)  | InferenceService | Monotonically increasing index of read samples.                        |
| **0x88 - 0xFF**    | Padding (120 bytes)            | N/A              | Separates cursors from the data payload.                               |
| **0x100 - End**    | Audio Data (Float32 Array)     | Shared           | The circular buffer storage.                                           |

### 3.3 Swift Implementation: UnsafeAtomic and Raw Pointers

Swift's strict memory safety must be bypassed to interact with this raw shared memory. We utilize the `swift-atomics` library to create atomic views over the raw pointers.^11^

#### 3.3.1 Binding the IOSurface Memory

The `IOSurface` API provides `baseAddress` as an `UnsafeMutableRawPointer`. We bind this to our typed layout manually.

**Swift**

```
import IOSurface
import Atomics

final class SharedRingBuffer {
    let surface: IOSurface
    private let baseAddr: UnsafeMutableRawPointer
    private let capacity: Int
  
    // Pointers to the specific memory regions
    private let writeCursorPtr: UnsafeMutablePointer<UInt64>
    private let readCursorPtr: UnsafeMutablePointer<UInt64>
    private let bufferPtr: UnsafeMutablePointer<Float>
  
    init(capacity: Int) {
        self.capacity = capacity
        // Header size (256 bytes) + Data size
        let totalBytes = 256 + (capacity * MemoryLayout<Float>.size)
      
        let properties: =
      
        guard let surface = IOSurface(properties: properties) else {
            fatalError("Failed to allocate IOSurface")
        }
      
        self.surface = surface
        self.surface.lock(options:, seed: nil) // Lock to map into process space
        self.baseAddr = self.surface.baseAddress!
      
        // Bind pointers with padding offsets
        self.writeCursorPtr = baseAddr.bindMemory(to: UInt64.self, capacity: 1)
        self.readCursorPtr = (baseAddr + 128).bindMemory(to: UInt64.self, capacity: 1)
        self.bufferPtr = (baseAddr + 256).bindMemory(to: Float.self, capacity: capacity)
      
        // Initialize atomics to 0
        UnsafeAtomic<UInt64>.create(at: writeCursorPtr).store(0, ordering:.sequentiallyConsistent)
        UnsafeAtomic<UInt64>.create(at: readCursorPtr).store(0, ordering:.sequentiallyConsistent)
    }
}
```

#### 3.3.2 The Producer (Write) Logic

The Audio Service writes to the buffer. The critical correctness constraint here is  **Memory Ordering** . We must ensure that the audio data is fully written to the buffer *before* we update the `WriteCursor`. If the CPU reorders these operations, the Consumer might see the updated cursor while the data is still in a store buffer, leading to it reading old/garbage data.^12^

We use `.releasing` ordering for the store to the `WriteCursor` to enforce this barrier.

**Swift**

```
func write(_ samples: [Float]) -> Bool {
    let atomicWrite = UnsafeAtomic<UInt64>(at: writeCursorPtr)
    let atomicRead = UnsafeAtomic<UInt64>(at: readCursorPtr)
  
    // Load local copy of WriteCursor (Relaxed is fine, we own it)
    let currentWrite = atomicWrite.load(ordering:.relaxed)
    // Load ReadCursor with Acquire to ensure we see the latest value from Consumer
    let currentRead = atomicRead.load(ordering:.acquiring)
  
    let used = currentWrite - currentRead
    let free = UInt64(capacity) - used
  
    if UInt64(samples.count) > free {
        return false // Buffer overrun
    }
  
    // Write data (handling wrap-around)
    for (i, sample) in samples.enumerated() {
        let idx = Int((currentWrite + UInt64(i)) % UInt64(capacity))
        bufferPtr[idx] = sample
    }
  
    // Publish the write:.releasing prevents stores above from moving below this line
    atomicWrite.store(currentWrite + UInt64(samples.count), ordering:.releasing)
    return true
}
```

#### 3.3.3 The Consumer (Read) Logic

The Inference Service reads from the buffer. It uses `.acquiring` when loading the `WriteCursor` to ensure it sees all the data writes that happened before the cursor update.

**Swift**

```
func read() -> [Float] {
    let atomicWrite = UnsafeAtomic<UInt64>(at: writeCursorPtr)
    let atomicRead = UnsafeAtomic<UInt64>(at: readCursorPtr)
  
    let currentRead = atomicRead.load(ordering:.relaxed)
    let currentWrite = atomicWrite.load(ordering:.acquiring)
  
    let available = Int(currentWrite - currentRead)
    if available == 0 { return }
  
    var output = [Float]()
    output.reserveCapacity(available)
  
    for i in 0..<available {
        let idx = Int((currentRead + UInt64(i)) % UInt64(capacity))
        output.append(bufferPtr[idx])
    }
  
    // Update ReadCursor:.releasing ensures we are done reading before we say so
    atomicRead.store(currentRead + UInt64(available), ordering:.releasing)
  
    return output
}
```

---

## 4. Persistent XPC Connections and Lifecycle Management

Unlike a standard monolithic app, XPC services are ephemeral. The system daemon `launchd` manages them and will aggressively terminate them to reclaim memory if it perceives them as idle.^3^ For GhostType, this behavior is a critical risk: the Audio Service must persist while waiting for voice input, even if no data is flowing to the UI.

### 4.1 The "Jetsam" Mechanism and Idle Exit

MacOS employs a memory management mechanism known as Jetsam (inherited from iOS). When system memory pressure rises, Jetsam identifies low-priority or idle processes and terminates them instantly via `SIGKILL`—there is no `applicationWillTerminate` or clean shutdown opportunity.^1^ `launchd` also implements "idle exit," where services that have processed all messages and have no active transactions are terminated after a short timeout (often as low as 5 seconds).^15^

### 4.2 Legacy vs. Modern Persistence APIs

Historically, developers used `xpc_transaction_begin()` and `xpc_transaction_end()` to manually increment a reference count that prevented idle exit.^15^ While still functional, the modern and preferred API is  **`os_transaction_t`** .

Another option often cited is `ProcessInfo.performExpiringActivity`. However, this API is designed for *completing* a task (like saving a file) when the app is about to be suspended.^16^ It implies a finite duration and a specific expiration handler. It is **not** suitable for keeping an XPC service alive indefinitely during a recording session. `os_transaction` is the correct primitive for asserting "I am busy" for an indeterminate duration.^15^

### 4.3 Implementing the Transaction Lifecycle

The `AudioService` must tie the `os_transaction` to the logical concept of a "Recording Session," not just the physical connection to the client.

**Swift**

```
import os.transaction

class AudioSessionManager: GhostTypeAudioXPCProtocol {
    // Strong reference to the transaction keeps the process alive
    private var activeTransaction: os_transaction_t?
  
    func startSession() {
        // Create the transaction. The string label is for debugging (visible in 'taskinfo')
        // The return value is an ARC-managed object. As long as we hold it, 
        // launchd counts an active transaction.
        self.activeTransaction = os_transaction_create("com.ghosttype.audio.active_session")
      
        // Start hardware audio engine...
    }
  
    func stopSession() {
        // Stop hardware...
      
        // Releasing the object drops the transaction count.
        // If count hits 0 and no XPC messages are pending, launchd may kill the process.
        self.activeTransaction = nil 
    }
}
```

### 4.4 Robustness: Handling Client Disappearance

A major failure mode in distributed systems is the "zombie transaction." If the Main App crashes while a recording session is active, it will never send the `stopSession` message. The Audio Service would hold the `os_transaction` forever, consuming microphone resources and battery until the user manually kills it or reboots.

To prevent this, we must link the transaction lifetime to the **XPC Connection** lifetime.

**Swift**

```
class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let sessionManager = AudioSessionManager()
      
        // Configure connection...
      
        // INVALIDATION HANDLER
        // This closure is executed if the connection is severed (e.g., Client crash)
        newConnection.invalidationHandler = { [weak sessionManager] in
            // Force stop the session, which releases the os_transaction
            sessionManager?.stopSession()
        }
      
        newConnection.resume()
        return true
    }
}
```

This ensures that the service's lifecycle is strictly bound to the client's presence, preventing resource leaks.^14^

---

## 5. The Inference Pipeline: Async VAD and Grammar Correction

The Inference Service is the computational heavy lifter. It runs two distinct models: a Voice Activity Detector (VAD) for segmentation and a T5 model for grammar correction. The challenge is managing these models without blocking the XPC communication loop.

### 5.1 Streaming VAD with CoreML

We utilize the Silero VAD model, converted to CoreML.^18^ This model requires a sliding window of audio samples (typically 512 samples at 16kHz).

MLMultiArray Performance:

Creating a new MLMultiArray for every 32ms chunk of audio is prohibitively expensive due to memory allocation and copying overhead. We must reuse a persistent MLMultiArray buffer.

**Swift**

```
import CoreML

class VADEngine {
    let model: SileroVAD // Auto-generated class
    let inputBuffer: MLMultiArray 
  
    init() {
        // Pre-allocate the buffer once. 
        // Shape  for batch 1, 512 samples.
        self.inputBuffer = try! MLMultiArray(shape: , dataType:.float32)
    }
  
    func process(chunk: [Float]) -> Double {
        // Zero-copy load: access the raw pointer of the MLMultiArray
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(inputBuffer.dataPointer))
      
        // Copy samples into the MLMultiArray's backing store
        chunk.withUnsafeBufferPointer { srcPtr in
            ptr.assign(from: srcPtr.baseAddress!, count: 512)
        }
      
        // Run prediction
        // Note: CoreML predictions are synchronous, so this must run off the main actor
        let output = try? model.prediction(input: inputBuffer)
        return output?.probability?? 0.0
    }
}
```

### 5.2 Async T5 Grammar Correction Pipeline

Once speech is detected and transcribed (via Whisper), the raw text flows into the T5 pipeline. T5 is computationally expensive; correcting a sentence might take 200-500ms on the Neural Engine. If the user is dictating rapidly, we cannot run T5 on every partial result. We need an **Async Debounce** pattern.

#### 5.2.1 The Actor-Based Pipeline

We use a Swift Actor to serialize access to the T5 model and manage the "pending" state. This pattern leverages Swift's cooperative thread pool to avoid spawning excessive threads.^20^

**Swift**

```
actor GrammarPipeline {
    private var activeTask: Task<String, Error>?
    private let t5Model: T5Model
  
    func submit(_ text: String) async throws -> String {
        // 1. Cancel any calculation currently waiting or running
        activeTask?.cancel()
      
        // 2. Create a new task
        let task = Task { [text] in
            // Debounce: Wait 300ms. If a new request comes in during this wait,
            // this task will be cancelled at the suspension point.
            try await Task.sleep(nanoseconds: 300 * 1_000_000)
          
            // Check cancellation before starting heavy compute
            try Task.checkCancellation()
          
            // Run Inference
            return try await t5Model.correct(text)
        }
      
        activeTask = task
      
        // 3. Await the result
        return try await task.value
    }
}
```

This "Restartable Task" pattern ensures that intermediate states are discarded, and only the "settled" text triggers the heavy inference, saving battery and reducing thermal throttling.^21^

---

## 6. Robust Text Injection: The "Golden Path" and Fallbacks

The "Last Mile" problem—getting the text from GhostType into the user's active application—is historically the most brittle part of macOS automation. Applications vary wildly in their support for accessibility APIs. We define a tiered strategy: Tier 1 (Accessibility), Tier 2 (Pasteboard Simulation), and Tier 3 (AppleScript/User Notification).

### 6.1 Tier 1: Accessibility API (AXUIElement)

This is the "Golden Path." It uses the system-wide Accessibility API to locate the focused text field and insert text programmatically.^22^ It is invisible to the clipboard and extremely fast.

**Implementation Nuances:**

1. **Trust Check:** We must verify `AXIsProcessTrusted()` returns true. If not, we must prompt the user to open System Settings.
2. **Attribute Selection:** Standard Cocoa apps (`NSTextView`) support `kAXValueAttribute` or `kAXSelectedTextAttribute`. However, some apps implement one but not the other. The code must try `kAXSelectedTextAttribute` first (inserting at cursor), and fall back to `kAXValueAttribute` (replacing content) only if necessary.^23^
3. **Electron Quirks:** Electron apps (VS Code, Slack, Discord) have a notorious history of AX bugs. Specifically, on macOS 14+ (Sonoma/Sequoia), Electron apps may report success when setting `kAXSelectedTextAttribute` but fail to update the visual DOM, or return `kAXErrorCannotComplete` unpredictably.^24^

### 6.2 Tier 2: The Robust Pasteboard Fallback

When AX fails (common in VS Code or Java apps), we must fallback to simulating a user Paste (Cmd+V). This is destructive to the user's clipboard, so we must implement a "Save-Restore" dance.

The "Safe Restore" Protocol:

Simply saving NSPasteboardItem references is insufficient because they are often lazy promises that disappear when we clear the board. We must deep-copy the data.26

**Swift**

```
extension NSPasteboard {
    func snapshot() -> {
        return self.pasteboardItems?.map { item in
            let newItem = NSPasteboardItem()
            // Iterate all types to ensure we capture images, RTF, PDFs, etc.
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }??
    }
}

func injectViaPasteboard(_ text: String) {
    let board = NSPasteboard.general
    let backup = board.snapshot() // 1. Save
  
    board.clearContents()
    // 2. Mark as Transient to hide from clipboard managers (e.g., Maccy)
    // 'org.nspasteboard.TransientType' is the standard flag.[27]
    board.setString(text, forType:.string)
    board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
  
    // 3. Simulate Cmd+V using CGEvent
    let src = CGEventSource(stateID:.hidSystemState)
    let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // 'v'
    vDown?.flags =.maskCommand
    vDown?.post(tap:.cghidEventTap)
  
    let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
    vUp?.flags =.maskCommand
    vUp?.post(tap:.cghidEventTap)
  
    // 4. Restore (Delayed)
    // We must wait for the target app's runloop to process the Paste event.
    // 200ms is usually safe.
    DispatchQueue.global().asyncAfter(deadline:.now() + 0.2) {
        board.clearContents()
        board.writeObjects(backup)
    }
}
```

**Security Note:** `CGEvent` simulation requires the `com.apple.security.temporary-exception.apple-events` entitlement or Accessibility permissions, similar to the AX API.^28^

---

## 7. Security and Deployment Considerations

Migrating to this architecture impacts the deployment pipeline, specifically regarding App Sandboxing and Notarization.

### 7.1 Entitlement Strategy

Each bundle requires a specific set of entitlements.

| **Bundle**            | **Entitlement**                                 | **Justification**                 |
| --------------------------- | ----------------------------------------------------- | --------------------------------------- |
| **Audio Service**     | `com.apple.security.device.audio-input`             | Required for microphone access.         |
| **All Services**      | `com.apple.security.app-sandbox`                    | Mandatory for App Store / Notarization. |
| **Main App**          | `com.apple.security.files.user-selected.read-write` | Saving recordings to disk.              |
| **Injection Service** | `com.apple.security.scripting-targets`              | If AppleScript fallback is used.        |

The TCC Paradox:

The Injection Service needs Accessibility rights. However, XPC services cannot trigger the system TCC prompt. The Main App must check AXIsProcessTrusted() and, if false, guide the user to System Settings to grant permission to the Main App. The XPC service inherits this trust if it is properly signed and bundled within the main app.25

### 7.2 Code Signing and Group Identifiers

To share `IOSurface` and `UserDefaults` (if needed), all services must belong to the same App Group. The `IOSurface` lookup does not strictly require App Groups if the surface ID is passed over XPC, but it is best practice for shared resources.

---

## 8. Conclusion

The transition of GhostType to a distributed XPC architecture is a significant engineering undertaking that trades the simplicity of a monolith for the robustness of a system. By implementing the  **IOSurface Ring Buffer** , we solve the latency and copy-overhead problems of IPC. By utilizing  **`os_transaction`** , we tame the aggressive macOS memory management and ensure recording persistence. By adopting the  **Async Actor Pipeline** , we ensure the heavy T5 model serves the user without freezing the application. Finally, the **Tiered Injection Strategy** ensures that GhostType works reliably across the diverse landscape of macOS applications.

This architecture serves as a foundation not just for the current feature set, but for future expansions—such as running larger models (Llama 2/3) or supporting multi-modal inputs—without destabilizing the core user experience. The engineering team is advised to begin the migration by establishing the Audio Service and the IOSurface transport layer, as these constitute the critical path for the system's reliability.

`</research>`
