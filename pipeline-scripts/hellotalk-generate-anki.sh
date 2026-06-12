#!/usr/bin/env bash
set -euo pipefail

ANALYSIS_DIR="${ANALYSIS_DIR:-$HOME/Android/HelloTalkCapture/Analysis}"
ANKI_DIR="${ANKI_DIR:-$HOME/Android/HelloTalkCapture/Anki}"
PROMPT_DIR="${PROMPT_DIR:-$HOME/Android/HelloTalkCapture}"
GRAMMAR_PROMPT="${GRAMMAR_PROMPT:-$PROMPT_DIR/anki-generator-grammar.md}"
CHUNKS_PROMPT="${CHUNKS_PROMPT:-$PROMPT_DIR/anki-generator-semantic.md}"
LLM_CALL="${LLM_CALL:-$HOME/.local/bin/hellotalk-llm-call.py}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"
TSV_RETRY_COUNT="${TSV_RETRY_COUNT:-1}"
EXPECTED_TABS="${EXPECTED_TABS:-5}"   # 6 fields = 5 tab separators; accept lines with >= this many
LOG_TAG="hellotalk-generate-anki"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

sanitize_analysis_input() {
    local src="$1"
    local dest="$2"

    # Strip helper-added chunk headers and failure markers so prompts see only analysis content.
    awk '!/^--- Chunk [0-9]+[/][0-9]+ ---$/ && !/\[ANALYSIS FAILED/' "$src" > "$dest"
}

# Validate TSV output: keep only lines with >= EXPECTED_TABS tabs.
# Returns the number of valid lines written to $2. Rejects blank lines,
# LLM commentary (0 tabs), and truncated/malformed lines (<5 tabs).
validate_and_filter_tsv() {
    local src="$1"
    local dest="$2"
    local tabs="$3"
    local valid=0
    local rejected=0

    : > "$dest"
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty/blank lines
        [ -z "${line//[$' \t']/}" ] && continue
        count=$(printf '%s' "$line" | tr -cd '\t' | wc -c)
        if [ "$count" -ge "$tabs" ]; then
            printf '%s\n' "$line" >> "$dest"
            ((valid++)) || true
        else
            ((rejected++)) || true
        fi
    done < "$src"

    if [ "$rejected" -gt 0 ]; then
        log "  TSV filter: $valid valid, $rejected rejected (< $tabs tabs)"
    fi
    echo "$valid"
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
        tmpvalidated=$(mktemp)
        tmpstrictprompt=$(mktemp)
        sanitize_analysis_input "$input_file" "$tmpinput"

        if [ ! -s "$tmpinput" ]; then
            rm -f "$tmpinput" "$tmpout" "$tmpvalidated" "$tmpstrictprompt"
            log "WARNING: $day/$output_name — sanitized input is empty."
            ((failed++)) || true
            continue
        fi

        attempt=0
        max_attempts=$(( TSV_RETRY_COUNT + 1 ))
        while [ $attempt -lt $max_attempts ]; do
            rc=0
            if [ $attempt -eq 0 ]; then
                current_prompt="$prompt_file"
            else
                # Build a stricter prompt for retry: original + enforcement suffix
                cat "$prompt_file" > "$tmpstrictprompt"
                cat >> "$tmpstrictprompt" <<'RETRY_SUFFIX'

━━━ CRITICAL FORMAT REMINDER ━━━
Your ENTIRE response must be raw TSV data only.
- One card per line. Exactly 6 tab-separated fields per line (5 tab characters).
- NO explanatory text, NO commentary, NO planning notes, NO markdown fences.
- NO blank lines. NO headers. NO code fences.
- Every non-empty line MUST contain exactly 5 tab characters.
- If you write anything other than tab-separated card data, the output will be rejected.
RETRY_SUFFIX
                current_prompt="$tmpstrictprompt"
                log "  Retry $attempt/$TSV_RETRY_COUNT for $day/$output_name (stricter prompt)..."
            fi

            timeout "$HARD_TIMEOUT" env LLM_CHUNK_HEADERS=0 python3 "$LLM_CALL" \
                "$current_prompt" "$tmpinput" "$tmpout" || rc=$?

            if [ $rc -eq 0 ] && [ -s "$tmpout" ]; then
                # Validate and filter TSV output
                valid_lines=$(validate_and_filter_tsv "$tmpout" "$tmpvalidated" "$EXPECTED_TABS")

                if [ "$valid_lines" -gt 0 ]; then
                    mv "$tmpvalidated" "$output_file"
                    log "Done: $day/$output_name -> $valid_lines valid line(s)"
                    ((generated++)) || true
                    break
                else
                    log "  WARNING: $day/$output_name — all lines rejected by TSV filter (attempt $((attempt+1))/$max_attempts)."
                    rm -f "$tmpout"
                fi
            elif [ $rc -ne 0 ]; then
                rm -f "$tmpout"
                case $rc in
                    2)
                        rm -f "$tmpinput" "$tmpvalidated" "$tmpstrictprompt"
                        log "QUOTA HIT on $day/$output_name — sentinel written, aborting batch."
                        log "Anki generation aborted. Generated: $generated, Skipped: $skipped, Failed: $failed (before quota)."
                        exit 75
                        ;;
                    3)
                        rm -f "$tmpinput" "$tmpvalidated" "$tmpstrictprompt"
                        log "FATAL API error on $day/$output_name — aborting batch."
                        exit 1
                        ;;
                    124)
                        log "ERROR: $day/$output_name — timed out (${HARD_TIMEOUT}s hard limit)."
                        break  # don't retry on timeout
                        ;;
                    *)
                        log "ERROR: $day/$output_name — failed (rc=$rc)."
                        break  # don't retry on other errors
                        ;;
                esac
            else
                # rc=0 but empty output
                rm -f "$tmpout"
                log "  WARNING: $day/$output_name — empty response (attempt $((attempt+1))/$max_attempts)."
            fi

            ((attempt++)) || true
        done

        # If we exhausted all attempts without success
        if [ $attempt -eq $max_attempts ] && [ ! -f "$output_file" ]; then
            log "ERROR: $day/$output_name — failed after $max_attempts attempt(s)."
            ((failed++)) || true
        fi

        rm -f "$tmpinput" "$tmpout" "$tmpvalidated" "$tmpstrictprompt"
    done
done
shopt -u nullglob

log "Anki generation complete. Generated: $generated, Skipped: $skipped, Failed: $failed"
