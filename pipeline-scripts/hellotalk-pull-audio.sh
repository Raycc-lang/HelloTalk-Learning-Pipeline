#!/usr/bin/env bash
set -euo pipefail

ADB="/usr/bin/adb"
DEVICE="${DEVICE:-}"                          # allow env override
REMOTE_DIR="/data/data/com.hellotalk/files/HelloTalkCapture"
STAGING_DIR="/sdcard/HelloTalkCapture"
LOCAL_DIR="$HOME/Android/HelloTalkCapture/Original_audio"
LOG_TAG="hellotalk-pull"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# Ensure local destination exists
mkdir -p "$LOCAL_DIR"

# Resolve device dynamically: use any already-connected network ADB device,
# otherwise fall back to the auto-connect script's discovery.
if [ -z "$DEVICE" ]; then
    DEVICE=$($ADB devices 2>/dev/null | awk -F'\t' '$2=="device" && $1 ~ /:5555$/ {print $1; exit}')
fi
if [ -z "$DEVICE" ]; then
    log "No connected ADB device; running adb-auto-connect..."
    "$HOME/.local/bin/adb-auto-connect.sh" >/dev/null 2>&1 || true
    DEVICE=$($ADB devices 2>/dev/null | awk -F'\t' '$2=="device" && $1 ~ /:5555$/ {print $1; exit}')
fi

# Connect to device (wireless ADB needs reconnect after reboot)
if [ -n "$DEVICE" ]; then
    log "Using device $DEVICE"
    $ADB connect "$DEVICE" 2>&1 | grep -v "already connected" || true
    sleep 1
fi

# Check device is reachable
if [ -z "$DEVICE" ] || ! $ADB -s "$DEVICE" shell echo ok &>/dev/null; then
    log "ERROR: no reachable ADB device (last tried: ${DEVICE:-none}). Aborting."
    exit 1
fi

# Check if any .wav files exist on device
WAV_COUNT=$($ADB -s "$DEVICE" shell "su -c 'ls ${REMOTE_DIR}/*.wav 2>/dev/null | wc -l'" | tr -d '[:space:]')
PCM_COUNT=$($ADB -s "$DEVICE" shell "su -c 'ls ${REMOTE_DIR}/*.pcm 2>/dev/null | wc -l'" | tr -d '[:space:]')

log "Found $WAV_COUNT .wav and $PCM_COUNT .pcm files on device."

if [ "$WAV_COUNT" -eq 0 ] && [ "$PCM_COUNT" -eq 0 ]; then
    log "No files to pull. Done."
    exit 0
fi

# Stage .wav files to /sdcard/ (accessible without root for adb pull)
wav_path_ok=0
if [ "$WAV_COUNT" -gt 0 ]; then
    log "Staging .wav files to $STAGING_DIR..."
    $ADB -s "$DEVICE" shell "su -c 'mkdir -p ${STAGING_DIR}'"
    cp_result=$($ADB -s "$DEVICE" shell "su -c 'cp ${REMOTE_DIR}/*.wav ${STAGING_DIR}/ && echo COPY_OK'")
    if ! echo "$cp_result" | grep -q COPY_OK; then
        log "ERROR: staging copy failed: $cp_result"
        exit 1
    fi

    # Capture staged basenames before pulling so we can verify each file
    # actually landed locally after the pull (mtime-based checks are unreliable).
    staged_files=$($ADB -s "$DEVICE" shell "su -c 'ls ${STAGING_DIR}'" | tr -d '\r')

    # Pull .wav files to local storage
    log "Pulling .wav files to $LOCAL_DIR..."
    pull_rc=0
    $ADB -s "$DEVICE" pull "$STAGING_DIR/." "$LOCAL_DIR/" || pull_rc=$?

    if [ "$pull_rc" -eq 0 ]; then
        # Verify every staged file exists locally and is non-empty before
        # touching device originals.
        verify_ok=1
        missing=""
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            if [ ! -s "$LOCAL_DIR/$name" ]; then
                verify_ok=0
                missing="$missing $name"
            fi
        done <<< "$staged_files"

        if [ "$verify_ok" -eq 1 ]; then
            log "Pull verified: all staged .wav files present locally."

            # Delete only the exact recording verified against the staging copy.
            # New/unmatched files appearing during pull are retained.
            while IFS= read -r name; do
                [[ "$name" =~ ^hellotalk_mic_[0-9]{8}_[0-9]{6}\.wav$ ]] || continue
                remote_size=$($ADB -s "$DEVICE" shell "stat -c %s '$STAGING_DIR/$name'" | tr -d '\r[:space:]')
                [ "$(stat -c %s "$LOCAL_DIR/$name")" = "$remote_size" ] || exit 1
                ffprobe -v error "$LOCAL_DIR/$name" >/dev/null 2>&1 || exit 1
                stem="${name%.wav}"
                $ADB -s "$DEVICE" shell "su -c 'cmp -s $REMOTE_DIR/$name $STAGING_DIR/$name && rm -f $REMOTE_DIR/$name $REMOTE_DIR/$stem.pcm $STAGING_DIR/$name'" || exit 1
            done <<< "$staged_files"
            wav_path_ok=1
        else
            log "ERROR: verification failed, missing/empty local files:$missing"
            log "Clearing staged .wav files from $STAGING_DIR..."
            $ADB -s "$DEVICE" shell "su -c 'rm -f ${STAGING_DIR}/*.wav'"
            exit 1
        fi
    else
        log "ERROR: adb pull failed (rc=$pull_rc). Keeping device originals for retry."
        # Still clear staging to avoid partial duplicates on next run
        log "Clearing staged .wav files from $STAGING_DIR..."
        $ADB -s "$DEVICE" shell "su -c 'rm -f ${STAGING_DIR}/*.wav'"
        exit 1
    fi
fi

# A PCM without its own verified WAV is always retained.
log "Done. Verified WAV recordings pulled; unmatched PCM files retained."
