#!/usr/bin/env python3
"""Build, self-test, and benchmark isolated CUDA tuning variants.

The tuner deliberately operates only on source/build paths and starts only the
native engine self-test plus tools/benchmark.py.  It never imports or starts
controller.py and never reads runtime/ or a secrets file.  Every child is
started in its own process group; interruption targets only the exact child
group created by this process.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence


APP_DIR = Path(__file__).resolve().parent.parent
BASE58_ALPHABET = frozenset(
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
)
DEFAULT_VARIANT_SPECS = (
    "baseline:4:16:0",
    "address2:2:16:0",
    "window17:4:17:0",
    "master2:4:16:2",
)
VARIANT_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


class TuneError(RuntimeError):
    """A safe, user-facing tuning failure."""


class TuneInterrupted(TuneError):
    """Raised after an operator signal stops the tuner and its active child."""


@dataclass(frozen=True)
class Variant:
    name: str
    address_candidates_per_thread: int
    secp_window_bits: int
    master_min_blocks_per_sm: int


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    elapsed_seconds: float


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def parse_variant(text: str) -> Variant:
    fields = text.split(":")
    if len(fields) != 4:
        raise argparse.ArgumentTypeError(
            "must be NAME:CANDIDATES_PER_THREAD:WINDOW_BITS:MASTER_MIN_BLOCKS"
        )
    name = fields[0]
    if not VARIANT_NAME_PATTERN.fullmatch(name):
        raise argparse.ArgumentTypeError(
            "variant NAME must be 1-64 ASCII letters, digits, '.', '_', or '-'"
        )
    try:
        candidates, window_bits, master_min_blocks = (
            int(value, 10) for value in fields[1:]
        )
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "variant tuning values must be decimal integers"
        ) from error
    if candidates not in {1, 2, 4, 8}:
        raise argparse.ArgumentTypeError(
            "CANDIDATES_PER_THREAD must be 1, 2, 4, or 8"
        )
    if not 8 <= window_bits <= 20:
        raise argparse.ArgumentTypeError("WINDOW_BITS must be from 8 through 20")
    if master_min_blocks not in {0, 2}:
        raise argparse.ArgumentTypeError("MASTER_MIN_BLOCKS must be 0 or 2")
    return Variant(name, candidates, window_bits, master_min_blocks)


def positive_float(text: str) -> float:
    try:
        value = float(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(value) or value <= 0.0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return value


def nonnegative_float(text: str) -> float:
    try:
        value = float(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(value) or value < 0.0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return value


def bounded_int(minimum: int, maximum: int):
    def parse(text: str) -> int:
        try:
            value = int(text, 10)
        except ValueError as error:
            raise argparse.ArgumentTypeError("must be an integer") from error
        if not minimum <= value <= maximum:
            raise argparse.ArgumentTypeError(
                f"must be between {minimum} and {maximum}"
            )
        return value

    return parse


def cuda_block_size(text: str) -> int:
    value = bounded_int(32, 1024)(text)
    if value % 32 != 0:
        raise argparse.ArgumentTypeError("must be a multiple of 32")
    return value


def benchmark_suffix(text: str) -> str:
    if not 1 <= len(text) <= 10 or any(char not in BASE58_ALPHABET for char in text):
        raise argparse.ArgumentTypeError(
            "must contain 1 to 10 Bitcoin/TRON Base58 characters"
        )
    return text


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Build isolated CUDA compile variants, run CTest and engine "
            "self-test, then benchmark each binary without controller/runtime access"
        )
    )
    parser.add_argument("--source-dir", default=str(APP_DIR))
    parser.add_argument(
        "--build-root",
        help=(
            "new, empty directory for all variant builds; default is a "
            "timestamped directory below source-dir/build"
        ),
    )
    parser.add_argument(
        "--output",
        help="aggregate JSON path; default is BUILD_ROOT/results.json",
    )
    parser.add_argument(
        "--variant",
        action="append",
        type=parse_variant,
        metavar="NAME:CANDIDATES:WINDOW_BITS:MASTER_MIN_BLOCKS",
        help=(
            "explicit compile variant; repeat to replace the four-variant "
            "safe default matrix"
        ),
    )
    parser.add_argument("--cmake", default="cmake")
    parser.add_argument("--ctest", default="ctest")
    parser.add_argument("--cuda-compiler")
    parser.add_argument(
        "--resource-tool",
        help=(
            "cuobjdump executable; default searches beside the CUDA compiler, "
            "/usr/local/cuda-12.8/bin, then PATH"
        ),
    )
    parser.add_argument("--build-type", default="Release")
    parser.add_argument("--jobs", type=bounded_int(1, 256), default=8)
    parser.add_argument(
        "--profile", choices=("smart", "rtx5070", "rtx4090"), default="smart"
    )
    parser.add_argument("--cpu-workers", type=bounded_int(0, 256), default=0)
    parser.add_argument("--batch-size", type=bounded_int(1, 4 * 1024 * 1024))
    parser.add_argument(
        "--master-block-size", type=cuda_block_size, default=256
    )
    parser.add_argument(
        "--address-block-size", type=cuda_block_size, default=384
    )
    parser.add_argument("--suffix", type=benchmark_suffix, default="8888888")
    parser.add_argument("--warmup", type=nonnegative_float, default=10.0)
    parser.add_argument("--duration", type=positive_float, default=20.0)
    parser.add_argument("--runs", type=bounded_int(1, 100), default=1)
    parser.add_argument("--startup-timeout", type=positive_float, default=600.0)
    parser.add_argument("--protocol-timeout", type=positive_float, default=90.0)
    parser.add_argument("--build-timeout", type=positive_float, default=3600.0)
    parser.add_argument("--self-test-timeout", type=positive_float, default=900.0)
    parser.add_argument("--resource-timeout", type=positive_float, default=120.0)
    parser.add_argument(
        "--benchmark-timeout",
        type=positive_float,
        help="outer timeout; default derives from startup and sample durations",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="stop after the first failed variant instead of recording the rest",
    )
    return parser


class ChildRunner:
    """Run one exact child process group at a time with bounded cleanup."""

    def __init__(self) -> None:
        self.current: Optional[subprocess.Popen[str]] = None
        self.interrupted_signal: Optional[int] = None

    def handle_signal(self, signum: int, _frame: Any) -> None:
        self.interrupted_signal = signum
        process = self.current
        if process is not None and process.poll() is None:
            self._signal_group(process, signal.SIGTERM)

    @staticmethod
    def _signal_group(process: subprocess.Popen[str], signum: int) -> None:
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    def check_interrupted(self) -> None:
        if self.interrupted_signal is not None:
            raise TuneInterrupted(f"received signal {self.interrupted_signal}")

    def _stop_after_timeout(self, process: subprocess.Popen[str]) -> None:
        self._signal_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=10.0)
        except subprocess.TimeoutExpired:
            self._signal_group(process, signal.SIGKILL)
            process.wait(timeout=10.0)

    def run(
        self,
        command: Sequence[str],
        *,
        cwd: Path,
        timeout: float,
        capture_stdout: bool = False,
    ) -> CommandResult:
        self.check_interrupted()
        print(f"+ {shlex.join(command)}", file=sys.stderr, flush=True)
        started = time.monotonic()
        try:
            process = subprocess.Popen(
                list(command),
                cwd=str(cwd),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if capture_stdout else None,
                stderr=None,
                text=True,
                encoding="utf-8",
                errors="replace",
                start_new_session=True,
            )
        except OSError as error:
            raise TuneError(f"could not start {command[0]}: {error}") from error
        self.current = process
        try:
            try:
                stdout, _stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                self._stop_after_timeout(process)
                raise TuneError(
                    f"command timed out after {timeout:.1f} seconds: "
                    f"{shlex.join(command)}"
                ) from error
        finally:
            self.current = None

        self.check_interrupted()
        elapsed = time.monotonic() - started
        if process.returncode != 0:
            raise TuneError(
                f"command exited with code {process.returncode}: "
                f"{shlex.join(command)}"
            )
        return CommandResult(stdout or "", elapsed)


def configure_command(
    args: argparse.Namespace, variant: Variant, build_dir: Path
) -> List[str]:
    command = [
        args.cmake,
        "-S",
        str(args.source_dir),
        "-B",
        str(build_dir),
        f"-DCMAKE_BUILD_TYPE={args.build_type}",
        "-DBUILD_TESTING=ON",
        (
            "-DTRXVANITY_ADDRESS_CANDIDATES_PER_THREAD="
            f"{variant.address_candidates_per_thread}"
        ),
        f"-DTRXVANITY_SECP_WINDOW_BITS={variant.secp_window_bits}",
        (
            "-DTRXVANITY_MASTER_MIN_BLOCKS_PER_SM="
            f"{variant.master_min_blocks_per_sm}"
        ),
        "-DTRXVANITY_MASTER_LOW_SPILL_THREADS=0",
        "-DTRXVANITY_PBKDF2_DIRECT_WORDS=0",
    ]
    if args.cuda_compiler:
        command.append(f"-DCMAKE_CUDA_COMPILER={args.cuda_compiler}")
    return command


def benchmark_command(
    args: argparse.Namespace, benchmark_script: Path, engine: Path
) -> List[str]:
    command = [
        sys.executable,
        str(benchmark_script),
        "--engine",
        str(engine),
        "--profile",
        args.profile,
        "--cpu-workers",
        str(args.cpu_workers),
        "--cuda-master-block-size",
        str(args.master_block_size),
        "--cuda-address-block-size",
        str(args.address_block_size),
        "--suffix",
        args.suffix,
        "--warmup",
        str(args.warmup),
        "--duration",
        str(args.duration),
        "--runs",
        str(args.runs),
        "--startup-timeout",
        str(args.startup_timeout),
        "--protocol-timeout",
        str(args.protocol_timeout),
    ]
    if args.batch_size is not None:
        command.extend(("--batch-size", str(args.batch_size)))
    return command


def expected_tuning_stamp(variant: Variant) -> str:
    return (
        "address_candidates_per_thread="
        f"{variant.address_candidates_per_thread}\n"
        f"secp_window_bits={variant.secp_window_bits}\n"
        f"master_min_blocks_per_sm={variant.master_min_blocks_per_sm}\n"
        "master_low_spill_threads=0\n"
        "pbkdf2_direct_words=0\n"
    )


def validate_tuning_stamp(build_dir: Path, variant: Variant) -> None:
    stamp = build_dir / "cuda-tuning-config.txt"
    try:
        actual = stamp.read_text(encoding="utf-8")
    except OSError as error:
        raise TuneError(f"CMake did not create tuning stamp: {stamp}") from error
    expected = expected_tuning_stamp(variant)
    if actual != expected:
        raise TuneError(
            f"CMake tuning stamp mismatch for {variant.name}: "
            f"expected {expected!r}, got {actual!r}"
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def summarize_resource_usage(output: str) -> Dict[str, Any]:
    lines = [line.rstrip() for line in output.splitlines() if line.strip()]
    prefixes = (
        "arch =",
        "code version =",
        "Resource usage:",
        "Common:",
        "Function ",
        "REG:",
        "STACK:",
        "SHARED:",
        "LOCAL:",
        "CONSTANT",
    )
    relevant = [line for line in lines if line.strip().startswith(prefixes)]
    return {
        "output_line_count": len(lines),
        "summary_lines": relevant[:512],
        "summary_truncated": len(relevant) > 512,
    }


def validate_benchmark_report(report: Any) -> Dict[str, Any]:
    if not isinstance(report, dict) or report.get("schema_version") != 1:
        raise TuneError("benchmark.py returned an unsupported JSON report")
    try:
        median = float(report["summary"]["attempts_per_second"]["median"])
        gpu_median = float(
            report["summary"]["gpu_attempts_per_second"]["median"]
        )
    except (KeyError, TypeError, ValueError) as error:
        raise TuneError("benchmark.py JSON is missing median speed fields") from error
    if not math.isfinite(median) or median <= 0.0:
        raise TuneError("benchmark.py returned an invalid total median speed")
    if not math.isfinite(gpu_median) or gpu_median <= 0.0:
        raise TuneError("benchmark.py returned an invalid GPU median speed")
    return report


def benchmark_outer_timeout(args: argparse.Namespace) -> float:
    if args.benchmark_timeout is not None:
        return args.benchmark_timeout
    measured = args.warmup + args.duration * args.runs
    return args.startup_timeout + measured + 180.0


def run_variant(
    args: argparse.Namespace,
    runner: ChildRunner,
    variant: Variant,
    build_root: Path,
    benchmark_script: Path,
) -> Dict[str, Any]:
    build_dir = build_root / variant.name
    build_dir.mkdir(mode=0o700)
    record: Dict[str, Any] = {
        "variant": asdict(variant),
        "build_dir": str(build_dir),
        "started_at": utc_now(),
        "status": "running",
        "phases_seconds": {},
    }
    try:
        result = runner.run(
            configure_command(args, variant, build_dir),
            cwd=args.source_dir,
            timeout=args.build_timeout,
        )
        record["phases_seconds"]["configure"] = result.elapsed_seconds
        validate_tuning_stamp(build_dir, variant)

        result = runner.run(
            [
                args.cmake,
                "--build",
                str(build_dir),
                "--config",
                args.build_type,
                "--parallel",
                str(args.jobs),
            ],
            cwd=args.source_dir,
            timeout=args.build_timeout,
        )
        record["phases_seconds"]["build"] = result.elapsed_seconds

        engine = build_dir / "trxvanity-gpu"
        if not engine.is_file() or not os.access(engine, os.X_OK):
            raise TuneError(f"build did not produce an executable engine: {engine}")
        record["linked_binary"] = {
            "path": str(engine),
            "size_bytes": engine.stat().st_size,
            "sha256": sha256_file(engine),
        }
        if args.resource_tool is None:
            record["resource_usage"] = {
                "status": "unavailable",
                "reason": "cuobjdump was not found",
            }
        else:
            try:
                result = runner.run(
                    [args.resource_tool, "--dump-resource-usage", str(engine)],
                    cwd=build_dir,
                    timeout=args.resource_timeout,
                    capture_stdout=True,
                )
            except TuneInterrupted:
                raise
            except TuneError as error:
                record["resource_usage"] = {
                    "status": "unavailable",
                    "tool": args.resource_tool,
                    "reason": str(error),
                }
            else:
                record["phases_seconds"]["resource_usage"] = result.elapsed_seconds
                record["resource_usage"] = {
                    "status": "ok",
                    "tool": args.resource_tool,
                    **summarize_resource_usage(result.stdout),
                }

        result = runner.run(
            [
                args.ctest,
                "--test-dir",
                str(build_dir),
                "--build-config",
                args.build_type,
                "--output-on-failure",
            ],
            cwd=args.source_dir,
            timeout=args.self_test_timeout,
        )
        record["phases_seconds"]["ctest"] = result.elapsed_seconds

        result = runner.run(
            [
                str(engine),
                "--self-test",
                "--profile",
                args.profile,
                "--batch-size",
                "128",
            ],
            cwd=build_dir,
            timeout=args.self_test_timeout,
        )
        record["phases_seconds"]["engine_self_test"] = result.elapsed_seconds

        result = runner.run(
            benchmark_command(args, benchmark_script, engine),
            cwd=args.source_dir,
            timeout=benchmark_outer_timeout(args),
            capture_stdout=True,
        )
        record["phases_seconds"]["benchmark"] = result.elapsed_seconds
        try:
            parsed = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise TuneError("benchmark.py did not return valid JSON") from error
        record["benchmark"] = validate_benchmark_report(parsed)
        record["status"] = "ok"
    except TuneInterrupted as error:
        record["status"] = "interrupted"
        record["error"] = str(error)
    except TuneError as error:
        record["status"] = "failed"
        record["error"] = str(error)
    finally:
        record["completed_at"] = utc_now()
    return record


def atomic_write_json(path: Path, report: Dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def print_summary(records: Sequence[Dict[str, Any]]) -> None:
    baseline: Optional[float] = None
    for record in records:
        if record.get("status") == "ok":
            baseline = float(
                record["benchmark"]["summary"]["attempts_per_second"]["median"]
            )
            break
    print("\nCUDA tuning summary", file=sys.stderr)
    print(
        "variant                 status       total M/s     GPU M/s    vs first",
        file=sys.stderr,
    )
    for record in records:
        name = str(record["variant"]["name"])
        status = str(record["status"])
        if status != "ok":
            print(f"{name:<23} {status:<12} {'-':>9} {'-':>11} {'-':>11}", file=sys.stderr)
            continue
        total = float(
            record["benchmark"]["summary"]["attempts_per_second"]["median"]
        )
        gpu = float(
            record["benchmark"]["summary"]["gpu_attempts_per_second"]["median"]
        )
        delta = 0.0 if baseline is None else 100.0 * (total / baseline - 1.0)
        print(
            f"{name:<23} {status:<12} {total / 1e6:>9.4f} "
            f"{gpu / 1e6:>11.4f} {delta:>+10.2f}%",
            file=sys.stderr,
        )


def resolve_program(parser: argparse.ArgumentParser, value: str, label: str) -> str:
    if os.sep in value:
        resolved = str(Path(value).expanduser().resolve())
        if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
            parser.error(f"{label} is missing or not executable: {resolved}")
        return resolved
    resolved = shutil.which(value)
    if resolved is None:
        parser.error(f"{label} is not available on PATH: {value}")
    return resolved


def discover_resource_tool(
    parser: argparse.ArgumentParser,
    requested: Optional[str],
    cuda_compiler: Optional[str],
) -> Optional[str]:
    if requested is not None:
        return resolve_program(parser, requested, "CUDA resource tool")
    candidates: List[Path] = []
    if cuda_compiler is not None:
        candidates.append(Path(cuda_compiler).parent / "cuobjdump")
    environment_compiler = os.environ.get("CUDACXX")
    if environment_compiler:
        candidates.append(
            Path(environment_compiler).expanduser().resolve().parent / "cuobjdump"
        )
    candidates.append(Path("/usr/local/cuda-12.8/bin/cuobjdump"))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which("cuobjdump")


def validate_variants(
    parser: argparse.ArgumentParser, variants: Sequence[Variant]
) -> None:
    if len(variants) > 64:
        parser.error("at most 64 explicit variants may be requested")
    names = [variant.name for variant in variants]
    if len(set(names)) != len(names):
        parser.error("variant names must be unique")


def path_is_within(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
    except ValueError:
        return False
    return True


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.source_dir = Path(args.source_dir).expanduser().resolve()
    cmake_lists = args.source_dir / "CMakeLists.txt"
    benchmark_script = args.source_dir / "tools" / "benchmark.py"
    if not cmake_lists.is_file():
        parser.error(f"source CMakeLists.txt is missing: {cmake_lists}")
    if not benchmark_script.is_file():
        parser.error(f"benchmark tool is missing: {benchmark_script}")
    args.cmake = resolve_program(parser, args.cmake, "cmake")
    args.ctest = resolve_program(parser, args.ctest, "ctest")
    if args.cuda_compiler is not None:
        args.cuda_compiler = str(Path(args.cuda_compiler).expanduser().resolve())
        if not os.path.isfile(args.cuda_compiler) or not os.access(
            args.cuda_compiler, os.X_OK
        ):
            parser.error(
                f"CUDA compiler is missing or not executable: {args.cuda_compiler}"
            )
    args.resource_tool = discover_resource_tool(
        parser, args.resource_tool, args.cuda_compiler
    )

    variants = (
        list(args.variant)
        if args.variant
        else [parse_variant(spec) for spec in DEFAULT_VARIANT_SPECS]
    )
    validate_variants(parser, variants)

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    build_root = (
        Path(args.build_root).expanduser().resolve()
        if args.build_root
        else args.source_dir / "build" / f"cuda-tuning-{timestamp}"
    )
    output = (
        Path(args.output).expanduser().resolve()
        if args.output
        else build_root / "results.json"
    )
    runtime_dir = (args.source_dir / "runtime").resolve()
    if path_is_within(build_root, runtime_dir) or path_is_within(output, runtime_dir):
        parser.error("build and result paths must not be inside source-dir/runtime")
    if output == build_root:
        parser.error("result path must not be the build root directory")

    # Validate every forbidden/colliding path before creating or traversing the
    # build tree.  Besides producing a clearer error, this preserves the tool's
    # guarantee that it never reads from or writes to runtime/.
    for variant in variants:
        variant_dir = (build_root / variant.name).resolve()
        if path_is_within(output, variant_dir):
            parser.error(
                "result path must not be inside a variant build directory: "
                f"{variant_dir}"
            )
    if build_root.exists():
        if not build_root.is_dir():
            parser.error(f"build root is not a directory: {build_root}")
        if any(build_root.iterdir()):
            parser.error(f"build root must be new or empty: {build_root}")
    if output.exists():
        parser.error(f"refusing to overwrite existing results: {output}")

    build_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    runner = ChildRunner()
    old_handlers = {
        signum: signal.getsignal(signum) for signum in (signal.SIGINT, signal.SIGTERM)
    }
    for signum in old_handlers:
        signal.signal(signum, runner.handle_signal)

    report: Dict[str, Any] = {
        "schema_version": 1,
        "started_at": utc_now(),
        "completed_at": None,
        "status": "running",
        "source_dir": str(args.source_dir),
        "build_root": str(build_root),
        "configuration": {
            "build_type": args.build_type,
            "jobs": args.jobs,
            "resource_tool": args.resource_tool,
            "profile": args.profile,
            "cpu_workers": args.cpu_workers,
            "batch_size": args.batch_size,
            "master_block_size": args.master_block_size,
            "address_block_size": args.address_block_size,
            "suffix": args.suffix,
            "warmup_seconds": args.warmup,
            "duration_seconds": args.duration,
            "runs": args.runs,
        },
        "variants": [],
    }
    atomic_write_json(output, report)
    exit_code = 0
    try:
        for index, variant in enumerate(variants, start=1):
            print(
                f"\n[{index}/{len(variants)}] {variant.name}: "
                f"candidates={variant.address_candidates_per_thread} "
                f"window={variant.secp_window_bits} "
                f"master_min_blocks={variant.master_min_blocks_per_sm}",
                file=sys.stderr,
                flush=True,
            )
            record = run_variant(
                args, runner, variant, build_root, benchmark_script
            )
            report["variants"].append(record)
            atomic_write_json(output, report)
            if record["status"] == "interrupted":
                report["status"] = "interrupted"
                report["error"] = record["error"]
                exit_code = 130
                break
            if record["status"] == "failed":
                exit_code = 1
                if args.fail_fast:
                    break
        if report["status"] != "interrupted":
            report["status"] = "ok" if exit_code == 0 else "failed"
    except TuneInterrupted as error:
        report["status"] = "interrupted"
        report["error"] = str(error)
        exit_code = 130
    finally:
        report["completed_at"] = utc_now()
        atomic_write_json(output, report)
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)

    print_summary(report["variants"])
    print(f"\nJSON: {output}", file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
