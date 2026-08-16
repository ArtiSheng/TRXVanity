#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)

if command -v python3 >/dev/null 2>&1; then
  python=python3
elif command -v py >/dev/null 2>&1; then
  python="py -3"
else
  echo "Python 3 is required to run the split-key client." >&2
  exit 1
fi

# shellcheck disable=SC2086
$python "$project_dir/client/trxvanity_client.py" --self-test
echo "CLIENT_SELFTEST OK $project_dir/client/trxvanity_client.py"
