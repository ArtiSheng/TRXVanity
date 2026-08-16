#!/usr/bin/env bash
set -uo pipefail

runtime_dir=${TRXVANITY_RUNTIME_DIR:-/root/autodl-tmp/TRXVanityLinuxWork/runtime}
log_file="$runtime_dir/search.log"
pid_file="$runtime_dir/search.pid"
started_file="$runtime_dir/started_at"

emit() {
  local key=$1
  local value=${2:-}
  value=${value//$'\t'/ }
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  printf '%s\t%s\n' "$key" "$value"
}

last_record() {
  local kind=$1
  if [[ -r "$log_file" ]]; then
    awk -F '\t' -v wanted="$kind" '$1 == wanted { line=$0 } END { print line }' "$log_file"
  fi
}

printf 'TRXVANITY_STATUS_V1\n'
emit HOST "$(hostname 2>/dev/null || true)"

os_name=unknown
if [[ -r /etc/os-release ]]; then
  os_name=$(awk -F= '$1 == "PRETTY_NAME" { value=$2; gsub(/^\"|\"$/, "", value); print value; exit }' /etc/os-release)
fi
emit OS "$os_name"

gpu_csv=$(nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)
if [[ -n "$gpu_csv" ]]; then
  IFS=',' read -r gpu_name driver memory_total memory_used utilization temperature power <<<"$gpu_csv"
  for variable in gpu_name driver memory_total memory_used utilization temperature power; do
    value=${!variable}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf -v "$variable" '%s' "$value"
  done
  emit GPU "$gpu_name"
  emit DRIVER "$driver"
  emit MEMORY_TOTAL_MIB "$memory_total"
  emit MEMORY_USED_MIB "$memory_used"
  emit UTILIZATION_PERCENT "$utilization"
  emit TEMPERATURE_C "$temperature"
  emit POWER_W "$power"
else
  emit GPU unavailable
fi

pid=
if [[ -r "$pid_file" ]]; then
  read -r pid <"$pid_file" || true
fi
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  emit STATE running
  emit PID "$pid"
else
  emit STATE stopped
  emit PID "${pid:-}"
fi
if [[ -r "$started_file" ]]; then
  emit STARTED_AT "$(head -n 1 "$started_file")"
fi

for record_type in SECURITY READY SEARCHING PROGRESS RESULT STOPPED ERROR; do
  record=$(last_record "$record_type")
  if [[ -n "$record" ]]; then
    encoded=$(printf '%s' "$record" | base64 -w 0)
    emit "RECORD_$record_type" "$encoded"
  fi
done

if [[ -r "$log_file" ]]; then
  log_tail=$(tail -n 80 "$log_file" | base64 -w 0)
  emit LOG_BASE64 "$log_tail"
  emit LOG_SIZE_BYTES "$(stat -c '%s' "$log_file" 2>/dev/null || true)"
fi
printf 'END\n'

