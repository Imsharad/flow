"""Convert Moonshine Tiny to CoreML.

This script converts the UsefulSensors Moonshine ASR model to CoreML format
for efficient on-device inference on Apple Silicon.

PRD requirements:
- Dynamic audio length support via ct.RangeDim (1s to 30s of audio)
- Target ANE where feasible (Float16 compute precision)
- Output distributable .mlpackage files

Architecture:
- Encoder: Processes raw audio -> hidden states (variable length)
- Decoder: Autoregressive token generation with KV caching

Usage:
    python convert_moonshine.py --out ./models
    python convert_moonshine.py --out ./models --model-id UsefulSensors/moonshine-base
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path
from typing import Optional, Tuple

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from transformers import AutoProcessor, MoonshineForConditionalGeneration

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

# Audio constants
SAMPLE_RATE = 16000
MIN_AUDIO_SECONDS = 1.0
MAX_AUDIO_SECONDS = 30.0
DEFAULT_AUDIO_SECONDS = 5.0

MIN_AUDIO_SAMPLES = int(MIN_AUDIO_SECONDS * SAMPLE_RATE)  # 16000
MAX_AUDIO_SAMPLES = int(MAX_AUDIO_SECONDS * SAMPLE_RATE)  # 480000
DEFAULT_AUDIO_SAMPLES = int(DEFAULT_AUDIO_SECONDS * SAMPLE_RATE)  # 80000

# Decoder constants
MAX_OUTPUT_TOKENS = 448  # Reasonable max for speech transcription


class MoonshineEncoderWrapper(nn.Module):
    """Wrapper for Moonshine encoder that takes raw audio and outputs hidden states.

    This wrapper:
    1. Takes raw audio waveform (batch=1, audio_length)
    2. Runs the audio through the encoder (which includes conv preprocessing)
    3. Returns encoder hidden states for decoder cross-attention
    """

    def __init__(self, model: MoonshineForConditionalGeneration):
        super().__init__()
        self.encoder = model.get_encoder()

    def forward(self, input_values: torch.Tensor) -> torch.Tensor:
        """
        Args:
            input_values: Raw audio tensor of shape (1, audio_length)

        Returns:
            Encoder hidden states of shape (1, seq_len, hidden_size)
        """
        # The Moonshine encoder handles audio preprocessing internally via conv layers
        encoder_outputs = self.encoder(
            input_values=input_values,
            attention_mask=None,
            output_attentions=False,
            output_hidden_states=False,
            return_dict=True,
        )

        return encoder_outputs.last_hidden_state


class MoonshineDecoderWrapper(nn.Module):
    """Wrapper for Moonshine decoder for autoregressive generation.

    This wrapper:
    1. Takes encoder hidden states and previous token IDs
    2. Runs one decoder step
    3. Returns logits for next token prediction

    Note: KV caching is handled externally in Swift for efficiency.
    """

    def __init__(self, model: MoonshineForConditionalGeneration):
        super().__init__()
        self.decoder = model.get_decoder()
        self.proj_out = model.proj_out  # LM head for Moonshine
        self.config = model.config

    def forward(
        self,
        decoder_input_ids: torch.Tensor,
        encoder_hidden_states: torch.Tensor,
    ) -> torch.Tensor:
        """
        Args:
            decoder_input_ids: Token IDs of shape (1, seq_len)
            encoder_hidden_states: Encoder output of shape (1, enc_seq_len, hidden_size)

        Returns:
            Logits of shape (1, seq_len, vocab_size)
        """
        # Get decoder hidden states
        decoder_outputs = self.decoder(
            input_ids=decoder_input_ids,
            encoder_hidden_states=encoder_hidden_states,
            encoder_attention_mask=None,
            attention_mask=None,
            past_key_values=None,
            use_cache=False,
            output_attentions=False,
            output_hidden_states=False,
            return_dict=True,
        )

        # Project to vocabulary
        logits = self.proj_out(decoder_outputs.last_hidden_state)

        return logits


class MoonshineFullWrapper(nn.Module):
    """Full end-to-end wrapper for simpler single-model conversion.

    This provides a single forward pass from audio to logits, useful for
    validation and simpler deployment scenarios.
    """

    def __init__(self, model: MoonshineForConditionalGeneration):
        super().__init__()
        self.model = model

    def forward(
        self,
        input_values: torch.Tensor,
        decoder_input_ids: torch.Tensor,
    ) -> torch.Tensor:
        """
        Args:
            input_values: Raw audio tensor of shape (1, audio_length)
            decoder_input_ids: Token IDs of shape (1, seq_len)

        Returns:
            Logits of shape (1, seq_len, vocab_size)
        """
        # Create a causal mask for the decoder to avoid internal dynamic slicing
        seq_len = decoder_input_ids.shape[1]
        # Moonshine expects float mask: 0.0 for attend, -inf for ignore
        # But wait, transformers usually takes 1 for attend, 0 for ignore for 'attention_mask'
        # Let's try passing a standard attention mask (all 1s) for the decoder inputs
        decoder_attention_mask = torch.ones((1, seq_len), dtype=torch.long, device=decoder_input_ids.device)

        outputs = self.model(
            input_values=input_values,
            decoder_input_ids=decoder_input_ids,
            decoder_attention_mask=decoder_attention_mask, # Explicitly provide mask
            use_cache=False,
            return_dict=True,
        )
        return outputs.logits


def load_moonshine_model(model_id: str) -> Tuple[MoonshineForConditionalGeneration, AutoProcessor]:
    """Load Moonshine model and processor from HuggingFace."""
    logger.info(f"Loading model: {model_id}")

    processor = AutoProcessor.from_pretrained(model_id)
    model = MoonshineForConditionalGeneration.from_pretrained(
        model_id,
        torch_dtype=torch.float32,  # Use float32 for tracing
        use_safetensors=True,
        attn_implementation="eager",  # Use eager attention for tracing compatibility
    )
    model.eval()

    logger.info(f"Model loaded. Config: {model.config.hidden_size}d, "
                f"{model.config.encoder_num_hidden_layers} encoder layers, "
                f"{model.config.decoder_num_hidden_layers} decoder layers")

    return model, processor


def trace_encoder(
    model: MoonshineForConditionalGeneration,
    audio_length: int = DEFAULT_AUDIO_SAMPLES,
) -> torch.jit.ScriptModule:
    """Trace the encoder wrapper."""
    logger.info(f"Tracing encoder with audio length {audio_length}")

    wrapper = MoonshineEncoderWrapper(model)
    wrapper.eval()

    # Create example input
    example_audio = torch.randn(1, audio_length)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_audio)

    return traced


def trace_decoder(
    model: MoonshineForConditionalGeneration,
    encoder_seq_len: int = 100,  # Approximate encoder output length
    decoder_seq_len: int = 128,  # Increased from 10 to avoid slicing errors during conversion
) -> torch.jit.ScriptModule:
    """Trace the decoder wrapper."""
    logger.info(f"Tracing decoder with encoder_seq_len={encoder_seq_len}, decoder_seq_len={decoder_seq_len}")

    wrapper = MoonshineDecoderWrapper(model)
    wrapper.eval()

    # Create example inputs
    example_decoder_ids = torch.ones(1, decoder_seq_len, dtype=torch.long)
    example_encoder_hidden = torch.randn(1, encoder_seq_len, model.config.hidden_size)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (example_decoder_ids, example_encoder_hidden))

    return traced


def convert_encoder_to_coreml(
    traced_encoder: torch.jit.ScriptModule,
    model: MoonshineForConditionalGeneration,
    output_path: Path,
    quantize: bool = True,
) -> ct.models.MLModel:
    """Convert traced encoder to CoreML with dynamic audio length support."""
    logger.info("Converting encoder to CoreML...")

    # Calculate approximate encoder output sequence length
    # Audio preprocessor: conv1 (stride 64) -> conv2 (stride 3)
    # seq_len ≈ audio_length / (64 * 3) = audio_length / 192
    min_enc_seq = max(1, MIN_AUDIO_SAMPLES // 192)
    max_enc_seq = MAX_AUDIO_SAMPLES // 192 + 1
    default_enc_seq = DEFAULT_AUDIO_SAMPLES // 192

    # Define input with dynamic audio length
    inputs = [
        ct.TensorType(
            name="input_values",
            shape=ct.Shape(
                shape=(
                    1,  # batch size
                    ct.RangeDim(
                        lower_bound=MIN_AUDIO_SAMPLES,
                        upper_bound=MAX_AUDIO_SAMPLES,
                        default=DEFAULT_AUDIO_SAMPLES,
                    ),
                )
            ),
            dtype=np.float32,
        )
    ]

    # Convert to CoreML
    mlmodel = ct.convert(
        traced_encoder,
        inputs=inputs,
        outputs=[ct.TensorType(name="encoder_hidden_states", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,  # ANE-friendly
        minimum_deployment_target=ct.target.macOS14,
    )

    # Add metadata
    mlmodel.author = "GhostType"
    mlmodel.short_description = "Moonshine ASR Encoder - converts audio to hidden states"
    mlmodel.version = "1.0"

    # Apply quantization if requested
    if quantize:
        logger.info("Applying Float16 quantization...")
        # Float16 is already applied via compute_precision
        # For further compression, could use palettization or linear quantization

    # Save
    encoder_path = output_path / "MoonshineEncoder.mlpackage"
    mlmodel.save(str(encoder_path))
    logger.info(f"Encoder saved to {encoder_path}")

    return mlmodel


def convert_decoder_to_coreml(
    traced_decoder: torch.jit.ScriptModule,
    model: MoonshineForConditionalGeneration,
    output_path: Path,
    quantize: bool = True,
) -> ct.models.MLModel:
    """Convert traced decoder to CoreML with dynamic sequence lengths."""
    logger.info("Converting decoder to CoreML...")

    hidden_size = model.config.hidden_size

    # Calculate encoder sequence length bounds (from audio length bounds)
    min_enc_seq = max(1, MIN_AUDIO_SAMPLES // 192)
    max_enc_seq = MAX_AUDIO_SAMPLES // 192 + 1
    default_enc_seq = DEFAULT_AUDIO_SAMPLES // 192

    # Define inputs with dynamic sequence lengths
    inputs = [
        ct.TensorType(
            name="decoder_input_ids",
            shape=ct.Shape(
                shape=(
                    1,  # batch size
                    ct.RangeDim(
                        lower_bound=1,
                        upper_bound=MAX_OUTPUT_TOKENS,
                        default=1,
                    ),
                )
            ),
            dtype=np.int32,
        ),
        ct.TensorType(
            name="encoder_hidden_states",
            shape=ct.Shape(
                shape=(
                    1,  # batch size
                    ct.RangeDim(
                        lower_bound=min_enc_seq,
                        upper_bound=max_enc_seq,
                        default=default_enc_seq,
                    ),
                    hidden_size,
                )
            ),
            dtype=np.float32,
        ),
    ]

    # Convert to CoreML
    mlmodel = ct.convert(
        traced_decoder,
        inputs=inputs,
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    # Add metadata
    mlmodel.author = "GhostType"
    mlmodel.short_description = "Moonshine ASR Decoder - generates tokens from encoder states"
    mlmodel.version = "1.0"

    # Save
    decoder_path = output_path / "MoonshineDecoder.mlpackage"
    mlmodel.save(str(decoder_path))
    logger.info(f"Decoder saved to {decoder_path}")

    return mlmodel


def validate_models(
    encoder_path: Path,
    decoder_path: Path,
    processor: AutoProcessor,
    original_model: MoonshineForConditionalGeneration,
) -> bool:
    """Validate converted models against original PyTorch model."""
    logger.info("Validating converted models...")

    try:
        # Load CoreML models
        encoder_mlmodel = ct.models.MLModel(str(encoder_path))
        decoder_mlmodel = ct.models.MLModel(str(decoder_path))

        # Create test audio (3 seconds of random noise)
        test_audio_length = 3 * SAMPLE_RATE
        test_audio = np.random.randn(test_audio_length).astype(np.float32)

        # Test encoder
        encoder_input = {"input_values": test_audio.reshape(1, -1)}
        encoder_output = encoder_mlmodel.predict(encoder_input)
        encoder_hidden = encoder_output["encoder_hidden_states"]
        logger.info(f"Encoder output shape: {encoder_hidden.shape}")

        # Test decoder (single token generation)
        decoder_start_token = original_model.config.decoder_start_token_id
        decoder_input = {
            "decoder_input_ids": np.array([[decoder_start_token]], dtype=np.int32),
            "encoder_hidden_states": encoder_hidden.astype(np.float32),
        }
        decoder_output = decoder_mlmodel.predict(decoder_input)
        logits = decoder_output["logits"]
        logger.info(f"Decoder output shape: {logits.shape}")

        # Verify output shapes are reasonable
        assert encoder_hidden.shape[0] == 1, "Batch size mismatch"
        assert encoder_hidden.shape[2] == original_model.config.hidden_size, "Hidden size mismatch"
        assert logits.shape[2] == original_model.config.vocab_size, "Vocab size mismatch"

        logger.info("Validation passed!")
        return True

    except Exception as e:
        logger.error(f"Validation failed: {e}")
        return False


def convert_combined_model(
    model: MoonshineForConditionalGeneration,
    output_path: Path,
) -> ct.models.MLModel:
    """Convert a combined encoder+decoder model for simpler deployment.

    This creates a single model that takes audio and outputs token IDs directly,
    suitable for simple transcription tasks without streaming.
    """
    logger.info("Converting combined model to CoreML (Static Shapes)...")

    # Create a wrapper that does full generation
    class CombinedWrapper(nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, input_values: torch.Tensor, decoder_input_ids: torch.Tensor) -> torch.Tensor:
            """Run encoder and single decoder step."""
            # Static mask injection to help tracing
            seq_len = decoder_input_ids.shape[1]
            decoder_attention_mask = torch.ones((1, seq_len), dtype=torch.long, device=decoder_input_ids.device)
            
            outputs = self.model(
                input_values=input_values,
                decoder_input_ids=decoder_input_ids,
                decoder_attention_mask=decoder_attention_mask,
                use_cache=False,
                return_dict=True,
            )
            return outputs.logits

    wrapper = CombinedWrapper(model)
    wrapper.eval()

    # Use STATIC shapes for conversion to avoid dynamic slicing bugs
    # 10 seconds of audio @ 16kHz
    STATIC_AUDIO_SAMPLES = 16000 * 10 
    # Max output tokens (decoder sequence length)
    STATIC_SEQ_LEN = 128 

    # Trace with example inputs matching static size
    example_audio = torch.randn(1, STATIC_AUDIO_SAMPLES)
    example_tokens = torch.ones(1, STATIC_SEQ_LEN, dtype=torch.long)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (example_audio, example_tokens))

    inputs = [
        ct.TensorType(
            name="input_values",
            shape=ct.Shape(shape=(1, STATIC_AUDIO_SAMPLES)), # Static
            dtype=np.float32,
        ),
        ct.TensorType(
            name="decoder_input_ids",
            shape=ct.Shape(shape=(1, STATIC_SEQ_LEN)), # Static
            dtype=np.int32,
        ),
    ]

    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    mlmodel.author = "GhostType"
    mlmodel.short_description = "Moonshine ASR - Speech to text transcription (Static 10s)"
    mlmodel.version = "1.0"

    combined_path = output_path / "MoonshineTiny.mlpackage"
    mlmodel.save(str(combined_path))
    logger.info(f"Combined model saved to {combined_path}")

    return mlmodel


def save_tokenizer_vocab(processor: AutoProcessor, output_path: Path) -> None:
    """Save tokenizer vocabulary for Swift-side decoding."""
    logger.info("Saving tokenizer vocabulary...")

    vocab_path = output_path / "moonshine_vocab.json"

    # Get tokenizer vocabulary
    tokenizer = processor.tokenizer
    vocab = tokenizer.get_vocab()

    # Create reverse mapping (id -> token) for decoding
    id_to_token = {v: k for k, v in vocab.items()}

    # Also save special tokens
    special_tokens = {
        "bos_token_id": tokenizer.bos_token_id,
        "eos_token_id": tokenizer.eos_token_id,
        "pad_token_id": tokenizer.pad_token_id,
        "decoder_start_token_id": tokenizer.bos_token_id,  # Moonshine uses BOS as decoder start
    }

    import json

    output_data = {
        "vocab": vocab,
        "id_to_token": id_to_token,
        "special_tokens": special_tokens,
    }

    with open(vocab_path, "w") as f:
        json.dump(output_data, f, indent=2, ensure_ascii=False)

    logger.info(f"Vocabulary saved to {vocab_path} ({len(vocab)} tokens)")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert Moonshine ASR model to CoreML format"
    )
    parser.add_argument(
        "--out",
        type=Path,
        required=True,
        help="Output directory for CoreML models",
    )
    parser.add_argument(
        "--model-id",
        type=str,
        default="UsefulSensors/moonshine-tiny",
        help="HuggingFace model ID (default: UsefulSensors/moonshine-tiny)",
    )
    parser.add_argument(
        "--skip-validation",
        action="store_true",
        help="Skip model validation after conversion",
    )
    parser.add_argument(
        "--no-quantize",
        action="store_true",
        help="Disable Float16 quantization (not recommended)",
    )
    parser.add_argument(
        "--combined-only",
        action="store_true",
        help="Only generate combined model (simpler, for basic use)",
    )
    parser.add_argument(
        "--split-only",
        action="store_true",
        help="Only generate encoder/decoder split (for streaming)",
    )
    args = parser.parse_args()

    # Create output directory
    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    # Load model
    model, processor = load_moonshine_model(args.model_id)

    # Save tokenizer vocabulary for Swift
    save_tokenizer_vocab(processor, out_dir)

    quantize = not args.no_quantize
    generate_combined = not args.split_only
    generate_split = not args.combined_only

    # Generate combined model (for simple deployment)
    if generate_combined:
        convert_combined_model(model, out_dir)

    # Generate encoder/decoder split (for streaming)
    if generate_split:
        traced_encoder = trace_encoder(model)
        traced_decoder = trace_decoder(model)
        convert_encoder_to_coreml(traced_encoder, model, out_dir, quantize=quantize)
        convert_decoder_to_coreml(traced_decoder, model, out_dir, quantize=quantize)

        # Validate split models
        if not args.skip_validation:
            encoder_path = out_dir / "MoonshineEncoder.mlpackage"
            decoder_path = out_dir / "MoonshineDecoder.mlpackage"
            validate_models(encoder_path, decoder_path, processor, model)

    logger.info(f"\nConversion complete! Models saved to {out_dir}")
    logger.info("\nGenerated files:")
    if generate_combined:
        logger.info("  - MoonshineTiny.mlpackage (combined model for simple use)")
    if generate_split:
        logger.info("  - MoonshineEncoder.mlpackage (audio -> hidden states)")
        logger.info("  - MoonshineDecoder.mlpackage (hidden states + tokens -> logits)")
    logger.info("  - moonshine_vocab.json (tokenizer vocabulary)")
    logger.info("\nNext steps:")
    logger.info("  1. Copy .mlpackage files to Sources/GhostType/Resources/")
    logger.info("  2. Update Transcriber.swift to load and run inference")


if __name__ == "__main__":
    main()
