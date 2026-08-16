#!/usr/bin/env python3
"""Sustained stdin/stdout benchmark driver for the Linux vanity engine.

This tool deliberately starts only the native engine. It does not import or
start controller.py, read an environment/secrets file, or access runtime/.
Human-readable progress is written to stderr; the final report is JSON on
stdout so it can be redirected to a file without post-processing.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import queue
import signal
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence


BASE58_ALPHABET = frozenset(
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
)
DEFAULT_SUFFIX = "9999999999"
APP_DIR = Path(__file__).resolve().parent.parent
DEFAULT_ENGINE = APP_DIR / "build" / "trxvanity-gpu"


class BenchmarkError(RuntimeError):
    """A safe, user-facing benchmark failure."""


class BenchmarkInterrupted(RuntimeError):
    """Raised when a termination signal requests orderly engine shutdown."""


@dataclass(frozen=True)
class ReadyInfo:
    device: str
    batch_capacity: int
    active_profile: str
    cpu_workers: int
    active_batch_size: int
    cuda_master_block_size: int
    cuda_address_block_size: int
    kernel_mode: str
    cpu_budget: int
    cpu_budget_source: str


@dataclass(frozen=True)
class ProgressSnapshot:
    attempts: int
    reported_attempts_per_second: float
    elapsed_seconds: float
    accumulated_gpu_seconds: float
    accumulated_cpu_seconds: float
    batch_size: int
    gpu_attempts: int
    cpu_attempts: int


@dataclass(frozen=True)
class Sample:
    kind: str
    run: int
    attempts: int
    gpu_attempts: int
    cpu_attempts: int
    attempt_counter_skew: int
    engine_elapsed_seconds: float
    wall_seconds_at_measurement: float
    reported_attempts_per_second: float
    attempts_per_second: float
    gpu_attempts_per_second: float
    cpu_attempts_per_second: float
    accumulated_gpu_seconds: float
    accumulated_cpu_seconds: float
    batch_size: int


def parse_nonnegative_int(text: str, name: str) -> int:
    try:
        value = int(text, 10)
    except ValueError as error:
        raise BenchmarkError(f"engine emitted an invalid {name}") from error
    if value < 0:
        raise BenchmarkError(f"engine emitted a negative {name}")
    return value


def parse_nonnegative_float(text: str, name: str) -> float:
    try:
        value = float(text)
    except ValueError as error:
        raise BenchmarkError(f"engine emitted an invalid {name}") from error
    if not math.isfinite(value) or value < 0.0:
        raise BenchmarkError(f"engine emitted an invalid {name}")
    return value


def parse_ready(fields: Sequence[str]) -> ReadyInfo:
    # ``fields`` includes the READY message kind.  The legacy protocol has
    # eight payload fields (nine fields total); CPU-budget telemetry appends
    # exactly two more payload fields.
    if not fields or fields[0] != "READY":
        raise BenchmarkError("engine emitted an invalid READY protocol kind")
    if len(fields) not in (9, 11):
        raise BenchmarkError(
            "engine emitted an unsupported READY protocol; expected exactly "
            "8 legacy payload fields or 10 payload fields with CPU budget "
            "telemetry"
        )
    cpu_budget = 0
    cpu_budget_source = "legacy"
    if len(fields) == 11:
        cpu_budget = parse_nonnegative_int(fields[9], "effective CPU budget")
        if cpu_budget == 0:
            raise BenchmarkError("engine emitted a zero effective CPU budget")
        cpu_budget_source = fields[10]
        if cpu_budget_source not in {
            "logical", "affinity", "cgroup-v1", "cgroup-v2"
        }:
            raise BenchmarkError("engine emitted an invalid CPU budget source")
    return ReadyInfo(
        device=fields[1],
        batch_capacity=parse_nonnegative_int(fields[2], "batch capacity"),
        active_profile=fields[3],
        cpu_workers=parse_nonnegative_int(fields[4], "CPU worker count"),
        active_batch_size=parse_nonnegative_int(fields[5], "active batch size"),
        cuda_master_block_size=parse_nonnegative_int(
            fields[6], "CUDA master block size"
        ),
        cuda_address_block_size=parse_nonnegative_int(
            fields[7], "CUDA address block size"
        ),
        kernel_mode=fields[8],
        cpu_budget=cpu_budget,
        cpu_budget_source=cpu_budget_source,
    )


def parse_progress(fields: Sequence[str]) -> ProgressSnapshot:
    if len(fields) < 9:
        raise BenchmarkError(
            "engine PROGRESS protocol is too old; GPU and CPU attempt counters "
            "are required"
        )
    snapshot = ProgressSnapshot(
        attempts=parse_nonnegative_int(fields[1], "total attempt count"),
        reported_attempts_per_second=parse_nonnegative_float(
            fields[2], "reported speed"
        ),
        elapsed_seconds=parse_nonnegative_float(fields[3], "elapsed time"),
        accumulated_gpu_seconds=parse_nonnegative_float(
            fields[4], "accumulated GPU time"
        ),
        accumulated_cpu_seconds=parse_nonnegative_float(
            fields[5], "accumulated CPU verification time"
        ),
        batch_size=parse_nonnegative_int(fields[6], "active batch size"),
        gpu_attempts=parse_nonnegative_int(fields[7], "GPU attempt count"),
        cpu_attempts=parse_nonnegative_int(fields[8], "CPU attempt count"),
    )
    # The engine samples the total and component counters with separate relaxed
    # atomic loads while CPU workers are still running. A small skew is expected
    # and is retained in the JSON instead of incorrectly rejecting the sample.
    return snapshot


class EngineClient:
    """Line-oriented engine process with bounded, orderly shutdown."""

    _EOF = object()

    def __init__(self, command: Sequence[str], cwd: Path) -> None:
        self.command = list(command)
        self.cwd = cwd
        self.process: Optional[subprocess.Popen[str]] = None
        self.search_active = False
        self.forced_shutdown = False
        self.return_code: Optional[int] = None
        self._lines: "queue.Queue[object]" = queue.Queue()
        self._reader: Optional[threading.Thread] = None

    def start(self) -> None:
        try:
            self.process = subprocess.Popen(
                self.command,
                cwd=str(self.cwd),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                start_new_session=True,
            )
        except OSError as error:
            raise BenchmarkError(f"could not start engine: {error}") from error
        self._reader = threading.Thread(
            target=self._read_stdout,
            name="benchmark-engine-stdout",
            daemon=True,
        )
        self._reader.start()

    def _read_stdout(self) -> None:
        process = self.process
        if process is None or process.stdout is None:
            self._lines.put(self._EOF)
            return
        try:
            for raw_line in process.stdout:
                line = raw_line.rstrip("\r\n")
                if line:
                    self._lines.put(line)
        finally:
            self._lines.put(self._EOF)

    def send(self, command: str, *, best_effort: bool = False) -> bool:
        process = self.process
        if (
            process is None
            or process.poll() is not None
            or process.stdin is None
            or process.stdin.closed
        ):
            if best_effort:
                return False
            raise BenchmarkError("engine exited before accepting a command")
        try:
            process.stdin.write(command + "\n")
            process.stdin.flush()
            return True
        except (BrokenPipeError, OSError, ValueError) as error:
            if best_effort:
                return False
            raise BenchmarkError("could not write to engine stdin") from error

    def read_line(self, timeout: float) -> str:
        try:
            item = self._lines.get(timeout=max(0.001, timeout))
        except queue.Empty as error:
            raise BenchmarkError(
                f"engine emitted no protocol line for {timeout:.1f} seconds"
            ) from error
        if item is self._EOF:
            process = self.process
            return_code = None if process is None else process.poll()
            raise BenchmarkError(
                f"engine stdout closed unexpectedly (exit code {return_code})"
            )
        return str(item)

    def wait_ready(self, timeout: float) -> ReadyInfo:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0.0:
                raise BenchmarkError(
                    f"engine did not become READY within {timeout:.1f} seconds"
                )
            fields = self.read_line(remaining).split("\t")
            kind = fields[0]
            if kind == "READY":
                return parse_ready(fields)
            if kind == "ERROR":
                detail = fields[1] if len(fields) >= 2 else "unknown engine error"
                raise BenchmarkError(f"engine initialization failed: {detail}")
            if kind == "RESULT":
                raise BenchmarkError("engine emitted an unexpected result; result redacted")

    def run_sample(
        self,
        *,
        suffix: str,
        duration: float,
        kind: str,
        run: int,
        protocol_timeout: float,
    ) -> Sample:
        self.send(f"START\t\t{suffix}")
        self.search_active = True
        wall_started = time.monotonic()
        frozen: Optional[ProgressSnapshot] = None
        wall_at_measurement = 0.0

        while True:
            fields = self.read_line(protocol_timeout).split("\t")
            message = fields[0]
            if message == "SEARCHING":
                continue
            if message == "PROGRESS":
                snapshot = parse_progress(fields)
                if frozen is None and snapshot.elapsed_seconds >= duration:
                    frozen = snapshot
                    wall_at_measurement = time.monotonic() - wall_started
                    self.send("STOP")
                continue
            if message == "STOPPED":
                self.search_active = False
                if frozen is None:
                    raise BenchmarkError(
                        "engine stopped before a complete benchmark measurement"
                    )
                elapsed = max(frozen.elapsed_seconds, 1e-9)
                return Sample(
                    kind=kind,
                    run=run,
                    attempts=frozen.attempts,
                    gpu_attempts=frozen.gpu_attempts,
                    cpu_attempts=frozen.cpu_attempts,
                    attempt_counter_skew=(
                        frozen.attempts
                        - frozen.gpu_attempts
                        - frozen.cpu_attempts
                    ),
                    engine_elapsed_seconds=frozen.elapsed_seconds,
                    wall_seconds_at_measurement=wall_at_measurement,
                    reported_attempts_per_second=(
                        frozen.reported_attempts_per_second
                    ),
                    attempts_per_second=frozen.attempts / elapsed,
                    gpu_attempts_per_second=frozen.gpu_attempts / elapsed,
                    cpu_attempts_per_second=frozen.cpu_attempts / elapsed,
                    accumulated_gpu_seconds=frozen.accumulated_gpu_seconds,
                    accumulated_cpu_seconds=frozen.accumulated_cpu_seconds,
                    batch_size=frozen.batch_size,
                )
            if message == "RESULT":
                self.search_active = False
                raise BenchmarkError(
                    "benchmark suffix unexpectedly matched; mnemonic and address redacted"
                )
            if message == "ERROR":
                self.search_active = False
                detail = fields[1] if len(fields) >= 2 else "unknown engine error"
                raise BenchmarkError(f"engine search failed: {detail}")

    def close(self, timeout: float = 15.0) -> None:
        process = self.process
        if process is None:
            return

        if process.poll() is None and self.search_active:
            self.send("STOP", best_effort=True)
            deadline = time.monotonic() + timeout
            while process.poll() is None and time.monotonic() < deadline:
                try:
                    line = self.read_line(min(0.5, deadline - time.monotonic()))
                except BenchmarkError:
                    continue
                kind = line.split("\t", 1)[0]
                if kind in {"STOPPED", "RESULT", "ERROR"}:
                    self.search_active = False
                    break

        if process.poll() is None:
            self.send("EXIT", best_effort=True)
            if process.stdin is not None and not process.stdin.closed:
                try:
                    process.stdin.close()
                except OSError:
                    pass
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.forced_shutdown = True
                process.terminate()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5.0)

        if self._reader is not None:
            self._reader.join(timeout=1.0)
        self.return_code = process.poll()
        self.process = None


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
            "Sustained stdin/stdout benchmark for the TRX Vanity Linux engine; "
            "does not start the controller or access secrets/runtime data"
        )
    )
    parser.add_argument("--engine", default=str(DEFAULT_ENGINE))
    parser.add_argument(
        "--profile",
        choices=("smart", "rtx5070", "rtx4090"),
        default="smart",
    )
    parser.add_argument("--cpu-workers", type=bounded_int(0, 256))
    parser.add_argument(
        "--batch-size",
        "--batch",
        type=bounded_int(1, 4 * 1024 * 1024),
    )
    parser.add_argument(
        "--cuda-block-size",
        type=cuda_block_size,
        help="legacy shorthand that applies one value to both CUDA stages",
    )
    parser.add_argument(
        "--cuda-master-block-size",
        "--master-block-size",
        dest="cuda_master_block_size",
        type=cuda_block_size,
        help="BIP39/PBKDF2 CUDA stage block size",
    )
    parser.add_argument(
        "--cuda-address-block-size",
        "--address-block-size",
        dest="cuda_address_block_size",
        type=cuda_block_size,
        help="BIP32/secp256k1/address CUDA stage block size",
    )
    parser.add_argument(
        "--warmup",
        "--warmup-seconds",
        type=nonnegative_float,
        default=30.0,
    )
    parser.add_argument(
        "--duration",
        "--duration-seconds",
        type=positive_float,
        default=120.0,
    )
    parser.add_argument("--runs", type=bounded_int(1, 100), default=3)
    parser.add_argument("--suffix", type=benchmark_suffix, default=DEFAULT_SUFFIX)
    parser.add_argument("--startup-timeout", type=positive_float, default=600.0)
    parser.add_argument("--protocol-timeout", type=positive_float, default=60.0)
    return parser


def validate_cuda_block_options(
    parser: argparse.ArgumentParser,
    args: argparse.Namespace,
) -> None:
    if args.cuda_block_size is not None and (
        args.cuda_master_block_size is not None
        or args.cuda_address_block_size is not None
    ):
        parser.error(
            "--cuda-block-size cannot be combined with "
            "--cuda-master-block-size or --cuda-address-block-size"
        )


def metric_summary(values: Sequence[float]) -> Dict[str, float]:
    mean = statistics.fmean(values)
    deviation = statistics.pstdev(values)
    return {
        "median": statistics.median(values),
        "mean": mean,
        "minimum": min(values),
        "maximum": max(values),
        "standard_deviation": deviation,
        "relative_standard_deviation_percent": (
            100.0 * deviation / mean if mean > 0.0 else 0.0
        ),
    }


def print_sample(sample: Sample, total_runs: int) -> None:
    label = "WARMUP" if sample.kind == "warmup" else f"RUN {sample.run}/{total_runs}"
    print(
        f"{label}: total={sample.attempts_per_second:.3f}/s "
        f"gpu={sample.gpu_attempts_per_second:.3f}/s "
        f"cpu={sample.cpu_attempts_per_second:.3f}/s "
        f"attempts={sample.attempts} gpu_attempts={sample.gpu_attempts} "
        f"cpu_attempts={sample.cpu_attempts} batch={sample.batch_size} "
        f"elapsed={sample.engine_elapsed_seconds:.3f}s",
        file=sys.stderr,
        flush=True,
    )


def signal_handler(signum: int, _frame) -> None:  # noqa: ANN001
    raise BenchmarkInterrupted(f"received signal {signum}")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_cuda_block_options(parser, args)

    engine = Path(args.engine).expanduser().resolve()
    if not engine.is_file() or not os.access(engine, os.X_OK):
        parser.error(f"engine is missing or not executable: {engine}")

    command = [str(engine), "--server", "--profile", args.profile]
    if args.batch_size is not None:
        command.extend(("--batch-size", str(args.batch_size)))
    if args.cpu_workers is not None:
        command.extend(("--cpu-workers", str(args.cpu_workers)))
    if args.cuda_block_size is not None:
        command.extend(("--cuda-block-size", str(args.cuda_block_size)))
    if args.cuda_master_block_size is not None:
        command.extend(
            ("--cuda-master-block-size", str(args.cuda_master_block_size))
        )
    if args.cuda_address_block_size is not None:
        command.extend(
            ("--cuda-address-block-size", str(args.cuda_address_block_size))
        )

    client = EngineClient(command, engine.parent)
    measurements: List[Sample] = []
    warmup: Optional[Sample] = None
    ready: Optional[ReadyInfo] = None
    exit_code = 0

    signal.signal(signal.SIGTERM, signal_handler)
    try:
        client.start()
        ready = client.wait_ready(args.startup_timeout)
        print(
            f"READY: {ready.device}; profile={ready.active_profile} "
            f"workers={ready.cpu_workers} capacity={ready.batch_capacity} "
            f"batch={ready.active_batch_size} "
            f"blocks={ready.cuda_master_block_size}/{ready.cuda_address_block_size} "
            f"mode={ready.kernel_mode}",
            file=sys.stderr,
            flush=True,
        )

        if args.warmup > 0.0:
            warmup = client.run_sample(
                suffix=args.suffix,
                duration=args.warmup,
                kind="warmup",
                run=0,
                protocol_timeout=args.protocol_timeout,
            )
            print_sample(warmup, args.runs)

        for run in range(1, args.runs + 1):
            sample = client.run_sample(
                suffix=args.suffix,
                duration=args.duration,
                kind="measurement",
                run=run,
                protocol_timeout=args.protocol_timeout,
            )
            measurements.append(sample)
            print_sample(sample, args.runs)
    except (BenchmarkInterrupted, KeyboardInterrupt) as error:
        print(f"Benchmark interrupted: {error}", file=sys.stderr)
        exit_code = 130
    except BenchmarkError as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        exit_code = 1
    finally:
        client.close()

    if exit_code != 0:
        return exit_code
    if client.forced_shutdown:
        print("Benchmark failed: engine ignored EXIT and was terminated", file=sys.stderr)
        return 1
    if client.return_code != 0:
        print(
            f"Benchmark failed: engine exited with code {client.return_code}",
            file=sys.stderr,
        )
        return 1

    assert ready is not None
    total_speeds = [sample.attempts_per_second for sample in measurements]
    gpu_speeds = [sample.gpu_attempts_per_second for sample in measurements]
    cpu_speeds = [sample.cpu_attempts_per_second for sample in measurements]
    report = {
        "schema_version": 1,
        "configuration": {
            "engine": str(engine),
            "profile": args.profile,
            "requested_cpu_workers": args.cpu_workers,
            "requested_batch_size": args.batch_size,
            "requested_cuda_block_size": args.cuda_block_size,
            "requested_master_block_size": args.cuda_master_block_size,
            "requested_address_block_size": args.cuda_address_block_size,
            "warmup_seconds": args.warmup,
            "duration_seconds": args.duration,
            "runs": args.runs,
            "suffix": args.suffix,
        },
        "ready": asdict(ready),
        "warmup": None if warmup is None else asdict(warmup),
        "measurements": [asdict(sample) for sample in measurements],
        "summary": {
            "attempts_per_second": metric_summary(total_speeds),
            "gpu_attempts_per_second": metric_summary(gpu_speeds),
            "cpu_attempts_per_second": metric_summary(cpu_speeds),
        },
    }
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
