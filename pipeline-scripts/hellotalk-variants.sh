#!/usr/bin/env bash
# Multi-model variant generation for the HelloTalk pipeline.
# Source this file (do not execute) after hellotalk-provider-resolve.sh.
#
# Replaces a direct `python3 hellotalk-llm-call.py PROMPT INPUT OUTPUT` call
# with: generate the same output from two independently configured models, then
# have a third call reconcile the two candidates into the final artifact.
#
# The public entry point is:
#
#   hellotalk_generate <prompt_file> <input_file> <output_file> <kind> [label]
#
#   kind: analysis | tsv | drill   — selects the judge prompt and the
#                                    sanity check applied to the judge's output.
#   label: short string used in log lines and variant filenames (default: basename
#          of output_file without its extension).
#
# Exit status matches hellotalk-llm-call.py so existing caller `case $rc in`
# blocks keep working unchanged:
#   0 success   1 ordinary failure   2 quota (abort batch)   3 fatal API error
#
# When VARIANTS is not 1, or fewer than two slots are usable, this makes exactly
# one call with the caller's existing environment — identical to the old
# behavior, same cost.
#
# Cost warning: with VARIANTS=1 a single artifact costs three API calls
# (two generations + one reconciliation) instead of one.

: "${VARIANTS:=0}"
: "${VARIANT_SLOTS:=PRIMARY SECONDARY}"
: "${VARIANT_DIR_NAME:=variants}"
: "${VARIANT_KEEP:=1}"
: "${LLM_CALL:=$HOME/.local/bin/hellotalk-llm-call.py}"
: "${HARD_TIMEOUT:=2400}"
: "${JUDGE_PROMPT_DIR:=$HOME/Android/HelloTalkCapture}"

# hellotalk-llm-call.py chunks any input over this size. A chunked judge call
# would split the candidates apart mid-file and reconcile fragments, so the
# judge step is skipped rather than allowed to chunk.
: "${VARIANT_JUDGE_MAX_CHARS:=115000}"

# Logs go to stderr: _hv_usable_slots' stdout is captured by the caller, so a
# log line written to stdout would be read back as a slot name.
_hv_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [variants] $*" >&2; }

# ── Slot configuration ────────────────────────────────────────────────
# Each slot reads <SLOT>_PROVIDER / _MODEL / _API_BASE / _API_KEY /
# _REASONING_EFFORT / _MAX_TOKENS, falling back to the ambient
# PROVIDER / MODEL / ... so an unconfigured PRIMARY slot behaves exactly like
# the current single-model setup.

_hv_slot_value() {
    local slot="$1" field="$2" fallback="${3:-}"
    local var="${slot}_${field}"
    local value="${!var:-}"
    [ -n "$value" ] && { printf '%s' "$value"; return; }
    printf '%s' "$fallback"
}

# Resolve a slot into API_BASE / API_KEY without touching the caller's env.
# Prints "provider<TAB>model<TAB>base<TAB>key<TAB>effort<TAB>max_tokens", or
# nothing when the slot cannot be used.
#
# Only the first slot inherits the ambient configuration, so leaving it
# unconfigured reproduces today's single-model setup exactly — including an
# API_BASE or API_KEY set directly in the env file, which hellotalk-provider-
# resolve.sh deliberately preserves. Rebuilding those from the provider's own
# variables instead would silently bypass a proxy or custom endpoint.
#
# Every later slot must name its own model: inheriting there would generate both
# candidates from one model, which triples the cost and reconciles a model
# against its own habits.
_hv_resolve_slot() {
    local slot="$1"
    local provider model base key effort mtok
    local first_slot="${VARIANT_SLOTS%% *}"
    local amb_provider="" amb_model="" amb_base="" amb_key=""

    if [ "$slot" = "$first_slot" ]; then
        amb_provider="${PROVIDER:-google}"
        amb_model="${MODEL:-}"
        amb_base="${API_BASE:-}"
        amb_key="${API_KEY:-}"
    fi

    provider="$(_hv_slot_value "$slot" PROVIDER "$amb_provider")"
    model="$(_hv_slot_value "$slot" MODEL "$amb_model")"
    base="$(_hv_slot_value "$slot" API_BASE "$amb_base")"
    key="$(_hv_slot_value "$slot" API_KEY "$amb_key")"
    effort="$(_hv_slot_value "$slot" REASONING_EFFORT "${REASONING_EFFORT:-}")"
    # The output budget, unlike BASE/KEY, is a property of the request rather
    # than of the endpoint, so it falls back to the ambient MAX_TOKENS for
    # every slot: a slot whose model has a lower output cap names its own
    # budget here (SECONDARY_MAX_TOKENS=65536) instead of imposing a global cap
    # on the other models — or relying on the endpoint to clamp, which is what
    # turned one oversized ask into a 400 the caller cannot recover from.
    mtok="$(_hv_slot_value "$slot" MAX_TOKENS "${MAX_TOKENS:-}")"

    [ -n "$provider" ] || return 1

    # Fill base/key from the provider's own env vars when the slot did not
    # override them. Mirrors hellotalk-provider-resolve.sh.
    case "$provider" in
        google)
            : "${base:=${GOOGLE_API_BASE:-https://generativelanguage.googleapis.com/v1beta/openai}}"
            : "${key:=${GOOGLE_API_KEY:-}}"
            ;;
        nvidia)
            : "${base:=${NVIDIA_API_BASE:-https://integrate.api.nvidia.com/v1}}"
            : "${key:=${NVIDIA_API_KEY:-}}"
            ;;
        custom)
            : "${base:=${CUSTOM_API_BASE:-}}"
            : "${key:=${CUSTOM_API_KEY:-}}"
            ;;
        *)
            return 1
            ;;
    esac

    [ -n "$model" ] && [ -n "$base" ] && [ -n "$key" ] || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s' "$provider" "$model" "$base" "$key" "$effort" "$mtok"
}

# List the slots that are fully configured, in VARIANT_SLOTS order, skipping any
# slot that resolves to a provider and model an earlier slot already claimed.
# Two candidates from one model are two draws from the same distribution: they
# share their blind spots, so reconciling them costs three calls and corrects
# nothing.
_hv_usable_slots() {
    local slot spec provider model rest
    local -A seen=()

    for slot in $VARIANT_SLOTS; do
        spec="$(_hv_resolve_slot "$slot" 2>/dev/null)" || continue
        [ -n "$spec" ] || continue
        IFS=$'\t' read -r provider model rest <<< "$spec"
        if [ -n "${seen[$provider/$model]:-}" ]; then
            _hv_log "slot ${slot,,} resolves to the same model as ${seen[$provider/$model]} ($model) — skipping it."
            continue
        fi
        seen[$provider/$model]="${slot,,}"
        printf '%s\n' "$slot"
    done
}

# True when variant slots can carry the run on their own credentials.
# Callers preflight the ambient API_KEY before their first request; a
# configuration that supplies keys only per-slot is valid and must not be
# rejected by that check.
hellotalk_variants_ready() {
    [ "${VARIANTS:-0}" = "1" ] || return 1
    [ -n "$(_hv_usable_slots 2>/dev/null)" ]
}

# ── One generation call under a specific slot's model ─────────────────
# Args: slot prompt_file input_file output_file label
# Status is hellotalk-llm-call.py's, with 124 for timeout.
_hv_call_slot() {
    local slot="$1" prompt_file="$2" input_file="$3" output_file="$4" label="$5"
    local spec provider model base key effort mtok rc=0

    spec="$(_hv_resolve_slot "$slot")" || return 3
    IFS=$'\t' read -r provider model base key effort mtok <<< "$spec"

    _hv_log "$label: ${slot,,} model=$model provider=$provider"

    (
        export PROVIDER="$provider" MODEL="$model" API_BASE="$base" API_KEY="$key"
        if [ -n "$effort" ]; then
            export REASONING_EFFORT="$effort"
        fi
        if [ -n "$mtok" ]; then
            export MAX_TOKENS="$mtok"
        fi
        timeout "$HARD_TIMEOUT" python3 "$LLM_CALL" \
            "$prompt_file" "$input_file" "$output_file"
    ) || rc=$?

    return $rc
}

# ── Sanity checks on a generated artifact ─────────────────────────────
# Count the artifact's countable units: TSV cards, analysis entries, drill
# topics. Used both as a structural check (zero units = not this kind of file)
# and as a truncation check against the candidates.
#
# The patterns are deliberately loose about decoration, because real model
# output is: 8 of 122 live analysis files open with a prose preamble or a
# markdown heading before the first entry, and live drill files write
# "## Topic 1:" as often as "## Topic:". A check strict enough to reject those
# would reject good merges and quietly disable reconciliation.
_hv_count_units() {
    local file="$1" kind="$2"
    [ -s "$file" ] || { echo 0; return; }

    case "$kind" in
        tsv)
            awk -F'\t' 'NF==6 { n++ } END { print n+0 }' "$file"
            ;;
        analysis)
            # Count entries by whichever per-entry label the model actually used.
            # Some real files put the pattern name in a markdown heading and never
            # write a PATTERN NAME: label at all, so counting only that label reads
            # a perfectly good analysis as empty. Strip decoration, then take the
            # strongest signal among the labels that appear once per entry.
            awk '
                { l = tolower($0); gsub(/[*#>[:space:]]/, "", l) }
                l ~ /^patternname:/    { a++ }
                l ~ /^sub-?type:/      { b++ }
                l ~ /^cardtype:/       { c++ }
                l ~ /^originalphrase:/ { d++ }
                l ~ /^intent:/         { e++ }
                END {
                    m = a
                    if (b > m) m = b; if (c > m) m = c
                    if (d > m) m = d; if (e > m) m = e
                    print m + 0
                }
            ' "$file"
            ;;
        drill)
            grep -cE '^#{1,4}[ \t]+Topic' "$file" || true
            ;;
        *)
            wc -l < "$file"
            ;;
    esac
}

# Returns 0 when the file is usable as the final artifact.
#
# With a third argument (the best candidate's unit count) this also rejects a
# collapsed result: a judge that truncates, or returns two cards out of thirty,
# must not replace a complete candidate. Merging legitimately removes duplicates,
# so the floor is a fraction rather than parity.
: "${VARIANT_MIN_UNIT_PCT:=50}"

_hv_output_sane() {
    local file="$1" kind="$2" ref_units="${3:-0}"
    local units

    [ -s "$file" ] || return 1
    units=$(_hv_count_units "$file" "$kind")
    [ "$units" -gt 0 ] || return 1

    # A drill session needs its body, not just a topic heading.
    if [ "$kind" = "drill" ]; then
        grep -qE '^\*{0,2}(Source context|Target (structures|chunks)|Content skeleton|Drill instructions)' "$file" || return 1
    fi

    if [ "$ref_units" -gt 0 ]; then
        [ $(( units * 100 / ref_units )) -ge "$VARIANT_MIN_UNIT_PCT" ] || return 1
    fi
    return 0
}

# Echo the best candidate to fall back on: the first that passes its structural
# check, or failing that the one with the most units. Always taking candidate 1
# would hand back a malformed file while a good one sat next to it.
_hv_pick_fallback() {
    local kind="$1"; shift
    local f best="" best_units=-1 units

    for f in "$@"; do
        if _hv_output_sane "$f" "$kind"; then
            printf '%s' "$f"
            return 0
        fi
        units=$(_hv_count_units "$f" "$kind")
        if [ "$units" -gt "$best_units" ]; then
            best_units=$units
            best="$f"
        fi
    done
    printf '%s' "$best"
}

# ── Build the judge's user message ────────────────────────────────────
# Source material first, then each candidate inside a named delimiter. The
# judge prompt tells the model to treat everything inside the delimiters as
# data. with_source=0 drops the source material to fit the size budget.
_hv_build_judge_input() {
    local dest="$1" source_file="$2" with_source="$3"; shift 3
    local n=0 variant

    : > "$dest"
    if [ "$with_source" = "1" ]; then
        {
            printf '===== BEGIN SOURCE MATERIAL =====\n'
            cat "$source_file"
            printf '\n===== END SOURCE MATERIAL =====\n\n'
        } >> "$dest"
    fi

    for variant in "$@"; do
        n=$((n + 1))
        {
            printf '===== BEGIN CANDIDATE %d =====\n' "$n"
            cat "$variant"
            printf '\n===== END CANDIDATE %d =====\n\n' "$n"
        } >> "$dest"
    done
}

# ── Public entry point ────────────────────────────────────────────────
hellotalk_generate() {
    local prompt_file="$1" input_file="$2" output_file="$3" kind="$4"
    local label="${5:-$(basename "${output_file%.*}")}"
    local rc=0

    # Single-model path: exactly the old behavior, one call, caller's env.
    if [ "$VARIANTS" != "1" ]; then
        timeout "$HARD_TIMEOUT" python3 "$LLM_CALL" \
            "$prompt_file" "$input_file" "$output_file" || rc=$?
        return $rc
    fi

    local -a slots=()
    mapfile -t slots < <(_hv_usable_slots)

    if [ "${#slots[@]}" -lt 2 ]; then
        _hv_log "$label: only ${#slots[@]} slot(s) configured — single-model call."
        timeout "$HARD_TIMEOUT" python3 "$LLM_CALL" \
            "$prompt_file" "$input_file" "$output_file" || rc=$?
        return $rc
    fi

    # Callers that generate into a mktemp file set VARIANT_OUT_DIR to the real
    # destination directory, so kept variants land beside the finished artifact
    # instead of in /tmp.
    local variant_dir="${VARIANT_OUT_DIR:-$(dirname "$output_file")}/$VARIANT_DIR_NAME"
    mkdir -p "$variant_dir"

    # ── Generate one candidate per slot ───────────────────────────────
    local -a produced=()
    local slot slot_rc vfile ok=0
    local attempted=0 fatal=0 timedout=0
    for slot in "${slots[@]}"; do
        vfile="$variant_dir/${label}.${slot,,}"
        slot_rc=0
        attempted=$((attempted + 1))
        _hv_call_slot "$slot" "$prompt_file" "$input_file" "$vfile" "$label" || slot_rc=$?

        case $slot_rc in
            0)
                if [ -s "$vfile" ]; then
                    produced+=("$vfile")
                    ok=$((ok + 1))
                else
                    _hv_log "$label: ${slot,,} returned an empty file — dropping this candidate."
                fi
                ;;
            2)
                # Quota is a batch-level condition; propagate immediately so the
                # caller writes its sentinel and stops, same as before.
                _hv_log "$label: ${slot,,} hit quota."
                return 2
                ;;
            3)
                fatal=$((fatal + 1))
                _hv_log "$label: ${slot,,} hit a fatal API error — dropping this candidate."
                ;;
            124)
                timedout=$((timedout + 1))
                _hv_log "$label: ${slot,,} timed out after ${HARD_TIMEOUT}s — dropping this candidate."
                ;;
            *)
                _hv_log "$label: ${slot,,} failed (rc=$slot_rc) — dropping this candidate."
                ;;
        esac
    done

    if [ "$ok" -eq 0 ]; then
        # Preserve the failure class. A bad key or model ID is fatal for every
        # remaining artifact too, so it has to reach the caller's abort branch
        # rather than being retried once per day for the rest of the batch.
        if [ "$fatal" -eq "$attempted" ]; then
            _hv_log "$label: every slot failed fatally — aborting."
            return 3
        fi
        if [ "$timedout" -eq "$attempted" ]; then
            _hv_log "$label: every slot timed out."
            return 124
        fi
        _hv_log "$label: every candidate failed."
        return 1
    fi

    if [ "$ok" -eq 1 ]; then
        _hv_log "$label: only one candidate survived — using it without reconciliation."
        cp "${produced[0]}" "$output_file"
        [ "$VARIANT_KEEP" = "1" ] || rm -f "${produced[@]}"
        return 0
    fi

    # Best candidate to fall back on, and the unit count the reconciled file is
    # measured against.
    local fallback ref_units
    fallback="$(_hv_pick_fallback "$kind" "${produced[@]}")"
    ref_units=0
    local c u
    for c in "${produced[@]}"; do
        u=$(_hv_count_units "$c" "$kind")
        [ "$u" -gt "$ref_units" ] && ref_units=$u
    done

    # ── Reconcile ─────────────────────────────────────────────────────
    local judge_prompt="$JUDGE_PROMPT_DIR/judge-${kind}.md"
    if [ ! -s "$judge_prompt" ]; then
        _hv_log "$label: no judge prompt at $judge_prompt — using $(basename "$fallback")."
        cp "$fallback" "$output_file"
        return 0
    fi

    local judge_input judge_out judge_rc=0 size
    judge_input=$(mktemp)
    judge_out=$(mktemp)

    _hv_build_judge_input "$judge_input" "$input_file" 1 "${produced[@]}"
    size=$(wc -c < "$judge_input")
    if [ "$size" -gt "$VARIANT_JUDGE_MAX_CHARS" ]; then
        _hv_log "$label: judge input ${size} chars — retrying without the source material."
        _hv_build_judge_input "$judge_input" "$input_file" 0 "${produced[@]}"
        size=$(wc -c < "$judge_input")
    fi

    if [ "$size" -gt "$VARIANT_JUDGE_MAX_CHARS" ]; then
        _hv_log "$label: candidates alone are ${size} chars, over the judge budget — using $(basename "$fallback") unreconciled."
        cp "$fallback" "$output_file"
        rm -f "$judge_input" "$judge_out"
        return 0
    fi

    local judge_slot="JUDGE"
    _hv_resolve_slot JUDGE >/dev/null 2>&1 || judge_slot="${slots[0]}"

    _hv_log "$label: reconciling ${ok} candidates (${size} chars)."
    _hv_call_slot "$judge_slot" "$judge_prompt" "$judge_input" "$judge_out" "$label-judge" || judge_rc=$?

    if [ $judge_rc -eq 2 ]; then
        # Do not promote a candidate here. The caller is about to abort the
        # batch and deletes its temporary output first, so a copy would be
        # discarded anyway — but even if it survived, an unreconciled file
        # written to the final path would then be newer than its input, and the
        # freshness check would skip this day on every later run. That would
        # lock in the unreconciled version permanently. Leaving the artifact
        # absent means the next run regenerates and reconciles it properly.
        rm -f "$judge_input" "$judge_out"
        _hv_log "$label: quota hit during reconciliation. Both candidates are kept in $variant_dir; the next run after quota resets will regenerate and reconcile."
        return 2
    fi

    if [ $judge_rc -ne 0 ] || ! _hv_output_sane "$judge_out" "$kind" "$ref_units"; then
        _hv_log "$label: reconciliation failed or returned an incomplete file — using $(basename "$fallback") instead."
        cp "$fallback" "$output_file"
        rm -f "$judge_input" "$judge_out"
        return 0
    fi

    mv "$judge_out" "$output_file"
    rm -f "$judge_input"
    [ "$VARIANT_KEEP" = "1" ] || rm -f "${produced[@]}"
    _hv_log "$label: reconciled -> $(wc -c < "$output_file") bytes"
    return 0
}
