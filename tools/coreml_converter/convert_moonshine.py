"""Convert Moonshine Tiny to CoreML.

PRD requirements:
- Dynamic audio length support via ct.RangeDim
- Target ANE where feasible (e.g., quantization/int8 if supported)
- Output a distributable .mlpackage

This is a scaffold: the exact conversion steps depend on the upstream Moonshine
model entrypoints and preprocessing.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True, help="Output directory")
    parser.add_argument(
        "--model-id",
        type=str,
        default="usefulsensors/moonshine-tiny",
        help="HF model id (reference)",
    )
    args = parser.parse_args()

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    # TODO: Implement conversion using coremltools.
    # Suggested outline:
    # 1) Load Moonshine model weights (PyTorch)
    # 2) Trace/torchscript or export to an intermediate (e.g., torch.export)
    # 3) Convert with coremltools, using ct.RangeDim for variable-length PCM
    # 4) Save as .mlpackage and validate multiple input lengths
    raise SystemExit(
        "Not implemented: Moonshine conversion scaffold. "
        "See docs/prompt.md Sprint 1 for requirements."
    )


if __name__ == "__main__":
    main()
