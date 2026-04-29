#!/usr/bin/env bash
set -euo pipefail

ADB="/usr/bin/adb"
DEVICE="192.168.1.13:5555"
REMOTE_DIR="/data/data/com.hellotalk/files/HelloTalkCapture"
STAGING_DIR="/sdcard/HelloTalkCapture"
LOCAL_DIR="$HOME/Android/HelloTalkCapture/Original_audio"
LOG_TAG="hellotalk-pull"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# Ensure local destination exists
mkdir -p "$LOCAL_DIR"

# Connect to device (wireless ADB needs reconnect after reboot)
log "Connecting to device $DEVICE..."
$ADB connect "$DEVICE" 2>&1 | grep -v "already connected" || true
sleep 1

# Check device is reachable
if ! $ADB -s "$DEVICE" shell echo ok &>/dev/null; then
    log "ERROR: Device $DEVICE not reachable. Aborting."
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
if [ "$WAV_COUNT" -gt 0 ]; then
    log "Staging .wav files to $STAGING_DIR..."
    $ADB -s "$DEVICE" shell "su -c 'mkdir -p ${STAGING_DIR}'"
    $ADB -s "$DEVICE" shell "su -c 'cp ${REMOTE_DIR}/*.wav ${STAGING_DIR}/'"

    # Pull .wav files to local storage
    log "Pulling .wav files to $LOCAL_DIR..."
    pull_rc=0
    $ADB -s "$DEVICE" pull "$STAGING_DIR/." "$LOCAL_DIR/" || pull_rc=$?

    if [ "$pull_rc" -eq 0 ]; then
        # Verify local file count matches expected WAV_COUNT
        local_wav_count=$(find "$LOCAL_DIR" -maxdepth 1 -name '*.wav' -newer "$LOCAL_DIR" -type f 2>/dev/null | wc -l || echo 0)
        log "Pull succeeded. Local .wav files present: $local_wav_count (expected: $WAV_COUNT)."

        # Clear staged .wav files to avoid re-pulling duplicates next run
        log "Clearing staged .wav files from $STAGING_DIR..."
        $ADB -s "$DEVICE" shell "su -c 'rm -f ${STAGING_DIR}/*.wav'"

        # Delete .wav originals from device
        log "Deleting .wav files from device..."
        $ADB -s "$DEVICE" shell "su -c 'rm -f ${REMOTE_DIR}/*.wav'"

        # Delete .pcm files from device (not needed, .wav has same data with header)
        if [ "$PCM_COUNT" -gt 0 ]; then
            log "Deleting .pcm files from device..."
            $ADB -s "$DEVICE" shell "su -c 'rm -f ${REMOTE_DIR}/*.pcm'"
        fi
    else
        log "ERROR: adb pull failed (rc=$pull_rc). Keeping device originals for retry."
        # Still clear staging to avoid partial duplicates on next run
        log "Clearing staged .wav files from $STAGING_DIR..."
        $ADB -s "$DEVICE" shell "su -c 'rm -f ${STAGING_DIR}/*.wav'"
        exit 1
    fi
fi

log "Done. Pulled $WAV_COUNT .wav files, deleted $PCM_COUNT .pcm files."
