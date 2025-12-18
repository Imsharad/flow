#!/bin/bash
# Script to download MLX-compatible Whisper Weights
# Target: distil-whisper/distil-large-v3 converted to MLX 4-bit

set -e

MODEL_REPO="mlx-community/distil-whisper-large-v3"
OUTPUT_DIR="Sources/GhostType/Resources/mlx-distil-large-v3"

echo "🦄 Downloading MLX Weights for $MODEL_REPO..."
mkdir -p "$OUTPUT_DIR"

# Check if huggingface-cli is installed
if ! command -v huggingface-cli &> /dev/null; then
    echo "❌ huggingface-cli could not be found."
    echo "Please install it via: pip install huggingface_hub"
    exit 1
fi

# Download contents
echo "⬇️ Downloading to $OUTPUT_DIR..."
huggingface-cli download "$MODEL_REPO" --local-dir "$OUTPUT_DIR" --local-dir-use-symlinks False

echo "✅ Download complete."
echo "📦 verifying files..."
ls -lh "$OUTPUT_DIR"
