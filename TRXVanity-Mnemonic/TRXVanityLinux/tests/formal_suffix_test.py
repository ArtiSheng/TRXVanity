#!/usr/bin/env python3
"""Formal suffix file loading. No SSH, CUDA, or secrets."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import controller  # noqa: E402
import secure_cleanup  # noqa: E402


class FormalSuffixLoadTests(unittest.TestCase):
    def test_controller_defaults_when_file_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "formal-suffix"
            self.assertEqual(controller.load_formal_suffix(path), "8888888")

    def test_controller_reads_deployed_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "formal-suffix"
            path.write_text("666666\n", encoding="ascii")
            self.assertEqual(controller.load_formal_suffix(path), "666666")
            with mock.patch.object(controller, "FORMAL_SUFFIX_FILE", path):
                self.assertTrue(
                    controller.is_formal_run(SimpleNamespace(mode="run", suffix="666666"))
                )
                self.assertFalse(
                    controller.is_formal_run(SimpleNamespace(mode="run", suffix="8888888"))
                )

    def test_controller_rejects_invalid_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "formal-suffix"
            path.write_text("0000\n", encoding="ascii")
            with self.assertRaises(controller.ControllerError):
                controller.load_formal_suffix(path)

    def test_cleanup_defaults_and_custom_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(secure_cleanup.load_expected_suffix(root), "8888888")
            (root / "formal-suffix").write_text("7777777\n", encoding="ascii")
            self.assertEqual(secure_cleanup.load_expected_suffix(root), "7777777")


if __name__ == "__main__":
    unittest.main()
