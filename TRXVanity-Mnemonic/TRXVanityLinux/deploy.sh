#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if ! command -v python3 >/dev/null; then
    echo "python3 is required. On Windows run: py -3 deploy.py" >&2
    exit 2
fi
exec python3 ./deploy.py
