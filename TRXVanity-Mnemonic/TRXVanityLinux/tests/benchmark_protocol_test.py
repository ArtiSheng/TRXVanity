#!/usr/bin/env python3
"""Protocol parsing tests for the sustained engine benchmark."""

from __future__ import annotations

import math
import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import benchmark  # noqa: E402


class BenchmarkProtocolTests(unittest.TestCase):
    def test_current_ready_and_progress_protocol(self) -> None:
        ready = benchmark.parse_ready(
            (
                "READY", "NVIDIA GeForce RTX 5090", "2097152", "smart",
                "8", "130560", "256", "384", "cuda-bip39+openssl-cpu",
                "16", "cgroup-v2",
            )
        )
        self.assertEqual(ready.cuda_master_block_size, 256)
        self.assertEqual(ready.cuda_address_block_size, 384)
        self.assertEqual(ready.cpu_workers, 8)
        self.assertEqual(ready.cpu_budget, 16)
        self.assertEqual(ready.cpu_budget_source, "cgroup-v2")

        progress = benchmark.parse_progress(
            ("PROGRESS", "1000", "20.5", "5", "4.9", "0", "276480", "900", "100")
        )
        self.assertEqual(progress.gpu_attempts, 900)
        self.assertEqual(progress.cpu_attempts, 100)

    def test_legacy_ready_and_malformed_extensions(self) -> None:
        legacy_fields = (
            "READY", "NVIDIA GeForce RTX 5090", "2097152", "smart",
            "8", "130560", "256", "384", "cuda-bip39+openssl-cpu",
        )
        self.assertEqual(len(legacy_fields) - 1, 8)
        legacy = benchmark.parse_ready(legacy_fields)
        self.assertEqual(legacy.cpu_workers, 8)
        self.assertEqual(legacy.cuda_master_block_size, 256)
        self.assertEqual(legacy.cuda_address_block_size, 384)
        self.assertEqual(legacy.cpu_budget, 0)
        self.assertEqual(legacy.cpu_budget_source, "legacy")

        for malformed in (
            (
                "READY", "GPU", "1", "smart", "0", "1", "256", "384",
                "cuda-bip39", "16",
            ),
            (
                "READY", "GPU", "1", "smart", "0", "1", "256", "384",
                "cuda-bip39", "0", "cgroup-v2",
            ),
            (
                "READY", "GPU", "1", "smart", "0", "1", "256", "384",
                "cuda-bip39", "16", "untrusted-source",
            ),
        ):
            with self.subTest(malformed=malformed), self.assertRaises(
                benchmark.BenchmarkError
            ):
                benchmark.parse_ready(malformed)

        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.parse_ready(("NOT_READY",) + legacy_fields[1:])

    def test_nonfinite_protocol_floats_are_rejected(self) -> None:
        for value in ("nan", "inf", "-inf"):
            with self.subTest(value=value), self.assertRaises(benchmark.BenchmarkError):
                benchmark.parse_progress(
                    ("PROGRESS", "1", value, "1", "1", "1", "128", "1", "0")
                )
        self.assertTrue(math.isfinite(benchmark.parse_nonnegative_float("1.5", "x")))


if __name__ == "__main__":
    unittest.main()
