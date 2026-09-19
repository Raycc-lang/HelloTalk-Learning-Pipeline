# Common helpers for HelloTalk pipeline scripts. Source this file (do not execute).

JUNK_MAX_BYTES=6

# Check that a merged transcript has assessable text (not blank or only
# pipeline markers). Replaces the old validate-analysis.py mechanism whose
# VERBATIM provenance check was removed — it guarded against LLM "corrections"
# of ASR errors, but that rejected legitimate edits and blocked generation.
source_has_text() {
    local merged="$1"
    [ -s "$merged" ] || return 1
    # Reject files that are only chunk markers / failure markers / whitespace.
    local compact
    compact=$(tr -d '[:space:]' < "$merged")
    [ -n "$compact" ] && [[ "$compact" != *"[ANALYSISFAILED"* ]]
}

# Extract YYYY-MM-DD from filename like hellotalk_mic_20260323_...
date_subdir() {
    local d="${1:14:8}"
    echo "${d:0:4}-${d:4:2}-${d:6:2}"
}

is_junk_file() {
    local file="$1"
    local size
    local compact
    size="$(wc -c < "$file")"
    compact="$(tr -d '[:space:]' < "$file")"
    [ "$size" -le "$JUNK_MAX_BYTES" ] || [ "$compact" = "." ] || [ -z "$compact" ]
}

# Strip helper-added chunk headers and failure markers from an analysis file so
# downstream prompts see only analysis content. hellotalk-llm-call.py inserts
# "--- Chunk N/M ---" whenever an input exceeds CHUNK_THRESHOLD; no consumer
# prompt defines those lines, so they must not reach one.
# Usage: sanitize_analysis_input <src> <dest>
sanitize_analysis_input() {
    local src="$1"
    local dest="$2"
    awk '!/^--- Chunk [0-9]+[/][0-9]+ ---$/ && !/\[ANALYSIS FAILED/' "$src" > "$dest"
}

# Fold a label value to a comparison key: lowercase, then drop every byte that
# is not an ASCII letter or digit. Punctuation is discarded rather than
# normalized, so the model's curly quotes and non-breaking hyphens compare equal
# to the straight ASCII a human types into prior-results.txt. Markdown
# decoration (**, *, #) and trailing spaces fall away for the same reason.
# Reads stdin, writes stdout.
normalize_label_key() {
    tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9\n'
}
