## Progress Log

### 2025-12-13

- **Repository initialized + pushed to GitHub**
  - Repo: `https://github.com/Imsharad/flow`

- **Build environment note**
  - Xcode is not installed; the active developer directory is Command Line Tools (`/Library/Developer/CommandLineTools`).
  - `xcodebuild` is unavailable and `swift build` can fail due to SDK/toolchain mismatch.
  - To build/run the macOS app + XPC targets end-to-end, install Xcode and set the active developer directory to Xcode’s Developer folder.

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

- **PR #2 review notes (high-signal)**
  - Scaffolds a macOS menubar app + onboarding (Mic/Accessibility) + overlay UI + audio/VAD/transcription service skeletons (with mock-mode fallbacks)
  - Build issue observed on this machine: Swift toolchain/SDK mismatch (`swift build` fails because installed compiler and SDK Swift versions don’t match; `xcrun` platform path lookup also failing)
  - Implementation caveats to address later:
    - Caret positioning via Accessibility is likely inaccurate for editors (focused element position != caret)
    - Pasteboard injection overwrites clipboard without restore
    - Audio resampling path may need `AVAudioConverter` for reliable 16k conversion
    - Resources/models/sounds are placeholders; services will run in mock mode until assets are added
