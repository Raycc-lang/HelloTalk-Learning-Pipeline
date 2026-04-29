# Common helpers for HelloTalk pipeline scripts. Source this file (do not execute).

JUNK_MAX_BYTES=6

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
