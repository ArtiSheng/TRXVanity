#!/usr/bin/env python3
"""Local command-orchestration tests for tools/tune_cuda.py; no CUDA needed."""

from __future__ import annotations

import argparse
import json
import signal
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import tune_cuda  # noqa: E402


def write_executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(0o700)


class TuneCudaTests(unittest.TestCase):
    def test_variant_parser_accepts_only_supported_compile_controls(self) -> None:
        self.assertEqual(
            tune_cuda.parse_variant("candidate2:2:17:2"),
            tune_cuda.Variant("candidate2", 2, 17, 2),
        )
        for invalid in (
            "missing-fields:4:16",
            "../escape:4:16:0",
            "bad-candidates:3:16:0",
            "bad-window:4:21:0",
            "bad-blocks:4:16:1",
        ):
            with self.subTest(invalid=invalid):
                with self.assertRaises(argparse.ArgumentTypeError):
                    tune_cuda.parse_variant(invalid)

    def test_signal_stops_only_the_current_child_group(self) -> None:
        runner = tune_cuda.ChildRunner()

        def interrupt_when_started() -> None:
            deadline = time.monotonic() + 5.0
            while runner.current is None and time.monotonic() < deadline:
                time.sleep(0.005)
            runner.handle_signal(signal.SIGTERM, None)

        interrupter = threading.Thread(target=interrupt_when_started)
        interrupter.start()
        with self.assertRaises(tune_cuda.TuneInterrupted):
            runner.run(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                cwd=Path.cwd(),
                timeout=10.0,
            )
        interrupter.join(timeout=1.0)
        self.assertFalse(interrupter.is_alive())

    def test_runtime_build_path_is_rejected_without_creating_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            tools = source / "tools"
            tools.mkdir(parents=True)
            (source / "CMakeLists.txt").write_text("# test\n", encoding="utf-8")
            (tools / "benchmark.py").write_text("# test\n", encoding="utf-8")
            forbidden = source / "runtime" / "cuda-tuning"

            with self.assertRaises(SystemExit) as raised:
                tune_cuda.main(
                    [
                        "--source-dir",
                        str(source),
                        "--build-root",
                        str(forbidden),
                        "--cmake",
                        sys.executable,
                        "--ctest",
                        sys.executable,
                    ]
                )

            self.assertEqual(raised.exception.code, 2)
            self.assertFalse((source / "runtime").exists())

    def test_result_cannot_collide_with_build_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            tools = source / "tools"
            tools.mkdir(parents=True)
            (source / "CMakeLists.txt").write_text("# test\n", encoding="utf-8")
            (tools / "benchmark.py").write_text("# test\n", encoding="utf-8")

            for output_suffix in ((), ("baseline", "results.json")):
                with self.subTest(output_suffix=output_suffix):
                    build_root = Path(temporary) / ("build-" + str(len(output_suffix)))
                    output = build_root.joinpath(*output_suffix)
                    with self.assertRaises(SystemExit) as raised:
                        tune_cuda.main(
                            [
                                "--source-dir",
                                str(source),
                                "--build-root",
                                str(build_root),
                                "--output",
                                str(output),
                                "--cmake",
                                sys.executable,
                                "--ctest",
                                sys.executable,
                            ]
                        )
                    self.assertEqual(raised.exception.code, 2)
                    self.assertFalse(build_root.exists())

    def test_fake_toolchain_runs_configure_build_tests_and_benchmark(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            tools = source / "tools"
            tools.mkdir(parents=True)
            (source / "CMakeLists.txt").write_text(
                "cmake_minimum_required(VERSION 3.22)\n", encoding="utf-8"
            )

            fake_cmake = root / "fake-cmake"
            write_executable(
                fake_cmake,
                r'''
                #!/usr/bin/env python3
                import sys
                from pathlib import Path

                if "--build" in sys.argv:
                    raise SystemExit(0)
                build = Path(sys.argv[sys.argv.index("-B") + 1])
                build.mkdir(parents=True, exist_ok=True)
                values = {}
                for argument in sys.argv:
                    if argument.startswith("-DTRXVANITY_"):
                        key, value = argument[2:].split("=", 1)
                        values[key] = value
                stamp = (
                    "address_candidates_per_thread="
                    + values["TRXVANITY_ADDRESS_CANDIDATES_PER_THREAD"] + "\n"
                    + "secp_window_bits="
                    + values["TRXVANITY_SECP_WINDOW_BITS"] + "\n"
                    + "master_min_blocks_per_sm="
                    + values["TRXVANITY_MASTER_MIN_BLOCKS_PER_SM"] + "\n"
                    + "master_low_spill_threads="
                    + values["TRXVANITY_MASTER_LOW_SPILL_THREADS"] + "\n"
                    + "pbkdf2_direct_words="
                    + values["TRXVANITY_PBKDF2_DIRECT_WORDS"] + "\n"
                )
                (build / "cuda-tuning-config.txt").write_text(stamp)
                engine = build / "trxvanity-gpu"
                engine.write_text(
                    "#!/usr/bin/env python3\n"
                    "import sys\n"
                    "raise SystemExit(0 if '--self-test' in sys.argv else 2)\n"
                )
                engine.chmod(0o700)
                ''',
            )
            fake_ctest = root / "fake-ctest"
            write_executable(fake_ctest, "#!/usr/bin/env python3\n")
            fake_resource = root / "fake-cuobjdump"
            write_executable(
                fake_resource,
                """#!/usr/bin/env python3
print('Resource usage:')
print(' Function kernel():')
print('  REG:170 STACK:112 SHARED:0 LOCAL:0')
""",
            )
            fake_benchmark = tools / "benchmark.py"
            write_executable(
                fake_benchmark,
                r'''
                #!/usr/bin/env python3
                import json
                report = {
                    "schema_version": 1,
                    "summary": {
                        "attempts_per_second": {"median": 2100000.0},
                        "gpu_attempts_per_second": {"median": 2090000.0},
                    },
                }
                print(json.dumps(report))
                ''',
            )

            build_root = root / "builds"
            output = root / "results.json"
            exit_code = tune_cuda.main(
                [
                    "--source-dir",
                    str(source),
                    "--build-root",
                    str(build_root),
                    "--output",
                    str(output),
                    "--cmake",
                    str(fake_cmake),
                    "--ctest",
                    str(fake_ctest),
                    "--resource-tool",
                    str(fake_resource),
                    "--variant",
                    "fake:2:17:2",
                    "--jobs",
                    "1",
                    "--warmup",
                    "0",
                    "--duration",
                    "0.01",
                    "--runs",
                    "1",
                ]
            )

            self.assertEqual(exit_code, 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "ok")
            self.assertEqual(len(report["variants"]), 1)
            record = report["variants"][0]
            self.assertEqual(record["status"], "ok")
            self.assertEqual(record["resource_usage"]["status"], "ok")
            self.assertTrue(
                any(
                    "REG:170" in line
                    for line in record["resource_usage"]["summary_lines"]
                )
            )
            self.assertEqual(
                record["variant"]["address_candidates_per_thread"], 2
            )
            self.assertEqual(
                record["benchmark"]["summary"]["attempts_per_second"][
                    "median"
                ],
                2_100_000.0,
            )
            self.assertEqual(
                (build_root / "fake" / "cuda-tuning-config.txt").read_text(),
                tune_cuda.expected_tuning_stamp(tune_cuda.Variant("fake", 2, 17, 2)),
            )


if __name__ == "__main__":
    unittest.main()
