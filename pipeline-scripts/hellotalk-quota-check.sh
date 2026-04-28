#!/usr/bin/env bash
# Shared quota-sentinel helper.
# Source this file (do not execute) AFTER hellotalk-provider-resolve.sh so $PROVIDER is set.
#
# Provides:
#   hellotalk_quota_sentinel_path   - path of sentinel file for current provider
#   hellotalk_quota_check           - if active sentinel exists, log + exit 75; auto-deletes expired
#
# Sentinel file format (key=value):
#   provider=...
#   model=...
#   hit_at=<ISO8601 UTC>
#   expires_at=<epoch seconds>
#   reason=<daily|rate>
#   message=<truncated>

: "${PROVIDER:=nvidia}"
: "${HELLOTALK_QUOTA_DIR:=$HOME/.cache/hellotalk}"

hellotalk_quota_sentinel_path() {
    echo "$HELLOTALK_QUOTA_DIR/quota-block-${PROVIDER}"
}

hellotalk_quota_check() {
    local f
    f="$(hellotalk_quota_sentinel_path)"
    [ -f "$f" ] || return 0

    local expires_at now
    expires_at="$(grep -E '^expires_at=' "$f" | head -n1 | cut -d= -f2-)"
    now="$(date -u +%s)"

    if [ -z "$expires_at" ] || ! [[ "$expires_at" =~ ^[0-9]+$ ]]; then
        # Malformed; treat as expired and clear it.
        rm -f "$f"
        return 0
    fi

    if [ "$now" -ge "$expires_at" ]; then
        rm -f "$f"
        return 0
    fi

    local reason msg remaining
    reason="$(grep -E '^reason=' "$f" | head -n1 | cut -d= -f2-)"
    msg="$(grep -E '^message=' "$f" | head -n1 | cut -d= -f2-)"
    remaining=$(( expires_at - now ))
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG:-hellotalk}] QUOTA BLOCK active for PROVIDER=$PROVIDER (reason=$reason, ${remaining}s remaining): $msg" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG:-hellotalk}] Sentinel: $f (auto-clears at $(date -u -d "@$expires_at" '+%Y-%m-%dT%H:%M:%SZ'))" >&2
    exit 75   # EX_TEMPFAIL
}
