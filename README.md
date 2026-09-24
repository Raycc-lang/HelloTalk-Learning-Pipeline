# HelloTalk Learning Pipeline

An automated 7-stage pipeline that extracts voice messages from the HelloTalk language-exchange app, transcribes them with Whisper, analyzes grammar and vocabulary with LLMs, builds timed 4/3/2 fluency drills, and generates Anki flashcards for targeted language learning.

Built for intermediate ESL learners whose L1 is Mandarin Chinese, but adaptable to any language pair.

[English](README.md) | [中文](README.zh-CN.md)

---

## Table of Contents

- [Motivation](#motivation)
- [Caveats](#caveats)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Android (LSPosed Module)](#android-lsposed-module)
  - [Linux (Pipeline Host)](#linux-pipeline-host)
- [Configuration](#configuration)
- [Multi-Model Variant Generation](#multi-model-variant-generation)
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

## Caveats

Read these before relying on the pipeline. They define what this tool is good for and where it stops.

**This pipeline surfaces errors you already make but don't notice - it does not teach you new language.** It is a feedback mirror, not a textbook. If a structure is entirely outside your active knowledge, no amount of analyzing your own output will introduce it. You still need comprehensible input and explicit study for acquisition; the pipeline only tightens what you can already produce.

**The audio source is not tied to HelloTalk.** The capture module happens to hook HelloTalk because that's where this project started, but the pipeline itself operates on `.wav` files. Any source of recorded spoken practice - another language-exchange app, a tutor platform, voice memos from self-talk - works equally well. Swap out Stage 1 (Pull) for whatever gets your audio onto disk; the rest is source-agnostic.

**Always read the analysis output yourself before moving on.** The LLM is wrong sometimes: it misattributes errors, invents patterns that aren't there, or marks correct usage as wrong. The pipeline deliberately does not add an automated verification step - reviewing the feedback yourself is itself a noticing exercise, which is part of the learning. Handing that step to a model would quietly remove one of the more valuable moments in the loop. So read `grammar.md` and `semantic.md`, check whether the flagged errors are real, and only then run the drill or Anki stages.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HELLOTALK LEARNING PIPELINE                         │
│                              (7-Stage Pipeline)                             │
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
                                                              │  4/3/2   │
                                                              │  DRILL   │
                                                              └──────────┘
                                                                   │
                                                                   ▼
                                                              grammar-drill.md
                                                              vocabulary-drill.md
                                                              (timed retell)
                                                                   │
                                                                   ▼
                                                              ┌──────────┐
                                                              │  Stage 7 │
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
| **6. 4/3/2 Drill** | `hellotalk-generate-drill-interactive.sh` | Builds timed 4/3/2 fluency drills (retell the same content at 4→3→2 min) from the day's grammar/semantic analysis + transcript context. Interactive-only; no systemd unit. |
| **7. Generate Anki** | `hellotalk-generate-anki.sh` | Converts analysis output into tab-separated Anki card files (`.tsv`) ready for import. |

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
- A Google AI Studio API key (default LLM provider) — or an NVIDIA key, or any OpenAI-compatible endpoint — for LLM inference; an NVIDIA API key for transcription

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
   mkdir -p ~/Android/HelloTalkCapture/Drill
   cp prompts/drill/*.md ~/Android/HelloTalkCapture/Drill/
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
| Google AI Studio (default) | `google` | `GOOGLE_API_KEY` |
| NVIDIA NIM | `nvidia` | `NVIDIA_API_KEY` |
| Custom (any OpenAI-compatible endpoint) | `custom` | `CUSTOM_API_BASE`, `CUSTOM_API_KEY` |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROVIDER` | `google` | Which backend to use for LLM calls (`google`, `nvidia`, or `custom`) |
| `MODEL` | `gemini-3.5-flash` | Model ID (provider-specific) |
| `REASONING_EFFORT` | `high` | Thinking effort: `minimal` \| `low` \| `medium` \| `high`. Mapped to a thinking budget on Google's OpenAI-compatible endpoint |
| `GOOGLE_API_KEY` | — | Google AI Studio API key |
| `NVIDIA_API_KEY` | — | NVIDIA API key |
| `CUSTOM_API_BASE` | — | Base URL for a custom OpenAI-compatible endpoint |
| `CUSTOM_API_KEY` | — | API key for the custom endpoint |
| `MERGE_MIN_LINES` | `80` | Minimum lines for a day's `merged.txt` to stand alone; sparse days are consolidated into the next day |
| `VARIANTS` | `0` | Set to `1` to generate every artifact with two models and reconcile them. See [Multi-Model Variant Generation](#multi-model-variant-generation) |
| `VARIANT_SLOTS` | `"PRIMARY SECONDARY"` | Which model slots take part, in order. Quote the value — the file is also sourced by bash |
| `<SLOT>_PROVIDER` | first slot inherits `PROVIDER` | Provider for one slot, e.g. `SECONDARY_PROVIDER=nvidia` |
| `<SLOT>_MODEL` | first slot inherits `MODEL` | Model ID for one slot. Required on every slot after the first |
| `<SLOT>_API_BASE` / `<SLOT>_API_KEY` | provider's own vars | Per-slot credential override, for pointing a slot at a different endpoint |
| `<SLOT>_REASONING_EFFORT` | `REASONING_EFFORT` | Per-slot thinking effort |
| `<SLOT>_MAX_TOKENS` | `MAX_TOKENS` | Per-slot output budget. Use it when one slot's model has a lower output cap (e.g. `65536` behind a gateway) instead of capping every model globally |
| `JUDGE_PROVIDER` / `JUDGE_MODEL` | first usable slot | Which model reconciles the candidates |
| `VARIANT_KEEP` | `1` | Keep the raw candidates under `variants/` beside the finished file |
| `VARIANT_MIN_UNIT_PCT` | `50` | Minimum percent of the richest candidate's entry/card/topic count a reconciled file must retain to be accepted |

> **Note on `MAX_TOKENS`:** it is no longer set globally. Thinking models spend the same token budget on internal reasoning, so a small cap can yield zero visible output. Each script supplies its own default instead (`131072` for analyze/drill, with a `32768` fallback inside `hellotalk-llm-call.py`). When one slot's model has a lower output cap, lower just that slot with `<SLOT>_MAX_TOKENS` — e.g. `SECONDARY_MAX_TOKENS=65536`.

### Script-Specific Notes

- `hellotalk-pull-audio.sh` — Edit `DEVICE=` to match your ADB target (e.g., `192.168.1.13:5555` for wireless).
- `hellotalk-transcribe.sh` — Requires the NVIDIA gRPC Python client (`transcribe_file_offline.py` from NVIDIA's Riva samples). Update `PYTHON_CLIENT=` if your path differs.
- `hellotalk-cleanse.sh` — Reads `~/.config/hellotalk/cleanse.conf` for PII blocklist patterns.
- `hellotalk-analyze.sh` — Set `MERGE_MIN_LINES` (default: 80) to control the sparse-day consolidation threshold.

---

## Multi-Model Variant Generation

Two models asked to analyze the same transcript do not find the same errors. Each
misses things the other catches, and the union is consistently better than either
alone. Setting `VARIANTS=1` makes that the pipeline's behavior instead of something
you assemble by hand.

With it enabled, every LLM stage runs three calls instead of one:

```
                 ┌── PRIMARY model   ──→ variants/<name>.primary   ─┐
input ───────────┤                                                  ├──→ judge ──→ final artifact
                 └── SECONDARY model ──→ variants/<name>.secondary  ─┘
```

The reconciliation step is itself a prompt — `prompts/judge-analysis.md`,
`judge-tsv.md` or `judge-drill.md`, picked by stage. Each one names the criteria
to merge on rather than asking which candidate "looks better": the analysis judge
takes the union of genuine findings and drops any whose quoted words are absent
from the transcript, the TSV judge merges cards and repairs field-count damage,
and the drill judge picks one coherent session as a base and repairs it from the
other. Candidates arrive inside delimiters and are treated as data, so a stray
instruction inside model output cannot redirect the merge.

### Setup

Configure a second slot in `~/.config/hellotalk/env`:

```bash
VARIANTS=1
VARIANT_SLOTS="PRIMARY SECONDARY"

PRIMARY_PROVIDER=google
PRIMARY_MODEL=gemini-3.5-flash

SECONDARY_PROVIDER=nvidia
SECONDARY_MODEL=moonshotai/kimi-k2.5
```

Only the first slot inherits the ambient configuration, so leaving `PRIMARY_*`
unset reproduces the ordinary single-model setup. Every later slot must name its
own model — two candidates drawn from one model share their blind spots, so the
runner detects a duplicate slot and skips it rather than paying for it.

More than two slots work: add `TERTIARY` to `VARIANT_SLOTS` and configure it. All
three judge prompts are written for an arbitrary number of `CANDIDATE N` sections,
and every candidate produced is sent to reconciliation. Cost scales with slot
count plus one — three slots means four calls per artifact.

### Cost and failure behavior

Each artifact costs three API calls instead of one. `VARIANTS=0` is the default so
the automated systemd runs stay cheap; turn it on per-invocation when the output
matters:

```bash
VARIANTS=1 hellotalk-generate-anki.sh
```

Every degradation path keeps whatever was already paid for:

| What happens | Result |
|---|---|
| One model fails or times out | The surviving candidate is used unreconciled |
| Every model fails the same way | The failure class is preserved — a bad key or model ID still aborts the batch instead of being retried once per artifact |
| Any generation hits its daily quota | Quota sentinel written, batch aborts (exit 75), as before |
| Quota is hit *during* reconciliation | Batch aborts, and the artifact is deliberately left unwritten. Both paid candidates stay in `variants/`; the next run regenerates and reconciles them properly |
| Reconciliation returns prose, an apology, or a collapsed file | The best *structurally valid* candidate is used — not simply the first |
| Candidates too large to reconcile in one call | Source material is dropped first, then the best valid candidate is used |
| Fewer than two distinct models configured | Exactly one call — identical to `VARIANTS=0`, same cost |

A reconciled file is accepted only if it still looks like the artifact it replaces
and did not collapse: it must retain at least `VARIANT_MIN_UNIT_PCT` (default 50)
percent of the entry, card, or topic count of the richest candidate. Merging
removes duplicates, so the bar is a fraction rather than parity — but a judge that
truncates, or returns two cards out of thirty, cannot overwrite a complete
candidate.

> **On the quota-during-reconciliation row:** promoting an unreconciled candidate
> to the final path would look helpful and be harmful. The artifact would then be
> newer than its input, so the freshness check would skip that day on every later
> run and the unreconciled version would be locked in permanently. Leaving it
> unwritten costs one regeneration and produces the correct result.

Raw candidates stay in `variants/` next to the finished file, so you can compare
what each model produced and see what the merge kept. Set `VARIANT_KEEP=0` to
delete them once reconciliation succeeds.

### Credentials

Only the first slot inherits the ambient configuration, and it inherits all of it
— `PROVIDER`, `MODEL`, and any `API_BASE` / `API_KEY` set directly in the env
file. A proxy or custom endpoint configured for single-model use therefore keeps
working unchanged when variants are switched on.

Credentials may also live entirely in the slots, with no ambient key at all:

```bash
VARIANTS=1
PRIMARY_PROVIDER=custom
PRIMARY_MODEL=alpha
PRIMARY_API_BASE=https://endpoint-a/v1
PRIMARY_API_KEY=...
SECONDARY_PROVIDER=custom
SECONDARY_MODEL=beta
SECONDARY_API_BASE=https://endpoint-b/v1
SECONDARY_API_KEY=...
```

The startup credential check is variant-aware, so this configuration starts
normally rather than being rejected for a missing ambient key.

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

# 6. Build 4/3/2 fluency drills (interactive picker — recommended)
hellotalk-generate-drill-interactive.sh
# (batch variant: hellotalk-generate-drill.sh)

# 7. Generate Anki TSVs
hellotalk-generate-anki.sh
```

After Stage 6, the drill sessions land in `Drill/sessions/YYYY-MM-DD/` as
`grammar-drill.md` and `vocabulary-drill.md` — a content skeleton to talk from, not a
script to read. Read it once, then do the 4→3→2 min timed retellings.

After Stage 7, import the generated `.tsv` files into Anki:
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
| `hellotalk-analyze.timer` | Every 6 hours (offset) | (manual drill / Anki) |
| `hellotalk-generate-anki.timer` | Every 6 hours (offset) | — |

> **Stage 6 (4/3/2 Drill) is deliberately interactive-only — there is no systemd unit for it.** Drill generation asks you to pick which dates and drill types to build, so it is run by hand via `hellotalk-generate-drill-interactive.sh`. The automated timers jump straight from Analyze to Anki.

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
│   ├── hellotalk-generate-drill-interactive.sh
│   ├── hellotalk-generate-drill.sh
│   ├── hellotalk-generate-anki.sh
│   ├── hellotalk-anki-interactive.sh
│   ├── hellotalk-llm-call.py
│   ├── hellotalk-provider-resolve.sh
│   ├── hellotalk-variants.sh     # multi-model generation + reconciliation
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
│   ├── anki-generator-semantic.md
│   ├── judge-analysis.md     # reconciles two analysis candidates
│   ├── judge-tsv.md          # reconciles two Anki card sets
│   ├── judge-drill.md        # reconciles two drill sessions
│   └── drill/                # 4/3/2 drill prompts
│       ├── grammar-drill-prompt.md
│       ├── vocabulary-drill-prompt.md
│       └── transcript-regenerator-prompt.md
├── config/                   # Configuration templates
│   ├── env.template
│   └── cleanse.conf.template
├── README.md
├── README.zh-CN.md
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
- Quarantines oversized files (> 200 MB — likely stuck recordings) to `Invalid_audio/`
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
  - **Semantic** — identifies three sub-types of lexical issue: near-miss collocations, missed idiomatic phrasing, and semantic boundary errors. Duplicate occurrences of the same underlying pattern are deduplicated into a single finding.
- Respects quota sentinels: if a provider hits its daily limit, the batch aborts gracefully and resumes later

### Stage 6 — 4/3/2 Drill
- A timed fluency drill: you retell the same content three times at shrinking durations (4 min → 3 min → 2 min). The compression forces proceduralization — you stop planning and start producing.
- **Interactive-only** by design; there is no systemd timer for this stage.
  - `hellotalk-generate-drill-interactive.sh` — the recommended entry point. Presents a picker for which dates and drill types (grammar / vocabulary / both) to build, and always includes transcript context.
  - `hellotalk-generate-drill.sh` — the non-interactive batch variant that walks every analyzed day.
- **Inputs:** `Analysis/YYYY-MM-DD/grammar.md` and `semantic.md`, plus the raw or cleaned transcript for topic/context reconstruction.
- **Outputs:** `Drill/sessions/YYYY-MM-DD/grammar-drill.md` and `vocabulary-drill.md` — a content skeleton plus a target-structure / chunk list to talk *from*, not a script to read aloud.
- Prompts live in `prompts/drill/`:
  - `grammar-drill-prompt.md` — builds a grammar-focused 4/3/2 session from `grammar.md`
  - `vocabulary-drill-prompt.md` — builds a chunk/collocation-focused session from `semantic.md`
  - `transcript-regenerator-prompt.md` — reconstructs a clean, speaker-labeled transcript from messy ASR output, using the analysis files as anchors

### Stage 7 — Generate Anki
- Takes `grammar.md` and `semantic.md` from Stage 5
- Generates tab-separated flashcard files:
  - `grammar_cards.tsv` — FILL_IN_BLANK and CORRECT_THE_ERROR cards
  - `chunk_cards.tsv` — ERROR_CORRECTION, COLLOCATION_COMPLETION, IDIOM_UPGRADE, and PATTERN_COMPLETION cards, each mapped from its upstream semantic sub-type
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
