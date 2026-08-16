#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/trxvanity-linux-gpu" >&2
  exit 2
fi

server_binary=$1
if [[ ! -x "$server_binary" ]]; then
  echo "server binary is missing or not executable: $server_binary" >&2
  exit 2
fi

for required_tool in nm strings grep mktemp; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "FAIL: required audit tool is unavailable: $required_tool" >&2
    exit 2
  fi
done

nm_output=$(mktemp "${TMPDIR:-/tmp}/trxvanity-nm.XXXXXX")
strings_output=$(mktemp "${TMPDIR:-/tmp}/trxvanity-strings.XXXXXX")
trap 'rm -f -- "$nm_output" "$strings_output"' EXIT

if ! nm -C --defined-only "$server_binary" >"$nm_output"; then
  echo "FAIL: nm could not inspect the server binary" >&2
  exit 2
fi
if ! strings "$server_binary" >"$strings_output"; then
  echo "FAIL: strings could not inspect the server binary" >&2
  exit 2
fi

if grep -E \
  'secp256k1_ec_seckey|random_private_key|add_private_tweak|public_key_from_private' \
  "$nm_output" >/dev/null; then
  echo "FAIL: secret-key symbol found in the public-only server binary" >&2
  exit 1
fi

if grep -E 'BASE_PRIVATE=|PRIVATE_KEY=' "$strings_output" >/dev/null; then
  echo "FAIL: secret file field found in the public-only server binary" >&2
  exit 1
fi

rm -f -- "$nm_output" "$strings_output"
trap - EXIT
echo "SECURITY_AUDIT OK PUBLIC_ONLY $server_binary"
