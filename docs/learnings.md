# GhostType Learnings

## macOS Permission Persistence ("The Gymnastics")

### The Problem
Accessibility permissions (AX) would not persist across app restarts or rebuilds. Every time the app was rebuilt, macOS treated it as a distinct, new application, invalidating the previous permission grant and forcing a new prompt.

### Root Causes
1.  **Certificate Ambiguity**: The Keychain contained multiple certificates with the same Common Name ("GhostType Development"). `security find-identity` returned multiple matches, causing `codesign` to either pick arbitrarily or fail.
2.  **Ad-Hoc Signing Instability**: When a valid certificate isn't found, builds often fall back to ad-hoc signing (`codesign -s -`). Ad-hoc identity is derived from the **binary itself**.
    -   *Rebuild Application* -> *Binary Changes* -> *Identity Changes* -> *TCC Permission Lost*.
3.  **Identity Mismatch**: The Keychain had "zombie" certificates where the private key was missing or the trust chain was broken, confusing the system's trust evaluation.

### The Solution: Stable Code Signing
To persist permissions, the app MUST be signed with a **Stable Certificate Identity** (same Common Name, same Public Key) that persists across builds.

1.  **Aggressive Cleanup**: We created `tools/cleanup_certs.sh` to delete **ALL** certificates matching "GhostType Development" by iterating through their specific SHA-1 hashes. This ensures a blank slate.
2.  **Explicit Hash Signing**: The `build.sh` script was updated to:
    -   Find the certificate by name.
    -   Extract its specific **SHA-1 Hash**.
    -   Pass the *Hash* (not the name) to `codesign`. This eliminates ambiguity.
    ```bash
    codesign --sign "$CERT_HASH" ...
    ```
3.  **TCC Database Reset**: Using `tccutil reset Accessibility com.ghosttype.app` clears the "poisoned" or stale entries, allowing the OS to register the new stable identity cleanly.

### Debugging Techniques
1.  **Verify Signature**: `codesign -vv GhostType.app`
    -   Must say: "valid on disk", "satisfies its Designated Requirement".
2.  **Check Entitlements**: `codesign -d --entitlements :- GhostType.app`
    -   Ensure `com.apple.security.app-sandbox` is `false` (or configured correctly) to avoid silence failures.
3.  **Launch Context Matters**:
    -   `./GhostType.app/Contents/MacOS/GhostType` runs in **Binary Context**.
    -   `open GhostType.app` runs in **Bundle Context** (LaunchServices).
    -   TCC treats these differently if the Info.plist isn't fully registered. Always verify with `open`.
4.  **The "Invisible Log" Problem**: Apps launched via `open` detach from the terminal. Standard `print()` goes nowhere.
    -   **Fix**: Use `freopen` to redirect `stdout/stderr` to a file in `/tmp`.
    ```swift
    freopen("/tmp/ghosttype_debug.log", "w", stdout)
    ```

### Command Cheat Sheet
```bash
# Check for multiple identities
security find-identity -v -p codesigning

# Check strict validity
codesign -vv GhostType.app

# Read Entitlements
codesign -d --entitlements :- GhostType.app

# Reset Permissions
tccutil reset Accessibility com.ghosttype.app
```
