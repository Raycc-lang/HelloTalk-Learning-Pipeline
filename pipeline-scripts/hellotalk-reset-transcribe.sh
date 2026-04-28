#!/usr/bin/env bash
set -euo pipefail

# Reset transcription pipeline for all audio dated 2026-04-10 and later.
# Moves transcribed audio back to Processed_audio/ and archives all
# downstream outputs (transcripts, cleaned transcripts, analysis, Anki)
# to Archives/ instead of deleting them.

BASE="$HOME/Android/HelloTalkCapture"
PROCESSED_DIR="$BASE/Processed_audio"
TRANSCRIBED_DIR="$BASE/Transcribed_audio"
TRANSCRIPT_DIR="$BASE/Transcripts"
CLEANED_DIR="$BASE/Cleaned_Transcripts"
CLEANSED_DIR="$BASE/Cleansed_Originals"
ANALYSIS_DIR="$BASE/Analysis"
ANKI_DIR="$BASE/Anki"
ARCHIVE_DIR="$BASE/Archives"

CUTOFF="2026-04-10"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [reset-transcribe] $*"; }

mkdir -p "$ARCHIVE_DIR"

# ── Step 1: Move audio files back to Processed_audio ─────────────────
log "Moving transcribed audio files (>= $CUTOFF) back to Processed_audio..."
moved=0
shopt -s nullglob
for date_dir in "$TRANSCRIBED_DIR"/????-??-??; do
    [ -d "$date_dir" ] || continue
    day="$(basename "$date_dir")"
    [[ "$day" < "$CUTOFF" ]] && continue

    for wav in "$date_dir"/*.wav; do
        [ -f "$wav" ] || continue
        mv "$wav" "$PROCESSED_DIR/"
        ((moved++)) || true
    done
done
shopt -u nullglob
log "Moved $moved audio file(s)."

# ── Step 2: Archive transcripts ──────────────────────────────────────
log "Archiving transcript files (>= $CUTOFF)..."
archived_transcripts=0
for txt in "$TRANSCRIPT_DIR"/*.txt; do
    [ -f "$txt" ] || continue
    base="$(basename "$txt" .txt)"
    date_str="${base:14:8}"
    [[ -z "$date_str" ]] && continue
    formatted="${date_str:0:4}-${date_str:4:2}-${date_str:6:2}"
    [[ "$formatted" < "$CUTOFF" ]] && continue
    dest_dir="$ARCHIVE_DIR/Transcripts/$formatted"
    mkdir -p "$dest_dir"
    mv "$txt" "$dest_dir/"
    ((archived_transcripts++)) || true
done
log "Archived $archived_transcripts transcript file(s)."

# ── Step 3: Archive cleaned transcripts ──────────────────────────────
log "Archiving cleaned transcript dirs (>= $CUTOFF)..."
archived_cleaned=0
shopt -s nullglob
for date_dir in "$CLEANED_DIR"/????-??-??; do
    [ -d "$date_dir" ] || continue
    day="$(basename "$date_dir")"
    [[ "$day" < "$CUTOFF" ]] && continue
    dest_dir="$ARCHIVE_DIR/Cleaned_Transcripts/$day"
    mkdir -p "$dest_dir"
    count=$(find "$date_dir" -name "*.txt" | wc -l)
    mv "$date_dir"/* "$dest_dir/" 2>/dev/null || true
    rmdir "$date_dir" 2>/dev/null || true
    archived_cleaned=$((archived_cleaned + count))
done
shopt -u nullglob
log "Archived $archived_cleaned cleaned transcript file(s)."

# ── Step 4: Archive cleansed originals ───────────────────────────────
log "Archiving cleansed original dirs (>= $CUTOFF)..."
archived_cleansed=0
shopt -s nullglob
for date_dir in "$CLEANSED_DIR"/????-??-??; do
    [ -d "$date_dir" ] || continue
    day="$(basename "$date_dir")"
    [[ "$day" < "$CUTOFF" ]] && continue
    dest_dir="$ARCHIVE_DIR/Cleansed_Originals/$day"
    mkdir -p "$dest_dir"
    count=$(find "$date_dir" -name "*.txt" | wc -l)
    mv "$date_dir"/* "$dest_dir/" 2>/dev/null || true
    rmdir "$date_dir" 2>/dev/null || true
    archived_cleansed=$((archived_cleansed + count))
done
shopt -u nullglob
log "Archived $archived_cleansed cleansed original file(s)."

# ── Step 5: Archive analysis outputs ─────────────────────────────────
log "Archiving analysis dirs (>= $CUTOFF)..."
archived_analysis=0
shopt -s nullglob
for date_dir in "$ANALYSIS_DIR"/????-??-??; do
    [ -d "$date_dir" ] || continue
    day="$(basename "$date_dir")"
    [[ "$day" < "$CUTOFF" ]] && continue
    dest_dir="$ARCHIVE_DIR/Analysis/$day"
    mkdir -p "$dest_dir"
    count=$(find "$date_dir" -type f | wc -l)
    mv "$date_dir"/* "$dest_dir/" 2>/dev/null || true
    rmdir "$date_dir" 2>/dev/null || true
    archived_analysis=$((archived_analysis + count))
done
shopt -u nullglob
log "Archived $archived_analysis analysis file(s)."

# ── Step 6: Archive Anki outputs ─────────────────────────────────────
log "Archiving Anki dirs (>= $CUTOFF)..."
archived_anki=0
shopt -s nullglob
for date_dir in "$ANKI_DIR"/????-??-??; do
    [ -d "$date_dir" ] || continue
    day="$(basename "$date_dir")"
    [[ "$day" < "$CUTOFF" ]] && continue
    dest_dir="$ARCHIVE_DIR/Anki/$day"
    mkdir -p "$dest_dir"
    count=$(find "$date_dir" -type f | wc -l)
    mv "$date_dir"/* "$dest_dir/" 2>/dev/null || true
    rmdir "$date_dir" 2>/dev/null || true
    archived_anki=$((archived_anki + count))
done
shopt -u nullglob
log "Archived $archived_anki Anki file(s)."

# ── Summary ──────────────────────────────────────────────────────────
log "=== Reset complete ==="
log "  Audio moved back to Processed_audio: $moved"
log "  Transcripts archived: $archived_transcripts"
log "  Cleaned transcripts archived: $archived_cleaned"
log "  Cleansed originals archived: $archived_cleansed"
log "  Analysis files archived: $archived_analysis"
log "  Anki files archived: $archived_anki"
log "  Archive location: $ARCHIVE_DIR"
log ""
log "Next step: run hellotalk-transcribe.sh to re-transcribe."
