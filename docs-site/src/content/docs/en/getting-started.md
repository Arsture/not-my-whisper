---
title: Install & first dictation
description: Install Whispree, turn on permissions, and get your first voice input into the previously focused app.
---

Whispree runs on **macOS 14 or later · Apple Silicon (arm64)**. On first launch, a 5-step onboarding walks you through permissions and engine setup.

## 1. Install

The simplest way is **Homebrew**.

```bash
brew tap Arsture/whispree && brew install --cask whispree
```

A microphone icon appears in the menu bar. The menu bar icon is always there; the Dock icon and the Cmd+Tab app-switcher entry appear together with the main window and disappear again once you close it — this has no effect on finding Whispree via Spotlight. Whispree is not notarized with an Apple Developer ID, but **installing via Homebrew clears the Gatekeeper block automatically** and wires up auto-updates — which is why it's the recommended path.

### Advanced: other install methods

**GitHub Releases (manual download)** — You can grab the `.zip`/`.dmg` from [GitHub Releases](https://github.com/Arsture/whispree/releases), but because the app isn't notarized, macOS Gatekeeper blocks it. After unzipping, clear the quarantine flag once and move it to `/Applications` (Homebrew does this for you):

```bash
xattr -cr Whispree.app
```

**Build from source (developers)** — To build it yourself:

```bash
git clone https://github.com/Arsture/whispree.git
cd whispree
brew install xcodegen
xcodegen generate
open Whispree.xcodeproj   # Build & run with Cmd+R in Xcode
```

SPM dependencies resolve automatically on the first build. Note that locally signed Xcode builds do not get Sparkle auto-updates (update via `git pull` + rebuild).

## 2. Turn on permissions

The first-launch onboarding guides you through the permissions you need. The two essentials are:

| Permission | Why it's needed | Without it |
| --- | --- | --- |
| **Microphone** | Voice recording | Recording won't work |
| **Accessibility** | Paste the result into the previously focused app (key events) | Only clipboard copy works; automatic insertion fails |
| **Screen Recording** | Capture visual context (vision) | Screenshots won't reach vision correction |
| **Automation** | Restore browser/terminal context | Only that restore feature stops working |

With just Microphone and Accessibility, basic dictation works fully. The rest are needed only when you use those specific features. For details, see [Permissions](/en/reference/permissions/).

## 3. Pick an engine (optional)

The defaults work right out of the box.

- **STT (dictation)**: Default is **WhisperKit** (local, ~1.5 GB download on first use). For a fast cloud option, use **Groq** (API key required).
- **AI correction**: Default is **None (original text as-is)**. To polish, choose from local MLX / OpenAI / Groq / Claude subscription.

You can switch engines anytime from the STT/LLM tabs in Settings or the home dashboard. For details, see [STT engines](/en/features/stt/) and [AI correction](/en/features/correction/).

## 4. Your first dictation

1. Click an input field in another app (Notes, an editor, a chat box, etc.).
2. Press **`Ctrl+Shift+R`** (the default shortcut).
3. Say a short sentence.
4. Press `Ctrl+Shift+R` again (toggle mode) to end dictation, and the result lands in **that very input field**.

While recording, a waveform overlay shows the state (recording/transcribing/correcting) and the shortcut badges. Press **ESC** to cancel only the current job.

## 5. Recording mode — push-to-talk vs toggle

Choose one of two in Settings → General.

- **Push-to-talk** — *default*. Records **while you hold** the shortcut, transcribes when you release.
- **Toggle** — press once to start, press again to stop.

:::tip
You can reassign the shortcut in Settings → General, and you can even assign **a single modifier key** (e.g., right ⌥). If it conflicts with a system shortcut, a warning is shown.
:::

## Other default settings

Convenience features you can toggle in Settings → General:

- **Pause music while recording** *(on by default)* — pauses playing media when recording starts and resumes when it ends.
- **Silence auto-skip (VAD)** *(on by default)* — skips speechless segments to speed up transcription.
- **Launch at login** *(off by default)* — starts automatically when you log into macOS.

## Next steps

- [Dictation & multi-recording](/en/features/dictation/) — speak several times in a row and control it via shortcuts/URLs.
- [AI correction](/en/features/correction/) — filler removal, structuring, and code-switching correction.
- [Dictionary & Quick Fix](/en/features/dictionary/) — fix and register words you frequently get wrong, on the fly.
