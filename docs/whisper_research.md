# Architectural Blueprint for GhostType v2: High-Performance Audio Intelligence on Apple Silicon

## Executive Summary

The mandate for GhostType v2 is precise, ambitious, and technically unforgiving: construct a native macOS dictation engine that shatters the 200ms latency barrier—the psychological threshold for perceived instantaneity—while maintaining server-grade accuracy comparable to OpenAI’s Whisper Large-v3. This objective requires navigating the "Iron Triangle" of latency, accuracy, and resource efficiency within the strict constraints of consumer hardware, specifically the Apple Silicon (M-Series) architecture.

The current landscape of local dictation, populated by incumbents like Superwhisper and Wispr Flow, demonstrates market viability but often relies on trade-offs that compromise either speed or accuracy. GhostType’s existing implementation, tethered to `SFSpeechRecognizer`, suffers from the mediocrity of on-device generic models, yielding Word Error Rates (WER) indistinguishable from legacy dictation systems of the past decade. The failed experiments with `MoonshineTiny` and `T5` grammar correction highlight the danger of mismatched model selection: one lacks the vocabulary for modern context, and the other introduces unacceptable latency.

This report presents a comprehensive technical analysis and the "Golden Path" Engineering Decision Record (EDR) for the Q1 2025 development cycle. The analysis concludes that the optimal architecture requires a radical departure from the Apple Neural Engine (ANE) via CoreML in favor of the GPU-accelerated Apple MLX framework. It necessitates the adoption of the **Whisper v3 Turbo** model with aggressive 4-bit quantization and the integration of the **TEN VAD** engine via a direct C++ interoperability layer. Furthermore, the "Rust Bridge" hypothesis is rejected in favor of a native Swift-to-C++ Zero-Copy audio pipeline, leveraging the Unified Memory Architecture (UMA) of Apple Silicon to eliminate redundant memory operations. This document details the rigorous technical justification for these decisions, dissecting the hardware substrate, the inference engine dynamics, and the precise audio engineering required to achieve the "instant" user experience.

---

## 1. The Silicon Landscape: Architectural Constraints & Opportunities

To engineer a system capable of sub-200ms Time-to-First-Token (TTFT), one must first possess a granular understanding of the substrate upon which GhostType v2 will operate. The Apple Silicon M-Series (M1, M2, M3, M4) represents a paradigm shift in consumer computing, introducing a Unified Memory Architecture (UMA) that fundamentally alters the optimization landscape for high-performance audio intelligence. Understanding the specific behaviors of the Neural Engine versus the GPU in this unified context is the prerequisite for all subsequent architectural decisions.

### 1.1 Unified Memory Architecture (UMA) and Zero-Copy Potentials

In traditional x86 architectures with discrete GPUs, the CPU and GPU possess discrete memory pools. Data captured by the microphone enters system RAM (CPU domain) and must be transferred over a PCIe bus to VRAM (GPU domain) for processing. This transfer imposes a latency penalty and consumes power. Apple Silicon eliminates this dichotomy. The M-Series chips grant all compute units—CPU, GPU, and Neural Engine (ANE)—access to a single, high-bandwidth pool of Unified Memory.

For a high-frequency dictation engine, this presents a critical optimization opportunity:  **Zero-Copy Inference** . Audio buffers captured by `AVAudioEngine` (CPU domain) can theoretically be read directly by the inference engine (GPU/ANE domain) without the latency penalty of `memcpy` operations or bus transfers. However, leveraging this capability requires bypassing high-level abstractions that enforce safety through implicit copying. The architecture proposed herein relies heavily on `UnsafePointer` manipulation in Swift and C++ interoperability to maintain a contiguous memory residency for audio data from capture to inference.

The implications of UMA extend beyond simple data transfer. It affects memory bandwidth contention. In a dictation scenario, the system is simultaneously writing audio data to memory, reading model weights from memory to the compute units, and writing text output back to memory. The M1 Pro/Max chips offer bandwidths of 200GB/s and 400GB/s respectively, but the base M1/M2/M3 chips are constrained to roughly 68GB/s to 100GB/s. This bandwidth constraint dictates that model size matters not just for capacity, but for speed; a smaller quantized model consumes less bandwidth per inference pass, leaving more headroom for the UI and system background tasks, thereby preventing the "UI freeze" phenomenon mentioned in the constraints.^1^

### 1.2 The Compute Unit Dilemma: ANE vs. GPU

The M-Series chips offer two primary accelerators for matrix multiplication, and choosing between them is the single most significant architectural decision for GhostType v2.

#### 1.2.1 Apple Neural Engine (ANE)

The ANE is a specialized NPU (Neural Processing Unit) optimized for energy efficiency and fixed-size compute graphs. It is designed to execute specific convolution and matrix multiplication operations at extremely low power (approx. 0.3W per forward pass for Whisper-class models).^3^

* **Throughput Characteristics:** The ANE excels at throughput—processing long queues of data where latency is less critical than battery life.
* **Compilation Constraints:** The ANE requires models to be compiled via `coremlc`. This compiler aggressively optimizes the graph, often fusing operations. However, this optimization requires static input shapes. The ANE does not natively support dynamic sequence lengths; an audio buffer of 3 seconds must be padded to the model's maximum input size (e.g., 30 seconds), or the model must be split into multiple sub-models of varying lengths.
* **The Cold Start Penalty:** A critical finding in real-time applications is the ANE's "cold start" latency. Loading a compiled CoreML model into the ANE's dedicated SRAM and warming up the circuit can take hundreds of milliseconds, sometimes exceeding 1 second if the ANE has powered down. For a dictation app where the user expects immediate responsiveness, this wake-up latency is often fatal to the <200ms goal.^4^

#### 1.2.2 The GPU (Metal)

The Apple GPU is a Tile Based Deferred Rendering (TBDR) architecture that also serves as a general-purpose parallel compute unit via the Metal API.

* **Flexibility:** Unlike the ANE, the GPU supports dynamic graph construction. It can process a 2-second audio chunk as a 2-second chunk, without the overhead of padding it to 30 seconds. This "dynamic shape" capability is intrinsic to the Transformer architectures used in Whisper.
* **Latency Profile:** While the GPU consumes more power than the ANE, its wake-up time is significantly shorter. The GPU is almost always active (driving the display), meaning it resides in a higher power state than the typically dormant ANE.
* **Raw Compute:** On higher-end chips (Pro/Max/Ultra), the GPU's raw TFLOPS capability vastly outstrips the ANE. On base chips, they are comparable, but the GPU's memory bandwidth access is often superior for the irregular memory access patterns found in attention mechanisms.^2^

The analysis indicates that for  *interactive, real-time dictation* —where the user expects an immediate response to a keypress or wake word—the GPU (via Metal/MLX) offers a superior latency profile compared to the ANE (via CoreML), primarily due to the latter's rigid compilation requirements and model loading penalties.

---

## 2. The Inference Engine Showdown: WhisperKit vs. MLX

The core of the GhostType v2 architecture is the inference engine. The evaluation pitted **Argmax WhisperKit** (CoreML/ANE) against **Apple MLX** (Metal/GPU). This comparison is not merely about raw speed benchmarks; it is about architectural suitability for *speculative streaming* and  *instant interactions* .

### 2.1 Argmax WhisperKit (CoreML/ANE)

**Argmax WhisperKit** ^5^ is the premier framework for deploying Whisper on Apple devices using CoreML. It represents the "standard" path for iOS/macOS developers, leveraging the system-native frameworks.

#### 2.1.1 Throughput vs. Latency

WhisperKit demonstrates high throughput. When transcribing a pre-recorded file, it can pipeline the audio to the ANE efficiently. Benchmarks show it achieving up to 45x real-time speed on M-series chips for long-form audio.^6^ However, throughput is not latency. In a live dictation scenario, the audio arrives in small, unpredictable bursts. The ANE's requirement for static graph compilation means that WhisperKit typically processes audio in fixed 30-second windows. To handle real-time streams, it must employ complex chunking or padding strategies, which introduce processing overhead and latency "jitters."

#### 2.1.2 The "Speculative Decoding" Mismatch

The user query specifically asks about "Simul-Streaming" and speculative decoding.3 Speculative decoding involves using a small "draft" model to predict tokens and a large "oracle" model to verify them. This technique is highly effective on GPUs where memory bandwidth is the bottleneck, as the verification step is compute-bound.

However, research specifically targeting Whisper on ANE 3 indicates that speculative decoding yields diminishing returns. The overhead of running the drafter model multiple times (beam length) combined with the ANE's graph dispatch overhead negates the speedup. For Whisper Large v3 Turbo, the speedup was found to be a negligible 1.25x, compared to the complexity cost.

Furthermore, "Simul-Streaming" (processing partial buffers) is inefficient on WhisperKit. Because the ANE model expects a fixed input (e.g., 30s mel-spectrogram), a 2-second utterance must be padded with 28 seconds of silence. The ANE then processes the entire 30-second equivalent of computation (masked, perhaps, but still passing through the fixed graph). This results in wasted compute and battery, and higher latency than necessary for short phrases.

#### 2.1.3 Compiler Fragility

Development logs and community discussions ^8^ reveal significant issues with `ANECompiler` when handling newer architectures like Whisper v3 Turbo on older chips (M1). The compiler often fails to map specific Transformer operations to the ANE, forcing a fallback to the GPU or CPU. When this fallback occurs within a CoreML container, it often incurs a performance penalty greater than running natively on the GPU from the start, due to the overhead of the CoreML runtime managing the fallback.

### 2.2 Apple MLX (Metal/GPU)

**Apple MLX** ^9^ is an array framework designed by Apple Research. It is explicitly modeled after NumPy and PyTorch but is built from the ground up for Apple Silicon.

#### 2.2.1 Dynamic Graph Construction

MLX utilizes "Lazy Computation." It builds the computation graph just-in-time. This is the critical differentiator for GhostType v2. When a 2-second audio buffer arrives, MLX constructs a graph for a 2-second input. It does not pad. It does not waste compute on silence. This architectural property allows MLX to handle "Simul-Streaming" naturally. The engine can ingest variable-length audio buffers (e.g., 200ms, then 400ms, then 600ms) without recompiling the graph or resetting the engine state.

#### 2.2.2 Latency Profile and Warm-up

Benchmarks comparing MLX to CoreML implementations 11 reveal that while CoreML may win on long-file throughput (battery efficiency), MLX dominates on "Time-to-First-Token." The "cold start" on MLX is effectively just the time to load the weights into RAM (which is fast on NVMe SSDs) and the first Metal kernel compilation (cached by the OS).

Crucially, MLX allows for "KV-Cache" persistence in a way that is more transparent and controllable than CoreML. For streaming dictation, maintaining the Key-Value cache of the Transformer's attention mechanism is vital to avoid re-processing the entire audio history for every new token. MLX's Python and C++ APIs expose this state directly, allowing the GhostType engineer to implement a custom "Sliding Window" attention mechanism that is impossible to implement efficiently inside the black box of CoreML.14

#### 2.2.3 Maturity of `mlx-swift`

The user questions if `mlx-swift` is mature enough.^9^ While Apple labels it as "research," the underlying C++ core (`mlx`) is stable and used in production-grade research. `mlx-swift` is a thin wrapper around this C++ core.

* **Production Readiness:** The core tensor operations are robust. The primary risk lies in API changes, which can be mitigated by vendoring the library.
* **UI Responsiveness:** The concern that GPU usage will freeze the UI is largely unfounded on M-Series chips due to the high-priority QoS channels available for UI rendering. As long as the MLX inference runs on a background thread (e.g., `DispatchQueue(label: "com.ghosttype.inference", qos:.userInteractive)`), the OS scheduler ensures the main thread retains priority for Core Animation commits. The GPU preemption on M-Series is granular enough to interleave UI rendering frames with compute kernels.^2^

### 2.3 Recommendation: The MLX Golden Path

**Verdict:** GhostType v2 must utilize  **MLX** .

For a "shipping app" targeting <200ms latency, the determinism, flexibility, and dynamic nature of MLX on the GPU outweigh the battery efficiency of the ANE. The ANE is a throughput engine; the GPU is a latency engine. Dictation is a latency problem.

The recommendation is to build a custom C++ inference loop using mlx's C++ API, exposed to Swift. This avoids the overhead of Python runtime entirely (unlike mlx-whisper Python package) and allows for the precise memory management required for Zero-Copy audio injection.

**Trade-off Analysis:**

* **Latency:** MLX Wins (Dynamic shapes, no ANE wake-up).
* **Accuracy:** Tie (Both run the same model weights).
* **Efficiency:** WhisperKit Wins (ANE is lower power).
* **Flexibility:** MLX Wins (KV-Cache control, custom decoding).

**Decision:** We accept the slightly higher power consumption of the GPU to secure the "instant" <200ms response time.

---

## 3. Model Selection for "Instant" Accuracy

The conflict between accuracy and speed is addressed by the model architecture. The "Iron Triangle" demands server-grade accuracy locally, which historically required massive models.

### 3.1 Candidate Analysis

#### 3.1.1 Whisper Large-v3

* **Stats:** 1.55B parameters. 32 Encoder layers, 32 Decoder layers.
* **Performance:** The gold standard for open-source accuracy. However, on an M1 Air, inference times can exceed 100-150ms per token even with optimization. This creates a "typewriter" effect that feels sluggish to the user.
* **Suitability:** Too slow for the "instant" requirement on base hardware.

#### 3.1.2 Distil-Whisper v3

* **Stats:** Distilled from Large-v3. Typically reduces the decoder layers to 2 or 4.
* **Performance:** Approx 6x faster than Large-v3.
* **Drawbacks:** Distillation is a lossy process. While WER remains low on clean test sets, distilled models often exhibit "brittleness" in real-world noisy environments (coffee shops, open offices). They are also more prone to hallucinations in silence—a notorious Whisper problem where the model generates text like "Subtitles by Amara.org" when no one is speaking.
* **Suitability:** Good, but potentially compromised accuracy in challenging acoustic environments.

#### 3.1.3 Whisper v3 Turbo

* **Stats:** ~809M parameters. 4 Decoder layers.
* **Architecture:** This is a *pruned and finetuned* version of Large-v3, not a distilled model in the traditional teacher-student sense. It retains the full encoder capacity of Large-v3 but drastically shortens the decoder.^16^
* **Performance:** Benchmarks indicate it achieves near-parity with Large-v3 in accuracy (WER ~8-9% vs 7.9% for Large-v3) while matching or exceeding the speed of Distil-Whisper (approx. 8x-10x speedup over Large-v3).^12^
* **Why it wins:** The encoder is where acoustic understanding happens; the decoder is where language generation happens. By keeping the large encoder, Turbo retains the robust "hearing" of the large model, while the short decoder speeds up the "typing."

### 3.2 Quantization: The Sweet Spot

Running models at native precision (Float16 or Float32) is unnecessary for speech recognition and wasteful of memory bandwidth. The M-Series memory bandwidth is the primary bottleneck for Transformer inference.

* **Int8:** Offers a 2x memory reduction over FP16. High fidelity.
* **Int4:** Offers a 4x memory reduction. For 7B+ parameter LLMs, Int4 can degrade reasoning capabilities. However, for the ~1B parameter Whisper architecture, the degradation in **Speech-to-Text (STT)** tasks is imperceptible to the end-user. Research shows that 4-bit quantization increases WER by <0.5% in most scenarios while doubling the inference speed and halving the memory footprint.^13^
* Decision: Whisper v3 Turbo (4-bit Quantized).
  This configuration fits entirely within the high-speed system cache of the GPU (approx 400MB-500MB), minimizing DRAM access penalties. It loads instantly.

### 3.3 The "Hybrid" Fallacy

The proposal to run a "Hybrid" model (`Tiny.en` for preview, `Large-v3` for correction) is a common pattern in cloud-based dictation but is **architecturally flawed** for local deployment on Unified Memory.

1. **Memory Pressure:** Loading two models (`Tiny` + `Large`) consumes more RAM. Even if `Tiny` is small, `Large` is big.
2. **Context Switching:** The GPU must switch contexts between the `Tiny` graph and the `Large` graph. This incurs overhead and cache thrashing.
3. **UI Jitter:** Users find it distracting when text appears (Tiny), then changes (Large). It erodes trust in the engine.
4. **Obsolescence:** With Whisper v3 Turbo 4-bit running on MLX, the inference speed is sufficient (TTFT < 200ms) to render the "preview" model redundant. The Turbo model is fast enough to serve as the "Instant" preview while being accurate enough to be the final output.

**Insight:** GhostType v2 will use a  **Single-Model Architecture** . This simplifies the codebase, reduces memory footprint, and provides a stable, deterministic user experience.

---

## 4. The Audio Hot-Path: The "Rust Bridge" vs. Native Swift

The existing Python-based research suggested using Rust (`cpal`) to avoid Garbage Collection (GC) pauses.^13^ In the context of a native Swift application, this hypothesis requires rigorous scrutiny.

### 4.1 The Myth of the Necessary Bridge

Rust is excellent for memory safety and low-latency audio. However, introducing a Rust dependency into a Swift codebase creates a complex Foreign Function Interface (FFI) boundary. Data must move from Swift (UI) -> Rust (Audio) -> C++ (MLX). This "sandwich" architecture introduces build complexity (Cargo + Xcodebuild) and potential marshaling overhead.

Crucially, Swift is not a garbage-collected language in the same sense as Java or Python. It uses Automatic Reference Counting (ARC). While ARC can introduce pauses if massive object graphs are deallocated on the main thread, it is deterministic. In a strictly typed audio callback using UnsafePointer and structs (value types), Swift incurs zero ARC overhead.

### 4.2 The "Zero-Copy" Strategy

The goal is to move audio from the microphone to the MLX inference engine without copying the data more times than absolutely necessary.

#### 4.2.1 The Legacy Path (To Avoid)

Standard `AVAudioEngine` implementation:

1. Microphone -> OS Buffer.
2. OS Buffer -> `AVAudioNodeTap` (Copy 1).
3. `AVAudioNodeTap` -> Swift `[Float]` array (Copy 2).
4. Swift Array -> Python/Rust/C++ Bridge (Copy 3).
5. Bridge -> MLX Tensor (Copy 4).

#### 4.2.2 The GhostType v2 Path (Swift + C++ Interop)

Swift 5.9+ introduces enhanced C++ Interoperability, allowing Swift to call C++ APIs directly.

1. **Audio Capture:** Use `AVAudioEngine` configured with `VoiceProcessingIO`. This unit provides hardware echo cancellation (AEC), which is essential for dictation if the user is listening to music or on a call.
2. **Buffer Access:** The `installTap` block provides an `AVAudioPCMBuffer`. This object wraps a C-level `AudioBufferList`.
3. **Pointer Extraction:** We access `buffer.floatChannelData` directly. This is an `UnsafePointer<Float>`.
4. **Direct C++ Injection:** We pass this pointer immediately to a C++ function exposed to Swift.
5. **Ring Buffer:** The C++ function writes this data into a pre-allocated  **Lock-Free Ring Buffer** .
6. **MLX View:** The MLX engine (running in C++) creates an `mlx::array` that *views* the data in the Ring Buffer. (Note: While MLX arrays are immutable and typically own their data, for the inference step we can perform a single optimized `memcpy` from the Ring Buffer to the MLX input tensor, which is an O(N) operation where N is tiny—microseconds—compared to the millisecond-scale inference).

**Decision:** Reject the Rust Bridge. Implement a  **Native Swift-C++ Direct Pipeline** . This reduces the tech stack to Apple-native languages, simplifying debugging and build times, while achieving the same "Zero-Copy" efficacy as Rust.

---

## 5. Voice Activity Detection (VAD): The Gatekeeper

VAD is the critical component that tells the engine when to listen and, more importantly, when to *stop* and commit the text. Latency here is perceived as "lag" between the user stopping speaking and the text appearing.

### 5.1 The Contenders

#### 5.1.1 EnergyVAD (CoreML)

* **Mechanism:** Threshold-based energy detection.
* **Pros:** Extremely low CPU usage.
* **Cons:** Fails in noisy environments (coffee shops), triggering false positives. It has no concept of "human speech," only "loudness."

#### 5.1.2 Silero VAD (v4/v5)

* **Mechanism:** Deep Neural Network (RNN/LSTM).
* **Status:** The industry standard for open-source VAD.
* **Pros:** High accuracy, robust to noise.
* **Cons:** Typically relies on ONNX Runtime or PyTorch. The ONNX Runtime adds a significant binary size dependency (approx 20-50MB depending on stripping). Latency is good (30ms chunks), but the "cut-off" behavior can be "sticky," waiting too long to confirm silence.^19^

#### 5.1.3 TEN VAD (The New Challenger)

* **Mechanism:** A recently released framework (Oct/Nov 2024 timeframe).^19^
* **Architecture:** C++ Native core with ONNX models, but highly optimized for minimal footprint.
* **Performance:** Benchmarks indicate significantly lower computational overhead and library size (306KB vs Silero's ~2MB) and faster "speech-to-non-speech" transition detection.
* **Key Advantage:** It is  **Agent-Optimized** . It is specifically tuned to detect the *end* of an utterance as fast as possible to allow voice agents to reply instantly. This aligns perfectly with the GhostType goal of "instant" text commitment.
* **Integration:** Being C++ native, it links directly into the GhostType binary via the C++ Interop layer, avoiding the need for a separate ONNX Runtime wrapper if the model is compiled or loaded via a lightweight inference shim.

### 5.2 Recommendation: Adopt TEN VAD

Verdict: TEN VAD is the superior choice for Q1 2025.

Its C++ native nature aligns perfectly with the MLX/C++ architecture. It allows for tighter integration into the audio loop without bridging through Python or heavy frameworks. The superior cut-off detection is crucial for the "snappy" feel of GhostType v2.

**Implementation Note:** We will bind the C++ TEN VAD library directly to Swift. The audio ring buffer will feed both the VAD (to check for speech) and the MLX Engine (to transcribe).

---

## 6. Architecture Blueprint

The proposed architecture is a **Hybrid Swift/C++ System** utilizing **Unified Memory** for zero-copy data flow.

### 6.1 High-Level System Diagram

The system operates on three concurrent threads with distinct Quality of Service (QoS) levels.

| **Thread / Actor**   | **QoS**       | **Responsibility**                                           |
| -------------------------- | ------------------- | ------------------------------------------------------------------ |
| **Audio Thread**     | `UserInteractive` | Captures mic input, AEC, writes to Ring Buffer.                    |
| **Inference Thread** | `UserInitiated`   | Reads Ring Buffer, VAD check, MLX Inference, Speculative Decoding. |
| **UI Thread**        | `Main`            | Renders text overlay, handles key events.                          |

**Code snippet**

```
graph TD
    Mic[Microphone Input] -->|AVAudioEngine VoiceProcessing| Tap
    Tap -->|UnsafePointer Float| Ring
  
    subgraph Inference Loop [C++ / MLX]
        Ring -->|Read Head| VAD
        VAD -->|State: SPEECH| MLX[MLX Inference Engine]
        VAD -->|State: SILENCE| Commit
      
        MLX -->|Input: Audio Tensor| Decoder
        Decoder -->|Output: Tokens| Stabilizer
    end
  
    Stabilizer -->|Stable Tokens| UI
    Stabilizer -->|Ghost Tokens| UI
    Commit -->|Paste| App[Active Application]
```

### 6.2 Component Detail

#### 6.2.1 Audio Ingestion (The Ring)

* **Implementation:** A Fixed-Size Circular Buffer (Ring Buffer) implemented in C++.
* **Rationale:** `AVAudioEngine` callbacks arrive on a real-time thread. We cannot perform memory allocation or complex logic here. We simply `memcpy` the incoming samples into the C++ Ring Buffer.
* **Size:** 30 seconds of audio capacity (approx 1MB at 16kHz float). This handles even long dictations. If the buffer wraps, we drop the oldest audio (which has likely already been transcribed).

#### 6.2.2 The Sliding Window (Simul-Streaming)

Instead of processing fixed chunks (e.g., waiting for 5 seconds of audio), GhostType v2 uses a **Sliding Window** strategy:

1. **Buffer:** Accumulate audio in the Ring Buffer.
2. **Stride:** Every 100-200ms (or upon VAD speech detection), create a "View" of the last **$N$** seconds of audio.
3. **Inference:** Pass this View to MLX.
4. **Stability Heuristic:** Whisper outputs a stream of tokens. Because the context grows, the model might change its mind about previous words. The engine compares the current output with the previous output. Tokens that have remained stable for 2 consecutive inference passes are "committed" to the UI (displayed in black), while unstable tokens are "ghosted" (displayed in gray). This gives the user instant feedback ("Ghost" text) that solidifies into "Type" text.

#### 6.2.3 Decoding Strategy

* **Method:**  **Greedy Decoding** .
* **Why:** Beam search improves accuracy slightly but increases computation linearly with the beam width. For real-time dictation, the latency cost of Beam Search (even Beam Size 2) usually outweighs the accuracy gain. Whisper Turbo is robust enough to perform well with Greedy decoding.
* **Prompting:** Use the `initial_prompt` parameter to condition the model with the previously transcribed sentence. This ensures context continuity (e.g., proper capitalization and punctuation flow) without needing to re-feed the entire audio history into the encoder, saving compute.

---

## 7. Engineering Decision Record (EDR)

Reference ID: EDR-2025-GT2

Date: Q4 2024

Status: APPROVED

Context: GhostType v2 Architecture for Apple Silicon

### Decision 1: Inference Framework

* **Choice:** **Apple MLX (via Swift/C++ bindings)**
* **Rejected:** WhisperKit (CoreML/ANE).
* **Reasoning:** MLX provides superior flexibility for streaming architectures, eliminates the ANE cold-start penalty (crucial for <200ms TTFT), and supports dynamic shapes required for variable-length dictation. The power trade-off is acceptable for the latency gain.

### Decision 2: Model Architecture

* **Choice:** **Whisper v3 Turbo (4-bit Quantized)**
* **Rejected:** Distil-Whisper, Whisper Large-v3, Hybrid Tiny/Large.
* **Reasoning:** Turbo offers the optimal convergence of accuracy (comparable to Large) and speed (comparable to Distil). 4-bit quantization allows the model to reside in system cache with negligible accuracy loss. Single-model architecture reduces complexity and memory pressure.

### Decision 3: Audio Pipeline

* **Choice:** **Native Swift `AVAudioEngine` + C++ Ring Buffer**
* **Rejected:** Rust (`cpal`), Python (`pyaudio`).
* **Reasoning:** Swift-C++ interoperability renders the Rust bridge redundant. Direct memory access via `UnsafePointer` achieves the Zero-Copy goal with lower build complexity and utilizes native Apple echo cancellation (VoiceProcessingIO).

### Decision 4: Voice Activity Detection

* **Choice:** **TEN VAD (C++ Native)**
* **Rejected:** Silero VAD, EnergyVAD, WebRTC VAD.
* **Reasoning:** TEN VAD offers lower latency for end-of-speech detection and a smaller resource footprint (306KB), critical for the "snappy" feel of the dictation engine. It integrates natively with the C++ inference loop.

### Decision 5: Streaming Strategy

* **Choice:** **Sliding Window with Stability Heuristic (Greedy Decoding)**
* **Reasoning:** Allows for instant text preview (<200ms) that stabilizes over time. Eliminates the need for a separate "Draft" model.

---

## 8. Detailed Implementation Strategy & Failure Analysis

### 8.1 The C++ Interop Layer

GhostType v2 will require a lightweight C++ module (e.g., `AudioCore`) included in the Swift project. This module acts as the safe harbor for the audio data.

**C++**

```
// AudioCore.hpp (Conceptual)
#include <vector>
#include <atomic>

class AudioRingBuffer {
    std::vector<float> buffer;
    std::atomic<size_t> writeHead;
public:
    AudioRingBuffer(size_t capacity);
    void write(const float* data, size_t count);
    // Returns a vector for MLX. 
    // Optimization: If MLX allows strided views, we return a view. 
    // Otherwise, we copy the specific linear segment needed for inference.
    std::vector<float> readLast(size_t seconds); 
};
```

In Swift, the `AVAudioNodeTapBlock` interacts with this C++ class directly, bypassing any Obj-C messaging overhead:

**Swift**

```
// Swift 5.9
let audioCore = AudioRingBuffer(capacity: 30 * 16000) // 30 seconds
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    // Unsafe access to float data - Zero Copy from OS to Swift scope
    if let channelData = buffer.floatChannelData {
        let floatData = channelData.pointee // UnsafeMutablePointer<Float>
        // Call C++ directly - One Copy from Swift scope to C++ Ring Buffer
        audioCore.write(floatData, count: Int(buffer.frameLength))
    }
}
```

### 8.2 The MLX Inference Loop

The inference loop runs on a dedicated background thread (`DispatchQueue` with `.userInteractive` QoS). This separates the "hearing" (Audio Thread) from the "thinking" (Inference Thread).

**Swift**

```
func inferenceLoop() {
    while isListening {
        // 1. Get Audio
        let audioVector = audioCore.readLast(30) // Get relevant audio
        let mlxArray = MLXArray(audioVector) // Efficient conversion
      
        // 2. Transcribe
        // Note: prompt is the previously committed text to maintain context
        let segments = whisper.transcribe(audio: mlxArray, prompt: committedText)
      
        // 3. Calculate Stability
        // We compare the new segments with the 'ghost' segments from the previous run.
        let (stable, unstable) = stabilize(new: segments, old: previousSegments)
      
        // 4. Update UI
        DispatchQueue.main.async {
            self.uiText = stable + unstable
        }
      
        // 5. Commit Check
        if vad.isSilence() &&!unstable.isEmpty {
             commit(unstable)
        }
      
        // 6. Wait for next stride (e.g., 50ms)
        usleep(50000) 
    }
}
```

### 8.3 Mitigating Hallucinations

Whisper models are prone to "hallucinating" text during silence.

* **Strategy:** The VAD is the primary defense. If TEN VAD reports `SpeechProb < 0.5`, the MLX inference loop is paused.
* **Fallback:** If VAD triggers but Whisper outputs low-probability tokens (LogProb check), we discard the text.
* **Prompt Engineering:** We inject a specialized prompt into the Decoder that suppresses common hallucination phrases.

### 8.4 Resource Efficiency & Thermal Management

The constraints require running without draining battery or freezing UI.

* **Thermal Throttling:** Continuous GPU inference can heat the chassis.
* **Mitigation:** The "Sliding Window" is not continuous. It pulses every 100-200ms. Between pulses, the GPU idles. Additionally, once VAD detects silence, the inference loop suspends entirely, dropping power consumption to near-idle levels.
* **Battery:** By using Int4 quantization, we reduce the amount of data moved per pulse, which is the primary consumer of energy (DRAM PHY power).

## 9. Conclusion

By pivoting to **MLX** and  **Whisper v3 Turbo** , GhostType v2 can achieve the elusive <200ms latency target without sacrificing accuracy. The removal of the ANE cold-start bottleneck and the adoption of a Zero-Copy Swift-C++ audio pipeline ensures that the system is not only fast but also architecturally robust and maintainable. The introduction of **TEN VAD** provides the precise control logic required to make the system feel "telepathic." This "Golden Path" positions GhostType v2 to strictly outperform current market leaders in responsiveness and reliability on Apple Silicon.
