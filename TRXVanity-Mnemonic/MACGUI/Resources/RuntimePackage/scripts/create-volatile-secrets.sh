#!/usr/bin/env bash
set -Eeuo pipefail

# Recovery helper after cleanup consumed /dev/shm. Normal setup is deploy.py.
readonly secrets_file="/dev/shm/trxvanity-secrets.env"

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 2
fi
if [[ -e "${secrets_file}" || -L "${secrets_file}" ]]; then
    echo "Refusing to overwrite existing ${secrets_file}; remove it deliberately first." >&2
    exit 2
fi

umask 077
read -r -s -p "AES-256 key (exactly 64 hexadecimal characters): " key_value
printf '\n'
if [[ ! "${key_value}" =~ ^[[:xdigit:]]{64}$ ]]; then
    unset key_value
    echo "Invalid AES key." >&2
    exit 2
fi
read -r -p "Upload URL (https://host/upload.php?token=...): " upload_endpoint
if [[ ! "${upload_endpoint}" =~ ^https://[^[:space:]]+/upload[.]php\?token=[^[:space:]]+$ ]]; then
    unset key_value
    echo "Invalid upload URL." >&2
    exit 2
fi

install -m 600 -o root -g root /dev/null "${secrets_file}"
printf 'TRX_AES_KEY_HEX=%s\nTRX_BACKUP_ENABLED=true\nTRX_UPLOAD_ENDPOINT=%s\n' \
    "${key_value}" "${upload_endpoint}" > "${secrets_file}"
unset key_value
chmod 600 "${secrets_file}"
echo "Created volatile owner-only secrets file: ${secrets_file}"
echo "It will be overwritten and unlinked when verified formal cleanup starts."
