#!/usr/bin/env python3
"""Tests for the loopback-only multi-machine monitor."""

from __future__ import annotations

import json
import math
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import multi_monitor  # noqa: E402


class FakeStatusHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/api/status":
            self.send_error(404)
            return
        barrier = getattr(self.server, "barrier", None)
        if barrier is not None:
            barrier.wait(timeout=1)
        payload = json.dumps(self.server.payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, message_format: str, *args: object) -> None:
        pass


class MultiMonitorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.servers: list[ThreadingHTTPServer] = []
        self.threads: list[threading.Thread] = []

    def tearDown(self) -> None:
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=2)

    def start_status_server(self, payload: dict, barrier: threading.Barrier) -> int:
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeStatusHandler)
        server.payload = payload
        server.barrier = barrier
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.servers.append(server)
        self.threads.append(thread)
        return server.server_address[1]

    def test_machine_specs_allow_only_credential_free_loopback_origins(self) -> None:
        machine = multi_monitor.parse_machine_spec("GPU A=http://127.0.0.1:8787")
        self.assertEqual(machine.name, "GPU A")
        self.assertEqual(machine.status_url, "http://127.0.0.1:8787/api/status")

        invalid = (
            "missing separator",
            "remote=https://127.0.0.1:8787",
            "remote=http://example.com:8787",
            "secret=http://root:password@127.0.0.1:8787",
            "path=http://127.0.0.1:8787/private",
            "query=http://127.0.0.1:8787/?token=secret",
            "no-port=http://127.0.0.1",
        )
        for spec in invalid:
            with self.subTest(spec=spec):
                with self.assertRaises(multi_monitor.ConfigurationError):
                    multi_monitor.parse_machine_spec(spec)
        with self.assertRaises(multi_monitor.ConfigurationError):
            multi_monitor.validate_listen_host("0.0.0.0")

    def test_status_sanitizer_excludes_secrets_and_unknown_fields(self) -> None:
        status = multi_monitor.sanitize_status(
            {
                "state": "searching",
                "speed": 2_100_000.5,
                "attempts": 99,
                "engine_device": "RTX 5090",
                "heartbeat_ok": True,
                "mnemonic": "secret words must never leave the source",
                "aes_key": "secret-key",
                "upload_origin": "https://example.invalid/?token=secret",
                "result_address": "public-but-not-required",
            }
        )
        serialized = json.dumps(status)
        self.assertEqual(status["speed"], 2_100_000.5)
        self.assertEqual(status["attempts"], 99)
        self.assertNotIn("mnemonic", serialized)
        self.assertNotIn("secret", serialized)
        self.assertNotIn("upload_origin", status)
        self.assertNotIn("result_address", status)

    def test_forecast_distinguishes_work_progress_from_hit_probability(self) -> None:
        forecast = multi_monitor.build_forecast("1", attempts=29, speed=2)
        self.assertIsNotNone(forecast)
        assert forecast is not None
        self.assertEqual(forecast["search_space"], 58)
        self.assertEqual(forecast["work_progress"], 0.5)
        self.assertEqual(forecast["until_50_seconds"], 0)
        self.assertEqual(forecast["until_100_seconds"], 14.5)
        expected_probability = -math.expm1(29 * math.log1p(-1 / 58))
        self.assertAlmostEqual(
            forecast["cumulative_probability"], expected_probability, places=15
        )
        self.assertLess(forecast["cumulative_probability"], 0.5)
        self.assertIsNone(multi_monitor.build_forecast("0", attempts=1, speed=1))
        self.assertIsNone(multi_monitor.build_forecast("1" * 11, attempts=1, speed=1))

    def test_collection_fetches_in_parallel_and_builds_totals(self) -> None:
        barrier = threading.Barrier(2)
        common = {
            "state": "searching",
            "suffix": "8888888",
            "engine_device": "GPU",
            "heartbeat_ok": True,
            "mnemonic": "must-not-escape",
        }
        port_a = self.start_status_server(
            {**common, "speed": 2_000_000, "attempts": 10}, barrier
        )
        port_b = self.start_status_server(
            {**common, "speed": 3_000_000, "attempts": 20}, barrier
        )
        machines = multi_monitor.parse_machines(
            (
                f"GPU A=http://127.0.0.1:{port_a}",
                f"GPU B=http://127.0.0.1:{port_b}",
            )
        )

        snapshot = multi_monitor.collect_snapshot(machines, timeout=1.5)

        self.assertEqual(snapshot["summary"]["configured_count"], 2)
        self.assertEqual(snapshot["summary"]["online_count"], 2)
        self.assertEqual(snapshot["summary"]["running_count"], 2)
        self.assertEqual(snapshot["summary"]["total_speed"], 5_000_000)
        self.assertEqual(snapshot["summary"]["total_attempts"], 30)
        self.assertEqual(snapshot["summary"]["common_suffix"], "8888888")
        self.assertEqual(snapshot["summary"]["elapsed_seconds"], 0)
        self.assertEqual(
            snapshot["summary"]["forecast"]["search_space"], 58**7
        )
        self.assertEqual(
            snapshot["summary"]["forecast"]["work_progress"], 30 / 58**7
        )
        self.assertNotIn("must-not-escape", json.dumps(snapshot))

    def test_http_server_serves_dashboard_and_aggregate_api(self) -> None:
        barrier = threading.Barrier(1)
        upstream_port = self.start_status_server(
            {
                "state": "searching",
                "suffix": "8888888",
                "speed": 1_234_567,
                "attempts": 456,
                "engine_device": "RTX Test",
                "heartbeat_ok": True,
            },
            barrier,
        )
        machines = multi_monitor.parse_machines(
            (f"GPU Test=http://127.0.0.1:{upstream_port}",)
        )
        server = multi_monitor.MultiMonitorServer(
            ("127.0.0.1", 0), machines, timeout=1, quiet=True
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.servers.append(server)
        self.threads.append(thread)
        base = f"http://127.0.0.1:{server.server_address[1]}"

        with urllib.request.urlopen(f"{base}/", timeout=2) as response:
            html = response.read().decode("utf-8")
            self.assertEqual(response.status, 200)
            self.assertIn("多机器搜索监控", html)
            for element_id in (
                "searchedElapsed",
                "until50",
                "until100",
                "progress",
                "progressBar",
                "probability",
            ):
                self.assertIn(f'id="{element_id}"', html)
            self.assertIn("63.21%", html)
            self.assertIn("default-src 'self'", response.headers["Content-Security-Policy"])
        with urllib.request.urlopen(f"{base}/style.css", timeout=2) as response:
            css = response.read().decode("utf-8")
            self.assertIn(
                ".forecast-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr))",
                css,
            )
            self.assertIn(".forecast-grid>div{min-width:0", css)
            self.assertIn("text-align:center", css)
            self.assertEqual(css.count(".forecast-grid{"), 1)
        with urllib.request.urlopen(f"{base}/api/status", timeout=2) as response:
            snapshot = json.load(response)
            self.assertEqual(response.status, 200)
            self.assertEqual(snapshot["summary"]["total_speed"], 1_234_567)
            self.assertEqual(snapshot["machines"][0]["status"]["engine_device"], "RTX Test")
        try:
            urllib.request.urlopen(f"{base}/not-found", timeout=2)
        except urllib.error.HTTPError as error:
            self.assertEqual(error.code, 404)
            error.close()
        else:
            self.fail("unknown static paths must return HTTP 404")


if __name__ == "__main__":
    unittest.main()
