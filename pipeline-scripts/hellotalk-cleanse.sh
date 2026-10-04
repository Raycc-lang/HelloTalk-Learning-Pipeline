#!/usr/bin/env bash
set -euo pipefail

# ── Directories ──────────────────────────────────────────────────────
TRANSCRIPT_DIR="$HOME/Android/HelloTalkCapture/Transcripts"
CLEANED_DIR="$HOME/Android/HelloTalkCapture/Cleaned_Transcripts"
CLEANSED_ORIGINALS_DIR="$HOME/Android/HelloTalkCapture/Cleansed_Originals"
TRANSCRIBED_DIR="$HOME/Android/HelloTalkCapture/Transcribed_audio"
CONFIG_FILE="$HOME/.config/hellotalk/cleanse.conf"
LOG_TAG="hellotalk-cleanse"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-common.sh"

mkdir -p "$CLEANED_DIR"
filter_grep() {
    local rc=0
    grep "$@" || rc=$?
    [ "$rc" -le 1 ]
}
filter_fingerprint=$( { cat "$CONFIG_FILE" 2>/dev/null || [ ! -e "$CONFIG_FILE" ]; cat "$0"; } | sha256sum)


delete_matching_audio() {
    local transcript_base="$1"
    local stem="${transcript_base%.txt}"
    local date_dir
    local wav

    date_dir="$(date_subdir "$transcript_base")"
    local deleted=1
    wav="$TRANSCRIBED_DIR/$date_dir/${stem}.wav"
    if [ -f "$wav" ]; then
        rm -f "$wav"
        deleted=0
    fi
    # Merged recording transcripts have no single <stem>.wav; their audio lives
    # as per-segment wavs <stem>_001.wav, _002.wav, … in the same date dir.
    local seg_wav
    for seg_wav in "$TRANSCRIBED_DIR/$date_dir/${stem}_"[0-9][0-9][0-9].wav; do
        [ -f "$seg_wav" ] || continue
        rm -f "$seg_wav"
        deleted=0
    done
    return $deleted
}

# ── Load blocklist from config ───────────────────────────────────────
# Config file format: one keyword/regex per line, lines starting with # are comments.
# Example:
#   John
#   \b\d{11}\b
#   my\.email@example\.com
BLOCKLIST_PATTERNS=()
if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        BLOCKLIST_PATTERNS+=("$line")
    done < "$CONFIG_FILE"
    log "Loaded ${#BLOCKLIST_PATTERNS[@]} blocklist pattern(s) from $CONFIG_FILE"
else
    log "No config file at $CONFIG_FILE — skipping privacy filter (create it to add patterns)."
fi

# ── Build combined grep pattern for blocklist ────────────────────────
BLOCKLIST_REGEX=""
if [ ${#BLOCKLIST_PATTERNS[@]} -gt 0 ]; then
    BLOCKLIST_REGEX=$(printf "%s\n" "${BLOCKLIST_PATTERNS[@]}" | paste -sd'|')
fi

# ── Filler / noise patterns (lines matching these entirely are dropped) ──
# Single filler words or very short noise fragments
NOISE_REGEX='^[[:space:]]*(uh+|um+|oh+|ah+|hm+|hmm+|mhm+|huh|wow|okay|ok|yeah|yep|yes|no|nah|right|sure|so|and|but|well|like|just|woo+|ha(ha)*)[[:space:]]*$'

# ── ASR artifact patterns (Whisper hallucinations) ───────────────────
# Repeated identical phrases, "Thank you for watching", music tags, etc.
ARTIFACT_PATTERNS=(
    '^\[.*\]$'                           # [Music], [Applause], etc.
    '^(thank you for watching|thanks for watching)'
    '^(subscribe|like and subscribe)'
    '^\.\.\.*$'                          # Just dots
)
ARTIFACT_REGEX=$(printf "%s\n" "${ARTIFACT_PATTERNS[@]}" | paste -sd'|')

# Validate regexes before touching any source or destination.
for regex in "$NOISE_REGEX" "$ARTIFACT_REGEX" "$BLOCKLIST_REGEX"; do
    filter_grep -E "$regex" </dev/null >/dev/null || exit 1
done

# ── Process transcripts ─────────────────────────────────────────────
shopt -s nullglob
txt_files=("$CLEANSED_ORIGINALS_DIR"/????-??-??/*.txt "$TRANSCRIPT_DIR"/*.txt)
shopt -u nullglob

success=0
skipped=0
predeleted=0
postdeleted=0
audio_deleted=0

if [ ${#txt_files[@]} -gt 0 ]; then
    log "Found ${#txt_files[@]} transcript(s) to process."

    # Brute-force pre-clean: drop obvious junk before expensive cleansing.
    for src in "${txt_files[@]}"; do
        [ -f "$src" ] || continue
        [[ "$(basename "$src")" =~ _[0-9]{3}\.txt$ ]] && continue
        if is_junk_file "$src"; then
            rm -f "$src"
            predeleted=$((predeleted + 1))
            if delete_matching_audio "$(basename "$src")"; then
                audio_deleted=$((audio_deleted + 1))
            fi
            log "Pre-deleted junk transcript: $(basename "$src")"
        fi
    done

    # Refresh list after pre-clean.
    shopt -s nullglob
    txt_files=("$CLEANSED_ORIGINALS_DIR"/????-??-??/*.txt "$TRANSCRIPT_DIR"/*.txt)
    shopt -u nullglob

for src in "${txt_files[@]}"; do
    base="$(basename "$src")"
    # Skip transcribe-internal per-segment files (<base>_NNN.txt). transcribe.sh
    # retains these immutable inputs for recording rebuilds. Only the complete
    # recording is cleansed so segment content is not counted twice.
    [[ "$base" =~ _[0-9]{3}\.txt$ ]] && continue
    if [ "$src" = "$TRANSCRIPT_DIR/$base" ] && { [ -f "${src%.txt}.complete.json" ] || [ -f "$HOME/Android/HelloTalkCapture/Processed_audio/${base%.txt}.segments" ]; }; then
        python3 - "$src" "${src%.txt}.complete.json" <<'CHECK'
import hashlib, json, sys
from pathlib import Path
s, m = map(Path, sys.argv[1:])
if hashlib.sha256(s.read_bytes()).hexdigest() != json.loads(m.read_text())['sha256']:
    sys.exit(1)
CHECK
    fi
    date_dir="$(date_subdir "$base")"
    dest_dir="$CLEANED_DIR/$date_dir"
    mkdir -p "$dest_dir"
    dest="$dest_dir/$base"

    # Skip if already cleansed (output exists and is newer than source)
    if [ -f "$dest.filter" ] && [ "$(cat "$dest.filter")" = "$filter_fingerprint" ] && [ "$dest.filter" -nt "$src" ]; then
        log "Skipping $base (already cleansed)."
        ((skipped++)) || true
        continue
    fi

    log "Cleansing $base..."

    # Pipeline:
    #   1. Remove blank/whitespace-only lines
    #   2. Remove pure filler/noise lines (case-insensitive)
    #   3. Remove ASR artifact lines (case-insensitive)
    #   4. Remove repetition hallucinations (phrase repeated 4+ times)
    #   5. Remove short lines (≤3 words)
    #   6. Strip leading/trailing whitespace per line
    #   7. Collapse multiple consecutive blank lines into one
    tmpfile=$(mktemp "$dest_dir/.cleanse.XXXXXX")

    cat "$src" \
        | sed '/^[[:space:]]*$/d' \
        | filter_grep -viE "$NOISE_REGEX" \
        | filter_grep -viE "$ARTIFACT_REGEX" \
        | python3 -c "
import re, sys, unicodedata
def is_english(line):
    \"\"\"Return True if the line is predominantly English/ASCII text.\"\"\"
    if not line.strip():
        return False
    # Count characters by script category
    latin = 0
    non_latin = 0
    for ch in line:
        if ch.isspace() or ch in '.,;:!?\"\x27-()[]{}…':
            continue
        cat = unicodedata.category(ch)
        name = unicodedata.name(ch, '')
        if ch.isascii() or 'LATIN' in name:
            latin += 1
        elif cat.startswith(('L', 'N')):
            non_latin += 1
    total = latin + non_latin
    if total == 0:
        return False
    return latin / total >= 0.5

for line in sys.stdin:
    line = line.rstrip('\n')
    # Drop lines where a 1-5 word phrase repeats 4+ times consecutively
    if re.search(r'(\b\w+(?:\s+\w+){0,4})\s+(?:\1\s*){3,}', line, re.IGNORECASE):
        continue
    # Drop non-English lines (Chinese, Hindi, etc.)
    if not is_english(line):
        continue
    print(line)
" \
        | awk 'NF > 3' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | cat -s \
        > "$tmpfile"

    # Apply blocklist if patterns exist
    if [ -n "$BLOCKLIST_REGEX" ]; then
        filter_grep -viE "$BLOCKLIST_REGEX" "$tmpfile" > "${tmpfile}.2"
        mv "${tmpfile}.2" "$tmpfile"
    fi

    # Only write output if there's content left
    line_count=$(wc -l < "$tmpfile")
    if [ "$line_count" -gt 0 ]; then
        mv "$tmpfile" "$dest"
        orig_dir="$CLEANSED_ORIGINALS_DIR/$date_dir"
        mkdir -p "$orig_dir"
        [ "$src" = "$orig_dir/$base" ] || mv "$src" "$orig_dir/$base"
        postdeleted=$((postdeleted + 1))
        if delete_matching_audio "$base"; then
            audio_deleted=$((audio_deleted + 1))
        fi
        log "Done: $base — $line_count lines (source archived to Cleansed_Originals)"
        ((success++)) || true
    else
        rm -f "$tmpfile" "$dest"
        orig_dir="$CLEANSED_ORIGINALS_DIR/$date_dir"
        mkdir -p "$orig_dir"
        [ "$src" = "$orig_dir/$base" ] || mv "$src" "$orig_dir/$base"
        postdeleted=$((postdeleted + 1))
        if delete_matching_audio "$base"; then
            audio_deleted=$((audio_deleted + 1))
        fi
        log "Deleted: $base — empty after cleansing (source archived to Cleansed_Originals)."
    fi
    printf '%s\n' "$filter_fingerprint" > "$dest.filter.tmp"
    mv "$dest.filter.tmp" "$dest.filter"
done

log "Finished. Cleansed: $success, Skipped: $skipped, Pre-deleted junk: $predeleted, Post-deleted sources: $postdeleted, Matching audio deleted: $audio_deleted"
fi
