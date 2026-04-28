#!/usr/bin/env bash
set -euo pipefail

ANALYSIS_DIR="${ANALYSIS_DIR:-$HOME/Android/HelloTalkCapture/Analysis}"
ANKI_DIR="${ANKI_DIR:-$HOME/Android/HelloTalkCapture/Anki}"
PROMPT_DIR="${PROMPT_DIR:-$HOME/Android/HelloTalkCapture}"
GRAMMAR_PROMPT="${GRAMMAR_PROMPT:-$PROMPT_DIR/Anki_cards_generating_prompt_Grammar.md}"
CHUNKS_PROMPT="${CHUNKS_PROMPT:-$PROMPT_DIR/Anki_cards_generating_prompt_Chunks.md}"
LLM_CALL="${LLM_CALL:-$HOME/.local/bin/hellotalk-llm-call.py}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"
LOG_TAG="hellotalk-generate-anki"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

sanitize_analysis_input() {
    local src="$1"
    local dest="$2"

    # Strip helper-added chunk headers so prompts see only analysis content.
    awk '!/^--- Chunk [0-9]+[/][0-9]+ ---$/' "$src" > "$dest"
}

mkdir -p "$ANKI_DIR"

# Resolve API_BASE / API_KEY from PROVIDER (nvidia|tencent|cloudflare).
# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-provider-resolve.sh"
export API_BASE API_KEY MODEL MAX_TOKENS PROVIDER

if [ -z "${API_KEY:-}" ]; then
    log "ERROR: API_KEY not set for PROVIDER=$PROVIDER. Aborting."
    exit 1
fi

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-quota-check.sh"
hellotalk_quota_check

log "Provider: $PROVIDER  Model: ${MODEL:-<default>}  API: $API_BASE"

declare -a JOBS=()
[ -s "$GRAMMAR_PROMPT" ] && JOBS+=("grammar|$GRAMMAR_PROMPT|grammar.md|grammar_cards.tsv")
[ -s "$CHUNKS_PROMPT" ] && JOBS+=("chunks|$CHUNKS_PROMPT|semantic.md|chunk_cards.tsv")

if [ ${#JOBS[@]} -eq 0 ]; then
    log "ERROR: No non-empty Anki prompt files found. Aborting."
    exit 1
fi

log "Active Anki prompts: ${#JOBS[@]}"

generated=0
skipped=0
failed=0

shopt -s nullglob
for day_dir in "$ANALYSIS_DIR"/????-??-??; do
    [ -d "$day_dir" ] || continue
    day="$(basename "$day_dir")"
    day_anki="$ANKI_DIR/$day"
    mkdir -p "$day_anki"

    for job in "${JOBS[@]}"; do
        IFS='|' read -r job_name prompt_file input_name output_name <<< "$job"
        input_file="$day_dir/$input_name"
        output_file="$day_anki/$output_name"

        [ -s "$input_file" ] || continue

        if [ -f "$output_file" ] && [ "$output_file" -nt "$input_file" ] && [ "$output_file" -nt "$prompt_file" ]; then
            log "Skipping $day/$output_name (up to date)."
            ((skipped++)) || true
            continue
        fi

        log "Generating $day/$output_name from $(basename "$input_file")..."

        tmpinput=$(mktemp)
        tmpout=$(mktemp)
        sanitize_analysis_input "$input_file" "$tmpinput"

        if [ ! -s "$tmpinput" ]; then
            rm -f "$tmpinput" "$tmpout"
            log "WARNING: $day/$output_name — sanitized input is empty."
            ((failed++)) || true
            continue
        fi

        rc=0
        timeout "$HARD_TIMEOUT" env LLM_CHUNK_HEADERS=0 python3 "$LLM_CALL" \
            "$prompt_file" "$tmpinput" "$tmpout" || rc=$?

        if [ $rc -eq 0 ]; then
            if [ -s "$tmpout" ]; then
                mv "$tmpout" "$output_file"
                log "Done: $day/$output_name -> $(wc -l < "$output_file") line(s)"
                ((generated++)) || true
            else
                rm -f "$tmpout"
                log "WARNING: $day/$output_name — empty response after retries."
                ((failed++)) || true
            fi
        else
            rm -f "$tmpout"
            case $rc in
                2)
                    rm -f "$tmpinput"
                    log "QUOTA HIT on $day/$output_name — sentinel written, aborting batch."
                    log "Anki generation aborted. Generated: $generated, Skipped: $skipped, Failed: $failed (before quota)."
                    exit 75
                    ;;
                3)
                    rm -f "$tmpinput"
                    log "FATAL API error on $day/$output_name — aborting batch."
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

log "Anki generation complete. Generated: $generated, Skipped: $skipped, Failed: $failed"
