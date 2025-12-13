## Progress Log

### 2025-12-13

- **Repository initialized + pushed to GitHub**
  - Repo: `https://github.com/Imsharad/flow`

- **Build environment note**
  - Xcode is not installed; the active developer directory is Command Line Tools (`/Library/Developer/CommandLineTools`).
  - `xcodebuild` is unavailable and `swift build` can fail due to SDK/toolchain mismatch.
  - To build/run the macOS app + XPC targets end-to-end, install Xcode and set the active developer directory to Xcode’s Developer folder.

- **Xcode installation verified (but not yet selected)**
  - Xcode exists at `/Applications/Xcode.app`, but the active developer directory is still Command Line Tools (`xcode-select -p` → `/Library/Developer/CommandLineTools`).
  - `xcrun --show-sdk-platform-path` is currently failing under Command Line Tools.
  - Next step: switch the active developer directory to Xcode (requires admin): `sudo xcode-select -s "/Applications/Xcode.app/Contents/Developer"` and then run Xcode once to accept the license/finish setup.

- **Pull requests discovered and synced locally**
  - PR #1: “Implement GhostType macOS app” (draft)
  - PR #2: “Scaffold GhostType Application” (draft)

- **Checked out latest PR branch**
  - Branch: `ghosttype-scaffold-5956184854589995409` (PR #2)

- **`docs/tasks.json` brought up to date and pushed**
  - Detected local `docs/tasks.json` differed from branch HEAD (older “Phase”-based plan vs newer “Sprint”-based plan)
  - Updated to the newer Sprint roadmap (19 items)
  - Committed + pushed to PR #2 (commit: `726bce0`)

- **Caret positioning + injection improvements**
  - Added caret-rect lookup using Accessibility `kAXBoundsForRangeParameterizedAttribute` for more accurate overlay placement.
  - Pasteboard fallback now preserves and restores the user clipboard after paste.
  - Committed + pushed to PR #2 (commit: `914f183`)

- **CoreML-first scaffolding (removed ONNX runtime dependency)**
  - Removed `sherpa-onnx` dependency from `Package.swift`.
  - Added CoreML-based scaffolds for Moonshine ASR + T5 correction, and an energy-based VAD placeholder.
  - Committed + pushed to PR #2 (commit: `ab45557`)

- **Pre-roll buffering + streaming partials (single-process)**
  - Added an `AudioRingBuffer` and 1.5s pre-roll behavior, plus a 500ms partial update loop.
  - Refactored into a `DictationEngine` to mirror future XPC boundaries.
  - Committed + pushed to PR #2 (commits: `ebe0028`, `3eae57b`)

- **XPC + conversion workspace scaffolds**
  - Added placeholder XPC protocols (`DictationXPCServiceProtocol`/`DictationXPCClientProtocol`) and an `IOSurfaceAudioBuffer` scaffold.
  - Added `tools/coreml_converter/` with pinned Python dependencies and conversion script skeletons for Moonshine/T5.

- **Repo hygiene**
  - Added `.gitignore` for SwiftPM build outputs, Python venvs, and generated CoreML artifacts (commit: `3692b62`).

- **PR #2 review notes (high-signal)**
  - Scaffolds a macOS menubar app + onboarding (Mic/Accessibility) + overlay UI + audio/VAD/transcription service skeletons (with mock-mode fallbacks)
  - Build issue observed on this machine: Swift toolchain/SDK mismatch (`swift build` fails because installed compiler and SDK Swift versions don’t match; `xcrun` platform path lookup also failing)
  - Implementation caveats to address later:
    - Caret positioning via Accessibility is likely inaccurate for editors (focused element position != caret)
    - Pasteboard injection overwrites clipboard without restore
    - Audio resampling path may need `AVAudioConverter` for reliable 16k conversion
    - Resources/models/sounds are placeholders; services will run in mock mode until assets are added
