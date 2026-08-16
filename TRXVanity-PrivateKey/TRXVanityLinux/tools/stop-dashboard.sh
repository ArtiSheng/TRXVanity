#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)
state_dir="$project_dir/dashboard/state"
dashboard_program="$project_dir/dashboard/dashboard.py"
port_file="$state_dir/dashboard.port"
legacy_pid_file="$state_dir/dashboard.pid"
service_label="com.artisheng.trxvanity.dashboard"

stopped=false
if /bin/launchctl list "$service_label" >/dev/null 2>&1; then
  /bin/launchctl remove "$service_label"
  for _ in {1..50}; do
    if ! /bin/launchctl list "$service_label" >/dev/null 2>&1; then
      stopped=true
      break
    fi
    sleep 0.1
  done
  if [[ "$stopped" != true ]]; then
    echo "dashboard service did not stop within five seconds" >&2
    exit 1
  fi
fi

if [[ -r "$legacy_pid_file" ]]; then
  read -r legacy_pid <"$legacy_pid_file" || true
  if [[ "$legacy_pid" =~ ^[0-9]+$ ]] && kill -0 "$legacy_pid" 2>/dev/null; then
    if ! ps -p "$legacy_pid" -o command= | /usr/bin/grep -F "$dashboard_program" >/dev/null; then
      echo "refusing legacy PID that belongs to another process: $legacy_pid" >&2
      exit 1
    fi
    kill "$legacy_pid"
    for _ in {1..50}; do
      if ! kill -0 "$legacy_pid" 2>/dev/null; then
        stopped=true
        break
      fi
      sleep 0.1
    done
    if kill -0 "$legacy_pid" 2>/dev/null; then
      echo "legacy dashboard process did not stop within five seconds" >&2
      exit 1
    fi
  fi
fi

rm -f -- "$port_file" "$legacy_pid_file"
if [[ "$stopped" == true ]]; then
  echo "DASHBOARD STOPPED"
else
  echo "DASHBOARD NOT RUNNING"
fi
