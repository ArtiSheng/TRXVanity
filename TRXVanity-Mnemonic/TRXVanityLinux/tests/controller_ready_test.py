#!/usr/bin/env python3
"""READY telemetry parsing tests; no CUDA process or network is used."""

from __future__ import annotations

import json
import sys
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import controller  # noqa: E402


class ControllerReadyTests(unittest.TestCase):
    def test_current_ready_protocol_exposes_all_approved_telemetry(self) -> None:
        fields = (
            "READY",
            "NVIDIA GeForce RTX 5090 (SM 12.0, 170 multiprocessors)",
            "4194304",
            "smart",
            "8",
            "1048576",
            "256",
            "384",
            "cuda-bip39+openssl-cpu",
            "16",
            "cgroup-v2",
        )
        status = controller.parse_engine_ready_status(fields, "rtx4090")

        self.assertEqual(
            status["engine_device"],
            "NVIDIA GeForce RTX 5090 (SM 12.0, 170 multiprocessors)",
        )
        self.assertEqual(status["engine_profile"], "smart")
        self.assertEqual(status["engine_batch_capacity"], 4_194_304)
        self.assertEqual(status["engine_cpu_workers"], 8)
        self.assertEqual(status["engine_batch_size"], 1_048_576)
        self.assertEqual(status["engine_cuda_master_block_size"], 256)
        self.assertEqual(status["engine_cuda_address_block_size"], 384)
        self.assertEqual(status["engine_kernel_mode"], "cuda-bip39+openssl-cpu")
        self.assertEqual(status["engine_cpu_budget"], 16)
        self.assertEqual(status["engine_cpu_budget_source"], "cgroup-v2")

    def test_old_ready_protocol_has_safe_telemetry_fallbacks(self) -> None:
        status = controller.parse_engine_ready_status(
            ("READY", "NVIDIA RTX 4090", "2097152", "rtx4090"), "smart"
        )

        self.assertEqual(status["engine_device"], "NVIDIA RTX 4090")
        self.assertEqual(status["engine_profile"], "rtx4090")
        self.assertEqual(status["engine_batch_capacity"], 2_097_152)
        for name in (
            "engine_cpu_workers",
            "engine_batch_size",
            "engine_cuda_master_block_size",
            "engine_cuda_address_block_size",
            "engine_cpu_budget",
        ):
            self.assertEqual(status[name], 0)
        self.assertEqual(status["engine_kernel_mode"], "")
        self.assertEqual(status["engine_cpu_budget_source"], "")

    def test_invalid_or_extra_ready_fields_cannot_enter_public_status(self) -> None:
        secret = "abandon abandon abandon abandon abandon abandon abandon abandon"
        fields = (
            "READY",
            "GPU\nsecret",
            "-1",
            "untrusted-profile",
            "257",
            "NaN",
            "31",
            "1056",
            secret,
            "999999999999999999999",
            secret,
            "AES_KEY=00112233445566778899aabbccddeeff",
        )
        status = controller.parse_engine_ready_status(fields, "smart")
        serialized = json.dumps(status)

        self.assertEqual(status["engine_device"], "GPU")
        self.assertEqual(status["engine_profile"], "smart")
        self.assertNotIn(secret, serialized)
        self.assertNotIn("AES_KEY", serialized)
        self.assertEqual(
            set(status),
            {
                "engine_device",
                "engine_profile",
                "engine_batch_capacity",
                "engine_cpu_workers",
                "engine_batch_size",
                "engine_cuda_master_block_size",
                "engine_cuda_address_block_size",
                "engine_kernel_mode",
                "engine_cpu_budget",
                "engine_cpu_budget_source",
            },
        )

    def test_ready_never_starts_after_stop_was_requested(self) -> None:
        instance = controller.Controller.__new__(controller.Controller)
        instance.args = SimpleNamespace(profile="smart", suffix="8888888")
        instance.stop_requested = threading.Event()
        instance.stop_requested.set()
        instance.started_search = False
        instance.exit_code = 1
        commands: list[str] = []
        instance.update = lambda **_changes: None
        instance.send_engine = commands.append

        keep_reading = instance._handle_ready(
            ("READY", "NVIDIA GeForce RTX 5090", "4194304", "smart")
        )

        self.assertFalse(keep_reading)
        self.assertEqual(instance.exit_code, 130)
        self.assertEqual(commands, ["EXIT"])
        self.assertFalse(any(command.startswith("START\t") for command in commands))

    def test_stop_arriving_while_start_is_sent_gets_a_final_stop(self) -> None:
        instance = controller.Controller.__new__(controller.Controller)
        instance.args = SimpleNamespace(profile="smart", suffix="8888888")
        instance.stop_requested = threading.Event()
        instance.started_search = False
        instance.exit_code = 1
        commands: list[str] = []
        instance.update = lambda **_changes: None

        def send(command: str) -> None:
            commands.append(command)
            if command.startswith("START\t"):
                instance.stop_requested.set()

        instance.send_engine = send
        keep_reading = instance._handle_ready(
            ("READY", "NVIDIA GeForce RTX 5090", "4194304", "smart")
        )

        self.assertFalse(keep_reading)
        self.assertEqual(instance.exit_code, 130)
        self.assertEqual(commands, ["START\t\t8888888", "STOP"])


if __name__ == "__main__":
    unittest.main()
