#!/usr/bin/env python3
"""Deterministic controller watchdog simulations without a CUDA process."""

from __future__ import annotations

import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import controller  # noqa: E402


class FakeProcess:
    def __init__(self) -> None:
        self.return_code = None
        self.terminated = threading.Event()
        self.killed = False

    def poll(self):  # noqa: ANN201
        return self.return_code

    def terminate(self) -> None:
        self.return_code = -15
        self.terminated.set()

    def wait(self, timeout=None):  # noqa: ANN001, ANN201
        if not self.terminated.wait(timeout):
            raise controller.subprocess.TimeoutExpired("fake-engine", timeout)
        return self.return_code

    def kill(self) -> None:
        self.killed = True
        self.return_code = -9
        self.terminated.set()


def simulated_controller() -> tuple[controller.Controller, FakeProcess, list[dict]]:
    instance = controller.Controller.__new__(controller.Controller)
    process = FakeProcess()
    updates: list[dict] = []
    instance.stop_requested = threading.Event()
    instance.received_result = False
    instance.cleanup_handoff_started = False
    instance.process = process
    instance.exit_code = 1
    instance.stop_guard_lock = threading.Lock()
    instance.stop_guard_thread = None
    instance.controller_done = threading.Event()
    instance.progress_watchdog_condition = threading.Condition()
    instance.progress_watchdog_deadline = None
    instance.progress_watchdog_phase = None
    instance.progress_watchdog_error = None
    instance.progress_watchdog_closed = False
    instance.progress_watchdog_thread = None
    instance.update = lambda **changes: updates.append(changes)
    return instance, process, updates


class ControllerWatchdogTests(unittest.TestCase):
    def test_operator_stop_escalates_if_engine_ignores_protocol(self) -> None:
        instance, process, updates = simulated_controller()
        commands: list[str] = []
        instance.send_engine = commands.append
        with mock.patch.object(controller, "ENGINE_STOP_GRACE_SECONDS", 0.04):
            instance.request_stop()
            self.assertTrue(process.terminated.wait(1.0))
            assert instance.stop_guard_thread is not None
            instance.stop_guard_thread.join(timeout=1.0)

        self.assertEqual(instance.exit_code, 130)
        self.assertEqual(commands, ["STOP", "STOP"])
        self.assertEqual(updates[-1]["state"], "stopping")

    def test_second_operator_stop_terminates_immediately(self) -> None:
        instance, process, _updates = simulated_controller()
        instance.send_engine = lambda _command: None
        with mock.patch.object(controller, "ENGINE_STOP_GRACE_SECONDS", 10.0):
            instance.request_stop()
            instance.request_stop()
            self.assertTrue(process.terminated.wait(0.2))
        self.assertTrue(process.killed)

    def test_stop_guard_handles_process_published_after_signal(self) -> None:
        instance, process, _updates = simulated_controller()
        instance.process = None
        commands: list[str] = []
        instance.send_engine = commands.append
        with mock.patch.object(controller, "ENGINE_STOP_GRACE_SECONDS", 0.08):
            instance.request_stop()
            time.sleep(0.02)
            instance.process = process
            self.assertTrue(process.terminated.wait(1.0))
            assert instance.stop_guard_thread is not None
            instance.stop_guard_thread.join(timeout=1.0)

        self.assertIn("STOP", commands)
        self.assertEqual(instance.exit_code, 130)

    def test_stop_guard_kills_after_term_is_ignored(self) -> None:
        instance, process, _updates = simulated_controller()
        instance.send_engine = lambda _command: None

        def ignore_terminate() -> None:
            pass

        process.terminate = ignore_terminate
        with (
            mock.patch.object(controller, "ENGINE_STOP_GRACE_SECONDS", 0.02),
            mock.patch.object(
                controller, "ENGINE_WATCHDOG_TERMINATE_GRACE_SECONDS", 0.02
            ),
        ):
            instance.request_stop()
            assert instance.stop_guard_thread is not None
            instance.stop_guard_thread.join(timeout=1.0)

        self.assertTrue(process.killed)

    def test_timeout_terminates_only_the_recorded_engine_and_records_reason(self) -> None:
        instance, process, updates = simulated_controller()
        with mock.patch.object(controller, "ENGINE_PROGRESS_TIMEOUT_SECONDS", 0.04):
            instance._start_progress_watchdog()
            instance._arm_progress_watchdog()
            self.assertTrue(process.terminated.wait(1.0))
            instance._stop_progress_watchdog()

        self.assertEqual(process.return_code, -15)
        self.assertFalse(process.killed)
        self.assertEqual(instance.progress_watchdog_error, updates[-1]["detail"])
        self.assertIn("search progress", instance.progress_watchdog_error)
        self.assertEqual(updates[-1]["state"], "error")
        self.assertEqual(updates[-1]["heartbeat_state"], "error")

    def test_progress_resets_the_first_progress_deadline(self) -> None:
        instance, process, _updates = simulated_controller()
        with mock.patch.object(controller, "ENGINE_PROGRESS_TIMEOUT_SECONDS", 0.12):
            instance._start_progress_watchdog()
            instance._arm_progress_watchdog()
            time.sleep(0.07)
            instance._arm_progress_watchdog()
            self.assertFalse(process.terminated.wait(0.07))
            self.assertTrue(process.terminated.wait(0.20))
            instance._stop_progress_watchdog()

    def test_startup_timeout_terminates_stalled_initialization(self) -> None:
        instance, process, updates = simulated_controller()
        with mock.patch.object(controller, "ENGINE_STARTUP_TIMEOUT_SECONDS", 0.04):
            instance._start_progress_watchdog()
            instance._arm_startup_watchdog()
            self.assertTrue(process.terminated.wait(1.0))
            instance._stop_progress_watchdog()
        self.assertIn("initialization", instance.progress_watchdog_error)
        self.assertEqual(updates[-1]["state"], "error")

    def test_searching_switches_from_startup_to_short_progress_timeout(self) -> None:
        instance, process, _updates = simulated_controller()
        with (
            mock.patch.object(controller, "ENGINE_STARTUP_TIMEOUT_SECONDS", 0.5),
            mock.patch.object(controller, "ENGINE_PROGRESS_TIMEOUT_SECONDS", 0.04),
        ):
            instance._start_progress_watchdog()
            instance._arm_startup_watchdog()
            instance._arm_progress_watchdog()
            self.assertTrue(process.terminated.wait(1.0))
            instance._stop_progress_watchdog()
        self.assertIn("search progress", instance.progress_watchdog_error)

    def test_stop_result_and_cleanup_states_suppress_timeout(self) -> None:
        for state in ("stop", "result", "cleanup"):
            with self.subTest(state=state):
                instance, process, updates = simulated_controller()
                if state == "stop":
                    instance.stop_requested.set()
                elif state == "result":
                    instance.received_result = True
                else:
                    instance.cleanup_handoff_started = True
                with mock.patch.object(
                    controller, "ENGINE_PROGRESS_TIMEOUT_SECONDS", 0.03
                ):
                    instance._start_progress_watchdog()
                    instance._arm_progress_watchdog()
                    self.assertFalse(process.terminated.wait(0.09))
                    instance._stop_progress_watchdog()
                self.assertEqual(updates, [])


if __name__ == "__main__":
    unittest.main()
