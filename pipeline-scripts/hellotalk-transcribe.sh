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

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# ── Load env file ──────────────────────────────────────────────────
ENV_FILE="$HOME/.config/hellotalk/env"
if [ -f "$ENV_FILE" ]; then
    set -a && . "$ENV_FILE" && set +a
fi

# shellcheck source=/dev/null
. "$HOME/.local/bin/hellotalk-common.sh"

mkdir -p "$TRANSCRIBED_DIR" "$TRANSCRIPT_DIR" "$TRANSCRIPT_DIR/.rejected"
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

PYTHON_CLIENT_CACHE="$HOME/.cache/hellotalk/transcribe_file_offline.py"
PYTHON_CLIENT_URL="https://raw.githubusercontent.com/nvidia-riva/python-clients/main/scripts/asr/transcribe_file_offline.py"
PYTHON_CLIENT="${PYTHON_CLIENT:-$PYTHON_CLIENT_CACHE}"
NVIDIA_SERVER="grpc.nvcf.nvidia.com:443"
NVIDIA_FUNCTION_ID="b702f636-f60c-4a3d-a6f4-f3568c13bd7d"

if [ ! -s "$PYTHON_CLIENT" ]; then
    log "NVIDIA client not found at $PYTHON_CLIENT; downloading from upstream..."
    mkdir -p "$(dirname "$PYTHON_CLIENT")"
    client_tmp=$(mktemp "$(dirname "$PYTHON_CLIENT")/.client.XXXXXX")
    if curl -fsSL --connect-timeout 15 "$PYTHON_CLIENT_URL" -o "$client_tmp" && [ -s "$client_tmp" ] && python3 - "$client_tmp" <<'VALIDATE_CLIENT'
import ast, sys
from pathlib import Path
ast.parse(Path(sys.argv[1]).read_text())
VALIDATE_CLIENT
    then
        chmod +x "$client_tmp"
        mv "$client_tmp" "$PYTHON_CLIENT"
        log "Downloaded Riva client to $PYTHON_CLIENT"
    else
        rm -f "$client_tmp"
        log "ERROR: failed to download Riva client from $PYTHON_CLIENT_URL"
        exit 1
    fi
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

# Recover legacy service failures automatically; permanent audio rejection stays separate.
for failed_root in "${FAILED_DIR_ROOTS[@]}"; do
    for reason in auth_error network_error rate_limit grpc_error; do
        shopt -s nullglob
        for old in "$failed_root/$reason"/*.wav; do
            [ ! -e "$PROCESSED_DIR/$(basename "$old")" ] || continue
            mkdir -p "$PROCESSED_DIR"
            mv "$old" "$PROCESSED_DIR/"
        done
        shopt -u nullglob
    done
done
shopt -s nullglob
wav_files=("$PROCESSED_DIR"/*.wav)
shopt -u nullglob

success=0
fail=0
prefiltered=0

if [ ${#wav_files[@]} -gt 0 ]; then
log "Found ${#wav_files[@]} segment(s) to transcribe."

for wav in "${wav_files[@]}"; do
    base="$(basename "$wav" .wav)"
    txt_file="$TRANSCRIPT_DIR/${base}.txt"

    # New recordings are visible only after process-audio publishes its manifest.
    recording="${base%_[0-9][0-9][0-9]}"
    if [ -f "$PROCESSED_DIR/$recording.building" ]; then
        fail=$((fail + 1))
        continue
    fi
    if [ -f "$wav.retry" ]; then
        read -r retry_at < "$wav.retry"
        if [[ "$retry_at" =~ ^[0-9]+$ ]] && [ "$retry_at" -gt "$(date +%s)" ]; then
            fail=$((fail + 1))
            continue
        fi
    fi
    if [ -s "$txt_file" ] && ! is_junk_file "$txt_file"; then
        log "Skipping $base (already transcribed), moving audio."
        date_dir="$(date_subdir "$base")"
        mkdir -p "$TRANSCRIBED_DIR/$date_dir"
        mv "$wav" "$TRANSCRIBED_DIR/$date_dir/"
        continue
    fi

    pre_reason=""
    if pre_reason="$(prefilter_reason "$wav")"; then
        log "Pre-filter rejected $base ($pre_reason); deleting segment before API call."
        printf '%s\n' "$pre_reason" > "$TRANSCRIPT_DIR/.rejected/$base"
        rm -f "$wav" "$wav.retry"
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

        if [ "$last_exit_code" -eq 0 ] && [ -n "$transcript" ]; then
            if [ "$attempt" -gt 1 ]; then
                log "  Succeeded on attempt $attempt/$MAX_NETWORK_RETRIES."
            fi
            break
        fi

        transcript=""
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
        if [[ "$failure_type" = invalid_audio || "$failure_type" = no_speech ]]; then
            move_to_failed "$wav" "$failure_type"
            printf '%s\n' "$failure_type" > "$TRANSCRIPT_DIR/.rejected/$base"
        else
            printf '%s\n' "$(( $(date +%s) + ${TRANSCRIBE_RETRY_SECONDS:-600} ))" > "$wav.retry.tmp"
            mv "$wav.retry.tmp" "$wav.retry"
            fail=$((fail + 1))
            # An exhausted shared service failure applies to the whole batch.
            log "Provider failure; input remains pending. Stopping batch."
            break
        fi
        continue
    fi

    if is_junk_text "$transcript"; then
        log "  Junk transcript for $base (<= ${JUNK_MAX_BYTES} bytes / whitespace / dot-only); deleting audio segment."
        printf 'junk\n' > "$TRANSCRIPT_DIR/.rejected/$base"
        rm -f "$wav" "$wav.retry"
        continue
    fi

    tmp_txt=$(mktemp "$TRANSCRIPT_DIR/.transcript.XXXXXX")
    printf '%s\n' "$transcript" > "$tmp_txt"
    ! is_junk_file "$tmp_txt"
    mv "$tmp_txt" "$txt_file"
    rm -f "$wav.retry" "$TRANSCRIPT_DIR/.rejected/$base"
    date_dir="$(date_subdir "$base")"
    mkdir -p "$TRANSCRIBED_DIR/$date_dir"
    mv "$wav" "$TRANSCRIBED_DIR/$date_dir/"
    log "Done: $base -> $(wc -c < "$txt_file") bytes"
    success=$((success + 1))
done

log "Finished. Transcribed: $success, Failed: $fail, Pre-filtered: $prefiltered"
else
    log "No files to transcribe."
fi

# Publish recording only after all manifest segments have a terminal status.
python3 "$HOME/.local/bin/hellotalk-merge-recordings.py" "$PROCESSED_DIR" "$TRANSCRIBED_DIR" "$TRANSCRIPT_DIR" || fail=$((fail+1))
[ "$fail" -eq 0 ]
