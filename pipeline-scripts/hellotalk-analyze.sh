#!/usr/bin/env bash
set -euo pipefail
batch_started=$(date +%s)

# ── Directories ──────────────────────────────────────────────────────
CLEANED_DIR="$HOME/Android/HelloTalkCapture/Cleaned_Transcripts"
ANALYSIS_DIR="$HOME/Android/HelloTalkCapture/Analysis"
PROMPT_DIR="$HOME/Android/HelloTalkCapture"
LOG_TAG="hellotalk-analyze"
# ── Sparse-day consolidation config ─────────────────────────────────
# If a day's merged.txt has fewer lines than this threshold, its content
# is merged into the next day's analysis instead of getting its own run.
: "${MERGE_MIN_LINES:=80}"


# ── Prompt files ─────────────────────────────────────────────────────
GRAMMAR_PROMPT="$PROMPT_DIR/analysis-grammar.md"
SEMANTIC_PROMPT="$PROMPT_DIR/analysis-semantic.md"

# ── Model config ─────────────────────────────────────────────────────
# Resolve API_BASE / API_KEY from PROVIDER (google|nvidia|custom).
# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-provider-resolve.sh"
: "${MODEL:=gemini-3.5-flash}"
: "${MAX_TOKENS:=131072}"
export API_BASE API_KEY MODEL MAX_TOKENS PROVIDER

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }
# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-common.sh"

mkdir -p "$ANALYSIS_DIR"

# Multi-model variant generation (no-op unless VARIANTS=1 in the env file).
# Sourced before the credential check so a slot-only configuration — keys set
# per slot rather than ambiently — is not rejected before it can be used.
# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-variants.sh"

if [ -z "${API_KEY:-}" ] && ! hellotalk_variants_ready; then
    log "ERROR: API_KEY not set for PROVIDER=$PROVIDER, and no variant slot supplies one. Aborting."
    exit 1
fi

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-quota-check.sh"
if ! hellotalk_variants_ready; then hellotalk_quota_check; fi

log "Provider: $PROVIDER  Model: $MODEL  Reasoning: ${REASONING_EFFORT:-provider-default}  API: $API_BASE"
if [ "${VARIANTS:-0}" = "1" ]; then
    log "Variants: ON — slots [$VARIANT_SLOTS], each artifact costs 2 generations + 1 reconciliation."
fi

# ── Collect prompt files that exist and are non-empty ────────────────
declare -A PROMPTS
[ -s "$GRAMMAR_PROMPT" ]  && PROMPTS[grammar]="$GRAMMAR_PROMPT"
[ -s "$SEMANTIC_PROMPT" ] && PROMPTS[semantic]="$SEMANTIC_PROMPT"

if [ ${#PROMPTS[@]} -eq 0 ]; then
    log "ERROR: No non-empty prompt files found. Aborting."
    exit 1
fi

log "Active prompts: ${!PROMPTS[*]}"

# Persist source assignments before rebuilding; cleaned sources stay immutable.
python3 "$HOME/.local/bin/hellotalk-merge-days.py" "$CLEANED_DIR" "$ANALYSIS_DIR" "$MERGE_MIN_LINES"
: "${REQUEST_TIMEOUT:=900}"
: "${ARTIFACT_TIMEOUT:=2700}"
: "${BATCH_TIMEOUT:=6900}"
BATCH_DEADLINE=$(( batch_started + BATCH_TIMEOUT ))
export BATCH_DEADLINE ARTIFACT_TIMEOUT

# ── Step 2: Run AI analysis on each day's merged transcript ─────────
log "Starting AI analysis..."

analyzed=0
skipped=0
failed=0

shopt -s nullglob
mapfile -t analysis_days < <(printf '%s\n' "$ANALYSIS_DIR"/????-??-?? | sort -r)
for day_dir in "${analysis_days[@]}"; do
    [ -d "$day_dir" ] || continue
    [ ! -f "$day_dir/.consolidated-to" ] || continue
    day="$(basename "$day_dir")"
    merged="$day_dir/merged.txt"

    [ -f "$merged" ] || continue
    if ! source_has_text "$merged"; then
        log "WARNING: $day has no assessable source text; keeping existing files and skipping analysis."
        ((failed++)) || true
        continue
    fi

    for prompt_name in "${!PROMPTS[@]}"; do
        prompt_file="${PROMPTS[$prompt_name]}"
        output_file="$day_dir/${prompt_name}.md"

        # New input always regenerates. A changed prompt only regenerates
        # recent days (or under FORCE_REGEN=1) so a single prompt edit does
        # not invalidate every historical day of paid analysis at once.
        if [ "${FORCE_REGEN:-0}" != 1 ] && [ -s "$output_file" ] && _hv_output_sane "$output_file" analysis && [ "$output_file" -nt "$merged" ]; then
            if [ "$output_file" -nt "$prompt_file" ]; then
                log "Skipping $day/$prompt_name (up to date)."
                ((skipped++)) || true
                continue
            fi
            # Prompt is newer than output but input is not: gate on the window.
            day_epoch=$(date -d "$day" +%s 2>/dev/null || echo "")
            cutoff_epoch=$(date -d "-${REGEN_WINDOW_DAYS:-3} days" +%s 2>/dev/null || echo "")
            in_window=0
            if [ -n "$day_epoch" ] && [ -n "$cutoff_epoch" ] && [ "$day_epoch" -ge "$cutoff_epoch" ]; then
                in_window=1
            fi
            if [ "$in_window" -ne 1 ] && [ "${FORCE_REGEN:-0}" != "1" ]; then
                log "Skipping $day/$prompt_name (prompt changed but day outside ${REGEN_WINDOW_DAYS:-3}-day window; set FORCE_REGEN=1 to override)"
                ((skipped++)) || true
                continue
            fi
        fi

        file_bytes=$(wc -c < "$merged")
        remaining=$(( BATCH_DEADLINE - $(date +%s) ))
        if [ "$remaining" -lt "$ARTIFACT_TIMEOUT" ]; then
            log "Batch budget reached; completed artifacts saved, remaining work deferred."
            exit 75
        fi
        timeout_secs="$REQUEST_TIMEOUT"
        log "Analyzing $day with $prompt_name prompt (${file_bytes} bytes, timeout ${timeout_secs}s)..."

        tmpout=$(mktemp "$day_dir/.analysis.XXXXXX")
        rc=0
        HARD_TIMEOUT="$timeout_secs" VARIANT_OUT_DIR="$day_dir" \
            hellotalk_generate "$prompt_file" "$merged" "$tmpout" analysis "$day-$prompt_name" || rc=$?

        if [ $rc -eq 0 ]; then
            if [ -s "$tmpout" ]; then
                mv "$tmpout" "$output_file"
                log "Done: $day/$prompt_name -> $(wc -c < "$output_file") bytes"
                ((analyzed++)) || true
            else
                rm -f "$tmpout"
                log "WARNING: $day/$prompt_name — empty response; prior output preserved."
                ((failed++)) || true
            fi
        else
            rm -f "$tmpout"
            case $rc in
                2)
                    log "QUOTA HIT on $day/$prompt_name — sentinel written, aborting batch."
                    log "Analysis aborted. Analyzed: $analyzed, Skipped: $skipped, Failed: $failed (before quota)."
                    exit 75
                    ;;
                3)
                    log "FATAL API error on $day/$prompt_name — aborting batch."
                    exit 1
                    ;;
                124)
                    log "ERROR: $day/$prompt_name — timed out (${timeout_secs}s hard limit)."
                    ((failed++)) || true
                    ;;
                *)
                    log "ERROR: $day/$prompt_name — failed (rc=$rc)."
                    ((failed++)) || true
                    ;;
            esac
        fi
    done
done
shopt -u nullglob

log "Analysis complete. Analyzed: $analyzed, Skipped: $skipped, Failed: $failed"

[ "$failed" -eq 0 ]
