#!/usr/bin/env python3
"""Loopback-only dashboard that aggregates multiple TRX Vanity monitors.

The browser talks only to this local service.  Each configured upstream must be
an HTTP loopback address (normally an SSH tunnel), and only an explicit set of
public performance fields is copied into the aggregate response.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import http.server
import json
import math
import re
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Optional, Sequence, Tuple


APP_DIR = Path(__file__).resolve().parents[1]
WEB_DIR = APP_DIR / "web"
DEFAULT_MACHINE_SPECS = (
    "RTX 5090=http://127.0.0.1:8787",
)
MAX_RESPONSE_BYTES = 256 * 1024
MAX_MACHINES = 32
DEFAULT_TIMEOUT_SECONDS = 1.25
BASE58_ALPHABET = frozenset(
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
)

TEXT_FIELDS = {
    "updated_at": 80,
    "state": 40,
    "suffix": 64,
    "engine_device": 256,
    "engine_profile": 80,
    "engine_cpu_budget_source": 80,
    "engine_kernel_mode": 160,
    "heartbeat_at": 80,
}
INTEGER_FIELDS = {
    "attempts",
    "engine_cpu_workers",
    "engine_cpu_budget",
    "engine_batch_size",
    "engine_batch_capacity",
    "engine_cuda_master_block_size",
    "engine_cuda_address_block_size",
}
FLOAT_FIELDS = {"speed", "elapsed_seconds"}
BOOLEAN_FIELDS = {"heartbeat_ok"}
SEARCHING_STATES = {"searching"}
NAME_PATTERN = re.compile(r"^[^\x00-\x1f\x7f]{1,80}$")


class ConfigurationError(ValueError):
    """Raised when a machine or listener configuration is unsafe."""


class UpstreamError(RuntimeError):
    """A deliberately non-sensitive upstream failure."""


@dataclass(frozen=True)
class Machine:
    name: str
    base_url: str

    @property
    def machine_id(self) -> str:
        material = f"{self.name}\x00{self.base_url}".encode("utf-8")
        return hashlib.sha256(material).hexdigest()[:12]

    @property
    def status_url(self) -> str:
        return f"{self.base_url}/api/status"


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _is_loopback_hostname(hostname: Optional[str]) -> bool:
    if not hostname:
        return False
    return hostname.lower() in {"127.0.0.1", "localhost", "::1"}


def parse_machine_spec(spec: str) -> Machine:
    if "=" not in spec:
        raise ConfigurationError("machine must use NAME=http://127.0.0.1:PORT")
    name, raw_url = spec.split("=", 1)
    name = name.strip()
    raw_url = raw_url.strip()
    if not NAME_PATTERN.fullmatch(name):
        raise ConfigurationError("machine name must be 1-80 printable characters")

    parsed = urllib.parse.urlsplit(raw_url)
    if (
        parsed.scheme.lower() != "http"
        or not _is_loopback_hostname(parsed.hostname)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ConfigurationError(
            "machine URL must be a credential-free loopback HTTP origin"
        )
    try:
        port = parsed.port
    except ValueError as error:
        raise ConfigurationError("machine URL contains an invalid port") from error
    if port is None or not 1 <= port <= 65535:
        raise ConfigurationError("machine URL must include a valid port")

    hostname = parsed.hostname.lower()
    host_for_url = f"[{hostname}]" if ":" in hostname else hostname
    return Machine(name=name, base_url=f"http://{host_for_url}:{port}")


def parse_machines(specs: Iterable[str]) -> Tuple[Machine, ...]:
    machines = tuple(parse_machine_spec(spec) for spec in specs)
    if not machines:
        raise ConfigurationError("at least one machine is required")
    if len(machines) > MAX_MACHINES:
        raise ConfigurationError(f"at most {MAX_MACHINES} machines are supported")
    names = [machine.name.casefold() for machine in machines]
    origins = [machine.base_url for machine in machines]
    if len(set(names)) != len(names):
        raise ConfigurationError("machine names must be unique")
    if len(set(origins)) != len(origins):
        raise ConfigurationError("machine URLs must be unique")
    return machines


def validate_listen_host(host: str) -> None:
    if host != "127.0.0.1":
        raise ConfigurationError("multi-machine monitor must listen on 127.0.0.1")


def sanitize_status(raw_status: Any) -> Dict[str, Any]:
    """Return only explicitly approved public scalar telemetry."""
    if not isinstance(raw_status, Mapping):
        raise UpstreamError("upstream returned a non-object status")

    safe: Dict[str, Any] = {}
    for field, limit in TEXT_FIELDS.items():
        value = raw_status.get(field)
        if isinstance(value, str):
            safe[field] = value[:limit]
    for field in INTEGER_FIELDS:
        value = raw_status.get(field)
        if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 0xFFFFFFFFFFFFFFFF:
            safe[field] = value
    for field in FLOAT_FIELDS:
        value = raw_status.get(field)
        if (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
            and 0 <= float(value) <= 1e30
        ):
            safe[field] = float(value)
    for field in BOOLEAN_FIELDS:
        value = raw_status.get(field)
        if isinstance(value, bool):
            safe[field] = value
    return safe


def _read_upstream(machine: Machine, timeout: float) -> Tuple[Dict[str, Any], int]:
    request = urllib.request.Request(
        machine.status_url,
        headers={"Accept": "application/json", "User-Agent": "TRXVanity-MultiMonitor/1"},
        method="GET",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    started = dt.datetime.now(dt.timezone.utc)
    try:
        with opener.open(request, timeout=timeout) as response:
            if response.status != 200:
                raise UpstreamError(f"upstream returned HTTP {response.status}")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        raise UpstreamError(f"upstream returned HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError, OSError):
        raise UpstreamError("upstream is unreachable") from None
    if len(payload) > MAX_RESPONSE_BYTES:
        raise UpstreamError("upstream response is too large")
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise UpstreamError("upstream returned invalid JSON") from None
    elapsed = dt.datetime.now(dt.timezone.utc) - started
    return sanitize_status(decoded), max(0, round(elapsed.total_seconds() * 1000))


def fetch_machine(machine: Machine, timeout: float) -> Dict[str, Any]:
    try:
        status, latency_ms = _read_upstream(machine, timeout)
        return {
            "id": machine.machine_id,
            "name": machine.name,
            "source": urllib.parse.urlsplit(machine.base_url).netloc,
            "ok": True,
            "latency_ms": latency_ms,
            "fetched_at": utc_now(),
            "status": status,
            "error": "",
        }
    except UpstreamError as error:
        return {
            "id": machine.machine_id,
            "name": machine.name,
            "source": urllib.parse.urlsplit(machine.base_url).netloc,
            "ok": False,
            "latency_ms": None,
            "fetched_at": utc_now(),
            "status": {},
            "error": str(error),
        }


def build_forecast(
    suffix: str, attempts: int, speed: float
) -> Optional[Dict[str, Any]]:
    """Calculate one-search-space progress and cumulative hit probability."""
    if (
        not 1 <= len(suffix) <= 10
        or any(character not in BASE58_ALPHABET for character in suffix)
        or attempts < 0
        or not math.isfinite(speed)
        or speed < 0
    ):
        return None

    search_space = 58 ** len(suffix)
    work_progress = attempts / search_space
    miss_log = math.log1p(-1.0 / search_space)
    probability = min(1.0, max(0.0, -math.expm1(attempts * miss_log)))

    def remaining_seconds(target_ratio: float) -> Optional[float]:
        if speed <= 0:
            return None
        return max(0.0, search_space * target_ratio - attempts) / speed

    return {
        "search_space": search_space,
        "work_progress": work_progress,
        "cumulative_probability": probability,
        "until_50_seconds": remaining_seconds(0.5),
        "until_100_seconds": remaining_seconds(1.0),
    }


def collect_snapshot(machines: Sequence[Machine], timeout: float) -> Dict[str, Any]:
    results: list[Optional[Dict[str, Any]]] = [None] * len(machines)
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=len(machines), thread_name_prefix="trx-monitor"
    ) as executor:
        future_indexes = {
            executor.submit(fetch_machine, machine, timeout): index
            for index, machine in enumerate(machines)
        }
        for future in concurrent.futures.as_completed(future_indexes):
            index = future_indexes[future]
            try:
                results[index] = future.result()
            except Exception:  # defensive: never let one source break the dashboard
                machine = machines[index]
                results[index] = {
                    "id": machine.machine_id,
                    "name": machine.name,
                    "source": urllib.parse.urlsplit(machine.base_url).netloc,
                    "ok": False,
                    "latency_ms": None,
                    "fetched_at": utc_now(),
                    "status": {},
                    "error": "upstream collection failed",
                }

    final_results = [result for result in results if result is not None]
    online = [result for result in final_results if result["ok"]]
    running = [
        result
        for result in online
        if result["status"].get("state") in SEARCHING_STATES
    ]
    total_attempts = sum(int(result["status"].get("attempts", 0)) for result in online)
    total_speed = sum(float(result["status"].get("speed", 0.0)) for result in running)
    suffixes = {
        str(result["status"].get("suffix", ""))
        for result in running
        if result["status"].get("suffix")
    }
    common_suffix = next(iter(suffixes)) if len(suffixes) == 1 else ""
    search_elapsed_seconds = max(
        (float(result["status"].get("elapsed_seconds", 0.0)) for result in running),
        default=0.0,
    )
    forecast = build_forecast(common_suffix, total_attempts, total_speed)
    return {
        "version": 1,
        "generated_at": utc_now(),
        "refresh_seconds": 2,
        "summary": {
            "configured_count": len(final_results),
            "online_count": len(online),
            "running_count": len(running),
            "total_speed": total_speed,
            "total_attempts": total_attempts,
            "common_suffix": common_suffix,
            "elapsed_seconds": search_elapsed_seconds,
            "forecast": forecast,
        },
        "machines": final_results,
    }


class MultiMonitorServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: Tuple[str, int],
        machines: Sequence[Machine],
        timeout: float,
        web_dir: Path = WEB_DIR,
        quiet: bool = False,
    ) -> None:
        self.machines = tuple(machines)
        self.upstream_timeout = timeout
        self.web_dir = web_dir
        self.quiet = quiet
        super().__init__(address, MultiMonitorHandler)


class MultiMonitorHandler(http.server.BaseHTTPRequestHandler):
    server_version = "TRXVanityMultiMonitor/1"

    STATIC_FILES = {
        "/": ("multi.html", "text/html; charset=utf-8"),
        "/index.html": ("multi.html", "text/html; charset=utf-8"),
        "/app.js": ("multi.js", "text/javascript; charset=utf-8"),
        "/style.css": ("multi.css", "text/css; charset=utf-8"),
    }

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        if path in {"/api/status", "/api/machines"}:
            snapshot = collect_snapshot(
                self.server.machines, self.server.upstream_timeout  # type: ignore[attr-defined]
            )
            payload = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8"
            )
            self._send(200, "application/json; charset=utf-8", payload)
            return
        static = self.STATIC_FILES.get(path)
        if static is None:
            self._send(404, "text/plain; charset=utf-8", b"HTTP 404\n")
            return
        filename, content_type = static
        try:
            payload = (self.server.web_dir / filename).read_bytes()  # type: ignore[attr-defined]
        except OSError:
            self._send(500, "text/plain; charset=utf-8", b"HTTP 500\n")
            return
        self._send(200, content_type, payload)

    def do_HEAD(self) -> None:  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        static = self.STATIC_FILES.get(path)
        if static is None:
            self._send(404, "text/plain; charset=utf-8", b"", send_body=False)
            return
        filename, content_type = static
        try:
            size = (self.server.web_dir / filename).stat().st_size  # type: ignore[attr-defined]
        except OSError:
            self._send(500, "text/plain; charset=utf-8", b"", send_body=False)
            return
        self._send(200, content_type, b"", send_body=False, content_length=size)

    def log_message(self, message_format: str, *args: Any) -> None:
        if not self.server.quiet:  # type: ignore[attr-defined]
            super().log_message(message_format, *args)

    def _send(
        self,
        status: int,
        content_type: str,
        payload: bytes,
        *,
        send_body: bool = True,
        content_length: Optional[int] = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload) if content_length is None else content_length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self'; script-src 'self'; "
            "style-src 'self'; img-src 'none'; object-src 'none'; "
            "base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        if send_body:
            self.wfile.write(payload)


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Aggregate loopback TRX Vanity SSH tunnels into one local dashboard"
    )
    parser.add_argument(
        "--machine",
        action="append",
        metavar="NAME=URL",
        help="machine label and loopback monitor origin; repeat for every machine",
    )
    parser.add_argument("--http-host", default="127.0.0.1")
    parser.add_argument("--http-port", type=int, default=8790)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument("--quiet", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = create_parser()
    args = parser.parse_args(argv)
    try:
        validate_listen_host(args.http_host)
        if not 0 <= args.http_port <= 65535:
            raise ConfigurationError("HTTP port must be between 0 and 65535")
        if not math.isfinite(args.timeout) or not 0.1 <= args.timeout <= 10:
            raise ConfigurationError("timeout must be between 0.1 and 10 seconds")
        machines = parse_machines(args.machine or DEFAULT_MACHINE_SPECS)
    except ConfigurationError as error:
        parser.error(str(error))

    try:
        server = MultiMonitorServer(
            (args.http_host, args.http_port), machines, args.timeout, quiet=args.quiet
        )
    except OSError as error:
        print(f"multi-monitor: could not bind loopback listener: {error}", file=sys.stderr)
        return 1
    host, port = server.server_address[:2]
    print(f"Multi-machine monitor: http://{host}:{port}/", flush=True)
    for machine in machines:
        print(f"  {machine.name}: {machine.base_url}", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
