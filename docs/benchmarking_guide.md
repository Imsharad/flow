# GhostType E2E Benchmarking Guide

## Objective
Measure transcription latency and accuracy for both **Cloud (Groq)** and **Local (WhisperKit)** modes.

## Current Configuration
- **Cloud**: Groq Whisper API (`whisper-large-v3`)
- **Local**: WhisperKit (`distil-whisper_distil-large-v3`) on CPU/GPU (ANE disabled)
- **Compute Mode**: `cpuAndGPU` (ANE bypassed due to M1 Pro deadlock issues)

## Prerequisites
1. **Build**: Run `./build.sh` to create a fresh build.
2. **Console.app**: Open Console.app and filter for `process:GhostType`.
3. **API Key**: For cloud mode, ensure Groq API key is configured in the app.

## Benchmark Protocol

### 1. Warm-up Phase
*Why: Model loading and network cold-start affect first-run latency.*
1. Launch GhostType.
2. Dictate a short phrase ("Testing one two three").
3. Wait for result.
4. Dictate another short phrase.
5. **Ignore these first 2 results for benchmarking.**

### 2. Test Cases (Golden Phrases)

Perform each test case 3 times and record the latency from logs.

#### Test Case A: Short Command (~1s)
**Phrase**: "Hello world."
- Run 1 Latency: `____ ms`
- Run 2 Latency: `____ ms`
- Run 3 Latency: `____ ms`
- **Average**: `____ ms`

| Mode | Target |
|------|--------|
| Cloud (Groq) | <500ms |
| Local (WhisperKit) | <1500ms |

#### Test Case B: Medium Sentence (~3s)
**Phrase**: "The quick brown fox jumps over the lazy dog."
- Run 1 Latency: `____ ms`
- Run 2 Latency: `____ ms`
- Run 3 Latency: `____ ms`
- **Average**: `____ ms`

| Mode | Target |
|------|--------|
| Cloud (Groq) | <800ms |
| Local (WhisperKit) | <2000ms |

#### Test Case C: Continuous Dictation (~5s)
**Phrase**: "This is a longer sentence to test sustained transcription accuracy."
- Run 1 Latency: `____ ms`
- Run 2 Latency: `____ ms`
- Run 3 Latency: `____ ms`
- **Average**: `____ ms`

| Mode | Target |
|------|--------|
| Cloud (Groq) | <1000ms |
| Local (WhisperKit) | <2500ms |

## Log Analysis

Look for these log patterns:
```
☁️ CloudTranscriptionService: Success in XXXms
📊 WhisperKitService: Latency Metrics - E2E: XXXms
```

## Success Criteria

### Cloud Mode (Groq)
- [ ] Average E2E Latency < 1000ms for all cases
- [ ] No network errors or timeouts
- [ ] Accurate transcription (no hallucinations)

### Local Mode (WhisperKit)
- [ ] Average E2E Latency < 2500ms for all cases
- [ ] RTF (Real Time Factor) < 0.5x
- [ ] No hallucinations on silence (VAD gating working)

### Fallback Behavior
- [ ] When cloud fails, local fallback activates automatically
- [ ] Fallback latency acceptable (one-time penalty)
