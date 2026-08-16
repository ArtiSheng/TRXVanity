#!/usr/bin/env bash
set -Eeuo pipefail

readonly app_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly shared_app_link="/root/autodl-fs/TRXVanityLinux"
readonly runtime_dir="/root/autodl-tmp/TRXVanityLinux/runtime"
readonly secrets_file="/dev/shm/trxvanity-secrets.env"
readonly cleanup_marker="${runtime_dir}/cleanup-authorized.json"
export PATH="/root/miniconda3/bin:${PATH}"

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 2; }
[[ -d "${shared_app_link}" && ! -L "${shared_app_link}" ]] \
    || { echo "Formal shared runtime is missing: ${shared_app_link}." >&2; exit 2; }
[[ "${app_dir}" == "$(cd -- "${shared_app_link}" && pwd -P)" ]] \
    || { echo "Formal run requires ${shared_app_link}." >&2; exit 2; }
"${app_dir}/scripts/preflight-server.sh"
[[ -f "${secrets_file}" && ! -L "${secrets_file}" ]] \
    || { echo "Create ${secrets_file} first." >&2; exit 2; }
[[ ! -e "${cleanup_marker}" && ! -L "${cleanup_marker}" ]] \
    || { echo "Refusing formal search while a cleanup authorization marker exists." >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 2; }
ulimit -c 0

readonly suffix_file="${app_dir}/formal-suffix"
[[ -f "${suffix_file}" && ! -L "${suffix_file}" ]] \
    || { echo "formal-suffix is missing; deploy first and enter a suffix." >&2; exit 2; }
suffix="$(tr -d '\r\n' < "${suffix_file}")"
if [[ ! "${suffix}" =~ ^[1-9A-HJ-NP-Za-km-z]{1,10}$ ]]; then
    echo "formal-suffix is missing or invalid." >&2
    exit 2
fi
readonly suffix

readonly supervisor_lock="/run/trxvanity/formal-supervisor.lock"
exec 8>"${supervisor_lock}"
chmod 600 "${supervisor_lock}"
if ! flock -n 8; then
    echo "Another formal supervisor is already running." >&2
    exit 2
fi
[[ ! -e "${cleanup_marker}" && ! -L "${cleanup_marker}" ]] \
    || { echo "Refusing formal search while a cleanup authorization marker exists." >&2; exit 2; }

# A many-month search must survive a transient driver, network, or controller
# failure.  A verified result replaces the controller child with cleanup and
# returns only after all five passes; exit 0 then ends this supervisor.  Never
# restart after an operator stop, after the volatile key was consumed, or once
# a signed cleanup marker exists.
while true; do
    [[ ! -e "${cleanup_marker}" && ! -L "${cleanup_marker}" ]] \
        || { echo "Formal supervisor stopped because a cleanup authorization marker exists." >&2; exit 2; }
    set +e
    python3 "${app_dir}/controller.py" \
        --env-file "${secrets_file}" \
        run --suffix "${suffix}" --runtime-dir "${runtime_dir}"
    return_code=$?
    set -e
    if [[ ${return_code} -eq 0 || ${return_code} -eq 130 ]]; then
        exit "${return_code}"
    fi
    if [[ ! -f "${secrets_file}" || -e "${cleanup_marker}" || -L "${cleanup_marker}" ]]; then
        echo "Formal supervisor stopped after a protected cleanup handoff or refusal." >&2
        exit "${return_code}"
    fi
    echo "Formal search exited with code ${return_code}; retrying in 30 seconds." >&2
    sleep 30
done
