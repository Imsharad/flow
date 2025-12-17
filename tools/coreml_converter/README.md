# CoreML Model Converters for GhostType

This directory contains Python scripts to convert AI models to CoreML format for on-device inference.

## Prerequisites

1. **Python 3.10+** (recommended: use a virtual environment)
2. **macOS** (required for CoreML validation)

## Setup

```bash
cd tools/coreml_converter

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

## Converting Moonshine ASR Model

Moonshine is a speech recognition model optimized for edge devices. The conversion creates two CoreML models:

- **MoonshineEncoder.mlpackage**: Converts raw audio to hidden states
- **MoonshineDecoder.mlpackage**: Generates tokens from hidden states

### Basic Usage

```bash
# Convert moonshine-tiny (default, ~190MB)
python convert_moonshine.py --out ./models

# Convert moonshine-base (larger, ~400MB, better accuracy)
python convert_moonshine.py --out ./models --model-id UsefulSensors/moonshine-base

# Skip validation (faster, useful for CI)
python convert_moonshine.py --out ./models --skip-validation
```

### Output Files

After conversion, you'll have:

```
models/
├── MoonshineEncoder.mlpackage   # Audio encoder (~100MB)
├── MoonshineDecoder.mlpackage   # Token decoder (~90MB)
└── moonshine_vocab.json         # Tokenizer vocabulary
```

### Integration with GhostType

Copy the generated models to the app resources:

```bash
cp -r models/MoonshineEncoder.mlpackage ../Sources/GhostType/Resources/
cp -r models/MoonshineDecoder.mlpackage ../Sources/GhostType/Resources/
cp models/moonshine_vocab.json ../Sources/GhostType/Resources/
```

## Converting T5 Grammar Correction Model

T5 is a text-to-text transformer for grammar correction. The conversion creates:

- **T5Small.mlpackage**: Combined model for simple deployment
- **T5Encoder.mlpackage**: Text encoder for streaming use
- **T5Decoder.mlpackage**: Token decoder for streaming use

### Basic Usage

```bash
# Convert default t5-small (generic, 60M params)
python convert_t5.py --out ./models

# Convert grammar-tuned model (recommended for grammar correction)
python convert_t5.py --out ./models --model-id vennify/t5-base-grammar-correction

# Or use the smaller grammar-tuned model
python convert_t5.py --out ./models --model-id AventIQ-AI/T5-small-grammar-correction
```

### Supported Models

| Model ID | Size | Notes |
|----------|------|-------|
| `google-t5/t5-small` | 60M | Generic, requires "grammar: " prefix |
| `vennify/t5-base-grammar-correction` | 220M | Pre-tuned for grammar, uses "grammar: " prefix |
| `AventIQ-AI/T5-small-grammar-correction` | 60M | Small + grammar-tuned |

### Output Files

```
models/
├── T5Small.mlpackage      # Combined model (~120MB for t5-small)
├── T5Encoder.mlpackage    # Text encoder
├── T5Decoder.mlpackage    # Token decoder
├── t5_vocab.json          # Tokenizer vocabulary
└── tokenizer/             # SentencePiece tokenizer files
```

### Usage in Swift

```swift
// Prepend grammar prefix to input
let input = "grammar: " + rawTranscription
// Tokenize, run model, decode output
```

## Technical Details

### Dynamic Input Shapes

All models support variable-length inputs using CoreML's `RangeDim`:

**Moonshine (Audio)**:
- Audio input: 1-30 seconds (16,000 to 480,000 samples at 16kHz)
- Token output: Up to 448 tokens

**T5 (Text)**:
- Input tokens: 1-512 tokens
- Output tokens: 1-512 tokens

### Compute Precision

Models are converted with Float16 precision for optimal performance on Apple Neural Engine (ANE).

### Memory Requirements

- Moonshine Tiny: ~500MB peak during conversion
- Moonshine Base: ~1GB peak during conversion

## Troubleshooting

### "ModuleNotFoundError: No module named 'transformers.models.moonshine'"

Update transformers to v4.48+:
```bash
pip install --upgrade transformers>=4.48.0
```

### CoreML conversion fails with "upper_bound must be finite"

This is expected - we use finite bounds for mlprogram backend compatibility.

### Validation fails

Try with `--skip-validation` flag. Validation requires running inference which may fail on some systems.
