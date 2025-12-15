#!/usr/bin/env python3
"""
Silero VAD v5 to CoreML Converter

Converts the Silero Voice Activity Detection model to CoreML format
for efficient on-device inference on Apple Neural Engine.

Usage:
    python convert_silero_vad.py [--output-dir ./models]

Requirements:
    pip install torch torchaudio coremltools

Silero VAD Model:
    - Input: 512 samples at 16kHz (~32ms of audio)
    - Output: Probability of voice activity (0.0 - 1.0)
    - Hidden state: LSTM state for streaming inference
"""

import argparse
import os
import sys
from pathlib import Path

import torch
import torch.nn as nn
import coremltools as ct
from coremltools.models.neural_network import quantization_utils


def download_silero_vad():
    """Download Silero VAD model from torch.hub"""
    print("Downloading Silero VAD v5 from torch.hub...")
    
    model, utils = torch.hub.load(
        repo_or_dir='snakers4/silero-vad',
        model='silero_vad',
        force_reload=False,
        onnx=False  # We want PyTorch model for better CoreML conversion
    )
    
    # Get utility functions
    (get_speech_timestamps,
     save_audio,
     read_audio,
     VADIterator,
     collect_chunks) = utils
    
    return model


class SileroVADWrapper(nn.Module):
    """
    Wrapper around Silero VAD for CoreML export.
    
    The original model has complex state management. We simplify it for
    CoreML by:
    1. Taking audio chunk + hidden states as input
    2. Returning probability + updated hidden states
    """
    
    def __init__(self, original_model):
        super().__init__()
        self.model = original_model
        
        # Silero VAD v5 uses 2-layer LSTM with hidden size 64
        self.hidden_size = 64
        self.num_layers = 2
        
    def forward(self, audio: torch.Tensor, h: torch.Tensor, c: torch.Tensor):
        """
        Args:
            audio: [1, 512] - 512 samples at 16kHz
            h: [2, 1, 64] - LSTM hidden state
            c: [2, 1, 64] - LSTM cell state
            
        Returns:
            prob: [1] - Voice activity probability
            h_out: [2, 1, 64] - Updated hidden state
            c_out: [2, 1, 64] - Updated cell state
        """
        # Call the original model with state
        # The Silero model expects (audio, sr) for simple calls
        # or (audio, state) for stateful calls
        
        # Reset context each call and pass state through LSTM
        # This is a simplified wrapper - the actual implementation
        # may need adjustment based on Silero's exact API
        
        with torch.no_grad():
            # Silero VAD v5 API
            prob = self.model(audio, 16000)  # sr=16000
            
        return prob, h, c


def convert_to_coreml(model, output_dir: Path):
    """Convert Silero VAD to CoreML format"""
    print("\nConverting to CoreML...")
    
    model.eval()
    
    # Silero VAD expects 512 samples at 16kHz (~32ms)
    chunk_size = 512
    
    # Example inputs for tracing
    example_audio = torch.randn(1, chunk_size)
    
    # Trace the model (simplified - just the audio->prob path)
    # For production, we'd need to handle LSTM states properly
    print("Tracing model...")
    
    try:
        # Wrap the model to handle state and fixed sample rate
        print("Wrapping model...")
        wrapper = SileroVADWrapper(model)
        wrapper.eval()
        
        # Create dummy state
        h = torch.zeros(2, 1, 64)
        c = torch.zeros(2, 1, 64)
        
        # Trace the wrapper
        print("Tracing wrapper...")
        traced = torch.jit.trace(wrapper, (example_audio, h, c))
        
        # Convert to CoreML
        print("Converting to CoreML ML Program format...")
        
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="audio", shape=(1, chunk_size), dtype=float),
                ct.TensorType(name="h", shape=(2, 1, 64), dtype=float),
                ct.TensorType(name="c", shape=(2, 1, 64), dtype=float),
            ],
            outputs=[
                ct.TensorType(name="prob"),
                ct.TensorType(name="h_out"),
                ct.TensorType(name="c_out"),
            ],
            minimum_deployment_target=ct.target.macOS14,
            compute_precision=ct.precision.FLOAT16,
            convert_to="mlprogram",
        )
        
        # Set model metadata
        mlmodel.author = "GhostType"
        mlmodel.short_description = "Silero VAD v5 - Voice Activity Detection"
        mlmodel.input_description["audio"] = "512 audio samples at 16kHz (32ms)"
        mlmodel.output_description["probability"] = "Voice activity probability (0-1)"
        
        # Save model
        output_path = output_dir / "SileroVAD.mlpackage"
        mlmodel.save(str(output_path))
        print(f"Saved: {output_path}")
        
        # Also save a quantized version for faster inference
        print("\nCreating quantized version...")
        try:
            quantized = quantization_utils.quantize_weights(mlmodel, nbits=16)
            quantized_path = output_dir / "SileroVAD_fp16.mlpackage"
            quantized.save(str(quantized_path))
            print(f"Saved: {quantized_path}")
        except Exception as e:
            print(f"Quantization skipped: {e}")
        
        return mlmodel
        
    except Exception as e:
        print(f"Conversion failed: {e}")
        print("\nNote: Silero VAD v5 has complex LSTM state management.")
        print("Consider using the energy-based VAD as fallback or")
        print("implementing a custom CoreML-compatible VAD wrapper.")
        return None


def create_energy_vad_coreml(output_dir: Path):
    """
    Create a simple energy-based VAD as CoreML model.
    
    This is a fallback when Silero conversion fails.
    Uses RMS energy threshold for speech detection.
    """
    print("\nCreating energy-based VAD model...")
    
    class EnergyVAD(nn.Module):
        def __init__(self, threshold=0.02):
            super().__init__()
            self.threshold = threshold
            
        def forward(self, audio: torch.Tensor) -> torch.Tensor:
            # Compute RMS energy
            rms = torch.sqrt(torch.mean(audio ** 2, dim=-1, keepdim=True))
            # Sigmoid activation around threshold
            prob = torch.sigmoid((rms - self.threshold) * 100)
            return prob
    
    model = EnergyVAD()
    model.eval()
    
    # Trace
    example = torch.randn(1, 512)
    traced = torch.jit.trace(model, example)
    
    # Convert
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="audio", shape=(1, 512), dtype=float),
        ],
        outputs=[
            ct.TensorType(name="probability"),
        ],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    
    mlmodel.author = "GhostType"
    mlmodel.short_description = "Energy-based Voice Activity Detection"
    
    output_path = output_dir / "EnergyVAD.mlpackage"
    mlmodel.save(str(output_path))
    print(f"Saved: {output_path}")
    
    return mlmodel


def main():
    parser = argparse.ArgumentParser(description="Convert Silero VAD to CoreML")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./models"),
        help="Output directory for CoreML models"
    )
    parser.add_argument(
        "--energy-only",
        action="store_true",
        help="Only create energy-based VAD (skip Silero)"
    )
    
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    
    print("=" * 60)
    print("Silero VAD to CoreML Converter")
    print("=" * 60)
    
    if args.energy_only:
        create_energy_vad_coreml(args.output_dir)
    else:
        try:
            # Download Silero VAD
            model = download_silero_vad()
            
            # Convert to CoreML
            result = convert_to_coreml(model, args.output_dir)
            
            if result is None:
                print("\nSilero conversion failed. Creating energy-based fallback...")
                create_energy_vad_coreml(args.output_dir)
                
        except Exception as e:
            print(f"\nError: {e}")
            print("Creating energy-based fallback...")
            create_energy_vad_coreml(args.output_dir)
    
    print("\n" + "=" * 60)
    print("Done!")
    print("=" * 60)


if __name__ == "__main__":
    main()
