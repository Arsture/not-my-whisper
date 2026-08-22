---
title: AI correction
description: The 6 LLM providers that polish transcribed text, 4 correction modes, and custom prompts.
---

AI polishes your raw transcription — from spacing, punctuation, and misrecognized-word fixes to filler removal and structuring. Choose a **provider** and a **correction mode** in Settings → LLM. The default is **None (original text as-is)**, so you only turn correction on when you need it.

## Providers

| Provider | Location | Vision | Requirements |
| --- | --- | --- | --- |
| **None (use original)** *(default)* | — | — | None. Inserts the transcription as-is |
| **Local MLX** | Local (Apple Silicon) | Depends on model | Model download. Some MoE models need `uv` |
| **OpenAI (GPT)** | Cloud | ✅ | Codex CLI token or OpenAI login |
| **OpenAI-compatible** | Cloud/Local | Toggle | Base URL (+ API key, optional for local servers) |
| **Groq Cloud** | Cloud | Llama 4 Scout only | Groq API key (shared with STT) |
| **Claude (subscription)** | Via local `claude` CLI | ✅ | Claude Code CLI installed + logged in |

### Local MLX
Fully local correction. It supports text models (Qwen3, Gemma 4, GLM, etc.) and vision models (Qwen3-VL-4B, DiffusionGemma 26B); download models in Settings → Models. With a vision model, you can leverage [visual context](/en/features/context/) for correction. For per-model compatibility, see [Models & compatibility](/en/features/models/).

### OpenAI (GPT)
Uses the ChatGPT Responses API (SSE streaming). For authentication, it **prefers reusing the Codex CLI token (`~/.codex/auth.json`)**, and if absent, connects via **OpenAI login** (browser PKCE) in the LLM tab. Models: GPT-5.6 Sol (default) · Terra · Luna · 5.5 · 5.4 · 5.4 Mini · 5.3 Codex · 5.2. Vision supported.

### OpenAI-compatible
Works with any endpoint that serves `POST {Base URL}/chat/completions` — OpenRouter, DeepSeek, Together, vLLM, Ollama, LM Studio, and more. Enter the **Base URL** (including `/v1`) and **model ID** directly, plus an **API key** if required (local servers can leave it empty). If the model supports image input, turn on the **Vision-capable model** toggle to leverage visual context.

### Groq Cloud
OpenAI-compatible cloud. Models: Qwen3 32B (default) · Llama 3.3 70B · Llama 3.1 8B · GPT-OSS 120B/20B, with **vision supported on Llama 4 Scout only**. Uses the same Groq key as STT.

### Claude (subscription)
Calls the local `claude -p` CLI to **reuse your Claude subscription directly** (the only subscription path allowed under the ToS). Models: Haiku 4.5 (default) · Sonnet 4.6 · Opus 4.8 — all support vision. Responses usually take 5–20 seconds (including cold start), and billing draws from your subscription credit pool.

:::caution
Every correction provider has a **hallucination guard**. If the corrected result deviates too far from the original (exceeds the word-edit-distance threshold), the correction is discarded and the **original text** is inserted as-is. This prevents the AI from inventing content and replacing the whole thing.
:::

## Correction modes

These appear in Settings → LLM when the provider isn't 'None'. The prompts are Korean-based and include Korean↔English code-switching examples.

| Mode | What it does |
| --- | --- |
| **Standard** *(default)* | Fixes only obvious STT errors — spacing, punctuation, misrecognized words. |
| **Filler removal** | Standard + removes verbal fillers like "um/uh/you know" (keeps the content). |
| **Structured** | Standard + filler removal + tidies rambling speech into bullets/numbers (not a summary, just organization). |
| **Custom** | Uses a system prompt you write yourself. |

:::tip
**Structured** mode is especially useful when you're dictating a prompt for an AI — it organizes everything you said into a readable form without dropping anything.
:::

## Custom prompts

In **Custom** mode, you can edit the system prompt directly. In other modes, you can preview the currently applied prompt read-only, so you can see what instructions the correction follows.

## Code-switching

Even when English technical terms get mixed into Korean speech (e.g., "밸리데이션" → "validation"), it corrects them appropriately. The code-switching prompt is enabled when the **Language** setting is auto/Korean.
