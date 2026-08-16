#!/usr/bin/env bash
set -Eeuo pipefail

# The key is never accepted as a command-line argument.  This launcher reads
# only the exact AES key assignment from the volatile root-owned secrets file.
readonly secrets_file="/dev/shm/trxvanity-secrets.env"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export PATH="/root/miniconda3/bin:${PATH}"

if [[ ${EUID} -ne 0 ]]; then
    echo "secure cleanup must run as root" >&2
    exit 2
fi
if ! command -v python3 >/dev/null; then
    echo "python3 is required before secure cleanup can consume the volatile key" >&2
    exit 2
fi
if [[ -L "${secrets_file}" || ! -f "${secrets_file}" ]]; then
    echo "missing or unsafe volatile secrets file: ${secrets_file}" >&2
    exit 2
fi

read -r owner mode links bytes file_type < <(stat -c '%u %a %h %s %F' -- "${secrets_file}")
if [[ "${owner}" != "0" || "${mode}" != "600" || "${links}" != "1" || "${file_type}" != "regular file" ]]; then
    echo "${secrets_file} must be a root-owned regular file with mode 0600" >&2
    exit 2
fi
if (( bytes <= 0 || bytes > 16384 )); then
    echo "volatile secrets file has an unsafe size" >&2
    exit 2
fi

key_value=""
key_count=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == TRX_AES_KEY_HEX=* ]]; then
        key_value="${line#TRX_AES_KEY_HEX=}"
        ((key_count += 1))
    fi
done < "${secrets_file}"
unset line

if [[ ${key_count} -ne 1 || ! "${key_value}" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "volatile secrets file must contain exactly one valid TRX_AES_KEY_HEX entry" >&2
    exit 2
fi

export TRX_AES_KEY_HEX="${key_value}"
unset key_value

execute_requested=0
for argument in "$@"; do
    if [[ "${argument}" == "--execute" ]]; then
        execute_requested=1
    fi
done
unset argument

if [[ ${execute_requested} -eq 1 ]]; then
    # /dev/shm is volatile RAM, but clear the exact, already-validated inode
    # before unlinking it once the controller's dry-run preflight has passed.
    # No caller-controlled path participates in this removal.
    secrets_blocks=$(( (bytes + 4095) / 4096 ))
    dd if=/dev/zero of="${secrets_file}" bs=4096 count="${secrets_blocks}" \
        conv=notrunc,fsync status=none
    : > "${secrets_file}"
    rm -f -- "${secrets_file}"
    sync -f /dev/shm
    unset secrets_blocks
fi
unset execute_requested bytes owner mode links file_type

ulimit -c 0
exec python3 "${script_dir}/scripts/secure_cleanup.py" "$@"
