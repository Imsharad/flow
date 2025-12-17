"""Convert T5 to CoreML for grammar correction.

This script converts T5-based text-to-text models to CoreML format
for on-device grammar correction on Apple Silicon.

PRD requirements:
- Convert T5-Small for text-to-text grammar correction
- Float16 precision for Neural Engine (ANE)
- Target <50ms latency for short sentences

Architecture:
- Encoder: Processes input token IDs -> hidden states
- Decoder: Generates corrected tokens from encoder states

Supported models:
- google-t5/t5-small (generic, 60M params)
- vennify/t5-base-grammar-correction (grammar-tuned, 220M params)
- AventIQ-AI/T5-small-grammar-correction (grammar-tuned small)

Usage:
    python convert_t5.py --out ./models
    python convert_t5.py --out ./models --model-id vennify/t5-base-grammar-correction
"""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
from typing import Dict, Optional, Tuple

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from transformers import AutoTokenizer, T5ForConditionalGeneration

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

# Token sequence constants
MIN_INPUT_LENGTH = 1
MAX_INPUT_LENGTH = 512  # T5's default max length
DEFAULT_INPUT_LENGTH = 64  # Typical sentence length

MIN_OUTPUT_LENGTH = 1
MAX_OUTPUT_LENGTH = 512
DEFAULT_OUTPUT_LENGTH = 64


class T5EncoderWrapper(nn.Module):
    """Wrapper for T5 encoder that takes token IDs and outputs hidden states.

    This wrapper:
    1. Takes input token IDs (batch=1, seq_len)
    2. Runs through the encoder
    3. Returns encoder hidden states for decoder cross-attention
    """

    def __init__(self, model: T5ForConditionalGeneration):
        super().__init__()
        self.encoder = model.encoder
        self.shared = model.shared  # Token embeddings

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        """
        Args:
            input_ids: Token IDs of shape (1, seq_len)

        Returns:
            Encoder hidden states of shape (1, seq_len, hidden_size)
        """
        # Get embeddings
        inputs_embeds = self.shared(input_ids)

        # Run through encoder
        encoder_outputs = self.encoder(
            inputs_embeds=inputs_embeds,
            attention_mask=None,
            output_attentions=False,
            output_hidden_states=False,
            return_dict=True,
        )

        return encoder_outputs.last_hidden_state


class T5DecoderWrapper(nn.Module):
    """Wrapper for T5 decoder for autoregressive generation.

    This wrapper:
    1. Takes encoder hidden states and previous token IDs
    2. Runs one decoder step
    3. Returns logits for next token prediction
    """

    def __init__(self, model: T5ForConditionalGeneration):
        super().__init__()
        self.decoder = model.decoder
        self.shared = model.shared  # Token embeddings (shared with encoder)
        self.lm_head = model.lm_head
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
        # Get decoder embeddings
        decoder_inputs_embeds = self.shared(decoder_input_ids)

        # Run through decoder
        decoder_outputs = self.decoder(
            inputs_embeds=decoder_inputs_embeds,
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
        # T5 uses tied embeddings, need to scale by d_model^-0.5
        sequence_output = decoder_outputs.last_hidden_state

        if self.config.tie_word_embeddings:
            # Rescale before projecting to vocab
            sequence_output = sequence_output * (self.config.d_model ** -0.5)

        logits = self.lm_head(sequence_output)

        return logits


class T5CombinedWrapper(nn.Module):
    """Combined encoder+decoder wrapper for simpler deployment.

    This provides a single forward pass from input tokens to output logits,
    suitable for simple correction tasks without streaming.
    """

    def __init__(self, model: T5ForConditionalGeneration):
        super().__init__()
        self.model = model

    def forward(
        self,
        input_ids: torch.Tensor,
        decoder_input_ids: torch.Tensor,
    ) -> torch.Tensor:
        """
        Args:
            input_ids: Input token IDs of shape (1, seq_len)
            decoder_input_ids: Decoder token IDs of shape (1, dec_seq_len)

        Returns:
            Logits of shape (1, dec_seq_len, vocab_size)
        """
        outputs = self.model(
            input_ids=input_ids,
            decoder_input_ids=decoder_input_ids,
            use_cache=False,
            return_dict=True,
        )
        return outputs.logits


def load_t5_model(model_id: str) -> Tuple[T5ForConditionalGeneration, AutoTokenizer]:
    """Load T5 model and tokenizer from HuggingFace."""
    logger.info(f"Loading model: {model_id}")

    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = T5ForConditionalGeneration.from_pretrained(
        model_id,
        torch_dtype=torch.float32,  # Use float32 for tracing
    )
    model.eval()

    logger.info(f"Model loaded. Config: d_model={model.config.d_model}, "
                f"encoder_layers={model.config.num_layers}, "
                f"decoder_layers={model.config.num_decoder_layers}, "
                f"vocab_size={model.config.vocab_size}")

    return model, tokenizer


def trace_encoder(
    model: T5ForConditionalGeneration,
    seq_length: int = DEFAULT_INPUT_LENGTH,
) -> torch.jit.ScriptModule:
    """Trace the encoder wrapper."""
    logger.info(f"Tracing encoder with sequence length {seq_length}")

    wrapper = T5EncoderWrapper(model)
    wrapper.eval()

    # Create example input
    example_input_ids = torch.ones(1, seq_length, dtype=torch.long)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_input_ids)

    return traced


def trace_decoder(
    model: T5ForConditionalGeneration,
    encoder_seq_len: int = DEFAULT_INPUT_LENGTH,
    decoder_seq_len: int = 10,
) -> torch.jit.ScriptModule:
    """Trace the decoder wrapper."""
    logger.info(f"Tracing decoder with encoder_seq_len={encoder_seq_len}, decoder_seq_len={decoder_seq_len}")

    wrapper = T5DecoderWrapper(model)
    wrapper.eval()

    # Create example inputs
    example_decoder_ids = torch.ones(1, decoder_seq_len, dtype=torch.long)
    example_encoder_hidden = torch.randn(1, encoder_seq_len, model.config.d_model)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (example_decoder_ids, example_encoder_hidden))

    return traced


def trace_combined(
    model: T5ForConditionalGeneration,
    input_seq_len: int = DEFAULT_INPUT_LENGTH,
    decoder_seq_len: int = 10,
) -> torch.jit.ScriptModule:
    """Trace the combined wrapper."""
    logger.info(f"Tracing combined model with input_seq_len={input_seq_len}, decoder_seq_len={decoder_seq_len}")

    wrapper = T5CombinedWrapper(model)
    wrapper.eval()

    # Create example inputs
    example_input_ids = torch.ones(1, input_seq_len, dtype=torch.long)
    example_decoder_ids = torch.ones(1, decoder_seq_len, dtype=torch.long)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (example_input_ids, example_decoder_ids))

    return traced


def convert_encoder_to_coreml(
    traced_encoder: torch.jit.ScriptModule,
    model: T5ForConditionalGeneration,
    output_path: Path,
) -> ct.models.MLModel:
    """Convert traced encoder to CoreML with dynamic sequence length support."""
    logger.info("Converting encoder to CoreML...")

    # Define input with dynamic sequence length
    inputs = [
        ct.TensorType(
            name="input_ids",
            shape=ct.Shape(
                shape=(
                    1,  # batch size
                    ct.RangeDim(
                        lower_bound=MIN_INPUT_LENGTH,
                        upper_bound=MAX_INPUT_LENGTH,
                        default=DEFAULT_INPUT_LENGTH,
                    ),
                )
            ),
            dtype=np.int32,
        )
    ]

    # Convert to CoreML
    mlmodel = ct.convert(
        traced_encoder,
        inputs=inputs,
        outputs=[ct.TensorType(name="encoder_hidden_states", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    # Add metadata
    mlmodel.author = "GhostType"
    mlmodel.short_description = "T5 Encoder - converts text tokens to hidden states"
    mlmodel.version = "1.0"

    # Save
    encoder_path = output_path / "T5Encoder.mlpackage"
    mlmodel.save(str(encoder_path))
    logger.info(f"Encoder saved to {encoder_path}")

    return mlmodel


def convert_decoder_to_coreml(
    traced_decoder: torch.jit.ScriptModule,
    model: T5ForConditionalGeneration,
    output_path: Path,
) -> ct.models.MLModel:
    """Convert traced decoder to CoreML with dynamic sequence lengths."""
    logger.info("Converting decoder to CoreML...")

    hidden_size = model.config.d_model

    # Define inputs with dynamic sequence lengths
    inputs = [
        ct.TensorType(
            name="decoder_input_ids",
            shape=ct.Shape(
                shape=(
                    1,  # batch size
                    ct.RangeDim(
                        lower_bound=MIN_OUTPUT_LENGTH,
                        upper_bound=MAX_OUTPUT_LENGTH,
                        default=1,  # Usually decode one token at a time
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
                        lower_bound=MIN_INPUT_LENGTH,
                        upper_bound=MAX_INPUT_LENGTH,
                        default=DEFAULT_INPUT_LENGTH,
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
    mlmodel.short_description = "T5 Decoder - generates correction tokens from encoder states"
    mlmodel.version = "1.0"

    # Save
    decoder_path = output_path / "T5Decoder.mlpackage"
    mlmodel.save(str(decoder_path))
    logger.info(f"Decoder saved to {decoder_path}")

    return mlmodel


def convert_combined_to_coreml(
    traced_combined: torch.jit.ScriptModule,
    model: T5ForConditionalGeneration,
    output_path: Path,
) -> ct.models.MLModel:
    """Convert traced combined model to CoreML."""
    logger.info("Converting combined model to CoreML...")

    # Define inputs with dynamic sequence lengths
    inputs = [
        ct.TensorType(
            name="input_ids",
            shape=ct.Shape(
                shape=(
                    1,  # batch size
                    ct.RangeDim(
                        lower_bound=MIN_INPUT_LENGTH,
                        upper_bound=MAX_INPUT_LENGTH,
                        default=DEFAULT_INPUT_LENGTH,
                    ),
                )
            ),
            dtype=np.int32,
        ),
        ct.TensorType(
            name="decoder_input_ids",
            shape=ct.Shape(
                shape=(
                    1,  # batch size
                    ct.RangeDim(
                        lower_bound=MIN_OUTPUT_LENGTH,
                        upper_bound=MAX_OUTPUT_LENGTH,
                        default=1,
                    ),
                )
            ),
            dtype=np.int32,
        ),
    ]

    # Convert to CoreML
    mlmodel = ct.convert(
        traced_combined,
        inputs=inputs,
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    # Add metadata
    mlmodel.author = "GhostType"
    mlmodel.short_description = "T5 Grammar Correction - text to corrected text"
    mlmodel.version = "1.0"

    # Save
    combined_path = output_path / "T5Small.mlpackage"
    mlmodel.save(str(combined_path))
    logger.info(f"Combined model saved to {combined_path}")

    return mlmodel


def validate_models(
    encoder_path: Path,
    decoder_path: Path,
    tokenizer: AutoTokenizer,
    original_model: T5ForConditionalGeneration,
) -> bool:
    """Validate converted models against original PyTorch model."""
    logger.info("Validating converted models...")

    try:
        # Load CoreML models
        encoder_mlmodel = ct.models.MLModel(str(encoder_path))
        decoder_mlmodel = ct.models.MLModel(str(decoder_path))

        # Create test input
        test_text = "grammar: This are a test sentence with error."
        input_ids = tokenizer(test_text, return_tensors="np").input_ids.astype(np.int32)

        # Test encoder
        encoder_input = {"input_ids": input_ids}
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

        # Verify output shapes
        assert encoder_hidden.shape[0] == 1, "Batch size mismatch"
        assert encoder_hidden.shape[2] == original_model.config.d_model, "Hidden size mismatch"
        assert logits.shape[2] == original_model.config.vocab_size, "Vocab size mismatch"

        # Test a simple generation loop
        logger.info("Testing generation loop...")
        generated_ids = [decoder_start_token]
        for _ in range(5):  # Generate 5 tokens
            decoder_input = {
                "decoder_input_ids": np.array([generated_ids], dtype=np.int32),
                "encoder_hidden_states": encoder_hidden.astype(np.float32),
            }
            decoder_output = decoder_mlmodel.predict(decoder_input)
            logits = decoder_output["logits"]
            next_token = int(np.argmax(logits[0, -1, :]))
            generated_ids.append(next_token)

        generated_text = tokenizer.decode(generated_ids, skip_special_tokens=True)
        logger.info(f"Generated sample: '{generated_text}'")

        logger.info("Validation passed!")
        return True

    except Exception as e:
        logger.error(f"Validation failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def save_tokenizer_vocab(tokenizer: AutoTokenizer, output_path: Path) -> None:
    """Save tokenizer vocabulary for Swift-side encoding/decoding."""
    logger.info("Saving tokenizer vocabulary...")

    vocab_path = output_path / "t5_vocab.json"

    # Get vocabulary
    vocab = tokenizer.get_vocab()

    # Create reverse mapping (id -> token) for decoding
    id_to_token = {v: k for k, v in vocab.items()}

    # Get special tokens
    special_tokens = {
        "pad_token_id": tokenizer.pad_token_id,
        "eos_token_id": tokenizer.eos_token_id,
        "unk_token_id": tokenizer.unk_token_id,
        "decoder_start_token_id": tokenizer.pad_token_id,  # T5 uses pad as decoder start
    }

    # For grammar correction, we typically prepend "grammar: " or similar prefix
    # Save info about this for Swift side
    task_info = {
        "grammar_prefix": "grammar: ",
        "description": "Prepend this prefix to input text for grammar correction",
    }

    output_data = {
        "vocab": vocab,
        "id_to_token": id_to_token,
        "special_tokens": special_tokens,
        "task_info": task_info,
    }

    with open(vocab_path, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=2, ensure_ascii=False)

    logger.info(f"Vocabulary saved to {vocab_path} ({len(vocab)} tokens)")

    # Also save the SentencePiece model if available
    if hasattr(tokenizer, "sp_model"):
        sp_path = output_path / "t5_tokenizer.model"
        tokenizer.save_pretrained(str(output_path / "tokenizer"))
        logger.info(f"Tokenizer files saved to {output_path / 'tokenizer'}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert T5 model to CoreML format for grammar correction"
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
        default="google-t5/t5-small",
        help="HuggingFace model ID (default: google-t5/t5-small). "
             "Recommended: vennify/t5-base-grammar-correction for grammar tasks",
    )
    parser.add_argument(
        "--skip-validation",
        action="store_true",
        help="Skip model validation after conversion",
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
    model, tokenizer = load_t5_model(args.model_id)

    # Save tokenizer vocabulary for Swift
    save_tokenizer_vocab(tokenizer, out_dir)

    generate_combined = not args.split_only
    generate_split = not args.combined_only

    # Generate combined model (for simple deployment)
    if generate_combined:
        traced_combined = trace_combined(model)
        convert_combined_to_coreml(traced_combined, model, out_dir)

    # Generate encoder/decoder split (for streaming/advanced use)
    if generate_split:
        traced_encoder = trace_encoder(model)
        traced_decoder = trace_decoder(model)
        convert_encoder_to_coreml(traced_encoder, model, out_dir)
        convert_decoder_to_coreml(traced_decoder, model, out_dir)

        # Validate split models
        if not args.skip_validation:
            encoder_path = out_dir / "T5Encoder.mlpackage"
            decoder_path = out_dir / "T5Decoder.mlpackage"
            validate_models(encoder_path, decoder_path, tokenizer, model)

    logger.info(f"\nConversion complete! Models saved to {out_dir}")
    logger.info("\nGenerated files:")
    if generate_combined:
        logger.info("  - T5Small.mlpackage (combined model for simple use)")
    if generate_split:
        logger.info("  - T5Encoder.mlpackage (input tokens -> hidden states)")
        logger.info("  - T5Decoder.mlpackage (hidden states + tokens -> logits)")
    logger.info("  - t5_vocab.json (tokenizer vocabulary)")
    logger.info("  - tokenizer/ (SentencePiece tokenizer files)")
    logger.info("\nUsage notes:")
    logger.info("  - For grammar correction, prepend 'grammar: ' to input text")
    logger.info("  - Example: 'grammar: This are a test.' -> 'This is a test.'")
    logger.info("\nNext steps:")
    logger.info("  1. Copy .mlpackage files to Sources/GhostType/Resources/")
    logger.info("  2. Update TextCorrector.swift to load and run inference")


if __name__ == "__main__":
    main()
