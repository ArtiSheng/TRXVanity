#!/usr/bin/env python3
"""Fail-closed post-success cleanup for the Linux deployment.

This program deliberately has no command-line option for its target paths.  It
can only clean the fixed runtime directory after the controller creates a
signed authorization marker following an upload/download/decrypt round trip.
Secrets stay in RAM; cleanup replaces the process that held the winning
mnemonic, overwrites the volatile AES key, and securely deletes public runtime
status files.  It never fills free space on the data disk.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import resource
import signal
import stat
import sys
import uuid


DATA_MOUNT = Path("/root/autodl-tmp")
INSTALL_ROOT = DATA_MOUNT / "TRXVanityLinux"
WORK_DIR = INSTALL_ROOT / "runtime"
MARKER_PATH = WORK_DIR / "cleanup-authorized.json"
RUN_STATE_DIR = Path("/run/trxvanity")
STATUS_PATH = RUN_STATE_DIR / "cleanup-status.json"
LOCK_PATH = RUN_STATE_DIR / "cleanup.lock"
KEY_ENVIRONMENT_NAME = "TRX_AES_KEY_HEX"

EXPECTED_REASON = "verified_upload_roundtrip"
EXPECTED_SUFFIX = "8888888"
FORMAL_SUFFIX_FILE_NAME = "formal-suffix"
BASE58_PATTERN = re.compile(r"\A[1-9A-HJ-NP-Za-km-z]{1,10}\Z")
DEFAULT_PASSES = 5
MARKER_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
MARKER_MAX_BYTES = 16 * 1024
MAX_RUNTIME_FILE_BYTES = 256 * 1024**2
MAX_RUNTIME_TREE_BYTES = 1024**3
DEFAULT_CHUNK_BYTES = 16 * 1024**2

_stop_requested = False
_status_ready = False


class CleanupRefused(RuntimeError):
    """Raised when any safety invariant is not satisfied."""


def load_expected_suffix(install_root: Path | None = None) -> str:
    root = install_root if install_root is not None else INSTALL_ROOT
    suffix_path = root / FORMAL_SUFFIX_FILE_NAME
    if not suffix_path.exists():
        return EXPECTED_SUFFIX
    if suffix_path.is_symlink() or not suffix_path.is_file():
        raise CleanupRefused("formal-suffix must be a regular file")
    text = suffix_path.read_text(encoding="ascii").strip()
    if not BASE58_PATTERN.fullmatch(text):
        raise CleanupRefused("formal-suffix must contain 1 to 10 TRON Base58 characters")
    return text


def request_stop(signum: int, _frame: object) -> None:
    global _stop_requested
    _stop_requested = True


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def prepare_run_state() -> None:
    global _status_ready
    os.umask(0o077)
    if RUN_STATE_DIR.exists():
        info = RUN_STATE_DIR.lstat()
        if not stat.S_ISDIR(info.st_mode) or RUN_STATE_DIR.is_symlink():
            raise CleanupRefused(f"unsafe run-state path: {RUN_STATE_DIR}")
        if info.st_uid != 0:
            raise CleanupRefused(f"run-state directory is not root-owned: {RUN_STATE_DIR}")
        os.chmod(RUN_STATE_DIR, 0o700)
    else:
        RUN_STATE_DIR.mkdir(mode=0o700)
    _status_ready = True


def write_status(phase: str, **fields: object) -> None:
    if not _status_ready:
        return
    document: dict[str, object] = {
        "version": 1,
        "phase": phase,
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    document.update(fields)
    encoded = (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode()
    temporary = RUN_STATE_DIR / f".cleanup-status.{os.getpid()}.tmp"
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        os.write(descriptor, encoded)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, STATUS_PATH)
    os.chmod(STATUS_PATH, 0o600)
    fsync_directory(RUN_STATE_DIR)


def acquire_lock() -> int:
    descriptor = os.open(
        LOCK_PATH,
        os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exception:
        os.close(descriptor)
        raise CleanupRefused("another secure-cleanup process is already running") from exception
    return descriptor


def ensure_directory(path: Path, device: int, *, exact_mode: int = 0o700) -> os.stat_result:
    info = path.lstat()
    if path.is_symlink() or not stat.S_ISDIR(info.st_mode):
        raise CleanupRefused(f"required directory is not a real directory: {path}")
    if info.st_uid != 0:
        raise CleanupRefused(f"directory is not root-owned: {path}")
    if stat.S_IMODE(info.st_mode) != exact_mode:
        raise CleanupRefused(
            f"directory permissions must be {exact_mode:04o}: {path}"
        )
    if info.st_dev != device:
        raise CleanupRefused(f"directory crosses the authorized filesystem: {path}")
    return info


def preflight_filesystem() -> tuple[int, str, str]:
    if os.geteuid() != 0:
        raise CleanupRefused("secure cleanup must run as root")
    if DATA_MOUNT.resolve(strict=True) != DATA_MOUNT:
        raise CleanupRefused(f"data mount contains a symlink: {DATA_MOUNT}")
    mount_info = DATA_MOUNT.lstat()
    if not stat.S_ISDIR(mount_info.st_mode) or DATA_MOUNT.is_symlink():
        raise CleanupRefused(f"data mount is not a real directory: {DATA_MOUNT}")
    ensure_directory(INSTALL_ROOT, mount_info.st_dev)
    ensure_directory(WORK_DIR, mount_info.st_dev)
    return mount_info.st_dev, "shared-or-overlay", str(DATA_MOUNT)


def read_aes_key() -> bytearray:
    value = os.environ.pop(KEY_ENVIRONMENT_NAME, None)
    if value is None:
        raise CleanupRefused(f"missing {KEY_ENVIRONMENT_NAME} environment variable")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise CleanupRefused(f"{KEY_ENVIRONMENT_NAME} must contain exactly 64 hexadecimal digits")
    return bytearray.fromhex(value)


def read_marker_bytes(device: int) -> bytes:
    descriptor = os.open(
        MARKER_PATH,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
    )
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise CleanupRefused("authorization marker is not a regular file")
        if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600:
            raise CleanupRefused("authorization marker must be root-owned with mode 0600")
        if info.st_nlink != 1:
            raise CleanupRefused("authorization marker must not have hard links")
        if info.st_dev != device:
            raise CleanupRefused("authorization marker is on the wrong filesystem")
        if info.st_size <= 0 or info.st_size > MARKER_MAX_BYTES:
            raise CleanupRefused("authorization marker has an invalid size")
        payload = bytearray()
        while len(payload) <= MARKER_MAX_BYTES:
            part = os.read(descriptor, min(4096, MARKER_MAX_BYTES + 1 - len(payload)))
            if not part:
                break
            payload.extend(part)
        if len(payload) > MARKER_MAX_BYTES:
            raise CleanupRefused("authorization marker is too large")
        return bytes(payload)
    finally:
        os.close(descriptor)


def parse_utc_timestamp(value: object) -> dt.datetime:
    if not isinstance(value, str):
        raise CleanupRefused("marker verified_at is missing or invalid")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        timestamp = dt.datetime.fromisoformat(normalized)
    except ValueError as exception:
        raise CleanupRefused("marker verified_at is not ISO-8601") from exception
    if timestamp.tzinfo is None:
        raise CleanupRefused("marker verified_at must include a timezone")
    return timestamp.astimezone(dt.timezone.utc)


def validate_marker(device: int, key: bytearray) -> dict[str, object]:
    try:
        marker = json.loads(read_marker_bytes(device))
    except (UnicodeDecodeError, json.JSONDecodeError) as exception:
        raise CleanupRefused("authorization marker is not valid UTF-8 JSON") from exception
    if not isinstance(marker, dict):
        raise CleanupRefused("authorization marker must be a JSON object")

    supplied_hmac = marker.get("marker_hmac")
    if not isinstance(supplied_hmac, str) or not re.fullmatch(
        r"[0-9a-fA-F]{64}", supplied_hmac
    ):
        raise CleanupRefused("authorization marker HMAC is missing or invalid")
    unsigned = dict(marker)
    del unsigned["marker_hmac"]
    try:
        canonical = json.dumps(
            unsigned,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exception:
        raise CleanupRefused("authorization marker cannot be canonicalized") from exception
    expected_hmac = hmac.new(key, canonical, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected_hmac, supplied_hmac.lower()):
        raise CleanupRefused("authorization marker HMAC verification failed")

    if marker.get("version") != 1 or marker.get("authorized") is not True:
        raise CleanupRefused("authorization marker is not enabled or has an unknown version")
    if marker.get("reason") != EXPECTED_REASON:
        raise CleanupRefused("authorization reason is not a verified upload round trip")
    if marker.get("target_suffix") != load_expected_suffix():
        raise CleanupRefused("cleanup is authorized only for the deployed formal suffix")
    verification = marker.get("verification")
    if not isinstance(verification, dict) or any(
        verification.get(name) is not True
        for name in ("upload_success", "download_hash_match", "decrypt_match")
    ):
        raise CleanupRefused("marker does not prove all three round-trip verification stages")
    if marker.get("work_dir") != str(WORK_DIR):
        raise CleanupRefused("marker work_dir does not match the fixed runtime directory")
    if marker.get("filesystem_device") != device:
        raise CleanupRefused("marker filesystem_device does not match the mounted data disk")

    job_id = marker.get("job_id")
    try:
        parsed_job_id = uuid.UUID(job_id) if isinstance(job_id, str) else None
    except ValueError as exception:
        raise CleanupRefused("marker job_id is not a UUID") from exception
    if parsed_job_id is None or str(parsed_job_id) != job_id.lower():
        raise CleanupRefused("marker job_id is not a canonical UUID")
    nonce = marker.get("marker_nonce")
    if not isinstance(nonce, str) or not re.fullmatch(r"[0-9a-fA-F]{32,128}", nonce):
        raise CleanupRefused("marker nonce is missing or invalid")
    backup_file = marker.get("backup_file")
    if (
        not isinstance(backup_file, str)
        or not backup_file
        or len(backup_file) > 255
        or Path(backup_file).name != backup_file
    ):
        raise CleanupRefused("marker backup_file is missing or unsafe")

    verified_at = parse_utc_timestamp(marker.get("verified_at"))
    now = dt.datetime.now(dt.timezone.utc)
    age = (now - verified_at).total_seconds()
    if age < -300 or age > MARKER_MAX_AGE_SECONDS:
        raise CleanupRefused("authorization marker is outside its permitted time window")
    return marker


def preflight_runtime_tree(device: int) -> tuple[int, int]:
    file_count = 0
    total_file_bytes = 0
    for root, directories, files in os.walk(WORK_DIR, topdown=True, followlinks=False):
        root_path = Path(root)
        root_info = root_path.lstat()
        if root_info.st_dev != device or not stat.S_ISDIR(root_info.st_mode):
            raise CleanupRefused(f"runtime tree crosses a filesystem at {root_path}")
        if root_info.st_uid != 0:
            raise CleanupRefused(f"runtime tree contains a non-root-owned directory: {root_path}")
        for name in list(directories) + files:
            path = root_path / name
            info = path.lstat()
            if info.st_dev != device:
                raise CleanupRefused(f"runtime entry crosses the authorized filesystem: {path}")
            if info.st_uid != 0:
                raise CleanupRefused(f"runtime entry is not root-owned: {path}")
            if stat.S_ISLNK(info.st_mode):
                continue
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                raise CleanupRefused(f"runtime tree contains a special file: {path}")
            if info.st_nlink != 1:
                raise CleanupRefused(f"runtime file has hard links: {path}")
            if info.st_size > MAX_RUNTIME_FILE_BYTES:
                raise CleanupRefused(f"runtime file is unexpectedly large: {path}")
            file_count += 1
            total_file_bytes += info.st_size
            if total_file_bytes > MAX_RUNTIME_TREE_BYTES:
                raise CleanupRefused("runtime files have an unexpectedly large combined size")
    return file_count, total_file_bytes


def pass_chunk(pass_index: int, size: int) -> bytes:
    selector = pass_index % 5
    if selector == 0:
        return bytes(size)
    if selector == 1:
        return b"\xff" * size
    if selector == 3:
        return b"\xaa" * size
    return os.urandom(size)


def overwrite_regular_file(path: Path, passes: int, device: int) -> None:
    before = path.lstat()
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
    )
    try:
        current = os.fstat(descriptor)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_dev != device
            or current.st_ino != before.st_ino
            or current.st_nlink != 1
        ):
            raise CleanupRefused("runtime file changed during secure deletion")
        size = current.st_size
        for pass_index in range(passes):
            if _stop_requested:
                raise InterruptedError("cleanup interrupted")
            os.lseek(descriptor, 0, os.SEEK_SET)
            remaining = size
            while remaining:
                if _stop_requested:
                    raise InterruptedError("cleanup interrupted")
                amount = min(DEFAULT_CHUNK_BYTES, remaining)
                chunk = pass_chunk(pass_index, amount)
                view = memoryview(chunk)
                while view:
                    written = os.write(descriptor, view)
                    view = view[written:]
                remaining -= amount
            os.fsync(descriptor)
        os.ftruncate(descriptor, 0)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    after = path.lstat()
    if after.st_dev != before.st_dev or after.st_ino != before.st_ino:
        raise CleanupRefused("runtime file was replaced during secure deletion")
    path.unlink()


def remove_runtime_contents(directory: Path, passes: int, device: int) -> tuple[int, int]:
    removed_files = 0
    removed_directories = 0
    with os.scandir(directory) as entries:
        snapshot = list(entries)
    for entry in snapshot:
        path = Path(entry.path)
        if path == MARKER_PATH:
            continue
        info = path.lstat()
        if info.st_dev != device or info.st_uid != 0:
            raise CleanupRefused("runtime entry changed after preflight")
        if stat.S_ISLNK(info.st_mode):
            path.unlink()
            removed_files += 1
        elif stat.S_ISDIR(info.st_mode):
            files, directories = remove_runtime_contents(path, passes, device)
            removed_files += files
            removed_directories += directories
            path.rmdir()
            removed_directories += 1
        elif stat.S_ISREG(info.st_mode):
            overwrite_regular_file(path, passes, device)
            removed_files += 1
        else:
            raise CleanupRefused("runtime special file appeared after preflight")
    fsync_directory(directory)
    return removed_files, removed_directories


def consume_marker() -> None:
    info = MARKER_PATH.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise CleanupRefused("authorization marker changed before consumption")
    MARKER_PATH.unlink()
    fsync_directory(WORK_DIR)


def run_cleanup(args: argparse.Namespace) -> int:
    prepare_run_state()
    lock_descriptor = acquire_lock()
    key = bytearray()
    try:
        write_status("preflight", execute=args.execute)
        device, filesystem_type, mount_source = preflight_filesystem()
        key = read_aes_key()
        marker = validate_marker(device, key)
        file_count, total_file_bytes = preflight_runtime_tree(device)
        write_status(
            "authorized",
            execute=args.execute,
            job_id=marker["job_id"],
            filesystem_type=filesystem_type,
            mount_source=mount_source,
            runtime_file_count=file_count,
            runtime_file_bytes=total_file_bytes,
            passes=args.passes,
            warning=(
                "hybrid mode: runtime files are public status only; "
                "filesystem free-space overwrite is not used"
            ),
        )
        if not args.execute:
            print("Safety checks and signed authorization verification passed; no data was changed.")
            return 0

        write_status(
            "runtime_secure_delete",
            job_id=marker["job_id"],
            passes=args.passes,
        )
        removed_files, removed_directories = remove_runtime_contents(
            WORK_DIR,
            args.passes,
            device,
        )
        consume_marker()
        write_status(
            "complete",
            job_id=marker["job_id"],
            passes=args.passes,
            runtime_files_removed=removed_files,
            runtime_directories_removed=removed_directories,
            marker_consumed=True,
        )
        return 0
    except InterruptedError as exception:
        write_status(
            "interrupted",
            error=str(exception),
            marker_retained=MARKER_PATH.exists(),
        )
        return 130
    except (CleanupRefused, OSError) as exception:
        write_status("refused", error=str(exception))
        print(f"secure cleanup refused: {exception}", file=sys.stderr)
        return 2
    finally:
        for index in range(len(key)):
            key[index] = 0
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        finally:
            os.close(lock_descriptor)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify a signed controller authorization and securely delete "
            "public runtime files under /root/autodl-tmp/TRXVanityLinux/runtime."
        )
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="overwrite and delete runtime files; without this flag only preflight runs",
    )
    parser.add_argument(
        "--passes",
        type=int,
        default=DEFAULT_PASSES,
        help="runtime-file overwrite passes (minimum: 5)",
    )
    args = parser.parse_args()
    if args.passes < DEFAULT_PASSES or args.passes > 20:
        parser.error("--passes must be between 5 and 20")
    return args


def main() -> int:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    return run_cleanup(parse_arguments())


if __name__ == "__main__":
    raise SystemExit(main())
