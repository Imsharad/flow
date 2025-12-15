# TCC Permission Fix - Quick Start

## The Problem ❌

Every time you ran `./build.sh`, macOS invalidated your Accessibility permissions because:
- Ad-hoc signing (`codesign --sign -`) created a different signature each build
- macOS treated each rebuild as a "new" application
- You had to re-grant permissions after **every single rebuild**

## The Solution ✅

Use a **stable, self-signed certificate** for code signing during development.

## Quick Setup (5 minutes)

### Step 1: Create the Development Certificate

Run the setup script:

```bash
./setup-dev-signing.sh
```

This will:
- Generate a self-signed certificate named "GhostType Development"
- Import it into your keychain
- Configure it for code signing
- Ask for your password (for sudo) to set system trust

### Step 2: Clean Build with New Signature

```bash
./build.sh --clean
```

This will rebuild the app using the stable certificate.

### Step 3: Reset Accessibility Permissions

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Find any existing "GhostType" entries
3. Click the **(−)** button to remove them all
4. Close System Settings

### Step 4: Launch and Grant Permission

```bash
open GhostType.app
```

When prompted, grant Accessibility permission.

### Step 5: Verify It Works

```bash
# Rebuild the app
./build.sh

# Launch again (should NOT ask for permissions)
open GhostType.app
```

**Success!** Permissions now persist across rebuilds.

## How It Works

### Before (Ad-hoc Signing)
```
Build 1: codesign --sign - → Signature: ABC123
         ↓
         macOS grants permission to ABC123

Build 2: codesign --sign - → Signature: XYZ789 (different!)
         ↓
         macOS: "Who is XYZ789? No permission!"
         ❌ Permission denied
```

### After (Stable Certificate)
```
Build 1: codesign --sign "GhostType Development" → Signature: STABLE_ID
         ↓
         macOS grants permission to STABLE_ID

Build 2: codesign --sign "GhostType Development" → Signature: STABLE_ID (same!)
         ↓
         macOS: "I know STABLE_ID, permission granted!"
         ✅ Permission preserved
```

## Verify Your Setup

Check that the certificate exists:

```bash
security find-identity -v -p codesigning
```

You should see:
```
1) XXXXXXXX "GhostType Development"
   1 valid identities found
```

Check that builds use it:

```bash
./build.sh | grep "Using stable"
```

You should see:
```
[BUILD] Using stable development certificate: GhostType Development
```

Verify the app's signature:

```bash
codesign -dvvv GhostType.app | grep Authority
```

You should see:
```
Authority=GhostType Development
```

## Troubleshooting

### "Certificate not found" after setup

The certificate may not be trusted for code signing. To fix:

1. Open **Keychain Access**
2. Find "GhostType Development" in the login keychain
3. Right-click → **Get Info**
4. Expand **Trust** section
5. Set "Code Signing" to **Always Trust**
6. Close (enter your password when prompted)

Then verify:
```bash
security find-identity -v -p codesigning
```

### "codesign wants to use the key"

When you first build, macOS will ask for keychain access. Click **"Always Allow"** to avoid repeated prompts.

### Permissions still reset after rebuild

1. Verify the build is using the stable certificate:
   ```bash
   ./build.sh | grep "Using stable"
   ```

2. If you see "Using ad-hoc signing", the certificate wasn't found. Re-run:
   ```bash
   ./setup-dev-signing.sh
   ```

3. Make sure you removed ALL old GhostType entries from Accessibility settings before granting the new permission.

### Need to start over

Remove the certificate and recreate:

```bash
# Find and delete the certificate
security delete-identity -c "GhostType Development"

# Recreate
./setup-dev-signing.sh
```

## Files Created/Modified

- `setup-dev-signing.sh` - Creates the development certificate (new)
- `build.sh` - Updated to use stable certificate (modified)
- `docs/tcc_fix.md` - Detailed documentation (new)
- `docs/progress.md` - Updated with fix details (modified)

## Next Steps

Now that permissions persist, you can:

1. **Iterate freely**: Build as many times as needed without re-granting permissions
2. **Focus on development**: No more System Settings interruptions
3. **Test the app**: Try the dictation features!

## Additional Resources

For detailed technical explanation, see:
- `docs/tcc_fix.md` - In-depth documentation
- [Apple TCC Documentation](https://developer.apple.com/documentation/security/app_sandbox)
- [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)

---

**TCC Blocker Status**: ✅ **RESOLVED**

You can now develop GhostType without permission headaches!
