# GhostType E2E Benchmarking Guide

## Objective
Verify that the "Unicorn Stack" optimizations (Large-v3-Turbo + 4-bit OD-MBP + ANE + KV-Cache) achieve <1s latency.

## Prerequisites
1. **Unicorn Stack Build**: Ensure `useANE = true` and `modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"` in `WhisperKitService.swift`.
2. **Console.app**: Open Console.app and filter for `process:GhostType` or `subsystem:GhostType`.

## Benchmark Protocol

### 1. Warm-up Phase
*Why: ANE and Model loading can have a "cold start" penalty.*
1. Launch GhostType.
2. Dictate a short phrase ("Testing one two three").
3. Wait for result.
4. Dictate another short phrase.
5. **Ignore these first 2 results for benchmarking.**

### 2. Test Cases (Golden Phrases)

Perform each test case 3 times and record the "E2E" latency from the logs.

#### Test Case A: Short Command (~1s)
**Phrase**: "Hello world."
- Run 1 Latency: `____ ms`
- Run 2 Latency: `____ ms`
- Run 3 Latency: `____ ms`
- **Average**: `____ ms` (Target: <800ms)

#### Test Case B: Medium Sentence (~3s)
**Phrase**: "The quick brown fox jumps over the lazy dog."
- Run 1 Latency: `____ ms`
- Run 2 Latency: `____ ms`
- Run 3 Latency: `____ ms`
- **Average**: `____ ms` (Target: <1000ms)

#### Test Case C: Continuous Dictation (~5s)
**Phrase**: "This is a longer sentence to test sustained transcription accuracy on the neural engine."
- Run 1 Latency: `____ ms`
- Run 2 Latency: `____ ms`
- Run 3 Latency: `____ ms`
- **Average**: `____ ms` (Target: <1200ms)

## Verifying ANE Usage
During the tests, open **Activity Monitor**, go to **Window > CPU Usage**, and look for **"Core ML Compiler"** or **"AneCompilerService"** spiking. Alternatively, run:
```bash
sudo powermetrics -s thermal,cpu_power,ane_power --show-all
```
Look for `ANE Power` > 0 mW during dictation.

## Success Criteria
- [ ] Average E2E Latency for Case A & B is **< 1000 ms**.
- [ ] RTF (Real Time Factor) is **< 0.1x** (e.g., 3s audio takes <0.3s to transcribe).
- [ ] No "Hallucinations" (repeated text or garbled output).
