#!/usr/bin/env bash
set -Eeuo pipefail

readonly app_dir="/root/autodl-tmp/TRXVanityLinux"
readonly data_dir="/root/autodl-tmp"
staging=""
release=""
previous=""

cleanup() {
    local return_code=$?
    trap - EXIT
    if [[ -n "${release}" && "${release}" == "${app_dir}/.production-release."* ]]; then
        rm -rf -- "${release}"
    fi
    if [[ -n "${staging}" && "${staging}" == "${data_dir}/.trxvanity-production-build."* ]]; then
        rm -rf -- "${staging}"
    fi
    exit "${return_code}"
}
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 2; }
[[ "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" == "${app_dir}" ]] \
    || { echo "Production build installer must run from ${app_dir}." >&2; exit 2; }

# Compile and self-test in a brand-new directory.  Never trust an earlier
# CMake cache or object timestamp for the months-long production search.
staging="$(mktemp -d "${data_dir}/.trxvanity-production-build.XXXXXX")"
[[ "${staging}" == "${data_dir}/.trxvanity-production-build."* ]] \
    || { echo "Unsafe production staging path." >&2; exit 2; }

BUILD_DIR="${staging}" \
TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD=4 \
TRXVANITY_SECP_WINDOW_BITS=16 \
TRXVANITY_MASTER_MIN_BLOCKS_PER_SM=0 \
TRXVANITY_MASTER_LOW_SPILL_THREADS=0 \
TRXVANITY_PBKDF2_DIRECT_WORDS=0 \
    "${app_dir}/build-engine.sh" --self-test

[[ -x "${staging}/trxvanity-gpu" ]] \
    || { echo "Fresh build did not produce the engine." >&2; exit 1; }
[[ -f "${staging}/bip39-english.txt" ]] \
    || { echo "Fresh build did not produce the word list." >&2; exit 1; }
[[ -f "${staging}/cuda-tuning-config.txt" ]] \
    || { echo "Fresh build did not produce the tuning stamp." >&2; exit 1; }

# Keep the runtime directory intentionally minimal.  CMake embeds its build
# path in CMakeCache.txt, so installing only the tested runtime artifacts also
# avoids leaving a cache that falsely appears reusable after this atomic move.
release="$(mktemp -d "${app_dir}/.production-release.XXXXXX")"
[[ "${release}" == "${app_dir}/.production-release."* ]] \
    || { echo "Unsafe production release path." >&2; exit 2; }
install -m 700 -o root -g root \
    "${staging}/trxvanity-gpu" "${release}/trxvanity-gpu"
install -m 600 -o root -g root \
    "${staging}/bip39-english.txt" "${release}/bip39-english.txt"
install -m 600 -o root -g root \
    "${staging}/cuda-tuning-config.txt" "${release}/cuda-tuning-config.txt"

if [[ -e "${app_dir}/build" ]]; then
    previous="${app_dir}/build.previous.$(date -u +%Y%m%dT%H%M%SZ).$$"
    [[ ! -e "${previous}" ]] || { echo "Build backup path collision." >&2; exit 1; }
    mv -- "${app_dir}/build" "${previous}"
fi
if ! mv -- "${release}" "${app_dir}/build"; then
    if [[ -n "${previous}" && ! -e "${app_dir}/build" ]]; then
        mv -- "${previous}" "${app_dir}/build" || true
    fi
    echo "Could not atomically install the tested production build." >&2
    exit 1
fi
release=""

echo "Installed fresh production engine:"
sha256sum -- "${app_dir}/build/trxvanity-gpu"
if [[ -n "${previous}" ]]; then
    echo "Previous production build retained at ${previous}"
fi
