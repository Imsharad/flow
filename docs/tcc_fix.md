# TCC Permission Invalidation Fix

## The Problem

Every time you run `./build.sh`, macOS invalidates the Accessibility permission because:

1. **Recompilation**: Each build creates a new binary with a different hash
2. **Ad-Hoc Signing**: The `-` flag in `codesign --sign -` creates an unstable signature
3. **TCC Validation**: macOS treats each rebuild as a "new" application

**Result**: You must re-grant Accessibility permission after every single rebuild.

## The Solution

Use a **stable, self-signed certificate** for code signing during development.

### Quick Setup (Recommended)

Run the setup script once:

```bash
./setup-dev-signing.sh
```

This will:
- Create a self-signed certificate named "GhostType Development"
- Install it in your login keychain
- Configure it for code signing
- Make it valid for 10 years

### What Changes

After running the setup:

1. **build.sh** will automatically detect and use the stable certificate
2. The app's code signature remains consistent across rebuilds
3. macOS recognizes it as the "same" app
4. **Accessibility permissions persist** between builds

### Verification

After setup, verify the certificate exists:

```bash
security find-identity -v -p codesigning
```

You should see:
```
1) XXXXXXXX... "GhostType Development"
   1 valid identities found
```

### Building

Just use the normal build command:

```bash
./build.sh
```

The script will automatically:
- Detect the "GhostType Development" certificate
- Use it for signing
- Preserve TCC permissions across builds

### First Run After Setup

1. Build with the new certificate:
   ```bash
   ./build.sh --clean
   ```

2. **Important**: Remove GhostType from Accessibility settings:
   - Open System Settings → Privacy & Security → Accessibility
   - Find any existing "GhostType" entries
   - Click the (−) button to remove them

3. Launch the app:
   ```bash
   open GhostType.app
   ```

4. Grant Accessibility permission when prompted

5. **From now on**, permissions will persist across rebuilds!

### Troubleshooting

#### "codesign wants to use the 'GhostType Development' key"

When you first build, macOS will ask for keychain access. Click **"Always Allow"** to avoid repeated prompts.

#### Permissions still reset

If permissions still reset after setup:

1. Verify the certificate is being used:
   ```bash
   ./build.sh | grep "Using stable"
   ```
   You should see: `Using stable development certificate: GhostType Development`

2. Check the app's code signature:
   ```bash
   codesign -dvvv GhostType.app
   ```
   Look for `Authority=GhostType Development`

3. If ad-hoc signing is still being used, re-run the setup:
   ```bash
   ./setup-dev-signing.sh
   ```

#### Certificate expired or corrupted

The certificate is valid for 10 years, but if needed, remove and recreate:

```bash
# Remove old certificate
security delete-identity -c "GhostType Development"

# Recreate
./setup-dev-signing.sh
```

## Technical Details

### Why Ad-Hoc Signing Breaks TCC

macOS TCC (Transparency, Consent, and Control) tracks app permissions using:
- Bundle identifier (e.g., `com.ghosttype.GhostType`)
- Code signature hash
- Team identifier (if present)

Ad-hoc signing (`codesign --sign -`) generates:
- A **unique** signature hash for each binary
- **No** stable team identifier
- **No** designated requirement

Result: Each rebuild looks like a completely different app to TCC.

### How Stable Signing Fixes It

A self-signed certificate provides:
- **Stable** signing authority across builds
- **Designated requirement** that persists
- **Team identifier** embedded in the certificate

macOS TCC uses these stable identifiers to recognize the app across rebuilds.

### Alternative: Apple Developer Account

If you have an Apple Developer account, you can use:

```bash
# List your certificates
security find-identity -v -p codesigning

# Update build.sh to use your Development certificate
SIGNING_IDENTITY="Apple Development: Your Name (TEAM123)"
```

This provides even better stability and is required for:
- App Store distribution
- Notarization
- TestFlight

### Comparison

| Approach | TCC Stability | Cost | App Store |
|----------|---------------|------|-----------|
| Ad-hoc (`-`) | ❌ Breaks every rebuild | Free | ❌ Not allowed |
| Self-signed | ✅ Stable across rebuilds | Free | ❌ Not allowed |
| Apple Development | ✅ Stable + Team ID | $99/year | ✅ Allowed |
| Developer ID | ✅ Stable + Notarizable | $99/year | ❌ Outside store only |

For **local development**, self-signed is the optimal choice.

## Related Files

- `setup-dev-signing.sh` - Creates the development certificate
- `build.sh` - Updated to use stable signing
- `Sources/GhostType/Resources/GhostType.entitlements` - Permission declarations

## References

- [Apple TCC Documentation](https://developer.apple.com/documentation/security/app_sandbox)
- [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
- [Designated Requirements](https://developer.apple.com/documentation/bundleresources/entitlements)
