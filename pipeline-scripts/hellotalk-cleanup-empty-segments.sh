#!/usr/bin/env bash
set -euo pipefail

TRANSCRIPT_DIR="$HOME/Android/HelloTalkCapture/Transcripts"
FAILED_DIR_PRIMARY="$HOME/Android/HelloTalkCapture/Failed_transcription"
FAILED_DIR_FALLBACK="$HOME/.local/share/hellotalk/Failed_transcription"
FAILED_DIRS=("$FAILED_DIR_PRIMARY" "$FAILED_DIR_FALLBACK")
LOG_TAG="cleanup-empty-segments"
JUNK_MAX_BYTES=6
QUIET=false

if [ "${1:-}" = "--quiet" ]; then
    QUIET=true
fi

log() {
    if ! $QUIET; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"
    fi
}

is_junk_file() {
    local file="$1"
    local size
    local compact
    size="$(wc -c < "$file")"
    compact="$(tr -d '[:space:]' < "$file")"
    [ "$size" -le "$JUNK_MAX_BYTES" ] || [ "$compact" = "." ] || [ -z "$compact" ]
}

if [ ! -d "$TRANSCRIPT_DIR" ]; then
    log "Transcript directory not found: $TRANSCRIPT_DIR"
    exit 0
fi

scanned=0
deleted_txt=0
deleted_failed_wav=0

shopt -s nullglob
for seg_file in "$TRANSCRIPT_DIR"/*_[0-9][0-9][0-9].txt; do
    [ -f "$seg_file" ] || continue
    scanned=$((scanned + 1))

    if ! is_junk_file "$seg_file"; then
        continue
    fi

    base_name="$(basename "$seg_file" .txt)"
    wav_name="${base_name}.wav"

    rm -f "$seg_file"
    deleted_txt=$((deleted_txt + 1))
    log "Deleted junk segment transcript: $seg_file"

    for failed_root in "${FAILED_DIRS[@]}"; do
        [ -d "$failed_root" ] || continue
        for candidate in "$failed_root"/*/"$wav_name"; do
            [ -f "$candidate" ] || continue
            rm -f "$candidate"
            deleted_failed_wav=$((deleted_failed_wav + 1))
            log "Deleted matching failed wav: $candidate"
        done
    done
done
shopt -u nullglob

echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] Summary: scanned=$scanned deleted_txt=$deleted_txt deleted_failed_wav=$deleted_failed_wav threshold_bytes=$JUNK_MAX_BYTES"
