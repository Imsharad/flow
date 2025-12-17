# GhostType Quick Commands

## Build & Run
```bash
./build.sh           # Incremental build
./build.sh --clean   # Clean build
./run.sh --build --open    # Build + launch (ALWAYS use this)

# To see debug logs, run this in another terminal:
tail -f /tmp/ghosttype.log

# Then launch with:
./run.sh --open
```

## Testing
```bash
# Kill running instances
pkill -9 GhostType

# Check if running
ps aux | grep GhostType | grep -v grep

# View crash logs
ls -lt ~/Library/Logs/DiagnosticReports/GhostType*.ips | head -1 | xargs cat | head -100

# View live console output
tail -f /tmp/ghosttype.log
```

## Permissions
```bash
# Reset TCC permissions (requires re-granting)
./run.sh --reset-tcc

# Check permissions status
tccutil check Microphone com.ghosttype.app
tccutil check Accessibility com.ghosttype.app
```

## Debug
```bash
# Verify app bundle
codesign -dv GhostType.app

# Check Info.plist
plutil -p GhostType.app/Contents/Info.plist

# List resources
ls -lh GhostType.app/Contents/Resources/GhostType_GhostType.bundle/
```

## Models
```bash
# Convert models (from tools/coreml_converter/)
cd tools/coreml_converter
./setup_and_convert.sh

# Check model sizes
du -sh Sources/GhostType/Resources/*.mlpackage
```

## Git
```bash
# Current branch
git branch --show-current

# Quick commit
git add . && git commit -m "Fix: <description>"

# Push to PR
git push origin $(git branch --show-current)
```

## Quick Test Loop
```bash
# Full rebuild + test
./build.sh --clean && ./run.sh --open

# Fast iteration (after code changes)
./build.sh && pkill GhostType && open GhostType.app

# Poll Logs (Snapshot)
tail -n 20 /tmp/ghosttype.log
```
