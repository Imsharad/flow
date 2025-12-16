# Blueprint for Next-Generation Neural Interface: A Systems Architecture Report for macOS Voice Dictation

## 1. Executive Summary: The Convergence of Edge Silicon and Latency-Critical AI

The trajectory of human-computer interaction (HCI) is currently undergoing a seismic shift, moving away from explicit, mechanical inputs—such as keyboards and pointers—toward implicit, biological inputs like voice and gaze. For the macOS ecosystem, this transition has historically been bifurcated. Users were forced to choose between the high-latency, privacy-compromising accuracy of cloud-based APIs (e.g., OpenAI’s Whisper API) or the low-latency, low-fidelity experience of on-device solutions like Apple's legacy `SFSpeechRecognizer`. However, the introduction and maturation of Apple’s M-Series silicon, characterized by its Unified Memory Architecture (UMA) and powerful Neural Engine (ANE), has collapsed this dichotomy. It is now architecturally feasible to deploy "Superwhisper-class" transcription—achieving server-grade accuracy—entirely on the edge, with latencies that rival local keyboard input.

This comprehensive architectural analysis serves as the foundational document for developing a high-performance, Python-centric macOS dictation application. The defined objective is stringent: to engineer a system with a perceived Time-to-First-Token (TTFT) of under 200 milliseconds, a Word Error Rate (WER) competitive with large server-side models, and a user experience that feels "invisible." This report asserts that achieving these metrics requires a departure from standard application development patterns. A naive implementation using standard Python audio libraries and synchronous inference loops will inevitably fail to meet the latency budget due to Global Interpreter Lock (GIL) contention and operating system buffer overhead.

Instead, this report prescribes a hybrid "Golden Path" architecture. This involves a high-performance audio ingestion and Voice Activity Detection (VAD) layer implemented in Rust, bridging to an optimized Python inference layer leveraging Apple’s MLX framework. By decoupling the real-time safety requirements of audio processing from the rich ecosystem of Python’s AI tooling, and by implementing advanced streaming strategies like "Speculative Decoding" and "Local Agreement" policies, the proposed system can achieve the fluidity required to transform voice dictation from a novelty into a primary input modality. The following sections detail the rigorous benchmarking, architectural trade-offs, and user experience psychology necessary to build a market-leading product in 2025.

---

## 2. Contextual Analysis and Hardware Substrate

### 2.1 The Apple Silicon Advantage: A Unified Compute Fabric

To design for the M-series chips (M1 through M4), one must understand the fundamental architectural shift they represent. Unlike traditional x86 architectures where the CPU and GPU possess discrete memory pools requiring costly data transfers over PCIe buses, Apple Silicon employs a Unified Memory Architecture.^1^ This allows the CPU, GPU, and Apple Neural Engine (ANE) to access the same data without copying. For a voice dictation application, this is critical. It implies that audio buffers captured by the CPU can be read directly by the GPU-based inference engine, and the resulting large language model (LLM) weights do not need to be paged in and out of VRAM.

However, utilizing this hardware efficiently from a high-level language like Python remains a complex optimization challenge. The ecosystem is currently fragmented between multiple inference backends—CoreML for the ANE, Metal Performance Shaders (MPS) for the GPU, and raw CPU processing. Each has distinct "warm-up" characteristics and throughput profiles. As noted in benchmarks ^2^, while the ANE is incredibly power-efficient, it often imposes a static graph requirement that makes variable-length streaming dictation difficult to optimize for latency. Conversely, the GPU (via Metal) offers massive parallelism and dynamic shape support but requires careful memory management to avoid blocking the UI thread. The system architect must therefore navigate these hardware constraints to select the optimal execution provider.

### 2.2 The Latency Budget: Deconstructing "Instant"

In the domain of psychoacoustics and HCI, "latency" is not a single metric but a sequence of perceived delays. The "Time-to-First-Token" (TTFT) is the critical threshold for user trust. Research suggests that visual feedback appearing within 100ms is perceived as instantaneous causality—like flipping a light switch. Delays between 100ms and 300ms are noticeable but accepted as "working." Delays exceeding 300ms break the user's cognitive flow, shifting their focus from "what I am saying" to "is the app working?".^4^

Designing for a <200ms target requires a relentless auditing of the signal chain. A standard breakdown of the latency budget reveals the severity of the constraint:

* **Hardware Input:** The physical conversion of sound pressure to digital signal and the USB/Internal bus transfer typically consumes 10-15ms.
* **OS Buffer:** The CoreAudio HAL (Hardware Abstraction Layer) buffer. A standard 512-sample buffer at 16kHz adds ~32ms.
* **VAD Processing:** To detect the end of a word or phrase, the VAD needs a window of context. A typical window is 30ms.^6^
* **Inference Pre-fill:** The time taken to load the audio context into the Transformer model's attention mechanism.
* **Token Generation:** The autoregressive decoding of the first token.
* **Rendering:** The time for the OS to paint the text on the screen.

Summing these intrinsic latencies often leads to a baseline of ~150ms before any heavy AI processing even begins. This leaves a meager 50ms budget for the actual intelligence—the transcription model. Consequently, the architecture cannot afford a serial workflow where the system waits for silence before processing. It must adopt a fully concurrent, streaming architecture where inference happens *during* speech, and the display is updated speculatively.

---

## 3. Part 1: Technical Excellence (The Engine)

### 3.1 Inference Engine Benchmarks and Selection

The selection of the inference engine is the single most consequential technical decision. It dictates the floor for latency and the ceiling for accuracy. We evaluated five primary candidates based on their performance on Apple Silicon: MLX Whisper, Whisper.cpp (CoreML), Faster-Whisper, Distil-Whisper, and the native SFSpeechRecognizer.

#### 3.1.1 MLX Whisper: The Native Metal Contender

Apple’s MLX framework has emerged as the front-runner for high-performance inference on Mac. Unlike PyTorch, which wraps generic CUDA kernels or relies on the sometimes-unstable MPS backend, MLX is designed specifically for Apple’s unified memory and Metal architecture.^2^ It supports "lazy evaluation," meaning computations are only executed when the data is strictly needed, allowing for highly efficient pipelining.

Benchmarks indicate that MLX-based Whisper implementations significantly outperform standard PyTorch on M-series chips.^3^ For example, `mlx-whisper` running a quantized 4-bit model can achieve real-time factors (RTF) well exceeding 50x on an M2 Max, meaning it processes one second of audio in under 20 milliseconds. This raw throughput is essential for the "speculative streaming" approach, where the model must repeatedly transcribe overlapping audio chunks to update provisional text. The framework’s ability to handle dynamic input shapes (unlike the static requirements of CoreML) makes it ideal for the variable nature of human speech.^9^

#### 3.1.2 Whisper.cpp and CoreML: Efficiency vs. Latency

The `whisper.cpp` project, particularly when compiled with CoreML support, utilizes the Apple Neural Engine (ANE).^10^ The ANE is a specialized ASIC designed for matrix multiplication, offering incredible power efficiency—crucial for a menu bar app that runs continuously on a battery-powered MacBook Air.

However, the ANE has significant limitations regarding latency for real-time applications. The process of loading a model graph onto the ANE and the compilation overhead for the first inference pass can introduce a "cold start" latency of several hundred milliseconds.^10^ Furthermore, CoreML models typically require fixed input sizes (e.g., exactly 30 seconds of audio). For a dictation app that needs to transcribe short bursts of 2-5 seconds, the system must pad the audio with silence, processing unnecessary data and wasting compute cycles. While `whisper.cpp` is an excellent fallback for older Intel Macs or for background batch processing, its rigidity regarding input shapes makes it less responsive than MLX for live streaming.^12^

#### 3.1.3 Faster-Whisper (CTranslate2)

`Faster-Whisper` relies on CTranslate2, a C++ inference engine optimized for Transformer models. On NVIDIA GPUs, this is often the gold standard for speed. However, on Apple Silicon, CTranslate2 currently lacks the deep, hand-tuned Metal kernels that MLX provides. While faster than vanilla PyTorch, it does not fully exploit the M-series architecture to the same degree as MLX or CoreML, often resulting in higher memory bandwidth usage and slightly slower decoding speeds.^4^

#### 3.1.4 Distil-Whisper: The Critical Optimization

Regardless of the runtime engine, the sheer size of the `whisper-large-v3` model (approximately 1.5 billion parameters) imposes a latency penalty. `Distil-Whisper` is a knowledge-distilled variant that reduces the number of decoder layers while retaining the performance of the encoder.^13^ This results in a model that is 6x faster and 49% smaller than the large model, with a Word Error Rate (WER) degradation of less than 1% on clean audio.

For a <200ms latency target, utilizing `distil-large-v3` is almost mandatory. The reduced parameter count drastically lowers the "pre-fill" time—the time taken to process the initial audio prompt—which is the primary bottleneck in perceived latency. Combined with MLX’s 4-bit quantization, the memory footprint drops to under 2GB, ensuring the app does not trigger memory pressure warnings on 8GB MacBook Airs.^1^

**Table 3: Comparative Analysis of Inference Architectures**

| **Engine Architecture**  | **Latency (Pre-fill)** | **Throughput (Decoding)** | **Memory Efficiency**    | **Apple Silicon Suitability** | **Recommendation** |
| ------------------------------ | ---------------------------- | ------------------------------- | ------------------------------ | ----------------------------------- | ------------------------ |
| **MLX Whisper (4-bit)**  | **< 30ms**             | **High**                  | **High**(Unified Memory) | **Native / Best**             | **Primary Choice** |
| **Whisper.cpp (CoreML)** | > 100ms (Cold)               | Medium                          | Very High                      | High (ANE Optimized)                | Battery Saver Mode       |
| **Faster-Whisper**       | ~50ms                        | Medium                          | Medium                         | Moderate                            | Fallback                 |
| **Vanilla PyTorch**      | > 200ms                      | Low                             | Low                            | Poor                                | Do Not Use               |
| **SFSpeechRecognizer**   | < 10ms                       | High                            | N/A (OS)                       | Native                              | Offline Backup           |

### 3.2 Voice Activity Detection (VAD) & Endpointing

While the inference engine determines how fast text is generated, the Voice Activity Detector (VAD) determines *when* the system decides the user has finished speaking. This "endpointing" logic is the single most common source of user frustration. If the VAD is too aggressive, it cuts users off mid-thought; if too lax, the user stares at the screen waiting for the text to appear.

#### 3.2.1 The Superiority of Silero VAD

Traditional VADs like WebRTC operate on simple Gaussian Mixture Models (GMM) that analyze energy levels and frequency bands. While extremely fast, they are prone to false positives from mechanical noises—keyboard typing, mouse clicks, and breath sounds—which are ubiquitous in a desktop environment.^14^ A false positive keeps the microphone open, delaying the transcription and causing the inference engine to process noise, leading to hallucinations.

Silero VAD (specifically v4 or v5) utilizes a deep neural network trained on vast datasets of speech and noise. Despite being a neural model, it is highly optimized (ONNX runtime) and processes 30ms audio chunks in microseconds.^6^ Comparative analysis shows Silero maintains a high True Positive Rate (TPR) even in noisy environments where WebRTC fails. For a macOS dictation app, Silero is the requisite choice to ensure that a "thinking pause" is not interpreted as silence, while a "keyboard clack" is ignored.

#### 3.2.2 The "Thinking Pause" and Semantic Endpointing

A strictly acoustic VAD cannot solve the "Um..." problem. Users often pause for 500ms-1s while searching for a word. A standard VAD with a 500ms timeout would fracture the sentence. To solve this, the architecture must implement  **Semantic Endpointing** .

This technique couples the VAD with the real-time transcription stream. When the VAD detects silence, the system checks the last transcribed token. If the text ends in a "continuation token" (e.g., "and", "but", "the", or a comma), the system dynamically extends the silence timeout (e.g., to 1.5 seconds), anticipating more speech.^5^ If the text ends in a "terminal token" (e.g., a period, "thanks", "bye"), the system aggressively closes the stream (e.g., 200ms timeout) to provide a snappy response. This "Smart Timeout" logic is a key differentiator between a utility script and a polished product.

### 3.3 Architectural Optimization: The "Streaming" Paradigm

#### 3.3.1 Speculative Streaming and Local Agreement

To achieve the perception of "instant" transcription, the application cannot wait for a file to save. It must implement **SimulStreaming** using a **Local Agreement** policy.^5^

In this model, audio is fed to the engine in overlapping chunks (e.g., every 500ms). The model outputs a hypothesis for the current buffer. Because the user is still speaking, the end of the hypothesis is unstable—the word "text" might become "texting" as more audio arrives. The **Local Agreement** algorithm compares the hypothesis from the current chunk (**$T$**) with the hypothesis from the previous chunk (**$T-1$**). The longest common prefix (the sequence of words that has remained stable across updates) is considered "finalized" and is immediately pasted into the application. The remaining unstable text is displayed as "provisional" (often grayed out).

This decoupling of "generation" from "finalization" allows the user to see their words appearing in real-time (latency ~200ms for provisional text) while the system maintains high accuracy for the final committed text.

#### 3.3.2 The Python GIL and the Rust Bridge

A critical architectural bottleneck in Python-based real-time audio apps is the Global Interpreter Lock (GIL). Standard libraries like `PyAudio` (PortAudio wrapper) and `sounddevice` operate their callbacks in a Python thread. If the main thread is busy running a heavy MLX inference job (which, despite releasing the GIL for GPU ops, still requires Python interpreter cycles for tensor management), the audio callback may be delayed.^16^ This results in buffer under-runs, causing audio artifacts ("pops") or lost data.

The solution is to move the "Hot Path"—Audio Capture and VAD—entirely out of Python. By using **Rust** with the `cpal` crate (CoreAudio wrapper) ^17^, we can spawn a high-priority background thread that manages the audio ring buffer and runs the Silero VAD (via `tract` or `ort` crate) without ever acquiring the Python GIL. This Rust layer acts as a reliable reservoir, accumulating audio data and only signaling the Python application when a valid speech segment is ready for processing. This **Rust-Python Bridge** (via `PyO3`) ensures that the inference engine can be saturated (100% GPU usage) without ever compromising the integrity of the incoming audio stream.^18^

---

## 4. Part 2: Product Excellence (The Experience)

### 4.1 The "Invisible" UX

The most successful tools, like Superwhisper and Wispr Flow, succeed because they disappear. The "Aha Moment" occurs when the user stops thinking about the app as a "window" they speak into and starts treating their microphone as a keyboard.

#### 4.1.1 Latency Perception and Visual Feedback

Users are remarkably tolerant of slight delays if they receive immediate *visual confirmation* that their input was received. The "Floating Pill" UI pattern—a small, non-intrusive indicator that appears near the text cursor (using Accessibility APIs to track focus)—is essential. It should pulse in sync with voice volume immediately upon hotkey press. This 10-20ms feedback loop satisfies the brain's causality requirement, buying the system the 200ms it needs to generate the text.^20^

#### 4.1.2 The "Trust" Threshold

Trust is eroded by "hallucinations." Whisper models, when fed silence or background noise, have a known pathology of generating training data artifacts like "Subtitles by Amara.org" or "Thank you.".^22^ If a user sees this appear in their email, they lose confidence. The system must implement rigorous  **Logit Filtering** . By monitoring the `avg_logprob` and `no_speech_prob` metrics from the model, the app can suppress any output that falls below a confidence threshold, ensuring that "silence" results in "nothing pasted" rather than "garbage pasted".^22^

### 4.2 Competitive Analysis: Learning from the Market

Analysis of user reviews for Wispr Flow and Superwhisper reveals distinct gaps in the market.^23^

* **Superwhisper:** Users praise its privacy and local-first approach but complain about the steep learning curve and complexity of configuration. It is a "power user" tool.
* **Wispr Flow:** Users love the speed and simplicity ("it just works") but criticize the lack of customization and the subscription model. There are also reports of poor support responsiveness.
* **The Unmet Need:** There is a clear demand for a "Middle Path"—an app that offers the simplicity and speed of Wispr Flow but with the privacy and one-time-purchase model of a local app. Users specifically request "Context Awareness" (knowing what is on screen to improve accuracy) without sending data to the cloud.^26^

### 4.3 Activation and The Hotkey Debate

The debate between **Hold-to-Record** and **Toggle** is settled by context.

* **Hold-to-Record:** Is superior for short, command-like dictation ("Reply, sounds good."). It eliminates the VAD latency entirely because the "key up" event is a perfect, zero-latency endpoint signal.
* **Toggle:** Is necessary for long-form drafting.
* **Recommendation:** The app must support *both* on the same hotkey. A "tap" toggles recording; a "hold" engages push-to-talk. This unified interaction model covers all use cases without complex configuration.

---

## 5. The "Golden Path" Technical Stack

Based on the rigorous analysis of benchmarks, hardware capabilities, and UX requirements, the following implementation stack is proposed as the optimal "Golden Path" for a 2025 macOS dictation app.

### 5.1 Core Components

* **Language:** Hybrid **Python** (Logic/Inference) + **Rust** (Audio/VAD).
* **Bridge:** `PyO3` for zero-cost FFI (Foreign Function Interface).
* **Audio Backend:** **Rust `cpal`** (CoreAudio) with a lock-free Ring Buffer (`crossbeam-queue`).
  * *Why:* Bypasses PortAudio latency, ensures thread safety, avoids GIL.
* **VAD Engine:** **Silero VAD v5** (ONNX Runtime).
  * *Config:* 30ms Window, Threshold 0.5.
  * *Optimization:* Run in Rust thread; filter short bursts (<50ms).

### 5.2 Inference Stack

* **Engine:** **MLX** (Apple Silicon Native).
  * *Why:* Best throughput/latency balance, dynamic shapes, active Apple support.
* **Model:**  **Distil-Whisper Large-v3** .
  * *Quantization:*  **4-bit (Q4_0)** .
  * *Why:* ~1GB Memory footprint, <30ms pre-fill latency, effectively lossless accuracy for dictation.
* **Decoding Strategy:** **Greedy Decoding** with  **Speculative Streaming** .
  * *Why:* Beam search adds too much latency. Greedy is sufficient for real-time, corrected by user context if needed.

### 5.3 Pipeline Architecture (The "SimulStream" Loop)

1. **Capture (Rust):** Audio → Ring Buffer. VAD checks 30ms chunks.
2. **Trigger (Rust → Python):** If VAD=True, signal Python Event.
3. **Inference (Python/MLX):**
   * Read Ring Buffer.
   * Construct Input Tensor (pad if necessary, but MLX handles dynamic well).
   * **KV-Cache:** Maintain the KV-cache of the Transformer from the previous chunk. Only process the *new* audio samples appended to the buffer.
   * **Local Agreement:** Compare current output with previous.
   * **Emit:** Send "Stable Prefix" to UI. Keep "Unstable Suffix" for next loop.
4. **UI Injection:** Use **Accessibility API** (`AXUIElement`) via `PyObjC` to insert text at the caret.

---

## 6. Implementation Strategy and Roadmap

### 6.1 Phase 1: The Iron Core (Audio & VAD)

The first development sprint should focus exclusively on the Rust audio capture module. Using `cpal`, implement a robust input stream that is resilient to device changes (e.g., user plugging in AirPods). Integrate `silero-vad` and visualize the VAD trigger in a simple console graph. The goal is to verify that the system can distinguish speech from silence with <10ms latency and zero CPU spikes.

### 6.2 Phase 2: The Neural Engine (MLX Integration)

Develop the Python MLX inference worker. Benchmark `distil-large-v3` vs `tiny.en` to feel the latency difference. Implement the **SimulStreaming** logic—this is the most complex algorithmic challenge. You must handle the "stitching" of text segments where the overlap occurs to avoid duplicating words (e.g., "The cat cat sat"). Validate the "KV-Cache" reuse to ensure that processing a 10-second buffer doesn't take 10x longer than a 1-second buffer.

### 6.3 Phase 3: The Invisible Interface

Construct the macOS menu bar app using `PySide6` or `rumps`, but rely on `PyObjC` for the heavy lifting of window management. Implement the "Cursor Follower" logic. This requires querying the `AXFocusedUIElement` to find the screen coordinates of the text caret. Note that some apps (like Electron apps) may not report this correctly, so implement a fallback "Centered Overlay" for incompatible apps.

### 6.4 Phase 4: Polish and "Smart" Features

Once the core loop works, address the "Um..." problem. Implement the prompt engineering ("Verbatim=False"). Add the "Smart Spacing" logic: if the cursor is at the end of a sentence, auto-capitalize; if in the middle, lowercase. This context-awareness is what separates a "script" from a "product."

---

## 7. Conclusion

The architectural decision to decouple the audio engine (Rust) from the inference engine (Python/MLX) provides the robustness required for a system-level utility while retaining the flexibility of the AI research ecosystem. By leveraging the specific advantages of Apple Silicon—Unified Memory and Metal kernels—and employing advanced streaming algorithms like Local Agreement, this application can successfully break the 200ms latency barrier. The result is a tool that does not just transcribe speech, but seamlessly extends the user's intent into the digital realm, achieving the "invisible" user experience that defines the next generation of productivity software.

## 8. Detailed Analysis of Research Findings

### 8.1 The Reality of "Real-Time" on macOS

Research into existing open-source implementations reveals a landscape of compromise. Projects like `whisper.cpp` stream examples often suffer from "drift" and hallucination because they lack sophisticated buffer management.^11^ They often process disjoint chunks, leading to lost context at the boundaries. The **SimulStreaming** architecture ^5^ solves this by reprocessing the entire context window (leveraging the speed of M-series chips) or using KV-caching to append new information. This reinforces the need for a custom inference loop rather than relying on out-of-the-box CLI tools.

### 8.2 The "Prompt Engineering" of Silence

Snippets regarding Whisper's behavior with filler words ^28^ highlight a critical "Product Excellence" feature. Users usually want "clean" transcripts (no "ums"), but sometimes want "verbatim" (for legal or medical notes). The architecture must support  **Dynamic System Prompts** . By pre-pending a specific string to the audio context (e.g., "Transcript of a clear, concise lecture:"), the model's internal state is primed to suppress disfluencies. This is a zero-latency optimization that significantly improves perceived quality.

### 8.3 Hardware-Specific Quirks

The research indicates that while `whisper.cpp` with CoreML is efficient, the **compilation step** for CoreML models on the first run is a major friction point, taking minutes on some machines.^10^ For a "delightful" first-run experience, the app should ship with a pre-compiled MLX model or perform the optimization silently in the background while offering a faster, less accurate model (e.g., `tiny`) for immediate use. This "Progressive Enhancement" strategy ensures the user is never left waiting during the critical onboarding phase.

### 8.4 The Rust/Python Synergy

The debate between pure Python and Rust/Swift extensions is settled by the latency requirements. Snippets regarding `sounddevice` on macOS show inherent latencies due to the underlying PortAudio buffer sizes, which often default to high-latency profiles for safety.^30^ By dropping down to Rust and `cpal`, we gain control over the `AudioUnit` callback, allowing us to request buffer sizes as low as 64 or 128 samples (4ms-8ms), which is impossible to guarantee in a pure Python environment subject to Garbage Collection pauses.^19^ This low-level optimization is the foundation upon which the entire "instant" experience rests.

# Detailed Technical Addendum

## A. Mathematical Model of Latency

To rigorously define the <200ms target, we model the system latency **$L_{total}$** as:

$$
L_{total} = L_{io} + L_{vad} + L_{infer} + L_{ui}
$$

Where:

* **$L_{io}$** is the hardware/driver buffer latency. Using `cpal` with a 128-sample buffer at 16kHz: **$128 / 16000 = 8ms$**.
* **$L_{vad}$** is the VAD window latency. Silero requires 30ms + ~20ms processing overhead/safety margin = **$50ms$**.
* **$L_{infer}$** is the inference time. For `distil-large-v3` on M2 Max, the time to decode the first token (**$T_{ttft}$**) is approx **$60ms$**.
* **$L_{ui}$** is the rendering time. Accessibility injection takes ~**$10ms$**.

Total: $8 + 50 + 60 + 10 = 128ms$.

This theoretical minimum proves that <200ms is achievable, but only if $L_{infer}$ is kept low. If we used a standard large-v3 model without quantization, $L_{infer}$ could spike to >300ms, breaching the budget. Thus, quantization and distillation are not optional optimizations; they are architectural requirements.

## B. VAD State Machine Logic

The VAD is not a boolean switch; it is a state machine.

1. **State: IDLE.** Buffer energy < Threshold.
2. **State: PRE-TRIGGER.** Energy > Threshold. Accumulate 3 chunks (90ms). If all 3 are speech, transition to SPEECH.
3. **State: SPEECH.** Stream audio to Inference Engine.
4. **State: HANGOVER.** Energy < Threshold. Wait `min_silence_duration` (e.g., 300ms).
   * *Semantic Check:* If Inference Engine predicts a "continuation token", reset HANGOVER timer.
5. **State: COMMIT.** HANGOVER timer expired. Send "Finalize" signal.

This logic prevents the "choppy" transcription often seen in naive implementations where short pauses cause the text to be pasted prematurely.

## C. The "First Run" Guarantee

To ensure the "First Success" objective:

* **Permissions Pre-Flight:** On first launch, do not just ask for permissions. Show a wizard that validates Microphone and Accessibility access. Show a live volume meter *in the wizard* to prove the mic works before the user ever tries to dictate.
* **Model Download:** Do not make the user wait for a 2GB download. Ship a quantized `tiny.en` model (75MB) within the app bundle for instant functionality, and download the `distil-large-v3` in the background.

By addressing these granular details—from the mathematical latency model to the onboarding psychology—the application will transcend the status of a "wrapper" and become a robust, essential utility for the macOS platform.
