#!/usr/bin/env bash
set -euo pipefail

PROCESSED_DIR="$HOME/Android/HelloTalkCapture/Processed_audio"
TRANSCRIBED_DIR="$HOME/Android/HelloTalkCapture/Transcribed_audio"
TRANSCRIPT_DIR="$HOME/Android/HelloTalkCapture/Transcripts"
FAILED_DIR_PRIMARY="$HOME/Android/HelloTalkCapture/Failed_transcription"
FAILED_DIR_FALLBACK="$HOME/.local/share/hellotalk/Failed_transcription"
FAILED_DIR="$FAILED_DIR_PRIMARY"
FAILED_DIR_ROOTS=("$FAILED_DIR_PRIMARY" "$FAILED_DIR_FALLBACK")
LOG_TAG="hellotalk-transcribe"
JUNK_MAX_BYTES=6

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# Extract YYYY-MM-DD from filename like hellotalk_mic_20260323_...
date_subdir() {
    local name="$1"
    local d="${name:14:8}"  # extract YYYYMMDD
    echo "${d:0:4}-${d:4:2}-${d:6:2}"
}

mkdir -p "$TRANSCRIBED_DIR" "$TRANSCRIPT_DIR"
if ! mkdir -p "$FAILED_DIR_PRIMARY" 2>/dev/null; then
    FAILED_DIR="$FAILED_DIR_FALLBACK"
fi
if [ "$FAILED_DIR" = "$FAILED_DIR_PRIMARY" ]; then
    probe_dir="$(mktemp -d "$FAILED_DIR_PRIMARY/.write_probe.XXXXXX" 2>/dev/null || true)"
    if [ -z "$probe_dir" ]; then
        FAILED_DIR="$FAILED_DIR_FALLBACK"
    else
        rmdir "$probe_dir" >/dev/null 2>&1 || true
    fi
fi
mkdir -p "$FAILED_DIR"

if [ -z "${NVIDIA_API_KEY:-}" ]; then
    log "ERROR: NVIDIA_API_KEY not set. Aborting."
    exit 1
fi

PYTHON_CLIENT="$HOME/Android/hellotalk_analysis/python-clients/scripts/asr/transcribe_file_offline.py"
NVIDIA_SERVER="grpc.nvcf.nvidia.com:443"
NVIDIA_FUNCTION_ID="b702f636-f60c-4a3d-a6f4-f3568c13bd7d"

if [ ! -f "$PYTHON_CLIENT" ]; then
    log "ERROR: NVIDIA client not found at $PYTHON_CLIENT"
    exit 1
fi

# ── Retry and failure classification ────────────────────────────────
MAX_NETWORK_RETRIES=3
RETRY_DELAY=5  # seconds between network retries
MIN_FILE_SIZE_BYTES=51200   # 50 KB
MIN_DURATION_SEC=0.5
MIN_RMS_LINEAR=0.01
MIN_RMS_DB=-40  # 20*log10(0.01)

is_junk_text() {
    local text="$1"
    local size
    local compact
    size="$(printf '%s' "$text" | wc -c)"
    compact="$(printf '%s' "$text" | tr -d '[:space:]')"
    [ "$size" -le "$JUNK_MAX_BYTES" ] || [ "$compact" = "." ] || [ -z "$compact" ]
}

is_junk_file() {
    local file="$1"
    local size
    local content
    size="$(wc -c < "$file")"
    content="$(tr -d '[:space:]' < "$file")"
    [ "$size" -le "$JUNK_MAX_BYTES" ] || [ "$content" = "." ] || [ -z "$content" ]
}

get_duration_sec() {
    local wav="$1"
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$wav" 2>/dev/null || true
}

get_rms_db() {
    local wav="$1"
    ffmpeg -hide_banner -nostdin -i "$wav" -af astats=metadata=1:reset=0 -f null - 2>&1 \
        | awk -F': ' '
            /Overall RMS level dB/ {overall=$2}
            /RMS level dB/ {last=$2}
            END {
                if (overall != "") {
                    print overall
                } else if (last != "") {
                    print last
                }
            }'
}

prefilter_reason() {
    local wav="$1"
    local size
    local duration
    local rms_db

    size=$(wc -c < "$wav")
    if [ "$size" -lt "$MIN_FILE_SIZE_BYTES" ]; then
        echo "size_lt_50kb(${size}B)"
        return 0
    fi

    duration="$(get_duration_sec "$wav")"
    if [ -n "$duration" ] && awk -v d="$duration" -v min="$MIN_DURATION_SEC" 'BEGIN { exit !(d < min) }'; then
        echo "duration_lt_${MIN_DURATION_SEC}s(${duration}s)"
        return 0
    fi

    rms_db="$(get_rms_db "$wav")"
    if [ -n "$rms_db" ]; then
        if [ "$rms_db" = "-inf" ] || [ "$rms_db" = "inf" ]; then
            echo "rms_silence(${rms_db})"
            return 0
        fi
        if awk -v db="$rms_db" -v min_db="$MIN_RMS_DB" 'BEGIN { exit !(db < min_db) }'; then
            echo "rms_lt_${MIN_RMS_LINEAR}(${rms_db}dB)"
            return 0
        fi
    fi

    return 1
}

classify_failure() {
    local output="$1"
    local exit_code="$2"

    if echo "$output" | grep -qiE '(unauthenticated|permission denied|permissiondenied|forbidden|invalid.*key|invalid.*token|authorization failed)'; then
        echo "auth_error"
    elif echo "$output" | grep -qiE '(connection refused|timeout|unavailable|dns|network|socket|ssl|certificate)'; then
        echo "network_error"
    elif echo "$output" | grep -qiE '(invalid file|cannot open|corrupt|invalid.*wav|malformed|input audio channel count must be 1|channel count must be 1)'; then
        echo "invalid_audio"
    elif echo "$output" | grep -qiE '(resource exhausted|quota|rate limit|too many)'; then
        echo "rate_limit"
    elif echo "$output" | grep -qiE '(grpc|rpc|internal|unknown error)'; then
        echo "grpc_error"
    elif [ -z "$output" ] && [ "$exit_code" -eq 0 ]; then
        echo "no_speech"
    else
        # Non-empty, unclassified errors should be treated as generic gRPC/API errors.
        echo "grpc_error"
    fi
}

move_to_failed() {
    local wav="$1"
    local reason="$2"
    local base
    base="$(basename "$wav")"
    local dest_dir="$FAILED_DIR/$reason"
    mkdir -p "$dest_dir"
    mv "$wav" "$dest_dir/$base"
    log "  Moved to $dest_dir/$base"
}

shopt -s nullglob
wav_files=("$PROCESSED_DIR"/*.wav)
shopt -u nullglob

if [ ${#wav_files[@]} -eq 0 ]; then
    log "No files to transcribe."
    exit 0
fi

log "Found ${#wav_files[@]} segment(s) to transcribe."

success=0
fail=0
prefiltered=0

for wav in "${wav_files[@]}"; do
    base="$(basename "$wav" .wav)"
    txt_file="$TRANSCRIPT_DIR/${base}.txt"

    if [ -f "$txt_file" ]; then
        log "Skipping $base (already transcribed), moving audio."
        date_dir="$(date_subdir "$base")"
        mkdir -p "$TRANSCRIBED_DIR/$date_dir"
        mv "$wav" "$TRANSCRIBED_DIR/$date_dir/"
        continue
    fi

    pre_reason=""
    if pre_reason="$(prefilter_reason "$wav")"; then
        log "Pre-filter rejected $base ($pre_reason); deleting segment before API call."
        rm -f "$wav"
        prefiltered=$((prefiltered + 1))
        continue
    fi

    log "Transcribing $base..."

    transcript=""
    last_output=""
    last_exit_code=0
    retried=false

    for attempt in $(seq 1 $MAX_NETWORK_RETRIES); do
        last_exit_code=0
        transcribe_output=$(
            python3 "$PYTHON_CLIENT" \
                --server "$NVIDIA_SERVER" \
                --use-ssl \
                --metadata function-id "$NVIDIA_FUNCTION_ID" \
                --metadata authorization "Bearer $NVIDIA_API_KEY" \
                --language-code multi \
                --automatic-punctuation \
                --input-file "$wav" 2>&1
        ) || last_exit_code=$?

        last_output="$transcribe_output"
        transcript=$(printf '%s\n' "$transcribe_output" | sed -n 's/^Final transcript:[[:space:]]*//p' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')

        if [ -n "$transcript" ]; then
            if [ "$attempt" -gt 1 ]; then
                log "  Succeeded on attempt $attempt/$MAX_NETWORK_RETRIES."
            fi
            break
        fi

        failure_type=$(classify_failure "$transcribe_output" "$last_exit_code")

        if [[ "$failure_type" == "no_speech" || "$failure_type" == "invalid_audio" || "$failure_type" == "auth_error" ]]; then
            break
        fi

        if [ "$attempt" -lt "$MAX_NETWORK_RETRIES" ]; then
            log "  Attempt $attempt/$MAX_NETWORK_RETRIES failed ($failure_type), retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
            retried=true
        fi
    done

    if [ -z "$transcript" ]; then
        failure_type=$(classify_failure "$last_output" "$last_exit_code")
        if $retried; then
            attempt_count="$MAX_NETWORK_RETRIES"
        else
            attempt_count="1"
        fi
        log "ERROR: Failed to transcribe $base (reason: $failure_type, attempts: $attempt_count/$MAX_NETWORK_RETRIES)."
        if [ -n "$last_output" ]; then
            log "  Last error: $(printf '%s\n' "$last_output" | tail -n 1)"
        fi
        move_to_failed "$wav" "$failure_type"
        fail=$((fail + 1))
        continue
    fi

    if is_junk_text "$transcript"; then
        log "  Junk transcript for $base (<= ${JUNK_MAX_BYTES} bytes / whitespace / dot-only); deleting audio segment."
        rm -f "$wav"
        fail=$((fail + 1))
        continue
    fi

    echo "$transcript" > "$txt_file"
    date_dir="$(date_subdir "$base")"
    mkdir -p "$TRANSCRIBED_DIR/$date_dir"
    mv "$wav" "$TRANSCRIBED_DIR/$date_dir/"
    log "Done: $base -> $(wc -c < "$txt_file") bytes"
    success=$((success + 1))
done

log "Finished. Transcribed: $success, Failed: $fail, Pre-filtered: $prefiltered"

# Cleanup junk segment files before merge to avoid polluting merged outputs.
if [ -x "$HOME/.local/bin/hellotalk-cleanup-empty-segments.sh" ]; then
    "$HOME/.local/bin/hellotalk-cleanup-empty-segments.sh" --quiet || true
fi

# Merge segment transcripts into per-recording files
log "Merging segment transcripts..."
shopt -s nullglob
seg_files=("$TRANSCRIPT_DIR"/*_[0-9][0-9][0-9].txt)
shopt -u nullglob

# Collect unique base names
declare -A bases
for f in "${seg_files[@]}"; do
    base=$(basename "$f" | sed 's/_[0-9]\{3\}\.txt$//')
    bases["$base"]=1
done
for failed_root in "${FAILED_DIR_ROOTS[@]}"; do
    [ -d "$failed_root" ] || continue
    shopt -s nullglob
    for wav in "$failed_root"/*/*_[0-9][0-9][0-9].wav; do
        base=$(basename "$wav" .wav | sed 's/_[0-9]\{3\}$//')
        bases["$base"]=1
    done
    shopt -u nullglob
done

if [ ${#bases[@]} -eq 0 ]; then
    log "No segments to merge."
    exit 0
fi

merged=0
skipped_incomplete=0
skipped_empty_only=0
for base in "${!bases[@]}"; do
    date_dir="$(date_subdir "$base")"
    merged_file="$TRANSCRIPT_DIR/${base}.txt"

    # Compute expected segment count from available audio segment indexes.
    # We consider pending segments (Processed_audio), completed ones
    # (Transcribed_audio/YYYY-MM-DD), and permanently failed ones
    # (Failed_transcription/*) to avoid producing partial merged output.
    max_seg=0
    shopt -s nullglob
    audio_candidates=(
        "$PROCESSED_DIR/${base}_"[0-9][0-9][0-9].wav
        "$TRANSCRIBED_DIR/$date_dir/${base}_"[0-9][0-9][0-9].wav
    )
    # Also count failed segments so they don't block merging.
    for failed_root in "${FAILED_DIR_ROOTS[@]}"; do
        [ -d "$failed_root" ] || continue
        for fail_dir in "$failed_root"/*/; do
            [ -d "$fail_dir" ] || continue
            audio_candidates+=("$fail_dir/${base}_"[0-9][0-9][0-9].wav)
        done
    done
    shopt -u nullglob
    for af in "${audio_candidates[@]}"; do
        seg_idx="${af##*_}"
        seg_idx="${seg_idx%.wav}"
        seg_num=$((10#$seg_idx))
        (( seg_num > max_seg )) && max_seg=$seg_num
    done

    # Fallback for legacy data where audio files were removed already.
    if [ "$max_seg" -eq 0 ]; then
        shopt -s nullglob
        txt_candidates=("$TRANSCRIPT_DIR/${base}_"[0-9][0-9][0-9].txt)
        shopt -u nullglob
        for tf in "${txt_candidates[@]}"; do
            seg_idx="${tf##*_}"
            seg_idx="${seg_idx%.txt}"
            seg_num=$((10#$seg_idx))
            (( seg_num > max_seg )) && max_seg=$seg_num
        done
    fi

    incomplete=false
    if [ "$max_seg" -gt 0 ]; then
        for ((i=1; i<=max_seg; i++)); do
            seg_name="${base}_$(printf '%03d' "$i").wav"
            seg_txt="$TRANSCRIPT_DIR/${base}_$(printf '%03d' "$i").txt"
            if [ -f "$seg_txt" ] && ! is_junk_file "$seg_txt"; then
                continue
            fi

            # Permanently failed segments should not block merge.
            failed_segment=false
            for failed_root in "${FAILED_DIR_ROOTS[@]}"; do
                [ -d "$failed_root" ] || continue
                for fail_dir in "$failed_root"/*; do
                    [ -d "$fail_dir" ] || continue
                    if [ -f "$fail_dir/$seg_name" ]; then
                        failed_segment=true
                        break
                    fi
                done
                if $failed_segment; then
                    break
                fi
            done

            if ! $failed_segment; then
                incomplete=true
                break
            fi
        done
    fi

    if $incomplete; then
        log "Skipping merge for $base (incomplete segments, waiting for retry)."
        skipped_incomplete=$((skipped_incomplete + 1))
        continue
    fi

    # Concatenate usable segment transcripts in order.
    # Keep per-segment .txt files so reruns can rebuild deterministically.
    tmp_merge="$(mktemp)"
    usable_segments=0
    if [ "$max_seg" -gt 0 ]; then
        for ((i=1; i<=max_seg; i++)); do
            seg_txt="$TRANSCRIPT_DIR/${base}_$(printf '%03d' "$i").txt"
            if [ ! -f "$seg_txt" ]; then
                continue
            fi
            if is_junk_file "$seg_txt"; then
                continue
            fi
            cat "$seg_txt" >> "$tmp_merge"
            usable_segments=$((usable_segments + 1))
        done
    fi

    if [ "$usable_segments" -eq 0 ]; then
        rm -f "$tmp_merge"
        log "Skipping merge for $base (all segments are junk/failed; no usable segment transcripts)."
        skipped_empty_only=$((skipped_empty_only + 1))
        continue
    fi

    mv "$tmp_merge" "$merged_file"
    log "Merged -> $base.txt ($(wc -l < "$merged_file") lines, usable_segments=$usable_segments, discovered_segments=$max_seg)"
    merged=$((merged + 1))
done

log "Merged $merged recording(s). Skipped incomplete: $skipped_incomplete, skipped all-junk: $skipped_empty_only"
