#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_DIR="$HOME/Android/HelloTalkCapture/Original_audio"
PROCESSED_DIR="$HOME/Android/HelloTalkCapture/Processed_audio"
INVALID_DIR="$HOME/Android/HelloTalkCapture/Invalid_audio"
LOG_TAG="hellotalk-process"
MIN_SEGMENT_SEC=2
SILENCE_THRESH="-35dB"
SILENCE_MIN_DUR=3  # seconds of silence before splitting

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# Get current date for filtering
CURRENT_DATE=$(date +%Y-%m-%d)

mkdir -p "$PROCESSED_DIR"
mkdir -p "$INVALID_DIR"

shopt -s nullglob
wav_files=("$ORIGINAL_DIR"/*.wav)
shopt -u nullglob

if [ ${#wav_files[@]} -eq 0 ]; then
    log "No files to process."
    exit 0
fi

log "Found ${#wav_files[@]} file(s) to process."

processed_ok=0
quarantined=0

for wav in "${wav_files[@]}"; do
    base="$(basename "$wav" .wav)"
    tmp_dir=$(mktemp -d)

    log "Processing $base..."

    # Filter out audio recorded on current date.
    # Prefer filename date (HelloTalk naming) because WAV creation_time metadata
    # is often absent. Fall back to metadata for non-standard filenames.
    recording_date=""
    if [[ "$base" =~ ^hellotalk_mic_([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{6}$ ]]; then
        recording_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    else
        recording_date=$(ffprobe -v error -show_entries format_tags=creation_time -of default=noprint_wrappers=1:nokey=1 "$wav" 2>/dev/null | cut -d'T' -f1 || true)
    fi
    if [ "$recording_date" = "$CURRENT_DATE" ]; then
        log "  Skipping file recorded today ($CURRENT_DATE), deleting..."
        rm -rf "$tmp_dir"
        rm "$wav"
        continue
    fi

    # Quarantine malformed audio files instead of aborting the full batch.
    if ! ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$wav" >/dev/null 2>&1; then
        quarantine_target="$INVALID_DIR/$(basename "$wav")"
        if [ -e "$quarantine_target" ]; then
            quarantine_target="$INVALID_DIR/${base}_$(date +%s).wav"
        fi
        mv "$wav" "$quarantine_target"
        rm -rf "$tmp_dir"
        log "  Quarantined invalid file -> $(basename "$quarantine_target")"
        ((quarantined++)) || true
        continue
    fi

    # Step 1: Denoise
    denoised="$tmp_dir/denoised.wav"
    if ! ffmpeg -i "$wav" -af "afftdn=nf=-25" "$denoised" -y -loglevel error; then
        quarantine_target="$INVALID_DIR/$(basename "$wav")"
        if [ -e "$quarantine_target" ]; then
            quarantine_target="$INVALID_DIR/${base}_$(date +%s).wav"
        fi
        mv "$wav" "$quarantine_target"
        rm -rf "$tmp_dir"
        log "  Denoise failed, quarantined -> $(basename "$quarantine_target")"
        ((quarantined++)) || true
        continue
    fi

    # Step 2: Detect silence boundaries
    silence_log=$(ffmpeg -i "$denoised" \
        -af "silencedetect=noise=${SILENCE_THRESH}:d=${SILENCE_MIN_DUR}" \
        -f null - 2>&1 | grep "silencedetect" || true)

    # Parse silence intervals into speech intervals
    duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$denoised")
    duration=${duration%.*}  # truncate to integer

    # Build array of speech segments: [start, end] pairs
    speech_starts=()
    speech_ends=()
    pos=0

    while IFS= read -r line; do
        if [[ "$line" == *"silence_start:"* ]]; then
            s_start=$(echo "$line" | grep -oP 'silence_start: \K[0-9.]+')
            if [ "$(echo "$s_start > $pos" | bc -l)" -eq 1 ]; then
                speech_starts+=("$pos")
                speech_ends+=("$s_start")
            fi
        elif [[ "$line" == *"silence_end:"* ]]; then
            pos=$(echo "$line" | grep -oP 'silence_end: \K[0-9.]+')
        fi
    done <<< "$silence_log"

    # Last speech segment (from last silence_end to file end)
    if [ "$(echo "$pos < $duration" | bc -l)" -eq 1 ]; then
        speech_starts+=("$pos")
        speech_ends+=("$duration")
    fi

    # Handle case where no silence was detected (entire file is speech)
    if [ ${#speech_starts[@]} -eq 0 ]; then
        speech_starts=(0)
        speech_ends=("$duration")
    fi

    # Step 3: Extract speech segments
    seg_num=0
    for i in "${!speech_starts[@]}"; do
        ss="${speech_starts[$i]}"
        se="${speech_ends[$i]}"
        seg_dur=$(echo "$se - $ss" | bc)

        # Skip segments shorter than minimum
        if [ "$(echo "$seg_dur < $MIN_SEGMENT_SEC" | bc -l)" -eq 1 ]; then
            continue
        fi

        seg_num=$((seg_num + 1))
        out="$PROCESSED_DIR/${base}_$(printf '%03d' $seg_num).wav"
        ffmpeg -i "$denoised" -ss "$ss" -t "$seg_dur" -c copy "$out" -y -loglevel error
    done

    rm -rf "$tmp_dir"

    if [ "$seg_num" -eq 0 ]; then
        log "  No speech segments found, discarding."
    else
        log "  Extracted $seg_num segment(s)."
        ((processed_ok++)) || true
    fi

    rm "$wav"
    log "  Deleted original."
done

log "Done. Processed: $processed_ok, Quarantined: $quarantined"
