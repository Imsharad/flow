# Known Bugs & Issues

## 🚨 Critical

### [BUG-001] Speech Lost After VAD Trigger (Race Condition)
**Status**: ✅ Fixed (VAD Removed)
**Severity**: High
**Date Reported**: 2025-12-16
**Reporter**: User (E2E Session)

#### Description
When the user pauses long enough to trigger VAD (>0.7s), the system correctly commits the "Intermediate Chunk". However, if the user immediately resumes speaking (e.g., "type... [pause] ...keyword"), the speech occurring *immediately* after the cut is sometimes lost or dropped.

#### Steps to Reproduce
1. Hold dictation key.
2. Say "I am testing the ghost... [pause 1s] ...type application."
3. Observe that "ghost" triggers a cut/paste.
4. Observe that "type" (the very next word) is missing from the final output.
5. Result: "I am testing the ghost application." (missing "type")

#### Hypothesis
Possible race condition in `DictationEngine.commitSegment`.
- The `speechStartSampleIndex` is reset to `end` (current write pointer).
- If VAD/Audio thread writes new samples *while* the commit logic is calculating `end`, those samples might be skipped or the pointer arithmetic might be off by the duration of the processing time.

#### Potential Fix
- Ensure `AudioRingBuffer` snapshot and pointer updates are atomic.
- Re-verify `speechStartSampleIndex` logic in `DictationEngine.swift`.

---

### [BUG-002] Accidental Clipboard Paste
**Status**: 🆕 New
**Severity**: Critical
**Date Reported**: 2025-12-16
**Reporter**: User (E2E Session)

#### Description
When dictation finishes, the application sometimes pastes the *previously copied* content from the system clipboard instead of the transcribed text.

#### Root Cause
The `AccessibilityManager` or `GhostTypeApp` injection logic likely falls back to "Cmd+V" without properly setting the pasteboard content first, or the pasteboard set operation is failing/async race condition.

#### Observed Log
`Text injection: AX failed, falling back to pasteboard` followed by pasting a YouTube link.

#### Potential Fix
- Ensure `AccessibilityManager.insertText` explicitly sets the `NSPasteboard.general` content to the *transcribed text* before triggering Cmd+V.
- Add a delay to ensure pasteboard write propagates.

---

### [BUG-003] Missed Second Sentence (Consensus Failure)
**Status**: ✅ Fixed (VAD Removed)
**Severity**: High
**Date Reported**: 2025-12-16
**Reporter**: User (E2E Session)

#### Description
In the "Ghost ... type ... application" test, the middle or final segment was completely dropped.

#### Potential Causes
1. `ConsensusService` stability threshold (2) might be too high for short, sparse utterances with long pauses.
2. `WhisperKitService` might be returning empty segments for the "application" part if it was too short (VAD / Silence threshold aggressive).
3. `DictationEngine` sliding window `effectiveStart` might be cutting off the "tail" too aggressively if the buffer math is wrong.

#### Potential Fix
- Lower `ConsensusService` stability threshold to 1 for V1 (faster commits).
- Or, force a "flush" of the hypothesis buffer on `stop()`. Currently `consensusService.reset()` just wipes it. It should `flush()` remaining text.

---

### [BUG-004] Sentence Cut-off
**Status**: ✅ Fixed (VAD Removed)
**Severity**: High
**Date Reported**: 2025-12-17
**Reporter**: User (Golden Dataset Test)

#### Description
During the Golden Dataset test, the sentence "The quick brown fox jumps over the lazy dog" was cut off after "the". The final transcription was "The quick brown fox jumps over the". The last two words ("lazy dog") were lost.

#### Hypothesis
VAD might be triggering too early or the recording buffer is being truncated before the final processing.

---

## ⚠️ Medium

### [BUG-005] Accessibility Injection Failure (Persistent)
**Status**: ⚠️ Persistent
**Severity**: Medium
**Date Reported**: 2025-12-17

#### Description
`Text injection: AX failed, falling back to pasteboard` log persists. The app falls back to Cmd+V correctly, but direct AX injection is failing.

#### Potential Fix
Review TCC permissions and AXUIElement API usage for the target application (VS Code/Terminal).
