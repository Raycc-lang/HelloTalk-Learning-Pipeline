# HelloTalk Learning Pipeline

An automated 6-stage pipeline that extracts voice messages from the HelloTalk language-exchange app, transcribes them with Whisper, analyzes grammar and vocabulary with LLMs, and generates Anki flashcards for targeted language learning.

Built for intermediate ESL learners whose L1 is Mandarin Chinese, but adaptable to any language pair.

---

## Table of Contents

- [Motivation](#motivation)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Android (LSPosed Module)](#android-lsposed-module)
  - [Linux (Pipeline Host)](#linux-pipeline-host)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Manual](#manual)
  - [Automated (systemd)](#automated-systemd)
- [Project Structure](#project-structure)
- [Stage Reference](#stage-reference)
- [Acknowledgments](#acknowledgments)
- [License](#license)

---

## Motivation

Language learners on HelloTalk produce a large volume of spontaneous, authentic spoken output every day. That output is a goldmine for personalized study material — but it is lost the moment the call ends. This pipeline captures, cleans, and transforms that output into structured Anki cards that target *your* specific error patterns and vocabulary gaps.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HELLOTALK LEARNING PIPELINE                         │
│                              (6-Stage Pipeline)                             │
└─────────────────────────────────────────────────────────────────────────────┘

 ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
 │  Stage 1 │───>│  Stage 2 │───>│  Stage 3 │───>│  Stage 4 │───>│  Stage 5 │
 │   PULL   │    │  PROCESS │    │TRANSCRIBE│    │  CLEANSE │    │ ANALYZE  │
 └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
      │                │                │                │                │
      ▼                ▼                ▼                ▼                ▼
  .wav files     denoised &       raw .txt         noise-free      grammar.md
  from Android   split by         transcripts      transcripts     semantic.md
  → WSL2         silence          via NVIDIA       (PII blocked,   (LLM output)
                 → segments       Whisper gRPC     ASR artifacts
                                                   removed)

                                                                   │
                                                                   ▼
                                                              ┌──────────┐
                                                              │  Stage 6 │
                                                              │   ANKI   │
                                                              └──────────┘
                                                                   │
                                                                   ▼
                                                              grammar_cards.tsv
                                                              chunk_cards.tsv
                                                              → import to Anki
```

### Stage Summary

| Stage | Script | What It Does |
|-------|--------|--------------|
| **1. Pull** | `hellotalk-pull-audio.sh` | Pulls `.wav` files from Android via ADB (wireless or USB). |
| **2. Process** | `hellotalk-process-audio.sh` | Denoises with `afftdn`, splits on silence boundaries, discards short/junk segments. |
| **3. Transcribe** | `hellotalk-transcribe.sh` | Sends audio to NVIDIA Riva/Whisper gRPC API; retries on network failure; classifies errors. |
| **4. Cleanse** | `hellotalk-cleanse.sh` | Removes filler words, ASR artifacts ("thank you for watching"), non-English lines, and PII matching a user-defined blocklist. |
| **5. Analyze** | `hellotalk-analyze.sh` | Merges daily transcripts, consolidates sparse days, and runs two LLM prompts: **Grammar Analysis** and **Semantic/Collocational Analysis**. |
| **6. Generate Anki** | `hellotalk-generate-anki.sh` | Converts analysis output into tab-separated Anki card files (`.tsv`) ready for import. |

---

## Prerequisites

### Android
- Root access + [LSPosed](https://github.com/LSPosed/LSPosed) (or compatible Xposed framework)
- HelloTalk app installed
- ADB configured (wireless or USB)

### Linux Host (WSL2 or native)
- `bash`, `adb`, `ffmpeg`, `ffprobe`, `bc`
- Python 3.10+ with `openai` and `httpx` packages
- `systemd` (for automated timers; optional — everything works manually)
- NVIDIA API key (or Tencent / Cloudflare alternative) for transcription and LLM inference

### Optional
- [Anki](https://apps.ankiweb.net/) desktop or mobile for card import
- Custom Anki note types matching the TSV field layouts

---

## Installation

### Android (LSPosed Module)

1. Open `android-module/` in Android Studio or build from CLI:
   ```bash
   cd android-module
   export ANDROID_HOME=$HOME/Android/Sdk
   ./gradlew assembleDebug
   ```

2. Install the APK:
   ```bash
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```

3. In **LSPosed Manager**:
   - Enable the module **HelloTalk Capture**
   - Set scope to `com.hellotalk`
   - Force-stop HelloTalk and reopen

4. Verify capture:
   - Send a voice message in HelloTalk
   - Check `/sdcard/HelloTalkCapture/` on your device for `.wav` files

### Linux (Pipeline Host)

1. Clone this repo and symlink scripts into your PATH:
   ```bash
   git clone https://github.com/Raycc-lang/HelloTalk-Learning-Pipeline.git
   cd HelloTalk-Learning-Pipeline
   
   mkdir -p ~/.local/bin
   for f in pipeline-scripts/*; do
       ln -sf "$(realpath "$f")" ~/.local/bin/$(basename "$f")
   done
   ```

2. Copy LLM prompts to the expected location:
   ```bash
   cp prompts/*.md ~/Android/HelloTalkCapture/
   ```

3. Install Python dependencies:
   ```bash
   pip install openai httpx
   ```

4. Copy and fill in the configuration template:
   ```bash
   mkdir -p ~/.config/hellotalk
   cp config/env.template ~/.config/hellotalk/env
   # Edit ~/.config/hellotalk/env and add your API keys
   ```

5. (Optional) Create a privacy blocklist:
   ```bash
   cp config/cleanse.conf.template ~/.config/hellotalk/cleanse.conf
   # Add regex patterns, one per line, to remove sensitive content from transcripts
   ```

6. (Optional) Install systemd units for automation:
   ```bash
   mkdir -p ~/.config/systemd/user
   cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable hellotalk-pull-audio.timer
   systemctl --user start hellotalk-pull-audio.timer
   ```

---

## Configuration

All sensitive configuration lives in `~/.config/hellotalk/env`. The pipeline supports three LLM providers:

| Provider | `PROVIDER=` | Required Vars |
|----------|-------------|---------------|
| NVIDIA NIM | `nvidia` | `NVIDIA_API_KEY` |
| Tencent MaaS | `tencent` | `TENCENT_API_KEY` |
| Cloudflare Workers AI | `cloudflare` | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN` |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROVIDER` | `nvidia` | Which backend to use for LLM calls |
| `MODEL` | `moonshotai/kimi-k2.5` | Model ID (provider-specific) |
| `MAX_TOKENS` | `131072` | Max tokens per LLM response |
| `NVIDIA_API_KEY` | — | NVIDIA API key |
| `TENCENT_API_KEY` | — | Tencent API key |
| `CLOUDFLARE_API_TOKEN` | — | Cloudflare API token |
| `CLOUDFLARE_ACCOUNT_ID` | — | Cloudflare account ID |
| `MERGE_MIN_LINES` | `80` | Minimum lines for a day's `merged.txt` to stand alone; sparse days are consolidated into the next day |

### Script-Specific Notes

- `hellotalk-pull-audio.sh` — Edit `DEVICE=` to match your ADB target (e.g., `192.168.1.13:5555` for wireless).
- `hellotalk-transcribe.sh` — Requires the NVIDIA gRPC Python client (`transcribe_file_offline.py` from NVIDIA's Riva samples). Update `PYTHON_CLIENT=` if your path differs.
- `hellotalk-cleanse.sh` — Reads `~/.config/hellotalk/cleanse.conf` for PII blocklist patterns.
- `hellotalk-analyze.sh` — Set `MERGE_MIN_LINES` (default: 80) to control the sparse-day consolidation threshold.

---

## Usage

### Manual

Run each stage in order, or run only the ones you need:

```bash
# 1. Pull fresh audio from Android
hellotalk-pull-audio.sh

# 2. Denoise and split into speech segments
hellotalk-process-audio.sh

# 3. Transcribe with Whisper
hellotalk-transcribe.sh

# 4. Clean transcripts (remove noise, artifacts, PII)
hellotalk-cleanse.sh

# 5. Run AI analysis (grammar + semantic)
hellotalk-analyze.sh

# 6. Generate Anki TSVs
hellotalk-generate-anki.sh
```

After Stage 6, import the generated `.tsv` files into Anki:
- `Anki/YYYY-MM-DD/grammar_cards.tsv`
- `Anki/YYYY-MM-DD/chunk_cards.tsv`

### Automated (systemd)

The included systemd timers run the pipeline on a schedule:

| Timer | Schedule | Chains To |
|-------|----------|-----------|
| `hellotalk-pull-audio.timer` | Daily at 12:00 | → process |
| `hellotalk-process-audio.timer` | Daily at 12:05 | → transcribe |
| `hellotalk-transcribe.timer` | Daily at 12:15 | → cleanse |
| `hellotalk-cleanse.timer` | Every 6 hours | → analyze |
| `hellotalk-analyze.timer` | Every 6 hours (offset) | (manual Anki) |
| `hellotalk-generate-anki.timer` | Every 6 hours (offset) | — |

View timer status:
```bash
systemctl --user list-timers hellotalk-*
```

Run a single stage manually:
```bash
systemctl --user start hellotalk-analyze.service
```

---

## Project Structure

```
HelloTalk-Learning-Pipeline/
├── android-module/           # LSPosed Xposed module (Java)
│   ├── app/src/main/java/.../MainHook.java
│   ├── app/src/main/java/.../AudioCaptureManager.java
│   ├── app/src/main/java/.../WavHeaderWriter.java
│   ├── app/src/main/AndroidManifest.xml
│   └── build.gradle
├── pipeline-scripts/         # Bash + Python automation scripts
│   ├── hellotalk-pull-audio.sh
│   ├── hellotalk-process-audio.sh
│   ├── hellotalk-transcribe.sh
│   ├── hellotalk-cleanse.sh
│   ├── hellotalk-analyze.sh
│   ├── hellotalk-generate-anki.sh
│   ├── hellotalk-llm-call.py
│   ├── hellotalk-provider-resolve.sh
│   ├── hellotalk-quota-check.sh
│   ├── hellotalk-cleanup-empty-segments.sh
│   ├── hellotalk-reset-transcribe.sh
│   └── hellotalk-common.sh
├── systemd/                  # User systemd units
│   ├── *.service
│   └── *.timer
├── prompts/                  # LLM system prompts
│   ├── analysis-grammar.md
│   ├── analysis-semantic.md
│   ├── anki-generator-grammar.md
│   └── anki-generator-semantic.md
├── config/                   # Configuration templates
│   ├── env.template
│   └── cleanse.conf.template
├── README.md
└── LICENSE
```

---

## Stage Reference

### Stage 1 — Pull
- Connects to Android via ADB (wireless or USB)
- Stages `.wav` files from `/data/data/com.hellotalk/files/HelloTalkCapture` to `/sdcard/` for non-root pull
- Deletes originals after successful transfer

### Stage 2 — Process
- Skips files recorded "today" (to avoid pulling active recordings)
- Quarantines malformed audio to `Invalid_audio/`
- Denoises with `ffmpeg afftdn`
- Detects silence with `silencedetect`
- Splits into speech segments; drops segments < 2 seconds

### Stage 3 — Transcribe
- Prefilters by file size (> 50 KB), duration (> 0.5 s), and RMS level (> -40 dB)
- Calls NVIDIA Riva Whisper via gRPC with automatic punctuation
- Retries up to 3× on transient network errors
- Classifies failures: `auth_error`, `network_error`, `invalid_audio`, `rate_limit`, `no_speech`
- Merges segment transcripts into per-recording `.txt` files

### Stage 4 — Cleanse
- Removes filler words (`uh`, `um`, `like`, `so`, `I think`...)
- Strips ASR artifacts (`[Music]`, "Thank you for watching", "subscribe"...)
- Drops non-English lines (Chinese, Hindi, etc.)
- Removes repetition hallucinations (same phrase 4+ times)
- Applies user-defined PII blocklist from `cleanse.conf`
- Drops lines ≤ 3 words

### Stage 5 — Analyze
- Merges all cleansed transcripts for each calendar day into `Analysis/YYYY-MM-DD/merged.txt`
- **Consolidates sparse days**: days with fewer than `MERGE_MIN_LINES` (default 80) lines are prepended into the next day's `merged.txt` with a date separator header, and the sparse day's folder is removed. This avoids wasting API calls on thin content. Cascade-safe: if absorbing a sparse day still leaves the target under threshold, it gets consolidated further in the same pass.
- Runs two independent LLM analyses:
  - **Grammar** — identifies recurring grammatical errors and structural calques from L1 (Mandarin)
  - **Semantic** — identifies near-miss collocations, missed idioms, semantic boundary errors, register mismatches
- Respects quota sentinels: if a provider hits its daily limit, the batch aborts gracefully and resumes later

### Stage 6 — Generate Anki
- Takes `grammar.md` and `semantic.md` from Stage 5
- Generates tab-separated flashcard files:
  - `grammar_cards.tsv` — FILL_IN_BLANK and CORRECT_THE_ERROR cards
  - `chunk_cards.tsv` — SITUATION→CHUNK, CHUNK→REGISTER, PATTERN_COMPLETION, SEMANTIC_BOUNDARY cards
- Each card includes native-chunk examples, interference notes, and contextual example sentences

---

## Acknowledgments

- **[OpenAI Whisper](https://github.com/openai/whisper)** — The foundation of modern open-source speech recognition.
- **[NVIDIA Riva](https://docs.nvidia.com/ai-enterprise/deployment-guide-spark/0.1.0/whisper.html)** — Used here via NIM gRPC for fast, accurate transcription.
- **[LSPosed](https://github.com/LSPosed/LSPosed)** — The modern Xposed framework that makes runtime hooking possible on Android.
- **[Anki](https://apps.ankiweb.net/)** — The spaced-repetition platform that turns analysis into long-term memory.
- **[OpenClaw](https://github.com/Raycc-lang/openclaw)** / **[Hermes Agent](https://hermes-agent.nousresearch.com/)** — The agent infrastructure that helped design, debug, and document this pipeline.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Disclaimer

This tool is for **personal educational use only**. It captures audio from the HelloTalk app running on *your own* device. Respect HelloTalk's Terms of Service and the privacy of your conversation partners. Do not distribute captured audio or transcripts without explicit consent from all parties involved.
