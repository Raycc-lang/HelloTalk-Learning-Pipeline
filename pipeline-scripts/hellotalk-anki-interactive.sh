#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────
ANALYSIS_DIR="${ANALYSIS_DIR:-$HOME/Android/HelloTalkCapture/Analysis}"
ANKI_DIR="${ANKI_DIR:-$HOME/Android/HelloTalkCapture/Anki}"
PROMPT_DIR="${PROMPT_DIR:-$HOME/Android/HelloTalkCapture}"
GRAMMAR_PROMPT="${GRAMMAR_PROMPT:-$PROMPT_DIR/anki-generator-grammar.md}"
CHUNKS_PROMPT="${CHUNKS_PROMPT:-$PROMPT_DIR/anki-generator-semantic.md}"
LLM_CALL="${LLM_CALL:-$HOME/.local/bin/hellotalk-llm-call.py}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"
LOG_TAG="hellotalk-anki"

# Load env (API keys, PROVIDER, MODEL, etc.)
if [ -f "$HOME/.config/hellotalk/env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$HOME/.config/hellotalk/env"
    set +a
fi

# Anki generation — low reasoning for quality card generation.
: "${REASONING_EFFORT:=low}"
export REASONING_EFFORT

log() { echo "  $(date '+%H:%M:%S') $*"; }

sanitize_analysis_input() {
    local src="$1" dest="$2"
    awk '!/^--- Chunk [0-9]+[/][0-9]+ ---$/ && !/\[ANALYSIS FAILED/' "$src" > "$dest"
}

# ── Resolve provider ────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-provider-resolve.sh"
export API_BASE API_KEY MODEL MAX_TOKENS PROVIDER

if [ -z "${API_KEY:-}" ]; then
    echo "ERROR: API_KEY not set for PROVIDER=$PROVIDER." >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-quota-check.sh"
hellotalk_quota_check

# ── Collect available days ──────────────────────────────────────────────
declare -a DAYS=()
declare -A DAY_GRAMMAR DAY_SEMANTIC

shopt -s nullglob
for day_dir in "$ANALYSIS_DIR"/????-??-??; do
    [ -d "$day_dir" ] || continue
    day="$(basename "$day_dir")"
    has_any=false
    if [ -s "$day_dir/grammar.md" ]; then
        DAY_GRAMMAR[$day]="$day_dir/grammar.md"
        has_any=true
    fi
    if [ -s "$day_dir/semantic.md" ]; then
        DAY_SEMANTIC[$day]="$day_dir/semantic.md"
        has_any=true
    fi
    $has_any && DAYS+=("$day")
done
shopt -u nullglob

if [ ${#DAYS[@]} -eq 0 ]; then
    echo "No analysis files found in $ANALYSIS_DIR"
    exit 1
fi

# Sort chronologically
IFS=$'\n' DAYS=($(printf '%s\n' "${DAYS[@]}" | sort)); unset IFS

# ── Interactive selection ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         HelloTalk Anki Card Generator               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Provider: $PROVIDER  Model: ${MODEL:-<default>}  Reasoning: ${REASONING_EFFORT}"
echo ""

# Show available days with status
printf "  %-4s  %-12s  %-10s  %-10s  %s\n" "#" "Date" "Grammar" "Semantic" "Anki exists?"
printf "  %-4s  %-12s  %-10s  %-10s  %s\n" "───" "────────────" "──────────" "──────────" "────────────"

for i in "${!DAYS[@]}"; do
    day="${DAYS[$i]}"
    g_size="-"; s_size="-"
    g_anki="-"; s_anki="-"

    if [ -n "${DAY_GRAMMAR[$day]:-}" ]; then
        g_size="$(wc -c < "${DAY_GRAMMAR[$day]}")B"
        [ -f "$ANKI_DIR/$day/grammar_cards.tsv" ] && g_anki="✓"
    fi
    if [ -n "${DAY_SEMANTIC[$day]:-}" ]; then
        s_size="$(wc -c < "${DAY_SEMANTIC[$day]}")B"
        [ -f "$ANKI_DIR/$day/chunk_cards.tsv" ] && s_anki="✓"
    fi

    anki_status=""
    [ "$g_anki" = "✓" ] && anki_status="G"
    [ "$s_anki" = "✓" ] && anki_status="${anki_status}S"
    [ -z "$anki_status" ] && anki_status="-"

    printf "  %-4s  %-12s  %-10s  %-10s  %s\n" \
        "$((i+1))" "$day" "$g_size" "$s_size" "$anki_status"
done

echo ""
echo "  G = grammar anki exists, S = semantic anki exists"
echo ""

# ── Day selection ───────────────────────────────────────────────────────
read -rp "Select days (number, range like 3-7, 'all', or comma-separated): " day_input

declare -a SELECTED_DAYS=()

parse_selection() {
    local input="$1"
    # Split by comma
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)  # trim
        if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
            local start="${part%-*}" end="${part#*-}"
            for ((j=start; j<=end; j++)); do
                local idx=$((j-1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#DAYS[@]} ]; then
                    SELECTED_DAYS+=("${DAYS[$idx]}")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            local idx=$((part-1))
            if [ $idx -ge 0 ] && [ $idx -lt ${#DAYS[@]} ]; then
                SELECTED_DAYS+=("${DAYS[$idx]}")
            fi
        elif [ "$part" = "all" ]; then
            SELECTED_DAYS=("${DAYS[@]}")
            return
        fi
    done
}

if [ "$(echo "$day_input" | xargs)" = "all" ]; then
    SELECTED_DAYS=("${DAYS[@]}")
else
    parse_selection "$day_input"
fi

# Deduplicate
IFS=$'\n' SELECTED_DAYS=($(printf '%s\n' "${SELECTED_DAYS[@]}" | sort -u)); unset IFS

if [ ${#SELECTED_DAYS[@]} -eq 0 ]; then
    echo "No valid days selected."
    exit 1
fi

echo ""
echo "  Selected: ${#SELECTED_DAYS[@]} day(s) — ${SELECTED_DAYS[*]}"
echo ""

# ── Type selection ──────────────────────────────────────────────────────
echo "  Card types:"
echo "    1) grammar  — grammar correction cards"
echo "    2) semantic — chunk/semantic cards"
echo "    3) both"
echo ""
read -rp "Select type [1/2/3, default=3]: " type_choice
type_choice="${type_choice:-3}"

declare -a JOB_TYPES=()
case "$type_choice" in
    1) JOB_TYPES=("grammar") ;;
    2) JOB_TYPES=("semantic") ;;
    3|both) JOB_TYPES=("grammar" "semantic") ;;
    *) echo "Invalid choice."; exit 1 ;;
esac

# ── Force regenerate? ──────────────────────────────────────────────────
read -rp "Force regenerate even if up to date? [y/N]: " force_choice
force_choice="${force_choice:-N}"
FORCE=false
[[ "$force_choice" =~ ^[Yy] ]] && FORCE=true

# ── Preview plan ────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Plan                                                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

total_jobs=0
for day in "${SELECTED_DAYS[@]}"; do
    for jtype in "${JOB_TYPES[@]}"; do
        if [ "$jtype" = "grammar" ]; then
            src="${DAY_GRAMMAR[$day]:-}"
            out="$ANKI_DIR/$day/grammar_cards.tsv"
        else
            src="${DAY_SEMANTIC[$day]:-}"
            out="$ANKI_DIR/$day/chunk_cards.tsv"
        fi
        [ -z "$src" ] && continue

        status="generate"
        if [ -f "$out" ] && ! $FORCE; then
            if [ "$out" -nt "$src" ]; then
                status="skip (up to date)"
            fi
        fi

        printf "  %-12s  %-10s  %s\n" "$day" "$jtype" "$status"
        ((total_jobs++)) || true
    done
done

echo ""
echo "  Total: $total_jobs job(s)"
echo ""

if [ $total_jobs -eq 0 ]; then
    echo "  Nothing to do."
    exit 0
fi

read -rp "Proceed? [Y/n]: " go
go="${go:-Y}"
if [[ ! "$go" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

# ── Execute ─────────────────────────────────────────────────────────────
echo ""
mkdir -p "$ANKI_DIR"

generated=0
skipped=0
failed=0

for day in "${SELECTED_DAYS[@]}"; do
    for jtype in "${JOB_TYPES[@]}"; do
        if [ "$jtype" = "grammar" ]; then
            src="${DAY_GRAMMAR[$day]:-}"
            prompt="$GRAMMAR_PROMPT"
            out_name="grammar_cards.tsv"
        else
            src="${DAY_SEMANTIC[$day]:-}"
            prompt="$CHUNKS_PROMPT"
            out_name="chunk_cards.tsv"
        fi

        [ -z "$src" ] && continue

        day_anki="$ANKI_DIR/$day"
        mkdir -p "$day_anki"
        out="$day_anki/$out_name"

        # Check if up to date
        if [ -f "$out" ] && ! $FORCE; then
            if [ "$out" -nt "$src" ]; then
                log "[$day/$jtype] Skipped (up to date)."
                ((skipped++)) || true
                continue
            fi
        fi

        log "[$day/$jtype] Generating..."

        tmpinput=$(mktemp)
        tmpout=$(mktemp)
        sanitize_analysis_input "$src" "$tmpinput"

        if [ ! -s "$tmpinput" ]; then
            rm -f "$tmpinput" "$tmpout"
            log "[$day/$jtype] Skipped — sanitized input is empty."
            ((failed++)) || true
            continue
        fi

        start_ts=$(date +%s)
        rc=0
        timeout "$HARD_TIMEOUT" env LLM_CHUNK_HEADERS=0 python3 "$LLM_CALL" \
            "$prompt" "$tmpinput" "$tmpout" 2>&1 || rc=$?
        elapsed=$(( $(date +%s) - start_ts ))

        if [ $rc -eq 0 ]; then
            if [ -s "$tmpout" ]; then
                mv "$tmpout" "$out"
                lines=$(wc -l < "$out")
                log "[$day/$jtype] Done — ${lines} card(s) in ${elapsed}s"
                ((generated++)) || true
            else
                rm -f "$tmpout"
                log "[$day/$jtype] Failed — empty response."
                ((failed++)) || true
            fi
        else
            rm -f "$tmpout"
            case $rc in
                2)  log "[$day/$jtype] QUOTA HIT — sentinel written."
                    log "Aborting. Generated: $generated, Skipped: $skipped, Failed: $failed"
                    exit 75 ;;
                3)  log "[$day/$jtype] FATAL API error."
                    log "Aborting. Generated: $generated, Skipped: $skipped, Failed: $failed"
                    exit 1 ;;
                124) log "[$day/$jtype] Timed out (${HARD_TIMEOUT}s)."
                    ((failed++)) || true ;;
                *)  log "[$day/$jtype] Failed (rc=$rc)."
                    ((failed++)) || true ;;
            esac
        fi

        rm -f "$tmpinput"
    done
done

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Done!                                                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Generated: $generated"
echo "  Skipped:   $skipped"
echo "  Failed:    $failed"
echo ""

if [ $generated -gt 0 ]; then
    read -rp "Preview generated cards? [y/N]: " preview
    if [[ "$preview" =~ ^[Yy] ]]; then
        for day in "${SELECTED_DAYS[@]}"; do
            for jtype in "${JOB_TYPES[@]}"; do
                if [ "$jtype" = "grammar" ]; then
                    out="$ANKI_DIR/$day/grammar_cards.tsv"
                else
                    out="$ANKI_DIR/$day/chunk_cards.tsv"
                fi
                [ -f "$out" ] || continue
                echo ""
                echo "── $day/$jtype ($(wc -l < "$out") lines) ──"
                head -3 "$out" | while IFS=$'\t' read -r type question answer pattern _ _; do
                    echo "  [$type] $question"
                    echo "  → $answer"
                    echo ""
                done
            done
        done
    fi
fi
