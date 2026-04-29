#!/usr/bin/env bash
set -euo pipefail

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
# Resolve API_BASE / API_KEY from PROVIDER (nvidia|tencent|cloudflare).
# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-provider-resolve.sh"
: "${MODEL:=moonshotai/kimi-k2.5}"
: "${MAX_TOKENS:=131072}"
export API_BASE API_KEY MODEL MAX_TOKENS PROVIDER

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

mkdir -p "$ANALYSIS_DIR"

if [ -z "${API_KEY:-}" ]; then
    log "ERROR: API_KEY not set for PROVIDER=$PROVIDER. Aborting."
    exit 1
fi

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-quota-check.sh"
hellotalk_quota_check

log "Provider: $PROVIDER  Model: $MODEL  API: $API_BASE"

# ── Collect prompt files that exist and are non-empty ────────────────
declare -A PROMPTS
[ -s "$GRAMMAR_PROMPT" ]  && PROMPTS[grammar]="$GRAMMAR_PROMPT"
[ -s "$SEMANTIC_PROMPT" ] && PROMPTS[semantic]="$SEMANTIC_PROMPT"

if [ ${#PROMPTS[@]} -eq 0 ]; then
    log "ERROR: No non-empty prompt files found. Aborting."
    exit 1
fi

log "Active prompts: ${!PROMPTS[*]}"

# ── Step 1: Merge daily transcripts into Analysis/YYYY-MM-DD/ ───────
log "Merging daily transcripts..."
daily_merged=0

shopt -s nullglob
for date_dir in "$CLEANED_DIR"/????-??-??; do
    [ -d "$date_dir" ] || continue
    day="$(basename "$date_dir")"

    individual=()
    for f in "$date_dir"/hellotalk_mic_*.txt; do
        individual+=("$f")
    done

    [ ${#individual[@]} -eq 0 ] && continue

    day_analysis="$ANALYSIS_DIR/$day"
    mkdir -p "$day_analysis"
    merged="$day_analysis/merged.txt"

    # Find the newest individual transcript
    newest_src=0
    for f in "${individual[@]}"; do
        ts=$(stat -c %Y "$f")
        (( ts > newest_src )) && newest_src=$ts
    done

    # Skip merge if merged.txt exists and is newer than all sources
    if [ -f "$merged" ]; then
        merged_ts=$(stat -c %Y "$merged")
        if (( merged_ts >= newest_src )); then
            continue
        fi
    fi

    # Rebuild merged.txt: sorted by filename (chronological)
    tmpmerge=$(mktemp)
    first=true
    for f in $(printf '%s\n' "${individual[@]}" | sort); do
        if $first; then
            first=false
        else
            echo "" >> "$tmpmerge"
        fi
        cat "$f" >> "$tmpmerge"
    done

    mv "$tmpmerge" "$merged"
    log "Merged $day: ${#individual[@]} recording(s) -> merged.txt ($(wc -l < "$merged") lines)"
    ((daily_merged++)) || true
done
shopt -u nullglob

log "Daily merge complete. $daily_merged day(s) updated."


# ── Step 1.5: Consolidate sparse days ───────────────────────────────
# Days with fewer than MERGE_MIN_LINES lines in merged.txt are merged
# into the next day that has data, avoiding wasted API calls on thin content.
log "Consolidating sparse days (threshold: $MERGE_MIN_LINES lines)..."

shopt -s nullglob
declare -a all_days=()
for d in "$ANALYSIS_DIR"/????-??-??; do
    [ -d "$d" ] && all_days+=("$(basename "$d")")
done
shopt -u nullglob

# Sort chronologically
IFS=$'\n' sorted_days=($(printf '%s\n' "${all_days[@]}" | sort)); unset IFS

consolidated=0
for i in "${!sorted_days[@]}"; do
    day="${sorted_days[$i]}"
    day_dir="$ANALYSIS_DIR/$day"
    merged="$day_dir/merged.txt"

    # Skip if directory was already removed by a prior consolidation
    [ -d "$day_dir" ] || continue
    [ -f "$merged" ] || continue

    line_count=$(wc -l < "$merged")
    if [ "$line_count" -lt "$MERGE_MIN_LINES" ]; then
        # Find the next day that still exists (may have been consolidated too)
        next_day=""
        next_idx=$((i + 1))
        while [ "$next_idx" -lt "${#sorted_days[@]}" ]; do
            candidate="${sorted_days[$next_idx]}"
            if [ -d "$ANALYSIS_DIR/$candidate" ]; then
                next_day="$candidate"
                break
            fi
            next_idx=$((next_idx + 1))
        done

        if [ -z "$next_day" ]; then
            log "Sparse day $day ($line_count lines) — no next day to merge into, keeping as-is."
            continue
        fi

        next_merged="$ANALYSIS_DIR/$next_day/merged.txt"

        if [ -f "$next_merged" ]; then
            # Prepend sparse day content with a date separator
            tmpfile=$(mktemp)
            {
                echo "# ── Merged from $day ($line_count lines) ──"
                cat "$merged"
                echo ""
                cat "$next_merged"
            } > "$tmpfile"
            mv "$tmpfile" "$next_merged"
        else
            # Next day has no merged.txt — move this one over
            mkdir -p "$(dirname "$next_merged")"
            mv "$merged" "$next_merged"
        fi

        # Remove the sparse day's analysis folder (only merged.txt + any analysis outputs)
        rm -rf "$day_dir"
        log "Consolidated $day ($line_count lines) -> $next_day"
        ((consolidated++)) || true
    fi
done

log "Consolidation complete. $consolidated sparse day(s) merged."

# ── Step 2: Run AI analysis on each day's merged transcript ─────────
log "Starting AI analysis..."

analyzed=0
skipped=0
failed=0

shopt -s nullglob
for day_dir in "$ANALYSIS_DIR"/????-??-??; do
    [ -d "$day_dir" ] || continue
    day="$(basename "$day_dir")"
    merged="$day_dir/merged.txt"

    [ -f "$merged" ] || continue

    for prompt_name in "${!PROMPTS[@]}"; do
        prompt_file="${PROMPTS[$prompt_name]}"
        output_file="$day_dir/${prompt_name}.md"

        # Skip if output exists and is newer than BOTH merged.txt and the prompt file
        if [ -f "$output_file" ] && [ "$output_file" -nt "$merged" ] && [ "$output_file" -nt "$prompt_file" ]; then
            log "Skipping $day/$prompt_name (up to date)."
            ((skipped++)) || true
            continue
        fi

        file_bytes=$(wc -c < "$merged")
        timeout_secs=$(( 1800 + (file_bytes / 120000) * 1200 ))
        log "Analyzing $day with $prompt_name prompt (${file_bytes} bytes, timeout ${timeout_secs}s)..."

        tmpout=$(mktemp)
        rc=0
        timeout "$timeout_secs" python3 "$HOME/.local/bin/hellotalk-llm-call.py" \
            "$prompt_file" "$merged" "$tmpout" || rc=$?

        if [ $rc -eq 0 ]; then
            if [ -s "$tmpout" ]; then
                mv "$tmpout" "$output_file"
                log "Done: $day/$prompt_name -> $(wc -c < "$output_file") bytes"
                ((analyzed++)) || true
            else
                rm -f "$tmpout"
                log "WARNING: $day/$prompt_name — empty response after retries."
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
