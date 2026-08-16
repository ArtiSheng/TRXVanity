#!/usr/bin/env python3
"""Persistent public-counter resume tests without secrets or CUDA."""

from __future__ import annotations

import json
import math
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import controller  # noqa: E402


class DummyRemote:
    public_origin = "https://example.invalid"
    heartbeat_endpoint = "https://example.invalid/heartbeat"


def args(runtime_dir: Path, suffix: str = "8888888") -> SimpleNamespace:
    return SimpleNamespace(
        runtime_dir=str(runtime_dir),
        suffix=suffix,
        profile="smart",
        upload_endpoint=None,
    )


class ControllerResumeTests(unittest.TestCase):
    def make_controller(self, runtime_dir: Path) -> controller.Controller:
        with (
            mock.patch.object(controller, "require_aes_key", return_value=bytearray(32)),
            mock.patch.object(controller, "RemoteBackup", return_value=DummyRemote()),
            mock.patch.object(controller, "HeartbeatClient", return_value=object()),
            mock.patch.object(controller, "OpenSslEvp", return_value=object()),
        ):
            return controller.Controller(args(runtime_dir))

    def test_same_suffix_search_snapshot_becomes_fixed_offsets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "status.json").write_text(
                json.dumps(
                    {
                        "suffix": "8888888",
                        "state": "searching",
                        "attempts": 123_456,
                        "elapsed_seconds": 78.5,
                    }
                ),
                encoding="utf-8",
            )
            instance = self.make_controller(runtime)
            self.assertEqual(instance.status["run_attempt_offset"], 123_456)
            self.assertEqual(instance.status["attempts"], 123_456)
            self.assertEqual(instance.status["run_elapsed_offset_seconds"], 78.5)
            self.assertEqual(instance.status["elapsed_seconds"], 78.5)

    def test_same_suffix_stopping_snapshot_becomes_fixed_offsets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "status.json").write_text(
                json.dumps(
                    {
                        "suffix": "8888888",
                        "state": "stopping",
                        "attempts": 8_326_623_641,
                        "elapsed_seconds": 4_007.958,
                    }
                ),
                encoding="utf-8",
            )
            instance = self.make_controller(runtime)
            self.assertEqual(instance.status["run_attempt_offset"], 8_326_623_641)
            self.assertEqual(instance.status["attempts"], 8_326_623_641)
            self.assertEqual(instance.status["run_elapsed_offset_seconds"], 4_007.958)
            self.assertEqual(instance.status["elapsed_seconds"], 4_007.958)

    def test_stopping_snapshot_rejects_invalid_offset_fields_independently(self) -> None:
        cases = (
            (True, 78.5, 0, 78.5),
            (123_456, math.inf, 123_456, 0.0),
        )
        for attempts, elapsed, expected_attempts, expected_elapsed in cases:
            with (
                self.subTest(attempts=attempts, elapsed=elapsed),
                tempfile.TemporaryDirectory() as directory,
            ):
                runtime = Path(directory)
                (runtime / "status.json").write_text(
                    json.dumps(
                        {
                            "suffix": "8888888",
                            "state": "stopping",
                            "attempts": attempts,
                            "elapsed_seconds": elapsed,
                        }
                    ),
                    encoding="utf-8",
                )
                instance = self.make_controller(runtime)
                self.assertEqual(instance.status["run_attempt_offset"], expected_attempts)
                self.assertEqual(instance.status["run_elapsed_offset_seconds"], expected_elapsed)

    def test_result_wrong_suffix_and_nonfinite_values_are_not_resumed(self) -> None:
        cases = (
            {"suffix": "8888888", "state": "result", "attempts": 7, "elapsed_seconds": 1},
            {"suffix": "77777777", "state": "searching", "attempts": 7, "elapsed_seconds": 1},
            {"suffix": "8888888", "state": "error", "attempts": True, "elapsed_seconds": math.inf},
        )
        for previous in cases:
            with self.subTest(previous=previous), tempfile.TemporaryDirectory() as directory:
                runtime = Path(directory)
                (runtime / "status.json").write_text(json.dumps(previous), encoding="utf-8")
                instance = self.make_controller(runtime)
                self.assertEqual(instance.status["run_attempt_offset"], 0)
                self.assertEqual(instance.status["run_elapsed_offset_seconds"], 0.0)


if __name__ == "__main__":
    unittest.main()
