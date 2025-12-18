# Follow-Up Research Questions for Deep Research Agent

> These questions address implementation uncertainties identified during the hybrid architecture analysis. Each question is scoped to provide actionable engineering guidance.

---

## 1. RingBuffer to AVAudioPCMBuffer Conversion (HIGH PRIORITY)

**Context:**
GhostType's current `DictationEngine` uses a custom `AudioRingBuffer` that outputs `[Float]` arrays via `snapshot(from:to:)`. However, the new `TranscriptionProvider` protocol expects `AVAudioPCMBuffer` as input, which is the standard Apple audio container.

**Question:**
What is the most memory-efficient and thread-safe way to convert a `[Float]` array (16kHz, mono, Float32) into an `AVAudioPCMBuffer` in Swift?

**Sub-questions:**
1. Should we use `UnsafeMutablePointer` to directly populate the buffer's `floatChannelData`?
2. Is there a risk of memory layout mismatches between Swift arrays and `AVAudioPCMBuffer`'s internal storage?
3. Should we pre-allocate a reusable buffer to avoid repeated allocations during rapid dictation?

**Desired Deliverable:**
A Swift code snippet for `AudioBufferBridge.swift` with:
- `static func createBuffer(from samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer?`
- Thread-safety considerations documented.

---

## 2. Long Audio Strategy (>30 seconds)

**Context:**
The Groq/OpenAI Whisper API accepts audio up to 25MB (approximately 25 minutes at 16kHz mono Int16). However, the Whisper model's attention mechanism degrades for audio longer than ~30-60 seconds, leading to dropped words and hallucinations.

**Question:**
For dictation sessions exceeding 30 seconds, should GhostType:
- **Option A**: Send the entire audio at once and accept degraded quality?
- **Option B**: Chunk audio at VAD silence boundaries and concatenate transcriptions?
- **Option C**: Use a sliding window approach (overlapping chunks) with deduplication?

**Sub-questions:**
1. If chunking, how do we ensure sentence coherence across chunk boundaries?
2. Does Groq/OpenAI support the `prompt` parameter to provide context from previous chunks?
3. What's the optimal chunk duration (10s, 15s, 30s)?

**Desired Deliverable:**
A recommendation for the chunking strategy with pseudocode for the `TranscriptionManager` to handle multi-chunk sessions.

---

## 3. Network Resilience and Rate Limiting

**Context:**
Groq and OpenAI APIs have rate limits (requests per minute, tokens per minute). During rapid dictation toggling, users might inadvertently exceed limits, especially if silence is not properly gated.

**Question:**
What networking patterns should `CloudTranscriptionService` implement for production resilience?

**Sub-questions:**
1. Should we implement exponential backoff with jitter for 429 (Rate Limited) responses?
2. Is a circuit breaker pattern appropriate (trip after N consecutive failures, auto-reset after cooldown)?
3. How should we surface rate limit errors to the user (silent fallback to local, vs. user notification)?

**Desired Deliverable:**
A `NetworkResilience.swift` utility or inline logic for the cloud service that handles:
- Retry logic with backoff
- Rate limit detection
- Graceful degradation

---

## 4. Local Model Memory Management

**Context:**
WhisperKit loads models that consume 1-2GB+ of RAM. For a lightweight menu bar app, keeping the model loaded permanently is undesirable. The `cooldown()` method is defined in the protocol, but the **trigger conditions** are unspecified.

**Question:**
When should `LocalTranscriptionService.cooldown()` be called to unload the model?

**Options to evaluate:**
1. **Inactivity Timeout**: Unload after 5 minutes of no transcription requests.
2. **Mode Switch**: Unload immediately when user switches to Cloud mode.
3. **System Pressure**: Listen to `MemoryPressure` notifications and unload on `.warning` or `.critical`.
4. **Never**: Keep loaded if disk paging is acceptable.

**Sub-questions:**
1. What's the typical model reload time for WhisperKit (cold start)?
2. How do other macOS dictation apps (e.g., Whisper Transcription) handle this?

**Desired Deliverable:**
A recommendation for the unload strategy with Swift code for timer-based or event-based cooldown.

---

## 5. Swift Actor Reentrancy Semantics

**Context:**
The `TranscriptionManager` uses an `isTranscribing: Bool` flag to prevent concurrent transcription requests. However, Swift actors are **reentrant by design** — if a method awaits, another call can enter the actor.

**Question:**
Is an `isTranscribing` flag the correct pattern for preventing concurrent transcriptions in a Swift actor, or should we use a different concurrency primitive?

**Alternatives to evaluate:**
1. **Serial Executor**: Use a custom `SerialExecutor` to prevent reentrancy entirely.
2. **Task Cancellation**: Cancel any in-flight transcription when a new one starts.
3. **Queuing**: Queue requests and process them FIFO.
4. **Flag + Early Return**: Current approach — check flag, return `nil` if busy.

**Desired Deliverable:**
Clarify whether `isTranscribing` flag is sufficient or if we need a more robust pattern. Provide corrected code if needed.

---

## Summary Table

| # | Question Topic | Risk Level | Impact if Unaddressed |
|---|----------------|------------|----------------------|
| 1 | RingBuffer → AVAudioPCMBuffer | High | Core functionality breaks |
| 2 | Long Audio Chunking | Medium | Quality degrades for long dictation |
| 3 | Network Resilience | Low | UX issues under rate limits |
| 4 | Memory Management | Low | RAM bloat in menu bar app |
| 5 | Actor Reentrancy | Low | Race conditions possible |

---

**Instructions for Deep Research Agent:**
Please provide actionable Swift code snippets and clear recommendations for each question. Prioritize Question 1 as it is blocking implementation.
