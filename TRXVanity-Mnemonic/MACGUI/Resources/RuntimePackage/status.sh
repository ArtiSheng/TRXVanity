#!/usr/bin/env bash
set -Eeuo pipefail

readonly controller_status="/root/autodl-tmp/TRXVanityLinux/runtime/status.json"
readonly cleanup_status="/run/trxvanity/cleanup-status.json"
export PATH="/root/miniconda3/bin:${PATH}"

command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 2; }

if [[ -r "${controller_status}" ]]; then
    echo "Controller:"
    python3 -m json.tool "${controller_status}"
else
    echo "Controller status is not available."
fi
if [[ -r "${cleanup_status}" ]]; then
    echo "Cleanup:"
    python3 -m json.tool "${cleanup_status}"
else
    echo "Cleanup status is not available."
fi
