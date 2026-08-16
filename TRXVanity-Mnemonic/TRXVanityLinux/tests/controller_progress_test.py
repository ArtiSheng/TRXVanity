#!/usr/bin/env python3
"""Strict PROGRESS telemetry tests without a native engine process."""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import controller  # noqa: E402


def simulated_controller() -> tuple[controller.Controller, dict, list[dict]]:
    instance = controller.Controller.__new__(controller.Controller)
    status = {
        "engine_batch_capacity": 4_194_304,
        "engine_batch_size": 524_288,
        "run_attempt_offset": 0,
        "run_elapsed_offset_seconds": 0.0,
    }
    updates: list[dict] = []
    instance.public_status = lambda: copy.deepcopy(status)

    def update(**changes) -> None:  # noqa: ANN003
        updates.append(changes)
        status.update(changes)

    instance.update = update
    return instance, status, updates


class ControllerProgressTests(unittest.TestCase):
    def test_valid_current_progress_updates_the_tuned_batch(self) -> None:
        instance, status, updates = simulated_controller()
        accepted = instance._handle_progress(
            (
                "PROGRESS",
                "123456789",
                "2099000.25",
                "60.5",
                "58.0",
                "1.0",
                "1048576",
                "123000000",
                "456789",
            )
        )

        self.assertTrue(accepted)
        self.assertEqual(status["engine_batch_size"], 1_048_576)
        self.assertEqual(updates[-1]["attempts"], 123_456_789)
        self.assertEqual(updates[-1]["speed"], 2_099_000.25)

    def test_progress_adds_only_validated_prior_run_offsets(self) -> None:
        instance, status, updates = simulated_controller()
        status["run_attempt_offset"] = 9_000
        status["run_elapsed_offset_seconds"] = 40.0
        self.assertTrue(
            instance._handle_progress(("PROGRESS", "1000", "20.5", "5.0"))
        )
        self.assertEqual(updates[-1]["attempts"], 10_000)
        self.assertEqual(updates[-1]["elapsed_seconds"], 45.0)

    def test_old_progress_remains_compatible_without_overwriting_batch(self) -> None:
        instance, status, updates = simulated_controller()
        self.assertTrue(
            instance._handle_progress(("PROGRESS", "100", "20.5", "5.0"))
        )
        self.assertEqual(status["engine_batch_size"], 524_288)
        self.assertNotIn("engine_batch_size", updates[-1])

    def test_nonfinite_negative_or_out_of_range_progress_is_rejected(self) -> None:
        invalid = (
            ("PROGRESS", "1", "nan", "1"),
            ("PROGRESS", "1", "inf", "1"),
            ("PROGRESS", "1", "1", "-inf"),
            ("PROGRESS", "-1", "1", "1"),
            ("PROGRESS", "18446744073709551616", "1", "1"),
            ("PROGRESS", "1", "1", "1", "partial"),
            ("PROGRESS", "1", "1", "1", "partial", "partial"),
            ("PROGRESS", "1", "1", "1", "0", "0", "0"),
            ("PROGRESS", "1", "1", "1", "0", "0", "127"),
            ("PROGRESS", "1", "1", "1", "0", "0", "4194305"),
            ("PROGRESS", "1", "1", "1", "0", "0", "not-a-batch"),
        )
        for fields in invalid:
            with self.subTest(fields=fields):
                instance, status, updates = simulated_controller()
                original = copy.deepcopy(status)
                self.assertFalse(instance._handle_progress(fields))
                self.assertEqual(updates, [])
                self.assertEqual(status, original)


if __name__ == "__main__":
    unittest.main()
