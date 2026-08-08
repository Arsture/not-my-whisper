---
title: Models & Compatibility
description: The local model registry, the 'Can I Run' compatibility grade, download management, and other convenience settings.
---

With local models, dictation and correction complete fully without an internet connection. Whispree tells you which models your Mac can run comfortably via the **'Can I Run' grade**.

## Local model registry

Download and manage supported models under Settings → Models.

- **STT**: WhisperKit Large V3 Turbo (~1.5 GB), Qwen3-ASR-1.7B-8bit (~1.0 GB).
- **Correction (text)**: Qwen3 (1.7B/4B default/8B), Qwen3 Coder 30B, Gemma 4 (2B/4B/26B MoE/31B), SuperGemma4 26B, GLM-4.7 Flash, and more.
- **Correction (vision)**: Qwen3-VL-4B, DiffusionGemma 26B A4B.

Each model can be downloaded/canceled/deleted inline, with progress (bytes · %) and an "in use" badge shown. If another download is in progress, it queues up, and you can retry on failure.

:::note
Some large MoE/VLM models (e.g. Gemma 4 26B, DiffusionGemma 26B) are not ported to mlx-swift and **run via a Python worker**, which requires `uv` to be installed. The registry marks them with that runtime.
:::

## 'Can I Run' compatibility

By detecting your Mac's chip, RAM, memory bandwidth, and GPU cores, Whispree computes and shows the following per model (canirun.ai style):

- **RAM usage (%)**, **estimated speed (tok/s)**, **quality score (0–100)**,
- and an at-a-glance **compatibility grade** (6 tiers, e.g. *RUNS GREAT … TOO HEAVY*).

Cloud models (OpenAI/Groq/Claude) always show as *RUNS GREAT*. These metrics are surfaced throughout the STT, LLM, and Models tabs.

## Storage location

Models are stored in `~/.cache/huggingface/hub/`. You can check this directly via "Open in Finder" in Settings.

## Other convenience settings

Features you can toggle under Settings → General:

| Setting | What it does | Default |
| --- | --- | --- |
| **Pause music while recording** | Pauses currently playing media (Now Playing sources such as Apple Music, Spotify, YouTube) when recording starts, then resumes when it ends. | On |
| **Audio input channel** | Selects which mic channel to use on a multi-channel input device (0 = auto downmix). | 0 (auto) |
| **Launch at login** | Starts Whispree automatically at macOS login. | Off |

## Auto-update

Whispree checks for updates automatically via Sparkle. You can also check manually with **"Check for Updates…"** in the app menu.

:::caution
Auto-update only works on official release builds. It does not work if you signed and built it yourself with Xcode, because the signature differs from the released build — developers should update via `git pull` + rebuild.
:::
