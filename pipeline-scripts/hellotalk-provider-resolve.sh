#!/usr/bin/env bash
# Resolve API_BASE and API_KEY from PROVIDER selection.
# Source this file (do not execute) after loading the env file.
# Inputs:  $PROVIDER  (google|nvidia|custom; default: google)
# Outputs: exports API_BASE and API_KEY (only if not already set in env).

: "${PROVIDER:=google}"

case "$PROVIDER" in
    google)
        : "${API_BASE:=${GOOGLE_API_BASE:-https://generativelanguage.googleapis.com/v1beta/openai}}"
        : "${API_KEY:=${GOOGLE_API_KEY:-}}"
        ;;
    nvidia)
        : "${API_BASE:=${NVIDIA_API_BASE:-https://integrate.api.nvidia.com/v1}}"
        : "${API_KEY:=${NVIDIA_API_KEY:-}}"
        ;;
    custom)
        : "${API_BASE:=${CUSTOM_API_BASE:-}}"
        : "${API_KEY:=${CUSTOM_API_KEY:-}}"
        ;;
    *)
        echo "ERROR: unknown PROVIDER='$PROVIDER' (valid: google|nvidia|custom)" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

export PROVIDER API_BASE API_KEY
