# Archived Documentation

**Archived:** 2025-12-16

These documents describe **abandoned architectures** that were researched but never implemented.

---

## Why Archived?

On 2025-12-16, the project made a critical pivot:

> **Decision:** Abandoned **MLX** → Pivoted to **WhisperKit (CoreML)**
> 
> **Reason:** Irresolvable build environment issues on macOS Tahoe Beta (missing Metal Toolchain for compiling custom shaders).

The documents in this archive describe:
- MLX-based inference (abandoned)
- Rust audio bridge (not implemented - Swift-native approach used instead)
- Custom Distil-Whisper integration (WhisperKit handles this)

---

## Archived Files

| File | Description | Why Archived |
|:-----|:------------|:-------------|
| `mlx-metal.md` | MLX compilation fixes for macOS Tahoe | MLX abandoned entirely |
| `research.md` | MLX + Rust + Distil-Whisper architecture | Contradicts current implementation |
| `whisper_research.md` | MLX vs WhisperKit analysis (recommends MLX) | Project chose WhisperKit |

---

## Current Documentation

See the parent directory for current, accurate documentation:

- [`architecture.md`](../architecture.md) — **Current system architecture**
- [`progress.md`](../progress.md) — Development progress tracker
- [`whisper-chunking.md`](../whisper-chunking.md) — Chunking strategy (next implementation step)

---

## Historical Value

These documents may still be useful for:
- Understanding **why** certain decisions were made
- Future reference if revisiting MLX when macOS Tahoe stabilizes
- Academic understanding of alternative approaches
