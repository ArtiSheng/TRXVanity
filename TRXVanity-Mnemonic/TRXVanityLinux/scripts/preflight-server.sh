#!/usr/bin/env bash
set -Eeuo pipefail

readonly data_mount="/root/autodl-tmp"
readonly runtime_root="${data_mount}/TRXVanityLinux"
readonly runtime_dir="${runtime_root}/runtime"
readonly shared_app_link="/root/autodl-fs/TRXVanityLinux"
readonly app_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PATH="/root/miniconda3/bin:${PATH}"

fail() {
    echo "Preflight failed: $*" >&2
    exit 2
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ -d "${shared_app_link}" && ! -L "${shared_app_link}" ]] \
    || fail "missing shared production runtime ${shared_app_link}"
[[ "$(cd -- "${shared_app_link}" && pwd -P)" == "${app_dir}" ]] \
    || fail "preflight must run from ${shared_app_link}"
[[ -d "${data_mount}" && ! -L "${data_mount}" ]] \
    || fail "${data_mount} must be a real directory"
# Only public counters, timings and monitor state are written here.
# The AES key remains in /dev/shm and the winning mnemonic remains in
# non-dumpable process memory until the verified cleanup exec.
[[ -c /dev/nvidiactl ]] || fail "NVIDIA driver device /dev/nvidiactl is unavailable"
command -v nvidia-smi >/dev/null || fail "nvidia-smi is unavailable"
command -v python3 >/dev/null || fail "python3 is unavailable"
command -v openssl >/dev/null || fail "openssl is unavailable"
command -v flock >/dev/null || fail "flock is unavailable"
[[ -x "${app_dir}/build/trxvanity-gpu" ]] || fail "compiled GPU engine is missing"
[[ -f "${app_dir}/build/bip39-english.txt" ]] || fail "BIP39 word list is missing"

mkdir -p -- "${runtime_dir}" /run/trxvanity
chown root:root -- "${runtime_root}" "${runtime_dir}" /run/trxvanity
chmod 700 -- "${runtime_root}" "${runtime_dir}" /run/trxvanity
ulimit -c 0
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
echo "Server runtime safety and dependency preflight passed (hybrid-public-runtime)."
