#!/usr/bin/env python3
"""Local-only dashboard for a remote TRXVanity public search process."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import webbrowser


DASHBOARD_DIR = Path(__file__).resolve().parent
PROJECT_DIR = DASHBOARD_DIR.parent
STATE_DIR = DASHBOARD_DIR / "state"
CONFIG_PATH = STATE_DIR / "config.json"
DEFAULT_RESULT_DIR = PROJECT_DIR / "local-jobs"
IDENTITY_FILE_OVERRIDE: Path | None = None
KNOWN_HOSTS_FILE_OVERRIDE: Path | None = None
RESULT_DIRECTORY_OVERRIDE: Path | None = None
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
}

_cache_lock = threading.Lock()
_cache_value: dict[str, object] | None = None

JOB_ID_PATTERN = re.compile(r"[0-9A-Fa-f]{32}")
ADDRESS_PATTERN = re.compile(
    r"T[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]{33}"
)
TWEAK_PATTERN = re.compile(r"[0-9A-Fa-f]{64}")


def decode_record(value: str) -> list[str]:
    try:
        decoded = base64.b64decode(value, validate=True).decode("utf-8", "replace")
    except (ValueError, UnicodeError):
        return []
    return decoded.split("\t")


def parse_status(stdout: str) -> dict[str, object]:
    lines = stdout.splitlines()
    if not lines or lines[0] != "TRXVANITY_STATUS_V1" or lines[-1] != "END":
        raise RuntimeError("远端状态协议不完整")
    raw: dict[str, str] = {}
    for line in lines[1:-1]:
        key, separator, value = line.partition("\t")
        if separator and key:
            raw[key] = value
    records = {
        key.removeprefix("RECORD_").lower(): decode_record(value)
        for key, value in raw.items()
        if key.startswith("RECORD_")
    }
    progress = records.get("progress", [])
    ready = records.get("ready", [])
    searching = records.get("searching", [])
    result = records.get("result", [])
    security = records.get("security", [])
    try:
        log = base64.b64decode(raw.get("LOG_BASE64", ""), validate=True).decode(
            "utf-8", "replace"
        )
    except (ValueError, UnicodeError):
        log = ""
    job_id = ""
    for record in (searching, progress, ready, security, result):
        if len(record) >= 3:
            job_id = record[2]
            break

    def current_job(record: list[str]) -> list[str]:
        return record if len(record) >= 3 and record[2] == job_id else []

    progress = current_job(progress)
    ready = current_job(ready)
    searching = current_job(searching)
    result = current_job(result)
    security = current_job(security)
    error_record = current_job(records.get("error", []))
    return {
        "ok": True,
        "fetched_at": int(time.time()),
        "host": raw.get("HOST", ""),
        "os": raw.get("OS", ""),
        "state": raw.get("STATE", "unknown"),
        "pid": raw.get("PID", ""),
        "started_at": raw.get("STARTED_AT", ""),
        "gpu": raw.get("GPU", ""),
        "driver": raw.get("DRIVER", ""),
        "memory_total_mib": raw.get("MEMORY_TOTAL_MIB", ""),
        "memory_used_mib": raw.get("MEMORY_USED_MIB", ""),
        "utilization_percent": raw.get("UTILIZATION_PERCENT", ""),
        "temperature_c": raw.get("TEMPERATURE_C", ""),
        "power_w": raw.get("POWER_W", ""),
        "job_id": job_id,
        "suffix": searching[3] if len(searching) == 4 else "",
        "device": ready[3] if len(ready) == 5 else "",
        "lanes": ready[4] if len(ready) == 5 else "",
        "attempts": progress[3] if len(progress) == 6 else "0",
        "speed": progress[4] if len(progress) == 6 else "0",
        "elapsed": progress[5] if len(progress) == 6 else "0",
        "public_only": len(security) == 4 and security[3] == "PUBLIC_ONLY",
        "result": {
            "address": result[3] if len(result) == 7 else "",
            "attempts": result[5] if len(result) == 7 else "",
            "elapsed": result[6] if len(result) == 7 else "",
        },
        "_result_record": result,
        "error_record": error_record,
        "log": log,
        "log_size_bytes": raw.get("LOG_SIZE_BYTES", "0"),
    }


def validate_result_record(record: list[str], expected_job_id: str) -> None:
    if len(record) != 7 or record[0] != "RESULT" or record[1] != "1":
        raise RuntimeError("远端 RESULT 字段数量或协议版本无效")
    if JOB_ID_PATTERN.fullmatch(record[2]) is None or record[2] != expected_job_id:
        raise RuntimeError("远端 RESULT 任务 ID 无效或与当前任务不符")
    if ADDRESS_PATTERN.fullmatch(record[3]) is None:
        raise RuntimeError("远端 RESULT 地址格式无效")
    if TWEAK_PATTERN.fullmatch(record[4]) is None:
        raise RuntimeError("远端 RESULT 公开偏移格式无效")
    if not record[5].isdigit():
        raise RuntimeError("远端 RESULT 尝试次数格式无效")
    try:
        elapsed = float(record[6])
    except ValueError as exc:
        raise RuntimeError("远端 RESULT 运行时间格式无效") from exc
    if not math.isfinite(elapsed) or elapsed < 0:
        raise RuntimeError("远端 RESULT 运行时间无效")


def matching_result_path(result_dir: Path, job_id: str) -> Path:
    matches: list[Path] = []
    for request_path in result_dir.glob("*.request"):
        try:
            if request_path.is_symlink() or request_path.stat().st_size > 4096:
                continue
            request_lines = request_path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            continue
        if f"JOB_ID={job_id}" in request_lines:
            matches.append(request_path.with_suffix(".result"))
    if len(matches) > 1:
        raise RuntimeError("本地存在多个相同任务 ID 的 request，拒绝选择结果文件")
    return matches[0] if matches else result_dir / f"{job_id}.result"


def write_result_atomically(path: Path, payload: bytes) -> None:
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 4096:
            raise RuntimeError(f"本地结果路径不安全：{path}")
        if path.read_bytes() != payload:
            raise RuntimeError(f"本地结果文件已存在且内容不同：{path}")
        return

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("写入本地结果文件失败")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            os.link(temporary_path, path)
        except FileExistsError:
            if path.is_symlink() or not path.is_file() or path.read_bytes() != payload:
                raise RuntimeError(f"本地结果路径发生冲突：{path}")
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def archive_result(
    record: list[str], expected_job_id: str, config: dict[str, object]
) -> dict[str, str]:
    if not record:
        return {"state": "waiting", "message": "等待远端命中"}
    validate_result_record(record, expected_job_id)
    result_dir = Path(
        str(config.get("result_directory", DEFAULT_RESULT_DIR))
    ).expanduser().resolve()
    result_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if result_dir == DEFAULT_RESULT_DIR.resolve():
        result_dir.chmod(0o700)
    result_path = matching_result_path(result_dir, expected_job_id)
    payload = ("\t".join(record) + "\n").encode("ascii")
    write_result_atomically(result_path, payload)
    result_path.chmod(0o600)
    saved_at = datetime.fromtimestamp(
        result_path.stat().st_mtime
    ).astimezone().isoformat(timespec="seconds")
    return {
        "state": "saved",
        "message": "RESULT 已安全保存到本地",
        "path": str(result_path),
        "saved_at": saved_at,
    }


def load_config() -> dict[str, object]:
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    if IDENTITY_FILE_OVERRIDE is not None:
        config["identity_file"] = str(IDENTITY_FILE_OVERRIDE)
    if KNOWN_HOSTS_FILE_OVERRIDE is not None:
        config["known_hosts_file"] = str(KNOWN_HOSTS_FILE_OVERRIDE)
    if RESULT_DIRECTORY_OVERRIDE is not None:
        config["result_directory"] = str(RESULT_DIRECTORY_OVERRIDE)
    return config


def collect_remote_status(config: dict[str, object]) -> dict[str, object]:
    host = str(config["host"])
    user = str(config.get("user", "root"))
    port = int(config["port"])
    key_path = Path(str(config["identity_file"])).expanduser().resolve()
    known_hosts = Path(
        str(config.get("known_hosts_file", STATE_DIR / "known_hosts"))
    ).expanduser().resolve()
    if not key_path.is_file():
        raise RuntimeError(f"状态 SSH 私钥不存在：{key_path}")
    command = [
        "/usr/bin/ssh", "-i", str(key_path), "-p", str(port),
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
        "-o", "ServerAliveInterval=5", "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"UserKnownHostsFile={known_hosts}",
        f"{user}@{host}", "status",
    ]
    completed = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=False,
        env={**os.environ, "LC_ALL": "C"},
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip().splitlines()
        raise RuntimeError(detail[-1] if detail else "SSH 状态读取失败")
    value = parse_status(completed.stdout)
    record = value.pop("_result_record")
    job_id = str(value.get("job_id", ""))
    try:
        value["delivery"] = archive_result(record, job_id, config)
    except (OSError, UnicodeError, ValueError, RuntimeError) as exc:
        value["delivery"] = {
            "state": "error",
            "message": f"远端已返回状态，但本地结果保存失败：{exc}",
        }
    value["stale"] = False
    value["checked_at"] = int(time.time())
    return value


def publish_status(value: dict[str, object]) -> None:
    global _cache_value
    with _cache_lock:
        _cache_value = value


def publish_connection_error(exc: Exception) -> None:
    global _cache_value
    checked_at = int(time.time())
    with _cache_lock:
        if _cache_value is not None and _cache_value.get("ok"):
            stale = dict(_cache_value)
            stale["stale"] = True
            stale["connection_error"] = str(exc)
            stale["checked_at"] = checked_at
            _cache_value = stale
        else:
            _cache_value = {
                "ok": False,
                "fetched_at": checked_at,
                "checked_at": checked_at,
                "error": str(exc),
            }


def status_worker(stop_event: threading.Event) -> None:
    while not stop_event.is_set():
        interval = 2.0
        try:
            config = load_config()
            interval = max(1.0, min(30.0, float(config.get("poll_interval_seconds", 2))))
            publish_status(collect_remote_status(config))
        except (OSError, KeyError, ValueError, json.JSONDecodeError,
                subprocess.TimeoutExpired, RuntimeError) as exc:
            publish_connection_error(exc)
        stop_event.wait(interval)


def current_status() -> dict[str, object]:
    with _cache_lock:
        if _cache_value is None:
            return {
                "ok": False,
                "fetched_at": int(time.time()),
                "error": "正在建立只读 SSH 状态连接",
            }
        return dict(_cache_value)


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "TRXVanityDashboard/1"

    def do_GET(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path
        if path == "/api/status":
            payload = json.dumps(current_status(), ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.send_security_headers()
            self.end_headers()
            self.wfile.write(payload)
            return
        static = STATIC_FILES.get(path)
        if static is None:
            self.send_error(404)
            return
        filename, content_type = static
        payload = (DASHBOARD_DIR / filename).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(payload)))
        self.send_security_headers()
        self.end_headers()
        self.wfile.write(payload)

    def send_security_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'",
        )

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> int:
    global CONFIG_PATH, IDENTITY_FILE_OVERRIDE, KNOWN_HOSTS_FILE_OVERRIDE
    global RESULT_DIRECTORY_OVERRIDE
    parser = argparse.ArgumentParser(description="TRXVanity 本地只读监控台")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    parser.add_argument("--identity-file", type=Path)
    parser.add_argument("--known-hosts-file", type=Path)
    parser.add_argument("--result-directory", type=Path)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("--port 必须在 1024 到 65535 之间")
    CONFIG_PATH = args.config.expanduser().resolve()
    if args.identity_file is not None:
        IDENTITY_FILE_OVERRIDE = args.identity_file.expanduser().resolve()
    if args.known_hosts_file is not None:
        KNOWN_HOSTS_FILE_OVERRIDE = args.known_hosts_file.expanduser().resolve()
    if args.result_directory is not None:
        RESULT_DIRECTORY_OVERRIDE = args.result_directory.expanduser().resolve()
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    stop_event = threading.Event()
    collector = threading.Thread(
        target=status_worker, args=(stop_event,), name="result-collector", daemon=True
    )
    collector.start()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), DashboardHandler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"DASHBOARD READY {url}", flush=True)
    if not args.no_open:
        threading.Timer(0.25, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        server.server_close()
        collector.join(timeout=3)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
