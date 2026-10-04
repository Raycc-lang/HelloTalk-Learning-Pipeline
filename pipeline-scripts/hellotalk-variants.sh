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
# Candidate slots exclude JUDGE. Validated requests are cached, and failures
# leave the artifact pending for a later retry. VARIANTS=0 uses the ambient model.
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
        [ "$slot" = JUDGE ] && continue
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
    IFS='|' read -r provider model base key effort mtok <<< "${spec//$'\t'/|}"

    _hv_log "$label: ${slot,,} model=$model provider=$provider"

    (
        export PROVIDER="$provider" MODEL="$model" API_BASE="$base" API_KEY="$key"
        if [ -n "$effort" ]; then
            export REASONING_EFFORT="$effort"
        fi
        if [ -n "$mtok" ]; then
            export MAX_TOKENS="$mtok"
        fi
        . "$HOME/.local/bin/hellotalk-quota-check.sh" || exit 1
        hellotalk_quota_check || exit 2
        local remaining=$(( ${HV_ARTIFACT_DEADLINE:-$(($(date +%s) + HARD_TIMEOUT))} - $(date +%s) ))
        [ "$remaining" -gt 0 ] || exit 124
        [ "$remaining" -le "$HARD_TIMEOUT" ] || remaining="$HARD_TIMEOUT"
        timeout "$remaining" python3 "$LLM_CALL" \
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
            _hv_tsv_filter "$file" count
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
            awk '/^#{1,4}[ \t]+Topic/ {n++} END {print n+0}' "$file"
            ;;
        *)
            wc -l < "$file"
            ;;
    esac
}

# Required fields follow the two installed card schemas. Pattern/Contrast and
# WatchOut/OriginalPhrase may be empty, as the prompts explicitly allow.
_hv_tsv_filter() {
    awk -F'\t' -v mode="${2:-filter}" '
    NF==6 {
        ok=($1 ~ /[^[:space:]]/ && $2 ~ /[^[:space:]]/ && $3 ~ /[^[:space:]]/)
        if ($1 == "FILL IN THE BLANK" || $1 == "CORRECT THE ERROR") ok=ok && ($6 ~ /[^[:space:]]/)
        else if ($1 == "ERROR CORRECTION" || $1 == "COLLOCATION COMPLETION" || $1 == "IDIOM UPGRADE" || $1 == "PATTERN COMPLETION") ok=ok && ($4 ~ /[^[:space:]]/)
        else ok=0
        if(ok) {n++; if(mode != "count") print}
    }
    END {if(mode == "count") print n+0}' "$1"
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

    if [ "$kind" = tsv ]; then
        local total
        total=$(awk 'NF {n++} END {print n+0}' "$file") || return 1
        [ $((units * 100 / total)) -ge "${TSV_MIN_VALID_PCT:-90}" ] || return 1
    fi
    ! grep -q '\[ANALYSIS FAILED' "$file" || return 1

    # A drill session needs its body, not just a topic heading.
    if [ "$kind" = "drill" ]; then
        grep -qE '^\*{0,2}(Source context|Target (structures|chunks)|Content skeleton|Drill instructions)' "$file" || return 1
    fi

    if [ "$ref_units" -gt 0 ]; then
        [ $(( units * 100 / ref_units )) -ge "$VARIANT_MIN_UNIT_PCT" ] || return 1
    fi
    return 0
}

# ── Public entry point ────────────────────────────────────────────────
# Cache only validated immutable candidates. Fingerprint covers request settings;
# callers retain their existing freshness policy (model changes require force).
_hv_cache_key() {
    local spec
    spec=$(_hv_resolve_slot "$1") || return 3
    ( set -o pipefail; { printf '%s\n' "$spec" || exit 1; cat "$2" "$3" || exit 1; } | sha256sum | cut -d' ' -f1 )
}
_hv_build_judge_input_checked() {
    local dest="$1" source_file="$2" with_source="$3"; shift 3
    : > "$dest" || return 1
    if [ "$with_source" = 1 ]; then
        printf '===== BEGIN SOURCE MATERIAL =====\n' >> "$dest" || return 1
        cat "$source_file" >> "$dest" || return 1
        printf '\n===== END SOURCE MATERIAL =====\n' >> "$dest" || return 1
    fi
    local n=0 f
    for f in "$@"; do
        n=$((n+1))
        printf '\n===== BEGIN CANDIDATE %d =====\n' "$n" >> "$dest" || return 1
        cat "$f" >> "$dest" || return 1
        printf '\n===== END CANDIDATE %d =====\n' "$n" >> "$dest" || return 1
    done
}
hellotalk_generate() {
    local prompt_file="$1" input_file="$2" output_file="$3" kind="$4"
    local label="${5:-$(basename "${output_file%.*}")}"
    local HV_ARTIFACT_DEADLINE=$(( $(date +%s) + ${ARTIFACT_TIMEOUT:-$HARD_TIMEOUT} ))
    if [ -n "${BATCH_DEADLINE:-}" ] && [ "$BATCH_DEADLINE" -lt "$HV_ARTIFACT_DEADLINE" ]; then
        HV_ARTIFACT_DEADLINE="$BATCH_DEADLINE"
    fi
    local -a slots=() produced=()
    if [ "$VARIANTS" = 1 ]; then
        mapfile -t slots < <(_hv_usable_slots)
    fi
    if [ "${#slots[@]}" -eq 0 ]; then
        local AMBIENT_PROVIDER="${PROVIDER:-}" AMBIENT_MODEL="${MODEL:-}" AMBIENT_API_BASE="${API_BASE:-}" AMBIENT_API_KEY="${API_KEY:-}"
        local AMBIENT_REASONING_EFFORT="${REASONING_EFFORT:-}" AMBIENT_MAX_TOKENS="${MAX_TOKENS:-}"
        slots=(AMBIENT)
    fi
    local variant_dir="${VARIANT_OUT_DIR:-$(dirname "$output_file")}/$VARIANT_DIR_NAME"
    mkdir -p "$variant_dir" || return 1
    local slot key vfile tmp rc units ref_units=0 force_key=""
    if [ "${FORCE_REGEN:-0}" = 1 ]; then force_key=".force-$(date +%s%N)"; fi
    for slot in "${slots[@]}"; do
        key=$(_hv_cache_key "$slot" "$prompt_file" "$input_file") || return $?
        vfile="$variant_dir/${label}.${slot,,}.$key$force_key"
        if ! _hv_output_sane "$vfile" "$kind"; then
            tmp=$(mktemp "$variant_dir/.candidate.XXXXXX") || return 1
            rc=0
            _hv_call_slot "$slot" "$prompt_file" "$input_file" "$tmp" "$label" || rc=$?
            if [ "$rc" -ne 0 ]; then
                rm -f "$tmp" || return 1
                return "$rc"
            fi
            if ! _hv_output_sane "$tmp" "$kind"; then
                rm -f "$tmp" || return 1
                return 1
            fi
            mv "$tmp" "$vfile" || return 1
        else
            _hv_log "$label: cached ${slot,,} candidate"
        fi
        produced+=("$vfile")
        units=$(_hv_count_units "$vfile" "$kind") || return 1
        [ "$units" -le "$ref_units" ] || ref_units="$units"
    done
    local chosen="${produced[0]}"
    if [ "${#produced[@]}" -ge 2 ]; then
        local judge_prompt="$JUDGE_PROMPT_DIR/judge-${kind}.md" judge_slot=JUDGE judge_input size
        [ -s "$judge_prompt" ] || { _hv_log "Missing judge prompt: $judge_prompt"; return 1; }
        _hv_resolve_slot JUDGE >/dev/null || judge_slot="${slots[0]}"
        judge_input=$(mktemp "$variant_dir/.judge-input.XXXXXX") || return 1
        _hv_build_judge_input_checked "$judge_input" "$input_file" 1 "${produced[@]}" || return 1
        size=$(wc -c < "$judge_input") || return 1
        if [ "$size" -gt "$VARIANT_JUDGE_MAX_CHARS" ]; then
            _hv_build_judge_input_checked "$judge_input" "$input_file" 0 "${produced[@]}" || return 1
            size=$(wc -c < "$judge_input") || return 1
        fi
        if [ "$size" -gt "$VARIANT_JUDGE_MAX_CHARS" ]; then
            rm -f "$judge_input" || return 1
            return 1
        fi
        key=$(_hv_cache_key "$judge_slot" "$judge_prompt" "$judge_input") || return $?
        chosen="$variant_dir/${label}.judge.$key$force_key"
        if ! _hv_output_sane "$chosen" "$kind" "$ref_units"; then
            tmp=$(mktemp "$variant_dir/.judge.XXXXXX") || return 1
            rc=0
            _hv_call_slot "$judge_slot" "$judge_prompt" "$judge_input" "$tmp" "$label-judge" || rc=$?
            if [ "$rc" -ne 0 ]; then
                rm -f "$tmp" "$judge_input" || return 1
                return "$rc"
            fi
            if ! _hv_output_sane "$tmp" "$kind" "$ref_units"; then
                rm -f "$tmp" "$judge_input" || return 1
                return 1
            fi
            mv "$tmp" "$chosen" || return 1
        fi
        rm -f "$judge_input" || return 1
    fi
    tmp=$(mktemp "$(dirname "$output_file")/.publish.XXXXXX") || return 1
    cp "$chosen" "$tmp" || return 1
    mv "$tmp" "$output_file" || return 1
    if [ "$VARIANT_KEEP" != 1 ]; then
        rm -f "${produced[@]}" "$chosen" || return 1
    fi
    return 0
}
