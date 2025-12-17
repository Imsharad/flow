#!/bin/bash
# GhostType Development Runner
# Handles permissions and logging for development

set -e

APP_PATH="/Users/sharad/Projects/GhostType/GhostType.app"
BINARY_PATH="$APP_PATH/Contents/MacOS/GhostType"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
    echo "Usage: ./run.sh [options]"
    echo ""
    echo "Options:"
    echo "  --build       Build before running (incremental)"
    echo "  --clean       Clean build before running"
    echo "  --open        Launch with 'open' (for permission dialogs)"
    echo "  --debug       Run binary directly (shows logs, requires permissions already granted)"
    echo "  --reset-tcc   Reset TCC permissions for GhostType (requires re-granting)"
    echo "  --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  ./run.sh --build --open     # Build and launch (first time / after rebuild)"
    echo "  ./run.sh --debug            # Run with debug logs (after permissions granted)"
    echo "  ./run.sh --clean --open     # Clean rebuild and launch"
}

do_build() {
    local clean_flag=""
    if [ "$1" = "clean" ]; then
        clean_flag="--clean"
    fi
    ./build.sh $clean_flag
}

check_accessibility() {
    # Check if app has accessibility permission using AppleScript
    osascript -e 'tell application "System Events" to return (exists process "GhostType")' &>/dev/null
    return 0
}

reset_tcc() {
    echo -e "${YELLOW}Resetting TCC permissions for GhostType...${NC}"
    tccutil reset Accessibility com.ghosttype.app 2>/dev/null || true
    tccutil reset Microphone com.ghosttype.app 2>/dev/null || true
    tccutil reset SpeechRecognition com.ghosttype.app 2>/dev/null || true
    echo -e "${GREEN}TCC reset complete. You'll need to re-grant permissions.${NC}"
}

run_open() {
    echo -e "${GREEN}Launching GhostType.app via 'open'...${NC}"
    echo -e "${YELLOW}If prompted, grant Microphone and Accessibility permissions.${NC}"
    echo ""
    open "$APP_PATH"

    echo ""
    echo -e "${GREEN}App launched. To see debug logs, run:${NC}"
    echo "  ./run.sh --debug"
}

run_debug() {
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}Binary not found. Run './run.sh --build --open' first.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Running GhostType with debug output...${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
    echo ""

    "$BINARY_PATH"
}

# Parse arguments
BUILD=false
CLEAN=false
OPEN=false
DEBUG=false
RESET=false

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD=true
            shift
            ;;
        --clean)
            CLEAN=true
            BUILD=true
            shift
            ;;
        --open)
            OPEN=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --reset-tcc)
            RESET=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Execute actions
if [ "$RESET" = true ]; then
    reset_tcc
fi

if [ "$BUILD" = true ]; then
    if [ "$CLEAN" = true ]; then
        do_build clean
    else
        do_build
    fi
fi

if [ "$OPEN" = true ]; then
    run_open
elif [ "$DEBUG" = true ]; then
    run_debug
fi
