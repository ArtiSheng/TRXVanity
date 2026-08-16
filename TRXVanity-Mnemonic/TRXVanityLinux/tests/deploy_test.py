#!/usr/bin/env python3
"""Local checks for the cross-platform deployer. No SSH or CUDA."""

from __future__ import annotations

import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy  # noqa: E402


class SuffixAndHostTests(unittest.TestCase):
    def test_valid_suffixes(self) -> None:
        self.assertEqual(deploy.validate_suffix("8888888"), "8888888")
        self.assertEqual(deploy.validate_suffix(" 88 "), "88")
        self.assertEqual(deploy.validate_suffix("aB9"), "aB9")

    def test_interactive_terminal_is_required(self) -> None:
        with mock.patch.object(deploy.sys.stdin, "isatty", return_value=False):
            with self.assertRaises(deploy.DeployError):
                deploy.require_interactive()

    def test_invalid_suffixes(self) -> None:
        for value in ("", "0", "O", "I", "l", "88888888888", "88 88", "abc!"):
            with self.subTest(value=value):
                with self.assertRaises(deploy.DeployError):
                    deploy.validate_suffix(value)

    def test_aes_key_and_urls(self) -> None:
        self.assertEqual(
            deploy.validate_aes_key("Aa" + ("11" * 31)),
            "Aa" + ("11" * 31),
        )
        with self.assertRaises(deploy.DeployError):
            deploy.validate_aes_key("11" * 31)
        upload = deploy.validate_upload_url(
            "https://example.com/upload.php?token=abc123"
        )
        self.assertTrue(upload.endswith("token=abc123"))
        delete = deploy.validate_delete_url(
            "https://example.com/index.php?token=del456"
        )
        self.assertIn("index.php", delete)
        with self.assertRaises(deploy.DeployError):
            deploy.validate_upload_url("http://example.com/upload.php?token=abc")
        with self.assertRaises(deploy.DeployError):
            deploy.validate_delete_url("https://example.com/upload.php?token=abc")

    def test_probe_helpers(self) -> None:
        deploy.upload_probe_accepted(400, '{"error":"不是有效的 TRX Vanity AES 密文文件。"}')
        with self.assertRaises(deploy.DeployError):
            deploy.upload_probe_accepted(403, '{"error":"上传令牌错误。"}')
        deploy.delete_probe_accepted(200, "<h1>AES 密文备份</h1><div class=\"empty\">暂无加密备份文件</div>")
        with self.assertRaises(deploy.DeployError):
            deploy.delete_probe_accepted(200, "<p class=\"error\">删除令牌错误。</p>")
        with self.assertRaises(deploy.DeployError):
            deploy.delete_probe_accepted(200, "<button>解锁删除</button>")

    def test_secrets_file_bytes_do_not_quote_values(self) -> None:
        payload = deploy.secrets_file_bytes("ab" * 32, "https://example.com/upload.php?token=x")
        text = payload.decode("ascii")
        self.assertIn("TRX_AES_KEY_HEX=" + ("ab" * 32), text)
        self.assertIn("TRX_UPLOAD_ENDPOINT=https://example.com/upload.php?token=x", text)
        self.assertNotIn("'", text)

    def test_remote_start_search_uses_screen_and_run_formal(self) -> None:
        command = deploy.remote_start_search_command()
        self.assertIn("screen -dmS trxvanity-formal", command)
        self.assertIn("/root/autodl-tmp/TRXVanityLinux && exec ./run-formal.sh", command)
        self.assertIn("pgrep -f '[.]/run-formal[.]sh", command)
        self.assertNotIn("TRX_AES_KEY", command)

    def test_parse_ssh_target(self) -> None:
        self.assertEqual(
            deploy.parse_ssh_target("root@example.com:33"),
            ("root", "example.com", 33),
        )
        self.assertEqual(deploy.parse_ssh_target("192.168.1.8"), ("root", "192.168.1.8", 22))
        self.assertEqual(
            deploy.parse_ssh_target("ubuntu@box", default_port=2222),
            ("ubuntu", "box", 2222),
        )

class PayloadTests(unittest.TestCase):
    def test_skip_rules(self) -> None:
        self.assertTrue(deploy.should_skip_relative(("build", "trxvanity-gpu"), vendor=False))
        self.assertTrue(deploy.should_skip_relative(("runtime", "status.json"), vendor=False))
        self.assertTrue(deploy.should_skip_relative(("formal-suffix",), vendor=False))
        self.assertFalse(deploy.should_skip_relative(("controller.py",), vendor=False))
        self.assertFalse(deploy.should_skip_relative(("include", "foo.h"), vendor=True))

    def test_windows_newlines_are_normalized_in_manifest_and_tar(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            linux_dir = Path(directory) / "linux"
            vendor_dir = Path(directory) / "vendor"
            linux_dir.mkdir()
            vendor_dir.mkdir()
            script = linux_dir / "run-formal.sh"
            script.write_bytes(b"#!/bin/bash\r\necho hi\r\n")
            (vendor_dir / "note.txt").write_bytes(b"ok\n")
            files = list(deploy.iter_payload_files(linux_dir, vendor_dir))
            names = [name for name, _path, _payload in files]
            self.assertIn("TRXVanityLinux/run-formal.sh", names)
            self.assertIn("Vendor/note.txt", names)
            payload = next(item[2] for item in files if item[0].endswith("run-formal.sh"))
            self.assertEqual(payload, b"#!/bin/bash\necho hi\n")
            manifest = deploy.local_manifest_text(files)
            self.assertIn("TRXVanityLinux/run-formal.sh", manifest)
            self.assertNotIn("\r", manifest)
            tar_path = Path(directory) / "payload.tar"
            deploy.write_payload_tar(files, tar_path)
            with tarfile.open(tar_path, "r") as archive:
                extracted = archive.extractfile("TRXVanityLinux/run-formal.sh")
                assert extracted is not None
                self.assertEqual(extracted.read(), b"#!/bin/bash\necho hi\n")


if __name__ == "__main__":
    unittest.main()
