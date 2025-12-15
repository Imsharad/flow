#!/bin/bash
# Setup and run CoreML model conversions for GhostType
# Usage:
#   ./setup_and_convert.sh [output_dir]           # Convert all models
#   ./setup_and_convert.sh [output_dir] moonshine # Convert Moonshine only
#   ./setup_and_convert.sh [output_dir] t5        # Convert T5 only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR/models}"
MODEL_TYPE="${2:-all}"  # all, moonshine, or t5

echo "=== GhostType CoreML Converter Setup ==="
echo "Output directory: $OUTPUT_DIR"
echo "Model type: $MODEL_TYPE"
echo ""

# Check Python version
PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
echo "Python version: $PYTHON_VERSION"

# Create virtual environment if it doesn't exist
if [ ! -d "$SCRIPT_DIR/venv" ]; then
    echo ""
    echo "Creating virtual environment..."
    python3 -m venv "$SCRIPT_DIR/venv"
fi

# Activate virtual environment
echo "Activating virtual environment..."
source "$SCRIPT_DIR/venv/bin/activate"

# Install/upgrade dependencies
echo ""
echo "Installing dependencies (this may take a few minutes)..."
pip install --upgrade pip
pip install -r "$SCRIPT_DIR/requirements.txt"

# Run Moonshine conversion
if [ "$MODEL_TYPE" = "all" ] || [ "$MODEL_TYPE" = "moonshine" ]; then
    echo ""
    echo "=== Starting Moonshine ASR Conversion ==="
    python "$SCRIPT_DIR/convert_moonshine.py" --out "$OUTPUT_DIR"
fi

# Run T5 conversion
if [ "$MODEL_TYPE" = "all" ] || [ "$MODEL_TYPE" = "t5" ]; then
    echo ""
    echo "=== Starting T5 Grammar Correction Conversion ==="
    python "$SCRIPT_DIR/convert_t5.py" --out "$OUTPUT_DIR"
fi

echo ""
echo "=== Conversion Complete ==="
echo ""
echo "Generated files in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"

echo ""
echo "To use in GhostType, copy the models to the app resources:"
echo "  cp -r $OUTPUT_DIR/*.mlpackage Sources/GhostType/Resources/"
echo "  cp $OUTPUT_DIR/*.json Sources/GhostType/Resources/"
echo "  cp -r $OUTPUT_DIR/tokenizer Sources/GhostType/Resources/"
