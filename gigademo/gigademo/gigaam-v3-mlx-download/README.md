---
license: mit
base_model: ai-sage/GigaAM-v3
base_model_relation: quantized
library_name: mlx
pipeline_tag: automatic-speech-recognition
language:
  - ru
tags:
  - automatic-speech-recognition
  - speech-recognition
  - russian
  - offline
  - mlx
  - apple
  - apple-silicon
  - ios
  - ipados
  - macos
  - rnnt
  - conformer
  - sentencepiece
  - native-apple
---

# GigaAM v3 · MLX Runtime Bundle

> Offline Russian speech recognition for Apple devices.  
> Native MLX inference on iPhone, iPad, and Mac — no Python, no cloud, no server required at runtime.

Converted from [`ai-sage/GigaAM-v3`](https://huggingface.co/ai-sage/GigaAM-v3) (`e2e_rnnt` revision).  
No additional training or fine-tuning. The native runtime produced identical decoded text to the Python reference on the validated test inputs.

---

## Platforms

| Platform | Target | Runtime |
|----------|--------|---------|
| iOS | iPhone | Apple MLX (native) |
| iPadOS | iPad | Apple MLX (native) |
| macOS | Apple Silicon Mac | Apple MLX (native) |

---

## Performance · Apple M1 Max

### Short audio (~6 s)

| Runtime | Total time | RTF | Speed |
|---------|-----------|-----|-------|
| **Native Apple MLX** | ~0.168 s | ~0.028 | **~35.8× realtime** |
| Python reference | ~0.701 s | ~0.117 | ~8.6× realtime |

The native runtime is approximately **4.2× faster** than the Python reference on the same hardware.

### Long-form (911 s · 15 min 11 s)

| Metric | Value |
|--------|-------|
| Chunk size | 20.0 s |
| Chunk count | 46 |
| Total transcription time | 24.2 s |
| Real-time factor | 0.027 |
| **Speed** | **~37.6× realtime** |
| Peak resident memory | ~1.15 GB |

<details>
<summary>Stage breakdown (long-form)</summary>

| Stage | Time | Share |
|-------|------|-------|
| Audio load | 0.019 s | ~0.1% |
| Mel frontend | 5.993 s | ~24.8% |
| Encoder | 5.463 s | ~22.6% |
| RNNT greedy decoding | 12.736 s | ~52.6% |
| — RNNT decoder | 1.821 s | ~7.5% |
| — RNNT joint | 10.680 s | ~44.1% |
| — RNNT readback | 0.169 s | ~0.7% |
| Tokenizer | 0.003 s | ~0.0% |

The current main bottleneck is the **RNNT joint network** during greedy decoding.
</details>

### Memory

| Scenario | Peak RSS |
|----------|----------|
| Native MLX · short audio | ~1.10 GB |
| Native MLX · long-form audio | ~1.15 GB |
| Python reference · short audio | ~1.76 GB |

---

## Runtime Pipeline

```
Audio file / PCM samples
  → native audio loader
  → 16 kHz mono Float32 PCM
  → mel spectrogram frontend
  → Conformer encoder
  → RNNT greedy decoder
  → SentencePiece tokenizer
  → text
```

All preprocessing assets (`hann_window`, `mel_filterbank`) are bundled so native runtimes
can reproduce the original pipeline exactly without any Python audio libraries.

---

## Requirements

This bundle is designed for **native Apple platform development**.  
It is **not a Python package** — there is nothing to `pip install`.

### Native runtime (target)

| Requirement | Value |
|-------------|-------|
| Platform | iOS, iPadOS, and macOS — any version supported by MLX Swift |
| Architecture | arm64 Apple devices  |
| Framework | [Apple MLX](https://github.com/ml-explore/mlx) |
| Language | Swift |
| Runtime deps | MLX Swift runtime and bundled model assets |

To use this bundle in a native app, add the **MLX Swift** package to your Xcode project:

```
https://github.com/ml-explore/mlx-swift
```

This repository provides model assets. A native runtime should load `manifest.json`, `weights.fp16.safetensors`, tokenizer files, and bundled frontend assets, then execute the pipeline described below.

---

## Repository Files

```
README.md
.gitattributes
manifest.json
checksums.sha256
weights.fp16.safetensors
tokenizer.model
tokenizer_vocab.json
hann_window.f32.bin
mel_filterbank_mel_freq.f32.bin
```

| File | Description |
|------|-------------|
| `weights.fp16.safetensors` | FP16 model weights (MLX-compatible) |
| `tokenizer.model` | SentencePiece tokenizer model |
| `tokenizer_vocab.json` | Vocabulary export for native tokenizer implementations |
| `manifest.json` | Runtime manifest — model, frontend, and decoding metadata |
| `hann_window.f32.bin` | Hann window for mel frontend |
| `mel_filterbank_mel_freq.f32.bin` | Mel filterbank for mel frontend |
| `checksums.sha256` | SHA-256 checksums for integrity verification |

---

## Architecture

| Component | Value |
|-----------|-------|
| Encoder type | Conformer |
| Encoder layers | 16 |
| Model dimension | 768 |
| Attention heads | 16 |
| Attention type | Rotary self-attention |
| Convolution kernel size | 5 |
| Subsampling | Conv1D · factor 4 |
| Prediction network | RNNT predictor |
| Joint network | RNNT joint |
| Decoding | Greedy RNNT |
| Tokenizer | SentencePiece |
| Vocabulary size | 1024 |
| Blank ID | 1024 |
| Output classes | 1025 |
| Precision | FP16 |

---

## Frontend Configuration

| Parameter | Value |
|-----------|-------|
| Sample rate | 16 000 Hz |
| Channels | 1 (mono) |
| Mel bins | 64 |
| FFT size | 320 |
| Window length | 320 |
| Hop length | 160 |
| Center | false |
| Mel scale | HTK |
| Mel normalization | none |
| Power | 2.0 |

Effective feature hop: **10 ms** before encoder subsampling.  
Encoder subsampling factor: **4** → one encoder frame ≈ **40 ms** of audio.

---

## Long-Form Transcription

Long audio is intended to be processed in chunks to keep memory usage bounded and inference latency predictable.

**Recommended settings:**

```yaml
chunk_seconds: 20
overlap_seconds: 0–2
sample_rate: 16000
channels: mono
```

> Future runtimes may add VAD segmentation, overlap-aware merging, and timestamp-aware chunking for improved accuracy on long-form content.

---

## Validation

The conversion was validated against the original PyTorch/Hugging Face model using tensor-level golden references at each stage of the pipeline.

**Validated components:**

- Audio frontend · mel spectrogram
- Pre-encoder
- Conformer feed-forward blocks
- Rotary self-attention
- Conformer convolution block
- Full Conformer layer · encoder stack
- RNNT predictor · RNNT joint network
- RNNT greedy decoding
- SentencePiece tokenizer
- Full WAV-to-text pipeline (end-to-end)

**Selected numerical results:**

```
Mel frontend
  feature_shape      [64, 99]
  max_abs_diff       0.0004234314
  mean_abs_diff      2.8040542e-05

Encoder stack
  stack_max_abs_diff 2.5629997e-06
  stack_mean_abs_diff 3.8420205e-07

Full encoder
  output_shape       [1, 768, 25]
  max_abs_diff       2.682209e-06
  mean_abs_diff      4.0401252e-07
```

End-to-end: the native runtime and the Python reference produce **identical decoded text** for the same input audio.

---

## Limitations

- Optimized for native Apple MLX runtimes; not intended for server or Python-based inference.
- Long audio should be processed in chunks by the host runtime.
- Word-level timestamps are not included in the bundle.
- Speaker diarization is not supported.
- This repository contains **model assets only** — no application code, no Swift SDK source.

---

## License

MIT — follows the license of the original [`ai-sage/GigaAM-v3`](https://huggingface.co/ai-sage/GigaAM-v3) model.

---

## Citation & Attribution

If you use this bundle, please also cite the original GigaAM model:

```bibtex
@misc{gigaam-v3,
  author       = {ai-sage},
  title        = {GigaAM-v3},
  year         = {2024},
  publisher    = {Hugging Face},
  howpublished = {\url{https://huggingface.co/ai-sage/GigaAM-v3}}
}
```