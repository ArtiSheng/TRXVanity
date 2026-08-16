#!/usr/bin/env python3
"""Static safety contracts for compile-only CUDA experiments."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1]


class CudaExperimentControlTests(unittest.TestCase):
    def test_default_preprocessor_path_keeps_the_production_kernel(self) -> None:
        source = (APP_DIR / "Engine" / "mnemonic_cuda.cu").read_text(
            encoding="utf-8"
        )
        for name in (
            "TRXVANITY_MASTER_LOW_SPILL_THREADS",
            "TRXVANITY_PBKDF2_DIRECT_WORDS",
        ):
            self.assertRegex(
                source,
                rf"#ifndef {name}\s+#define {name} 0\s+#endif",
            )

        # With both experiment macros at their default zero, preprocessing
        # selects the original launch bound and original byte-output PBKDF2
        # call.  The direct-word helper and call exist only in the == 1 arm.
        self.assertIn(
            "#else\n#define TRXVANITY_MASTER_LAUNCH_BOUNDS "
            "__launch_bounds__(256)\n#endif",
            source,
        )
        self.assertRegex(
            source,
            r"#if TRXVANITY_PBKDF2_DIRECT_WORDS == 1\s+"
            r"std::uint64_t block\[16\];\s+"
            r"pbkdf2_bip39_sha512_direct_words\([\s\S]*?"
            r"#else\s+fastpbkdf2_hmac_sha512\(",
        )

    def test_stamp_and_build_script_track_both_experiments(self) -> None:
        cmake = (APP_DIR / "CMakeLists.txt").read_text(encoding="utf-8")
        build_script = (APP_DIR / "build-engine.sh").read_text(encoding="utf-8")
        for name, stamp_key in (
            ("TRXVANITY_MASTER_LOW_SPILL_THREADS", "master_low_spill_threads"),
            ("TRXVANITY_PBKDF2_DIRECT_WORDS", "pbkdf2_direct_words"),
        ):
            self.assertIn(f"-D{name}=", cmake)
            self.assertIn(f"{stamp_key}=${{{name}}}", cmake)
            self.assertIn(f"-D{name}=\"${{{stamp_key}}}\"", build_script)
            self.assertIn(f"{stamp_key}=${{{stamp_key}}}", build_script)

    def test_production_installer_pins_experiments_off(self) -> None:
        installer = (
            APP_DIR / "scripts" / "install-production-build.sh"
        ).read_text(encoding="utf-8")
        for name in (
            "TRXVANITY_MASTER_MIN_BLOCKS_PER_SM",
            "TRXVANITY_MASTER_LOW_SPILL_THREADS",
            "TRXVANITY_PBKDF2_DIRECT_WORDS",
        ):
            self.assertRegex(installer, rf"(?m)^{re.escape(name)}=0 \\$\n")
        self.assertNotIn("TRXVANITY_EXACT_SUFFIX8_PREFILTER", installer)

    def test_eight_character_checksum_prefilter_is_gone(self) -> None:
        source = (APP_DIR / "Engine" / "mnemonic_cuda.cu").read_text(
            encoding="utf-8"
        )
        cmake = (APP_DIR / "CMakeLists.txt").read_text(encoding="utf-8")
        build_script = (APP_DIR / "build-engine.sh").read_text(encoding="utf-8")
        for text in (source, cmake, build_script):
            self.assertNotIn("checksum_suffix8", text)
            self.assertNotIn("EXACT_SUFFIX8", text)
            self.assertNotIn("exact_suffix8", text)
        self.assertFalse((APP_DIR / "Engine" / "checksum_suffix8.hpp").exists())
        self.assertFalse((APP_DIR / "tests" / "checksum_suffix8_test.cpp").exists())


if __name__ == "__main__":
    unittest.main()
