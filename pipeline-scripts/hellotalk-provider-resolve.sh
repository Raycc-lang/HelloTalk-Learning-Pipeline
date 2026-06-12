#!/usr/bin/env bash
# Resolve API_BASE and API_KEY from PROVIDER selection.
# Source this file (do not execute) after loading the env file.
# Inputs:  $PROVIDER  (nvidia|tencent|cloudflare; default: nvidia)
# Outputs: exports API_BASE and API_KEY (only if not already set in env).

: "${PROVIDER:=nvidia}"

case "$PROVIDER" in
    nvidia)
        : "${API_BASE:=${NVIDIA_API_BASE:-https://integrate.api.nvidia.com/v1}}"
        : "${API_KEY:=${NVIDIA_API_KEY:-}}"
        ;;
    tencent)
        : "${API_BASE:=${TENCENT_API_BASE:-https://tokenhub.tencentmaas.com/v1}}"
        : "${API_KEY:=${TENCENT_API_KEY:-}}"
        ;;
    cloudflare)
        : "${API_BASE:=https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID:-}/ai/v1}"
        : "${API_KEY:=${CLOUDFLARE_API_TOKEN:-}}"
        ;;
    mimo)
        : "${API_BASE:=${MIMO_API_BASE:-https://token-plan-sgp.xiaomimimo.com/v1}}"
        : "${API_KEY:=${MIMO_API_KEY:-}}"
        ;;
    google)
        : "${API_BASE:=${GOOGLE_API_BASE:-https://generativelanguage.googleapis.com/v1beta/openai}}"
        : "${API_KEY:=${GOOGLE_API_KEY:-}}"
        ;;
    *)
        echo "ERROR: unknown PROVIDER='$PROVIDER' (valid: nvidia|tencent|cloudflare|mimo|google)" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

export PROVIDER API_BASE API_KEY
