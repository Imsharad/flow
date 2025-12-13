"""Convert T5-Small to CoreML for correction.

PRD requirements:
- Convert `t5-small` to a CoreML text-to-text model (Float16)
- Validate fast correction latency on Apple Neural Engine

This is a scaffold: production conversion needs tokenizer + decoding strategy.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True, help="Output directory")
    parser.add_argument("--model-id", type=str, default="t5-small")
    args = parser.parse_args()

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    # TODO: Implement conversion using coremltools.
    # Suggested outline:
    # 1) Load HF T5 model + tokenizer
    # 2) Decide generation strategy (greedy vs beam) and implement in CoreML-friendly way
    # 3) Convert encoder/decoder (may require separate models + a Swift decoding loop)
    # 4) Save as .mlpackage (and precompile to .mlmodelc for app bundling)
    raise SystemExit(
        "Not implemented: T5 conversion scaffold. "
        "See docs/prompt.md Sprint 1 for requirements."
    )


if __name__ == "__main__":
    main()
