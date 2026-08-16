#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)

cmake -S "$project_dir" -B "$project_dir/build-linux" \
  -DTRXVANITY_BUILD_SERVER=ON \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$project_dir/build-linux" --parallel
ctest --test-dir "$project_dir/build-linux" --output-on-failure -L cpu

server_binary="$project_dir/build-linux/bin/trxvanity-linux-gpu"
"$server_binary" --self-test --inverse-multiple 16384
"$script_dir/security-audit.sh" "$server_binary"

echo "SERVER_BUILD_AND_GPU_AUDIT OK $server_binary"
