#!/usr/bin/env bash
set -euo pipefail

# 4/3/2 drill session generator — inserted between analyze and Anki.
# Reads grammar.md + semantic.md analysis files and produces drill session outlines
# in Drill/sessions/YYYY-MM-DD/.

ANALYSIS_DIR="${ANALYSIS_DIR:-$HOME/Android/HelloTalkCapture/Analysis}"
DRILL_DIR="${DRILL_DIR:-$HOME/Android/HelloTalkCapture/Drill/sessions}"
PROMPT_DIR="${PROMPT_DIR:-$HOME/Android/HelloTalkCapture/Drill}"
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-$HOME/Android/HelloTalkCapture/Cleaned_Transcripts}"
LLM_CALL="${LLM_CALL:-$HOME/.local/bin/hellotalk-llm-call.py}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"
LOG_TAG="hellotalk-generate-drill"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# ── Prompt files ──────────────────────────────────────────────────────
GRAMMAR_DRILL_PROMPT="$PROMPT_DIR/grammar-drill-prompt.md"
VOCAB_DRILL_PROMPT="$PROMPT_DIR/vocabulary-drill-prompt.md"

# ── Model config ──────────────────────────────────────────────────────
# Load env (API keys, PROVIDER, MODEL, etc.)
if [ -f "$HOME/.config/hellotalk/env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$HOME/.config/hellotalk/env"
    set +a
fi

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-provider-resolve.sh"
: "${MODEL:=gemini-3.5-flash}"
: "${MAX_TOKENS:=131072}"
export API_BASE API_KEY MODEL MAX_TOKENS PROVIDER

if [ -z "${API_KEY:-}" ]; then
    log "ERROR: API_KEY not set for PROVIDER=$PROVIDER. Aborting."
    exit 1
fi

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-quota-check.sh"
hellotalk_quota_check

log "Provider: $PROVIDER  Model: ${MODEL:-<default>}  API: $API_BASE"

# ── Define jobs ───────────────────────────────────────────────────────
declare -a JOBS=()
[ -s "$GRAMMAR_DRILL_PROMPT" ] && JOBS+=("grammar|$GRAMMAR_DRILL_PROMPT|grammar.md|grammar-drill.md")
[ -s "$VOCAB_DRILL_PROMPT" ]  && JOBS+=("vocabulary|$VOCAB_DRILL_PROMPT|semantic.md|vocabulary-drill.md")

if [ ${#JOBS[@]} -eq 0 ]; then
    log "ERROR: No non-empty drill prompt files found in $PROMPT_DIR. Aborting."
    exit 1
fi

log "Active drill prompts: ${#JOBS[@]}"

generated=0
skipped=0
failed=0

# ── Process each day's analysis ───────────────────────────────────────
shopt -s nullglob
for day_dir in "$ANALYSIS_DIR"/????-??-??; do
    [ -d "$day_dir" ] || continue
    day="$(basename "$day_dir")"
    day_drill="$DRILL_DIR/$day"
    mkdir -p "$day_drill"

    for job in "${JOBS[@]}"; do
        IFS='|' read -r job_name prompt_file input_name output_name <<< "$job"
        input_file="$day_dir/$input_name"
        output_file="$day_drill/$output_name"

        [ -s "$input_file" ] || continue

        # Skip if output is up to date
        if [ -f "$output_file" ] && [ "$output_file" -nt "$input_file" ] && [ "$output_file" -nt "$prompt_file" ]; then
            log "Skipping $day/$output_name (up to date)."
            ((skipped++)) || true
            continue
        fi

        log "Generating $day/$output_name from $(basename "$input_file")..."

        # Build input context: analysis file + optionally the cleaned transcript
        # The drill prompt needs the analysis entries as primary input, plus
        # the transcript for topic/context reconstruction.
        tmpinput=$(mktemp)
        cat "$input_file" > "$tmpinput"

        # Append cleaned transcript if available (optional context for drill)
        transcript_file="$TRANSCRIPT_DIR/$day/merged.txt"
        if [ -f "$transcript_file" ] && [ -s "$transcript_file" ]; then
            printf "\n\n--- Raw transcript (for topic/context reconstruction only) ---\n\n" >> "$tmpinput"
            cat "$transcript_file" >> "$tmpinput"
        fi

        # Also check if there's a cleaned transcript in the drill session dir
        cleaned_transcript="$day_drill/cleaned-transcript.md"
        if [ -f "$cleaned_transcript" ] && [ -s "$cleaned_transcript" ]; then
            printf "\n\n--- Cleaned transcript (for topic/context reconstruction only) ---\n\n" >> "$tmpinput"
            cat "$cleaned_transcript" >> "$tmpinput"
        fi

        if [ ! -s "$tmpinput" ]; then
            rm -f "$tmpinput"
            log "WARNING: $day/$output_name — input is empty."
            ((failed++)) || true
            continue
        fi

        tmpout=$(mktemp)
        rc=0
        timeout "$HARD_TIMEOUT" python3 "$LLM_CALL" \
            "$prompt_file" "$tmpinput" "$tmpout" || rc=$?

        if [ $rc -eq 0 ] && [ -s "$tmpout" ]; then
            mv "$tmpout" "$output_file"
            log "Done: $day/$output_name -> $(wc -c < "$output_file") bytes"
            ((generated++)) || true
        else
            rm -f "$tmpout"
            case $rc in
                2)
                    log "QUOTA HIT on $day/$output_name — sentinel written, aborting batch."
                    log "Drill generation aborted. Generated: $generated, Skipped: $skipped, Failed: $failed (before quota)."
                    rm -f "$tmpinput"
                    exit 75
                    ;;
                3)
                    log "FATAL API error on $day/$output_name — aborting batch."
                    rm -f "$tmpinput"
                    exit 1
                    ;;
                124)
                    log "ERROR: $day/$output_name — timed out (${HARD_TIMEOUT}s hard limit)."
                    ((failed++)) || true
                    ;;
                *)
                    log "ERROR: $day/$output_name — failed (rc=$rc)."
                    ((failed++)) || true
                    ;;
            esac
        fi

        rm -f "$tmpinput"
    done
done
shopt -u nullglob

log "Drill generation complete. Generated: $generated, Skipped: $skipped, Failed: $failed"