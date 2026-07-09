# 4/3/2 Drill Prompts

Part of the English learning pipeline, inserted after **Analyze** and before **Anki**.

## What is 4/3/2?

A timed fluency drill: retell the same content three times at shrinking durations (4min → 3min → 2min). The compression forces proceduralization — you stop planning and start producing.

## Pipeline Position

```
Transcribe → Cleanse → Analyze → [4/3/2 Drill] → Anki
                                     ↑
                              You are here
```

## Files

| File | Purpose |
|---|---|
| `grammar-drill-prompt.md` | Prompt for generating grammar-focus 4/3/2 sessions. Feed grammar.md entries. |
| `vocabulary-drill-prompt.md` | Prompt for generating vocabulary/chunk-focus 4/3/2 sessions. Feed semantic.md entries. |
| `transcript-regenerator-prompt.md` | Prompt for regenerating a clean transcript from messy ASR output, using grammar.md and semantic.md as anchors. |

## Runtime Layout

At runtime these three prompt files are copied to `~/Android/HelloTalkCapture/Drill/` (see the repo's top-level [Installation](../../README.md#installation) step). `hellotalk-generate-drill-interactive.sh` (interactive, one day at a time) or `hellotalk-generate-drill.sh` (batch, over multiple days) run them automatically against that day's `grammar.md` / `semantic.md` / transcript. Output is written to `Drill/sessions/<date>/`.

## Usage

1. Run `transcript-regenerator-prompt.md` with the date's `merged.txt` + `grammar.md` + `semantic.md` to get a clean transcript.
2. Run `grammar-drill-prompt.md` with the date's `grammar.md` (and optionally the clean transcript) — output goes to `Drill/sessions/<date>/grammar-drill.md`.
3. Run `vocabulary-drill-prompt.md` with the date's `semantic.md` (and optionally the clean transcript) — output goes to `Drill/sessions/<date>/vocabulary-drill.md`.
4. Do the drill: read the skeleton once, then perform the 4/3/2 timed retellings.
