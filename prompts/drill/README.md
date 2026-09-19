# 4/3/2 Drill Pipeline

Part of the English learning pipeline, inserted after **analyzing** and before **Anki**.

## What is 4/3/2?

A timed fluency drill: retell the same content three times at shrinking durations (4min → 3min → 2min). The compression forces proceduralization — you stop planning and start producing.

## Pipeline Stages

```
Transcribe → Clean → Analyze → [4/3/2 Drill] → Anki
                                   ↑
                            You are here
```

## Files

| File | Purpose |
|---|---|
| `grammar-drill-prompt.md` | Prompt for generating grammar-focus 4/3/2 sessions. Feed grammar.md entries. |
| `vocabulary-drill-prompt.md` | Prompt for generating vocabulary/chunk-focus 4/3/2 sessions. Feed semantic.md entries. |
| `transcript-regenerator-prompt.md` | Prompt for regenerating a clean transcript from messy ASR output, using grammar.md and semantic.md as anchors. |

## Sessions

Each session output lives in `sessions/<date>/`. Run the prompts against the Analysis folder for that date.

## Usage

1. **Optional, and manual — no script runs this.** Run `transcript-regenerator-prompt.md` with the date's merged.txt + grammar.md + semantic.md to get a clean transcript, and save it as `sessions/<date>/cleaned-transcript.md`. That exact path is the only one the drill scripts look for; anywhere else and they silently fall back to the raw ASR text in merged.txt.
2. Run `grammar-drill-prompt.md` with the date's grammar.md (and optionally the clean transcript) — output goes to `sessions/<date>/grammar-drill.md`
3. Run `vocabulary-drill-prompt.md` with the date's semantic.md (and optionally the clean transcript) — output goes to `sessions/<date>/vocabulary-drill.md`
4. Do the drill: read skeleton once, then 4/3/2 timed retellings

Steps 2 and 3 are what `hellotalk-generate-drill.sh` and `hellotalk-generate-drill-interactive.sh` automate. Step 1 is not wired into either script, so drills are built from raw ASR text unless you run it by hand first. The `[E]`/`[I]` evidence tags in the generated skeleton are only as reliable as the transcript underneath them.