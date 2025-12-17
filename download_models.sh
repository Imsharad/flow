#!/bin/bash
set -e

# Directory to store models
MODEL_DIR="models/whisper-turbo"
mkdir -p "$MODEL_DIR"

echo "⬇️  Downloading Whisper v3 Turbo (4-bit) for MLX..."
echo "Target directory: $MODEL_DIR"

# Download using curl (forcing curl for consistency/auth avoidance)
BASE_URL="https://huggingface.co/mlx-community/whisper-large-v3-turbo-4bit/resolve/main"

echo "Using curl to fetch models from $BASE_URL..."

# List of files to download
files=(
    "config.json"
    "model.safetensors"
    "tokenizer_config.json"
    "tokenizer.json"
    "vocabulary.json"
    "preprocessor_config.json"
)

for file in "${files[@]}"; do
    echo "Fetching $file..."
    # Use -f to fail on 404/401
    curl -L -f "$BASE_URL/$file?download=true" -o "$MODEL_DIR/$file"
done

echo "✅ Download complete. Models are in $MODEL_DIR"
