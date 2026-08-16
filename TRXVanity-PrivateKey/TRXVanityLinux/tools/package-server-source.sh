#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT.tgz" >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
linux_dir=$(cd -- "$script_dir/.." && pwd)
project_root=$(cd -- "$linux_dir/.." && pwd)
output=$1
if [[ "$output" != /* ]]; then
  output="$(pwd)/$output"
fi
if [[ -e "$output" ]]; then
  echo "refusing to overwrite existing archive: $output" >&2
  exit 1
fi

cleanup_failed_archive() {
  status=$?
  if (( status != 0 )); then
    rm -f -- "$output"
  fi
  exit "$status"
}
trap cleanup_failed_archive EXIT

readonly files=(
  TRXVanityLinux/CMakeLists.txt
  TRXVanityLinux/README.md
  TRXVanityLinux/common/crypto.cpp
  TRXVanityLinux/common/crypto.hpp
  TRXVanityLinux/common/match_plan.cpp
  TRXVanityLinux/common/match_plan.hpp
  TRXVanityLinux/common/request.cpp
  TRXVanityLinux/common/request.hpp
  TRXVanityLinux/server/main.cpp
  TRXVanityLinux/server/opencl_engine.cpp
  TRXVanityLinux/server/opencl_engine.hpp
  TRXVanityLinux/server/opencl_minimal.hpp
  TRXVanityLinux/server/public_crypto.cpp
  TRXVanityLinux/server/public_crypto.hpp
  TRXVanityLinux/server/random.cpp
  TRXVanityLinux/server/random.hpp
  TRXVanityLinux/server/remote_status.sh
  TRXVanityLinux/kernels/keccak.cl
  TRXVanityLinux/kernels/profanity.cl
  TRXVanityLinux/kernels/tron.cl
  TRXVanityLinux/third_party/profanity2/precomp.cpp
  TRXVanityLinux/third_party/profanity2/precomp.hpp
  TRXVanityLinux/third_party/profanity2/types.hpp
  TRXVanityLinux/tests/public_self_test.cpp
  TRXVanityLinux/tools/build-server.sh
  TRXVanityLinux/tools/package-server-source.sh
  TRXVanityLinux/tools/security-audit.sh
  Vendor/secp256k1/COPYING
  Vendor/secp256k1/include/secp256k1.h
  Vendor/secp256k1/include/secp256k1_preallocated.h
  Vendor/secp256k1/src/assumptions.h
  Vendor/secp256k1/src/checkmem.h
  Vendor/secp256k1/src/ecdsa.h
  Vendor/secp256k1/src/ecdsa_impl.h
  Vendor/secp256k1/src/eckey.h
  Vendor/secp256k1/src/eckey_impl.h
  Vendor/secp256k1/src/ecmult.h
  Vendor/secp256k1/src/ecmult_const.h
  Vendor/secp256k1/src/ecmult_const_impl.h
  Vendor/secp256k1/src/ecmult_gen.h
  Vendor/secp256k1/src/ecmult_gen_impl.h
  Vendor/secp256k1/src/ecmult_impl.h
  Vendor/secp256k1/src/field.h
  Vendor/secp256k1/src/field_5x52.h
  Vendor/secp256k1/src/field_5x52_impl.h
  Vendor/secp256k1/src/field_5x52_int128_impl.h
  Vendor/secp256k1/src/field_impl.h
  Vendor/secp256k1/src/group.h
  Vendor/secp256k1/src/group_impl.h
  Vendor/secp256k1/src/hash.h
  Vendor/secp256k1/src/hash_impl.h
  Vendor/secp256k1/src/hsort.h
  Vendor/secp256k1/src/hsort_impl.h
  Vendor/secp256k1/src/int128.h
  Vendor/secp256k1/src/int128_impl.h
  Vendor/secp256k1/src/int128_native.h
  Vendor/secp256k1/src/int128_native_impl.h
  Vendor/secp256k1/src/modinv64.h
  Vendor/secp256k1/src/modinv64_impl.h
  Vendor/secp256k1/src/precomputed_ecmult.c
  Vendor/secp256k1/src/precomputed_ecmult.h
  Vendor/secp256k1/src/precomputed_ecmult_gen.c
  Vendor/secp256k1/src/precomputed_ecmult_gen.h
  Vendor/secp256k1/src/scalar.h
  Vendor/secp256k1/src/scalar_4x64.h
  Vendor/secp256k1/src/scalar_4x64_impl.h
  Vendor/secp256k1/src/scalar_impl.h
  Vendor/secp256k1/src/scratch.h
  Vendor/secp256k1/src/scratch_impl.h
  Vendor/secp256k1/src/secp256k1.c
  Vendor/secp256k1/src/selftest.h
  Vendor/secp256k1/src/util.h
  ThirdPartyLicenses/libsecp256k1-MIT.txt
  ThirdPartyLicenses/profanity2-MIT.txt
)

for item in "${files[@]}"; do
  if [[ ! -f "$project_root/$item" ]]; then
    echo "FAIL: allowlisted server source is missing: $item" >&2
    exit 1
  fi
done

tar -czf "$output" -C "$project_root" "${files[@]}"

archive_list=$(mktemp "${TMPDIR:-/tmp}/trxvanity-archive-list.XXXXXX")
trap 'status=$?; rm -f -- "$archive_list"; if (( status != 0 )); then rm -f -- "$output"; fi; exit "$status"' EXIT
tar -tzf "$output" >"$archive_list"
if [[ $(wc -l <"$archive_list") -ne ${#files[@]} ]]; then
  echo "FAIL: server archive contains an unexpected number of paths" >&2
  exit 1
fi
for item in "${files[@]}"; do
  if ! grep -Fx "$item" "$archive_list" >/dev/null; then
    echo "FAIL: server archive allowlist mismatch: $item" >&2
    exit 1
  fi
done

if grep -E '(^|/)client/|(^|/)build[^/]*/|(^|/)[^/]*\.(secret|wallet|request|result)$' "$archive_list" >/dev/null; then
  echo "FAIL: server archive contains a local-client or job-secret path" >&2
  exit 1
fi

rm -f -- "$archive_list"
trap - EXIT
echo "SERVER_SOURCE_ARCHIVE OK $output"
