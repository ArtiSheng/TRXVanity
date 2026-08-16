#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
state_dir="$project_dir/dashboard/state"
dashboard_program="$project_dir/dashboard/dashboard.py"
port_file="$state_dir/dashboard.port"
legacy_pid_file="$state_dir/dashboard.pid"
runtime_root="$HOME/Library/Application Support/TRXVanityDashboard"
runtime_dashboard_dir="$runtime_root/dashboard"
runtime_state_dir="$runtime_dashboard_dir/state"
runtime_result_dir="$runtime_root/results"
runtime_dashboard_program="$runtime_dashboard_dir/dashboard.py"
runtime_config="$runtime_state_dir/config.json"
runtime_identity="$runtime_state_dir/monitor_ed25519"
runtime_known_hosts="$runtime_state_dir/known_hosts"
log_file="$runtime_state_dir/dashboard.log"
service_label="com.artisheng.trxvanity.dashboard"
port=8787
port_explicit=false
open_browser=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)
      open_browser=false
      shift
      ;;
    --port)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
        echo "--port requires a numeric value" >&2
        exit 2
      fi
      port=$2
      port_explicit=true
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if (( port < 1024 || port > 65535 )); then
  echo "port must be between 1024 and 65535" >&2
  exit 2
fi

umask 077
mkdir -p "$state_dir"
chmod 700 "$state_dir"

service_pid() {
  /bin/launchctl list "$service_label" 2>/dev/null \
    | /usr/bin/awk -F'= ' '/"PID" =/ {gsub(/[;[:space:]]/, "", $2); print $2; exit}'
}

service_healthy() {
  local candidate_pid=$1
  local candidate_port=$2
  [[ "$candidate_pid" =~ ^[0-9]+$ ]] \
    && /usr/sbin/lsof -nP -a -p "$candidate_pid" -iTCP:"$candidate_port" -sTCP:LISTEN >/dev/null 2>&1 \
    && /usr/bin/curl -fsS "http://127.0.0.1:$candidate_port/api/status" >/dev/null 2>&1
}

submitted=false
running_pid=
if /bin/launchctl list "$service_label" >/dev/null 2>&1; then
  if [[ ! -r "$port_file" ]]; then
    echo "dashboard service exists but its port metadata is missing; run stop-dashboard.sh first" >&2
    exit 1
  fi
  read -r recorded_port <"$port_file" || true
  if [[ ! "$recorded_port" =~ ^[0-9]+$ ]] || (( recorded_port < 1024 || recorded_port > 65535 )); then
    echo "dashboard service has invalid port metadata; run stop-dashboard.sh first" >&2
    exit 1
  fi
  if [[ "$port_explicit" == true && "$port" != "$recorded_port" ]]; then
    echo "dashboard is already running on port $recorded_port; stop it before changing ports" >&2
    exit 1
  fi
  port=$recorded_port
else
  if [[ -r "$legacy_pid_file" ]]; then
    read -r legacy_pid <"$legacy_pid_file" || true
    if [[ "$legacy_pid" =~ ^[0-9]+$ ]] && kill -0 "$legacy_pid" 2>/dev/null; then
      if ps -p "$legacy_pid" -o command= | /usr/bin/grep -F "$dashboard_program" >/dev/null; then
        echo "an older dashboard process is still running; run stop-dashboard.sh first" >&2
      else
        echo "refusing legacy PID that belongs to another process: $legacy_pid" >&2
      fi
      exit 1
    fi
    rm -f -- "$legacy_pid_file"
  fi
  if /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is already used by another process" >&2
    exit 1
  fi
  mkdir -p "$runtime_dashboard_dir" "$runtime_state_dir" "$runtime_result_dir"
  chmod 700 "$runtime_root" "$runtime_dashboard_dir" "$runtime_state_dir" "$runtime_result_dir"
  for source_file in dashboard.py index.html app.js styles.css; do
    /bin/cp -f "$project_dir/dashboard/$source_file" "$runtime_dashboard_dir/$source_file"
  done
  /bin/cp -f "$state_dir/config.json" "$runtime_config"
  /bin/cp -f "$state_dir/monitor_ed25519" "$runtime_identity"
  /bin/cp -f "$state_dir/known_hosts" "$runtime_known_hosts"
  chmod 600 "$runtime_config" "$runtime_identity" "$runtime_known_hosts"
  : >"$log_file"
  printf '%s\n' "$port" >"$port_file"
  if ! /bin/launchctl submit -l "$service_label" -o "$log_file" -e "$log_file" -- \
      /usr/local/bin/python3 "$runtime_dashboard_program" --port "$port" --no-open \
      --config "$runtime_config" --identity-file "$runtime_identity" \
      --known-hosts-file "$runtime_known_hosts" --result-directory "$runtime_result_dir"; then
    rm -f -- "$port_file"
    echo "failed to submit dashboard to the current macOS login session" >&2
    exit 1
  fi
  submitted=true
fi

ready=false
for _ in {1..50}; do
  running_pid=$(service_pid || true)
  if service_healthy "$running_pid" "$port"; then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  if [[ "$submitted" == true ]]; then
    /bin/launchctl remove "$service_label" >/dev/null 2>&1 || true
    rm -f -- "$port_file"
  fi
  echo "dashboard did not become healthy" >&2
  tail -n 40 "$log_file" >&2 || true
  exit 1
fi

rm -f -- "$legacy_pid_file"
url="http://127.0.0.1:$port/"
if [[ "$open_browser" == true ]]; then
  /usr/bin/open "$url"
fi
echo "DASHBOARD RUNNING pid=$running_pid url=$url"
echo "浏览器、终端关闭或网络断开都不会停止监控；Mac 重启、注销或手动停止后需再运行此脚本。"
