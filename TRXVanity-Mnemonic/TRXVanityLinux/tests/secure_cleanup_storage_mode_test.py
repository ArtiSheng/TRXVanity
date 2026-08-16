#!/usr/bin/env python3
"""Filesystem preflight checks without secrets, CUDA, or destructive writes."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import secure_cleanup  # noqa: E402


class SecureCleanupHybridModeTests(unittest.TestCase):
    def test_preflight_accepts_public_runtime_on_shared_filesystem(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_mount = Path(directory).resolve()
            install_root = data_mount / "TRXVanityLinux"
            work_dir = install_root / "runtime"
            work_dir.mkdir(parents=True)
            with (
                mock.patch.object(secure_cleanup, "DATA_MOUNT", data_mount),
                mock.patch.object(secure_cleanup, "INSTALL_ROOT", install_root),
                mock.patch.object(secure_cleanup, "WORK_DIR", work_dir),
                mock.patch.object(secure_cleanup.os, "geteuid", return_value=0),
                mock.patch.object(secure_cleanup, "ensure_directory"),
            ):
                device, filesystem, source = secure_cleanup.preflight_filesystem()
            self.assertEqual(device, data_mount.stat().st_dev)
            self.assertEqual(filesystem, "shared-or-overlay")
            self.assertEqual(source, str(data_mount))

    def test_legacy_storage_mode_environment_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data_mount = Path(directory).resolve()
            install_root = data_mount / "TRXVanityLinux"
            work_dir = install_root / "runtime"
            work_dir.mkdir(parents=True)
            os.environ["TRX_RUNTIME_STORAGE_MODE"] = "dedicated-disk"
            try:
                with (
                    mock.patch.object(secure_cleanup, "DATA_MOUNT", data_mount),
                    mock.patch.object(secure_cleanup, "INSTALL_ROOT", install_root),
                    mock.patch.object(secure_cleanup, "WORK_DIR", work_dir),
                    mock.patch.object(secure_cleanup.os, "geteuid", return_value=0),
                    mock.patch.object(secure_cleanup, "ensure_directory"),
                ):
                    device, filesystem, _source = secure_cleanup.preflight_filesystem()
                self.assertEqual(device, data_mount.stat().st_dev)
                self.assertEqual(filesystem, "shared-or-overlay")
            finally:
                os.environ.pop("TRX_RUNTIME_STORAGE_MODE", None)


if __name__ == "__main__":
    unittest.main()
