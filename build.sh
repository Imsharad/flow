#!/bin/bash
# GhostType Build Script
# Builds the app for development or release and packages it as a macOS Bundle

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_NAME="GhostType"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[BUILD]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
BUILD_TYPE="debug"
CLEAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --release)
            BUILD_TYPE="release"
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--release] [--clean]"
            exit 1
            ;;
    esac
done

# Clean if requested
if [ "$CLEAN" = true ]; then
    print_status "Cleaning build directory and app bundle..."
    rm -rf "$BUILD_DIR"
    rm -rf "$APP_BUNDLE"
fi

# Build
print_status "Building GhostType binary ($BUILD_TYPE)..."

if [ "$BUILD_TYPE" = "release" ]; then
    swift build -c release
    BINARY_PATH="$BUILD_DIR/release/$APP_NAME"
    RESOURCE_BUNDLE="$BUILD_DIR/release/${APP_NAME}_${APP_NAME}.bundle"
else
    swift build
    BINARY_PATH="$BUILD_DIR/debug/$APP_NAME"
    RESOURCE_BUNDLE="$BUILD_DIR/debug/${APP_NAME}_${APP_NAME}.bundle"
fi

# Check if build succeeded
if [ ! -f "$BINARY_PATH" ]; then
    print_error "Build failed - binary not found at $BINARY_PATH"
    exit 1
fi

print_status "Creating App Bundle structure..."

# Create directory structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
if [ -f "$SCRIPT_DIR/Sources/GhostType/Resources/Info.plist" ]; then
    cp "$SCRIPT_DIR/Sources/GhostType/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
else
    print_error "Info.plist not found!"
    exit 1
fi

# Copy Resources (GhostType_GhostType.bundle AND dependencies like swift-transformers_Hub.bundle)
BUNDLE_SOURCE_DIR="$BUILD_DIR/$BUILD_TYPE"

# 🦄 Unicorn Stack: Copy MLX Metadata (built via xcodebuild)
MLX_BUNDLE_PATH="$BUILD_DIR/xcode/Build/Products/Debug/mlx-swift_Cmlx.bundle"
if [ -d "$MLX_BUNDLE_PATH" ]; then
    print_status "Copying MLX Bundle from Xcode build..."
    cp -R "$MLX_BUNDLE_PATH" "$APP_BUNDLE/Contents/Resources/"
else
    print_warning "MLX Bundle not found at $MLX_BUNDLE_PATH. Run xcodebuild if you see metal errors."
fi

print_status "Copying resources from $BUNDLE_SOURCE_DIR..."

# Use nullglob to handle case where no bundles exist
shopt -s nullglob
bundles=("$BUNDLE_SOURCE_DIR"/*.bundle)

if [ ${#bundles[@]} -gt 0 ]; then
    for bundle in "${bundles[@]}"; do
        print_status "  Copying $(basename "$bundle")..."
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    done
else
    print_warning "No resource bundles found in $BUNDLE_SOURCE_DIR"
fi
shopt -u nullglob

# Sign the app bundle
ENTITLEMENTS="$SCRIPT_DIR/Sources/GhostType/Resources/GhostType.entitlements"
SIGNING_IDENTITY="GhostType Development"

# Check if development certificate exists
# We use the SHA-1 hash to avoid ambiguity if multiple certificates exist
CERT_HASH=$(security find-certificate -c "$SIGNING_IDENTITY" -Z | grep "SHA-1" | head -n 1 | awk '{print $NF}')

if [ -n "$CERT_HASH" ]; then
    print_status "Using stable development certificate (Hash: $CERT_HASH)"
    SIGN_ARG="$CERT_HASH"
else
    print_warning "Development certificate not found. Using ad-hoc signing."
    print_warning "Run ./tools/setup-dev-signing.sh to create a stable certificate."
    print_warning "This will prevent TCC permission invalidation on rebuilds."
    SIGN_ARG="-"
fi

if [ -f "$ENTITLEMENTS" ]; then
    print_status "Signing GhostType.app with entitlements..."
    # Sign the resource bundle first if it exists
    # Then sign the main app with entitlements
    codesign --force --sign "$SIGN_ARG" --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE"
else
    print_warning "Entitlements file not found, signing without entitlements"
    codesign --force --sign "$SIGN_ARG" --options runtime "$APP_BUNDLE"
fi

print_status "Build & Packaging Complete!"
echo ""
echo "======================================"
echo "GhostType.app is ready at:"
echo "  $APP_BUNDLE"
echo "======================================"
echo ""
echo "To run GhostType:"
echo "  open $APP_BUNDLE"
echo ""
echo "Note: On first run, you will need to grant permissions:"
echo "  1. Microphone"
echo "  2. Accessibility (System Settings)"
echo ""
