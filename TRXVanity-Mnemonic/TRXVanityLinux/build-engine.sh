#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cuda_root="${CUDA_ROOT:-/usr/local/cuda-12.8}"
cuda_compiler="${CUDACXX:-${cuda_root}/bin/nvcc}"
build_dir="${BUILD_DIR:-${script_dir}/build}"
build_type="${BUILD_TYPE:-Release}"
build_jobs="${BUILD_JOBS:-$(nproc)}"
address_candidates_per_thread="${TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD:-4}"
secp_window_bits="${TRXVANITY_SECP_WINDOW_BITS:-16}"
master_min_blocks_per_sm="${TRXVANITY_MASTER_MIN_BLOCKS_PER_SM:-0}"
master_low_spill_threads="${TRXVANITY_MASTER_LOW_SPILL_THREADS:-0}"
pbkdf2_direct_words="${TRXVANITY_PBKDF2_DIRECT_WORDS:-0}"
run_self_test=0

if [[ ! -x "${cuda_compiler}" ]]; then
    echo "CUDA compiler is missing or not executable: ${cuda_compiler}" >&2
    exit 2
fi
export PATH="${cuda_root}/bin:${PATH}"

if [[ "${1:-}" == "--self-test" ]]; then
    run_self_test=1
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--self-test]" >&2
    exit 2
fi

cmake \
    -S "${script_dir}" \
    -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE="${build_type}" \
    -DCMAKE_CUDA_COMPILER="${cuda_compiler}" \
    -DTRXVANITY_ADDRESS_CANDIDATES_PER_THREAD="${address_candidates_per_thread}" \
    -DTRXVANITY_SECP_WINDOW_BITS="${secp_window_bits}" \
    -DTRXVANITY_MASTER_MIN_BLOCKS_PER_SM="${master_min_blocks_per_sm}" \
    -DTRXVANITY_MASTER_LOW_SPILL_THREADS="${master_low_spill_threads}" \
    -DTRXVANITY_PBKDF2_DIRECT_WORDS="${pbkdf2_direct_words}"
cmake --build "${build_dir}" --config "${build_type}" --parallel "${build_jobs}"

engine="${build_dir}/trxvanity-gpu"
wordlist="${build_dir}/bip39-english.txt"
if [[ ! -x "${engine}" || ! -f "${wordlist}" ]]; then
    echo "Build finished without the expected engine or BIP39 word list." >&2
    exit 1
fi

if [[ ${run_self_test} -eq 1 ]]; then
    tuning_stamp="${build_dir}/cuda-tuning-config.txt"
    expected_tuning="address_candidates_per_thread=${address_candidates_per_thread}
secp_window_bits=${secp_window_bits}
master_min_blocks_per_sm=${master_min_blocks_per_sm}"
    expected_tuning="${expected_tuning}
master_low_spill_threads=${master_low_spill_threads}"
    expected_tuning="${expected_tuning}
pbkdf2_direct_words=${pbkdf2_direct_words}"
    if [[ ! -f "${tuning_stamp}" || "$(<"${tuning_stamp}")" != "${expected_tuning}" ]]; then
        echo "CUDA tuning stamp does not match the requested build." >&2
        exit 1
    fi
    ctest --test-dir "${build_dir}" --output-on-failure
    "${engine}" --self-test --profile smart --batch-size 128
fi

echo "Engine: ${engine}"
echo "Word list: ${wordlist}"
