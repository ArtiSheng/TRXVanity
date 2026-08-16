#!/usr/bin/env python3
"""Linux supervisor for the TRX Vanity mnemonic engine.

The controller deliberately keeps the mnemonic and AES key in process memory.
Neither value is written to the runtime status, logs, backup marker, or disk.
"""

from __future__ import annotations

import argparse
import copy
import ctypes
import ctypes.util
import datetime as dt
import fcntl
import hashlib
import hmac
import http.server
import json
import math
import os
import re
import resource
import secrets
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple


APP_DIR = Path(__file__).resolve().parent
WEB_DIR = APP_DIR / "web"
DEFAULT_ENGINE = APP_DIR / "build" / "trxvanity-gpu"
DEFAULT_UPLOAD_ENDPOINT = (
    "https://t.artisheng.vip/upload.php?"
    "token=c38400a68071789409e4866449957acd5a181db11df7ecd51a97d3ebc0fb2d6e"
)
DERIVATION_PATH = "m/44'/195'/0'/0/0"
FORMAL_SUFFIX = "8888888"
FORMAL_SUFFIX_FILE = APP_DIR / "formal-suffix"
FORMAL_INSTALL_ROOT = Path("/root/autodl-fs/TRXVanityLinux")
FORMAL_RUNTIME_DIR = Path("/root/autodl-tmp/TRXVanityLinux/runtime")
CLEANUP_STATUS_PATH = Path("/run/trxvanity/cleanup-status.json")
RUN_STATE_DIR = Path("/run/trxvanity")
SEARCH_LOCK_PATH = RUN_STATE_DIR / "search.lock"
VOLATILE_SECRETS_PATH = Path("/dev/shm/trxvanity-secrets.env")
BASE58_PATTERN = re.compile(r"\A[1-9A-HJ-NP-Za-km-z]{1,10}\Z")
ENGINE_DEVICE_PATTERN = re.compile(
    r"\A(?:NVIDIA[A-Za-z0-9 .,_()+:/-]{0,193}|GPU)\Z"
)
ENGINE_READY_PROFILES = frozenset({"smart", "rtx5070", "rtx4090"})
ENGINE_KERNEL_MODES = frozenset({"cuda-bip39", "cuda-bip39+openssl-cpu"})
ENGINE_CPU_BUDGET_SOURCES = frozenset(
    {"logical", "affinity", "cgroup-v1", "cgroup-v2"}
)
BACKUP_NAME_PATTERN = re.compile(
    r"\Abackup_[0-9]{8}_[0-9]{6}_[a-f0-9]{16}\.trxv\Z"
)
MAGIC = b"TRXMNEMO"
AUTHENTICATION_LABEL = b"TRXVanity mnemonic backup authentication"
HEADER_LENGTH = 28
TAG_LENGTH = 32
MAX_DOWNLOAD_BYTES = 2 * 1024 * 1024
PR_SET_DUMPABLE = 4
ENGINE_PROGRESS_TIMEOUT_SECONDS = 90.0
ENGINE_STARTUP_TIMEOUT_SECONDS = 600.0
ENGINE_WATCHDOG_TERMINATE_GRACE_SECONDS = 5.0
ENGINE_STOP_GRACE_SECONDS = 10.0
_INSTANCE_LOCK_DESCRIPTOR: Optional[int] = None


class ControllerError(RuntimeError):
    """Expected, user-facing controller failure."""


def load_formal_suffix(path: Optional[Path] = None) -> str:
    """Read the suffix written by deploy.py, or the built-in default."""
    suffix_path = Path(path) if path is not None else FORMAL_SUFFIX_FILE
    if not suffix_path.exists():
        return FORMAL_SUFFIX
    if suffix_path.is_symlink() or not suffix_path.is_file():
        raise ControllerError("formal-suffix must be a regular file")
    text = suffix_path.read_text(encoding="ascii").strip()
    if not BASE58_PATTERN.fullmatch(text):
        raise ControllerError("formal-suffix must contain 1 to 10 TRON Base58 characters")
    return text


def is_formal_run(args: argparse.Namespace) -> bool:
    return args.mode == "run" and args.suffix == load_formal_suffix()


class BackupError(ControllerError):
    """Encryption, upload, download, or verification failure."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(_NoRedirect)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def parse_bool(value: Optional[str], default: bool) -> bool:
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ControllerError("boolean environment value must be true or false")


def parse_positive_int(value: Optional[str], default: int, name: str) -> int:
    if value is None or value == "":
        return default
    try:
        parsed = int(value, 10)
    except ValueError as error:
        raise ControllerError(f"{name} must be an integer") from error
    if parsed <= 0:
        raise ControllerError(f"{name} must be greater than zero")
    return parsed


def _ready_uint(
    fields: Sequence[str],
    index: int,
    *,
    minimum: int,
    maximum: int,
    multiple: int = 1,
) -> int:
    """Parse one bounded READY integer without trusting the engine's text."""
    if index >= len(fields) or not re.fullmatch(r"[0-9]{1,20}", fields[index]):
        return 0
    try:
        value = int(fields[index], 10)
    except ValueError:
        return 0
    if not minimum <= value <= maximum or value % multiple:
        return 0
    return value


def parse_engine_ready_status(
    fields: Sequence[str], fallback_profile: str
) -> Dict[str, Any]:
    """Return only bounded, non-sensitive fields from old or current READY lines."""
    device = fields[1] if len(fields) >= 2 else ""
    if not ENGINE_DEVICE_PATTERN.fullmatch(device):
        device = "GPU"

    profile = fields[3] if len(fields) >= 4 else ""
    if profile not in ENGINE_READY_PROFILES:
        profile = fallback_profile if fallback_profile in ENGINE_READY_PROFILES else "smart"

    kernel_mode = fields[8] if len(fields) >= 9 else ""
    if kernel_mode not in ENGINE_KERNEL_MODES:
        kernel_mode = ""

    budget_source = fields[10] if len(fields) >= 11 else ""
    if budget_source not in ENGINE_CPU_BUDGET_SOURCES:
        budget_source = ""

    cpu_budget = _ready_uint(fields, 9, minimum=1, maximum=1_000_000)
    if cpu_budget == 0:
        budget_source = ""

    return {
        "engine_device": device,
        "engine_profile": profile,
        "engine_batch_capacity": _ready_uint(
            fields, 2, minimum=1, maximum=0xFFFFFFFF
        ),
        "engine_cpu_workers": _ready_uint(fields, 4, minimum=0, maximum=256),
        "engine_batch_size": _ready_uint(
            fields, 5, minimum=1, maximum=0xFFFFFFFF
        ),
        "engine_cuda_master_block_size": _ready_uint(
            fields, 6, minimum=32, maximum=1024, multiple=32
        ),
        "engine_cuda_address_block_size": _ready_uint(
            fields, 7, minimum=32, maximum=1024, multiple=32
        ),
        "engine_kernel_mode": kernel_mode,
        "engine_cpu_budget": cpu_budget,
        "engine_cpu_budget_source": budget_source,
    }


def load_env_file(path_value: Optional[str]) -> None:
    """Load a small KEY=VALUE file after enforcing secret-file permissions."""
    if not path_value:
        return
    unresolved = Path(path_value).expanduser()
    unresolved_metadata = unresolved.lstat()
    if stat.S_ISLNK(unresolved_metadata.st_mode):
        raise ControllerError("environment file must not be a symbolic link")
    path = unresolved.resolve(strict=True)
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ControllerError("environment file must be a regular file")
    if metadata.st_uid != os.geteuid():
        raise ControllerError("environment file must be owned by the current user")
    if stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
        raise ControllerError(
            "environment file must have exactly mode 0600 and one hard link"
        )
    seen_names = set()
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        had_export_prefix = line.startswith("export ")
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ControllerError(f"invalid environment-file line {number}")
        name, value = line.split("=", 1)
        name = name.strip()
        if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", name):
            raise ControllerError(f"invalid environment name on line {number}")
        if name in seen_names:
            raise ControllerError(f"duplicate environment name on line {number}: {name}")
        seen_names.add(name)
        value = value.strip()
        was_quoted = (
            len(value) >= 2
            and value[0] == value[-1]
            and value[0] in {"'", '"'}
        )
        if was_quoted:
            value = value[1:-1]
        if name == "TRX_AES_KEY_HEX":
            expected_line = f"TRX_AES_KEY_HEX={value}"
            if had_export_prefix or was_quoted or raw_line != expected_line:
                raise ControllerError(
                    "TRX_AES_KEY_HEX must use one exact, unquoted KEY=VALUE line"
                )
        # The explicitly selected owner-only file is authoritative.  In
        # particular, the controller and cleanup wrapper must sign/verify the
        # marker with the identical AES key even if a service manager supplied
        # a stale process environment.
        os.environ[name] = value


def require_aes_key() -> bytearray:
    key_hex = os.environ.pop("TRX_AES_KEY_HEX", "").strip()
    if not re.fullmatch(r"[0-9a-fA-F]{64}", key_hex):
        raise ControllerError(
            "TRX_AES_KEY_HEX must contain exactly 64 hexadecimal characters"
        )
    key = bytearray.fromhex(key_hex)
    key_hex = ""
    return key


def wipe(value: Optional[bytearray]) -> None:
    if value is not None:
        for index in range(len(value)):
            value[index] = 0


def harden_process() -> None:
    """Keep controller secrets out of core dumps and ptrace-style reads."""
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if not sys.platform.startswith("linux"):
        return
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(libc, "prctl", None)
    if prctl is None:
        raise ControllerError("Linux prctl is unavailable")
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    if prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0:
        error_number = ctypes.get_errno()
        raise ControllerError(
            f"could not disable process dumpability (errno {error_number})"
        )


def acquire_instance_lock() -> None:
    """Hold one lock across the search and the exec'd cleanup program."""
    global _INSTANCE_LOCK_DESCRIPTOR
    if _INSTANCE_LOCK_DESCRIPTOR is not None:
        return
    try:
        RUN_STATE_DIR.mkdir(mode=0o700, parents=False, exist_ok=True)
        directory_info = RUN_STATE_DIR.lstat()
    except OSError as error:
        raise ControllerError("could not prepare the search instance lock") from error
    if (
        stat.S_ISLNK(directory_info.st_mode)
        or not stat.S_ISDIR(directory_info.st_mode)
        or directory_info.st_uid != os.geteuid()
    ):
        raise ControllerError("search lock directory is unsafe")
    os.chmod(RUN_STATE_DIR, 0o700)
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(SEARCH_LOCK_PATH, flags, 0o600)
        lock_info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(lock_info.st_mode)
            or lock_info.st_uid != os.geteuid()
            or lock_info.st_nlink != 1
        ):
            raise ControllerError("search instance lock file is unsafe")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Python makes new descriptors close-on-exec by default.  Deliberately
        # keep this one across controller -> bash wrapper -> cleanup Python so
        # no second search can start during the five overwrite passes.
        os.set_inheritable(descriptor, True)
    except BlockingIOError as error:
        try:
            os.close(descriptor)
        except (OSError, UnboundLocalError):
            pass
        raise ControllerError("another TRX Vanity search or cleanup is already running") from error
    except (OSError, ControllerError):
        try:
            os.close(descriptor)
        except (OSError, UnboundLocalError):
            pass
        raise
    _INSTANCE_LOCK_DESCRIPTOR = descriptor


def validate_upload_endpoint(value: str) -> Tuple[str, str, str]:
    parsed = urllib.parse.urlsplit(value)
    secure = parsed.scheme.lower() == "https"
    loopback_http = parsed.scheme.lower() == "http" and parsed.hostname in {
        "127.0.0.1",
        "::1",
        "localhost",
    }
    if not secure and not loopback_http:
        raise ControllerError("upload endpoint must use HTTPS (or loopback HTTP for tests)")
    if not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ControllerError("upload endpoint is invalid")
    if not parsed.path.endswith("/upload.php") and parsed.path != "/upload.php":
        raise ControllerError("upload endpoint path must end in upload.php")
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    if len(query.get("token", [])) != 1 or not query["token"][0]:
        raise ControllerError("upload endpoint must contain one non-empty token")
    base_path = parsed.path.rsplit("/", 1)[0] + "/"
    heartbeat = urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, base_path + "heartbeat.php", parsed.query, "")
    )
    public_origin = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))
    return value, heartbeat, public_origin


class OpenSslEvp:
    """Minimal AES-CBC binding to the system OpenSSL libcrypto.

    ctypes avoids placing the AES key in an openssl(1) command line, where it
    would otherwise be briefly visible to other processes.
    """

    def __init__(self) -> None:
        library_name = ctypes.util.find_library("crypto")
        if not library_name:
            raise BackupError("system OpenSSL libcrypto was not found")
        try:
            self.lib = ctypes.CDLL(library_name)
        except OSError as error:
            raise BackupError("system OpenSSL libcrypto could not be loaded") from error
        void_p = ctypes.c_void_p
        int_p = ctypes.POINTER(ctypes.c_int)
        self.lib.EVP_CIPHER_CTX_new.restype = void_p
        self.lib.EVP_CIPHER_CTX_free.argtypes = [void_p]
        self.lib.EVP_aes_256_cbc.restype = void_p
        self.lib.EVP_EncryptInit_ex.argtypes = [void_p, void_p, void_p, void_p, void_p]
        self.lib.EVP_EncryptUpdate.argtypes = [void_p, void_p, int_p, void_p, ctypes.c_int]
        self.lib.EVP_EncryptFinal_ex.argtypes = [void_p, void_p, int_p]
        self.lib.EVP_DecryptInit_ex.argtypes = [void_p, void_p, void_p, void_p, void_p]
        self.lib.EVP_DecryptUpdate.argtypes = [void_p, void_p, int_p, void_p, ctypes.c_int]
        self.lib.EVP_DecryptFinal_ex.argtypes = [void_p, void_p, int_p]

    def encrypt(self, clear: bytearray, key: bytearray, iv: bytes) -> bytes:
        return self._crypt(clear, key, iv, decrypt=False)

    def decrypt(self, cipher: bytes, key: bytearray, iv: bytes) -> bytes:
        return self._crypt(cipher, key, iv, decrypt=True)

    def _crypt(self, data, key: bytearray, iv: bytes, decrypt: bool) -> bytes:  # noqa: ANN001
        if len(key) != 32 or len(iv) != 16 or len(data) > 2_147_483_000:
            raise BackupError("invalid AES input")
        context = self.lib.EVP_CIPHER_CTX_new()
        if not context:
            raise BackupError("OpenSSL could not allocate an AES context")
        key_buffer = (ctypes.c_ubyte * len(key)).from_buffer_copy(key)
        iv_buffer = (ctypes.c_ubyte * len(iv)).from_buffer_copy(iv)
        input_buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
        output_buffer = ctypes.create_string_buffer(len(data) + 32)
        first_length = ctypes.c_int(0)
        final_length = ctypes.c_int(0)
        try:
            cipher_type = self.lib.EVP_aes_256_cbc()
            init = self.lib.EVP_DecryptInit_ex if decrypt else self.lib.EVP_EncryptInit_ex
            update = self.lib.EVP_DecryptUpdate if decrypt else self.lib.EVP_EncryptUpdate
            final = self.lib.EVP_DecryptFinal_ex if decrypt else self.lib.EVP_EncryptFinal_ex
            if not cipher_type or init(
                context,
                cipher_type,
                None,
                key_buffer,
                iv_buffer,
            ) != 1:
                raise BackupError("OpenSSL AES initialization failed")
            if update(
                context,
                output_buffer,
                ctypes.byref(first_length),
                input_buffer,
                len(data),
            ) != 1:
                raise BackupError("OpenSSL AES operation failed")
            final_pointer = ctypes.byref(output_buffer, first_length.value)
            if final(context, final_pointer, ctypes.byref(final_length)) != 1:
                message = "backup authentication or AES padding is invalid" if decrypt else (
                    "OpenSSL AES finalization failed"
                )
                raise BackupError(message)
            length = first_length.value + final_length.value
            return bytes(output_buffer.raw[:length])
        finally:
            ctypes.memset(key_buffer, 0, len(key_buffer))
            ctypes.memset(iv_buffer, 0, len(iv_buffer))
            ctypes.memset(input_buffer, 0, len(input_buffer))
            ctypes.memset(output_buffer, 0, len(output_buffer))
            self.lib.EVP_CIPHER_CTX_free(context)


def encrypt_backup(record: Mapping[str, str], key: bytearray, aes: OpenSslEvp) -> bytes:
    clear = bytearray(
        (json.dumps(record, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    )
    iv = secrets.token_bytes(16)
    try:
        cipher = aes.encrypt(clear, key, iv)
        header = MAGIC + iv + len(cipher).to_bytes(4, "big") + cipher
        authentication_key = hmac.new(key, AUTHENTICATION_LABEL, hashlib.sha256).digest()
        tag = hmac.new(authentication_key, header, hashlib.sha256).digest()
        return header + tag
    finally:
        wipe(clear)


def decrypt_backup(envelope: bytes, key: bytearray, aes: OpenSslEvp) -> Dict[str, Any]:
    if len(envelope) < HEADER_LENGTH + 16 + TAG_LENGTH or envelope[:8] != MAGIC:
        raise BackupError("download is not a TRXMNEMO backup")
    cipher_length = int.from_bytes(envelope[24:28], "big")
    if (
        cipher_length < 16
        or cipher_length % 16
        or len(envelope) != HEADER_LENGTH + cipher_length + TAG_LENGTH
    ):
        raise BackupError("downloaded backup has an invalid length")
    authenticated = envelope[: HEADER_LENGTH + cipher_length]
    authentication_key = hmac.new(key, AUTHENTICATION_LABEL, hashlib.sha256).digest()
    expected_tag = hmac.new(authentication_key, authenticated, hashlib.sha256).digest()
    if not hmac.compare_digest(expected_tag, envelope[-TAG_LENGTH:]):
        raise BackupError("downloaded backup failed HMAC authentication")
    clear = bytearray(aes.decrypt(envelope[28:-TAG_LENGTH], key, envelope[8:24]))
    try:
        decoded = json.loads(clear.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BackupError("downloaded backup plaintext is not valid JSON") from error
    finally:
        wipe(clear)
    if not isinstance(decoded, dict):
        raise BackupError("downloaded backup plaintext is not a JSON object")
    return decoded


def atomic_json(path: Path, value: Mapping[str, Any], mode: int) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    encoded = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode(
        "utf-8"
    )
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(5)}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_limited(response, maximum: int) -> bytes:  # noqa: ANN001
    data = response.read(maximum + 1)
    if len(data) > maximum:
        raise BackupError("server response exceeded the allowed size")
    return data


class RemoteBackup:
    def __init__(self, endpoint: str, timeout: int, attempts: int) -> None:
        self.endpoint, self.heartbeat_endpoint, self.public_origin = (
            validate_upload_endpoint(endpoint)
        )
        self.timeout = timeout
        self.attempts = attempts
        parsed = urllib.parse.urlsplit(self.endpoint)
        base_path = parsed.path.rsplit("/", 1)[0] + "/"
        self.download_base = urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, base_path + "download.php", "", "")
        )

    def upload(self, envelope: bytes) -> str:
        last_error: Optional[Exception] = None
        for attempt in range(1, self.attempts + 1):
            request = urllib.request.Request(
                self.endpoint,
                data=envelope,
                method="POST",
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/octet-stream",
                    "User-Agent": "TRXVanity-Linux-EncryptedBackup/1.0",
                },
            )
            try:
                with NO_REDIRECT_OPENER.open(request, timeout=self.timeout) as response:
                    if response.status < 200 or response.status >= 300:
                        raise BackupError(f"upload returned HTTP {response.status}")
                    payload = json.loads(read_limited(response, 65_536).decode("utf-8"))
                if not isinstance(payload, dict) or payload.get("ok") is not True:
                    raise BackupError("upload server did not confirm success")
                filename = payload.get("file")
                if not isinstance(filename, str) or not BACKUP_NAME_PATTERN.fullmatch(filename):
                    raise BackupError("upload server returned an invalid backup filename")
                if payload.get("bytes") not in {None, len(envelope)}:
                    raise BackupError("upload server byte count did not match")
                return filename
            except (OSError, urllib.error.URLError, urllib.error.HTTPError, ValueError, BackupError) as error:
                last_error = error
                if attempt < self.attempts:
                    time.sleep(min(2 ** (attempt - 1), 8))
        raise BackupError(f"encrypted upload failed after {self.attempts} attempts") from last_error

    def download(self, filename: str) -> bytes:
        if not BACKUP_NAME_PATTERN.fullmatch(filename):
            raise BackupError("refusing an invalid backup filename")
        target = self.download_base + "?" + urllib.parse.urlencode({"file": filename})
        last_error: Optional[Exception] = None
        for attempt in range(1, self.attempts + 1):
            request = urllib.request.Request(
                target,
                method="GET",
                headers={"User-Agent": "TRXVanity-Linux-BackupVerifier/1.0"},
            )
            try:
                with NO_REDIRECT_OPENER.open(request, timeout=self.timeout) as response:
                    if response.status != 200:
                        raise BackupError(f"download returned HTTP {response.status}")
                    return read_limited(response, MAX_DOWNLOAD_BYTES)
            except (OSError, urllib.error.URLError, urllib.error.HTTPError, BackupError) as error:
                last_error = error
                if attempt < self.attempts:
                    time.sleep(min(2 ** (attempt - 1), 8))
        raise BackupError(f"backup download failed after {self.attempts} attempts") from last_error


class HeartbeatClient:
    ALLOWED_STATES = {"starting", "ready", "searching", "result", "error", "closing"}

    def __init__(self, endpoint: str, controller: "Controller", timeout: int = 8) -> None:
        self.endpoint = endpoint
        self.controller = controller
        identity = f"{socket.gethostname()}|{APP_DIR}"
        self.client_id = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:32]
        self.run_id = uuid.uuid4().hex
        self.timeout = timeout
        self.sequence = 0
        self.sequence_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self.thread = threading.Thread(target=self._periodic, name="heartbeat", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=2.0)
        self.thread = None

    def _periodic(self) -> None:
        while not self.stop_event.wait(15.0):
            try:
                self.send()
            except ControllerError:
                self.controller.update(heartbeat_ok=False, heartbeat_at=utc_now())

    def send(
        self,
        event: str = "",
        event_detail: str = "",
        address: str = "",
        state_override: Optional[str] = None,
    ) -> Dict[str, Any]:
        snapshot = self.controller.public_status()
        state = state_override or snapshot.get("heartbeat_state", "starting")
        if state not in self.ALLOWED_STATES:
            state = "error"
        with self.sequence_lock:
            self.sequence += 1
            sequence = self.sequence
        payload = {
            "client_id": self.client_id,
            "run_id": self.run_id,
            "client_name": socket.gethostname(),
            "state": state,
            "detail": (event_detail or str(snapshot.get("detail", "")))[:1000],
            "event": event,
            "event_id": uuid.uuid4().hex if event else "",
            "address": address,
            "suffix": str(snapshot.get("suffix", "")),
            "sequence": sequence,
            "speed": max(0.0, float(snapshot.get("speed", 0.0))),
            "attempts": max(0, int(snapshot.get("attempts", 0))),
        }
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(
            self.endpoint,
            data=body,
            method="POST",
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json; charset=utf-8",
                "User-Agent": "TRXVanity-Linux-Heartbeat/1.0",
            },
        )
        try:
            with NO_REDIRECT_OPENER.open(request, timeout=self.timeout) as response:
                if response.status < 200 or response.status >= 300:
                    raise ControllerError(f"heartbeat returned HTTP {response.status}")
                decoded = json.loads(read_limited(response, 65_536).decode("utf-8"))
            if not isinstance(decoded, dict) or decoded.get("ok") is not True:
                raise ControllerError("heartbeat server did not confirm success")
            self.controller.record_heartbeat_response(
                max(0, int(decoded.get("notifications", 0)))
            )
            return decoded
        except (OSError, urllib.error.URLError, urllib.error.HTTPError, ValueError) as error:
            raise ControllerError("heartbeat request failed") from error


class MonitorHandler(http.server.BaseHTTPRequestHandler):
    server_version = "TRXVanityMonitor/1.0"

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.query or parsed.fragment:
            self._error(404)
            return
        if parsed.path == "/api/status":
            payload = (json.dumps(
                self.server.controller.public_status(),  # type: ignore[attr-defined]
                ensure_ascii=False,
                separators=(",", ":"),
            ) + "\n").encode("utf-8")
            self._send(200, "application/json; charset=utf-8", payload)
            return
        files = {
            "/": ("index.html", "text/html; charset=utf-8"),
            "/index.html": ("index.html", "text/html; charset=utf-8"),
            "/app.js": ("app.js", "text/javascript; charset=utf-8"),
            "/style.css": ("style.css", "text/css; charset=utf-8"),
        }
        selected = files.get(parsed.path)
        if not selected:
            self._error(404)
            return
        try:
            payload = (WEB_DIR / selected[0]).read_bytes()
        except OSError:
            self._error(500)
            return
        self._send(200, selected[1], payload)

    def do_HEAD(self) -> None:  # noqa: N802
        self._error(405)

    def _error(self, status: int) -> None:
        payload = f"HTTP {status}\n".encode("ascii")
        self._send(status, "text/plain; charset=utf-8", payload)

    def _send(self, status: int, content_type: str, payload: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self'; script-src 'self'; "
            "style-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'",
        )
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def log_message(self, format_string: str, *args) -> None:  # noqa: A002, ANN002
        return


class MonitorServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Controller:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.runtime_dir = Path(args.runtime_dir).expanduser().resolve()
        self.status_path = self.runtime_dir / "status.json"
        self.marker_path = self.runtime_dir / "cleanup-authorized.json"
        self.status_lock = threading.RLock()
        self.status_persist_enabled = True
        self.stop_requested = threading.Event()
        self.process: Optional[subprocess.Popen[str]] = None
        self.stop_guard_lock = threading.Lock()
        self.stop_guard_thread: Optional[threading.Thread] = None
        self.controller_done = threading.Event()
        self.monitor: Optional[MonitorServer] = None
        self.monitor_thread: Optional[threading.Thread] = None
        self.progress_watchdog_condition = threading.Condition()
        self.progress_watchdog_deadline: Optional[float] = None
        self.progress_watchdog_phase: Optional[str] = None
        self.progress_watchdog_error: Optional[str] = None
        self.progress_watchdog_closed = False
        self.progress_watchdog_thread: Optional[threading.Thread] = None
        self.key = require_aes_key()
        endpoint = args.upload_endpoint or DEFAULT_UPLOAD_ENDPOINT
        self.backup_enabled = parse_bool(os.environ.get("TRX_BACKUP_ENABLED"), True)
        if not self.backup_enabled:
            raise ControllerError("AES encrypted upload must remain enabled for this workflow")
        timeout = parse_positive_int(os.environ.get("TRX_HTTP_TIMEOUT"), 20, "TRX_HTTP_TIMEOUT")
        attempts = parse_positive_int(
            os.environ.get("TRX_UPLOAD_ATTEMPTS"), 5, "TRX_UPLOAD_ATTEMPTS"
        )
        self.remote = RemoteBackup(endpoint, timeout, attempts)
        self.heartbeat = HeartbeatClient(self.remote.heartbeat_endpoint, self)
        self.aes = OpenSslEvp()
        self.exit_code = 1
        self.started_search = False
        self.received_result = False
        self.cleanup_handoff_started = False
        self.status: Dict[str, Any] = {
            "version": 1,
            "updated_at": utc_now(),
            "state": "starting",
            "heartbeat_state": "starting",
            "detail": "controller is starting",
            "suffix": args.suffix,
            "run_attempt_offset": 0,
            "run_elapsed_offset_seconds": 0.0,
            "attempts": 0,
            "speed": 0.0,
            "elapsed_seconds": 0.0,
            "engine_device": "",
            "engine_profile": args.profile,
            "engine_batch_capacity": 0,
            "engine_cpu_workers": 0,
            "engine_batch_size": 0,
            "engine_cuda_master_block_size": 0,
            "engine_cuda_address_block_size": 0,
            "engine_kernel_mode": "",
            "engine_cpu_budget": 0,
            "engine_cpu_budget_source": "",
            "result_address": "",
            "backup_enabled": True,
            "backup_state": "waiting",
            "backup_verified": False,
            "backup_file": "",
            "backup_sha256": "",
            "upload_origin": self.remote.public_origin,
            "heartbeat_ok": False,
            "heartbeat_at": "",
            "heartbeat_notifications": 0,
            "cleanup_authorized": False,
            "cleanup_started": False,
            "monitor_refresh_seconds": 2,
            "monitor_host": "",
            "monitor_port": 0,
        }
        try:
            previous = json.loads(self.status_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            previous = {}
        if (
            isinstance(previous, dict)
            and previous.get("suffix") == args.suffix
            and previous.get("state") in {
                "starting",
                "ready",
                "searching",
                "stopping",
                "error",
            }
        ):
            previous_attempts = previous.get("attempts")
            previous_elapsed = previous.get("elapsed_seconds")
            if (
                isinstance(previous_attempts, int)
                and not isinstance(previous_attempts, bool)
                and 0 <= previous_attempts <= 0xFFFFFFFFFFFFFFFF
            ):
                self.status["run_attempt_offset"] = previous_attempts
                self.status["attempts"] = previous_attempts
            if (
                isinstance(previous_elapsed, (int, float))
                and not isinstance(previous_elapsed, bool)
                and math.isfinite(float(previous_elapsed))
                and 0.0 <= float(previous_elapsed) <= 1.0e20
            ):
                self.status["run_elapsed_offset_seconds"] = float(previous_elapsed)
                self.status["elapsed_seconds"] = float(previous_elapsed)
        self._write_status_locked()

    def public_status(self) -> Dict[str, Any]:
        with self.status_lock:
            return copy.deepcopy(self.status)

    def update(self, **changes: Any) -> None:
        with self.status_lock:
            unknown = set(changes).difference(self.status)
            if unknown:
                raise ControllerError(
                    "attempted to add an unapproved public status field: "
                    + ", ".join(sorted(unknown))
                )
            self.status.update(changes)
            self.status["updated_at"] = utc_now()
            self._write_status_locked()

    def record_heartbeat_response(self, notifications: int) -> None:
        """Atomically retain the strongest notification evidence for this run."""
        with self.status_lock:
            self.status["heartbeat_ok"] = True
            self.status["heartbeat_at"] = utc_now()
            self.status["heartbeat_notifications"] = max(
                int(self.status["heartbeat_notifications"]),
                max(0, notifications),
            )
            self.status["updated_at"] = utc_now()
            self._write_status_locked()

    def _write_status_locked(self) -> None:
        serialized = json.dumps(self.status, ensure_ascii=False).lower()
        key_hex = self.key.hex() if hasattr(self, "key") else ""
        if key_hex and key_hex in serialized:
            raise ControllerError("secret-data guard rejected the status document")
        if self.status_persist_enabled:
            atomic_json(self.status_path, self.status, 0o600)

    def start_monitor(self) -> None:
        if self.args.no_http:
            return
        try:
            self.monitor = MonitorServer(
                (self.args.http_host, self.args.http_port), MonitorHandler
            )
        except OSError as error:
            raise ControllerError("could not bind the local monitor address") from error
        self.monitor.controller = self  # type: ignore[attr-defined]
        self.monitor_thread = threading.Thread(
            target=self.monitor.serve_forever,
            name="local-monitor",
            daemon=True,
        )
        self.monitor_thread.start()
        bound_host, bound_port = self.monitor.server_address[:2]
        self.update(monitor_host=str(bound_host), monitor_port=int(bound_port))
        print(f"Local monitor: http://{bound_host}:{bound_port}/", flush=True)

    def stop_monitor(self) -> None:
        if self.monitor:
            self.monitor.shutdown()
            self.monitor.server_close()
        if self.monitor_thread:
            self.monitor_thread.join(timeout=2.0)
        self.monitor = None
        self.monitor_thread = None

    def request_stop(self, signum: int = 0, frame=None) -> None:  # noqa: ANN001
        if self.stop_requested.is_set():
            # A second operator signal is an explicit escalation.  Only touch
            # the exact child recorded by this Controller instance.
            self._kill_engine_now()
            return
        self.stop_requested.set()
        self.exit_code = 130
        self._disarm_progress_watchdog()
        self.update(state="stopping", detail="stop requested")
        self.send_engine("STOP")
        self._schedule_stop_guard()

    def _terminate_engine_now(self) -> None:
        process = self.process
        if process is None or process.poll() is not None:
            return
        try:
            process.terminate()
        except (ProcessLookupError, OSError):
            pass

    def _kill_engine_now(self) -> None:
        process = self.process
        if process is None or process.poll() is not None:
            return
        try:
            process.kill()
        except (ProcessLookupError, OSError):
            pass

    def _schedule_stop_guard(self) -> None:
        with self.stop_guard_lock:
            thread = self.stop_guard_thread
            if thread is not None and thread.is_alive():
                return
            self.stop_guard_thread = threading.Thread(
                target=self._stop_engine_after_grace,
                name="engine-stop-guard",
                daemon=True,
            )
            self.stop_guard_thread.start()

    def _stop_engine_after_grace(self) -> None:
        # A signal can arrive after run()'s pre-spawn check but before Popen is
        # published.  Wait until that exact child appears or run() is done;
        # there is deliberately no publication-timeout gap in which a late
        # child could escape the stop guard.
        process: Optional[subprocess.Popen[str]] = None
        while process is None:
            process = self.process
            if process is None and self.controller_done.wait(0.01):
                return
        if process.poll() is not None:
            return
        self.send_engine("STOP")
        try:
            process.wait(timeout=ENGINE_STOP_GRACE_SECONDS)
            return
        except subprocess.TimeoutExpired:
            pass
        except (ProcessLookupError, OSError):
            return
        try:
            process.terminate()
            process.wait(timeout=ENGINE_WATCHDOG_TERMINATE_GRACE_SECONDS)
            return
        except subprocess.TimeoutExpired:
            pass
        except (ProcessLookupError, OSError):
            return
        try:
            process.kill()
        except (ProcessLookupError, OSError):
            pass

    def send_engine(self, command: str) -> None:
        process = self.process
        if process is None or process.poll() is not None or process.stdin is None:
            return
        try:
            process.stdin.write(command + "\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def _drain_stderr(self) -> None:
        process = self.process
        if process is None or process.stderr is None:
            return
        for _line in process.stderr:
            # Engine stderr is intentionally consumed but never persisted: a
            # future engine must not accidentally leak result material here.
            pass

    @staticmethod
    def _progress_watchdog_detail() -> str:
        return (
            "GPU engine emitted no search progress for "
            f"{int(ENGINE_PROGRESS_TIMEOUT_SECONDS)} seconds; "
            "restarting the stalled search"
        )

    @staticmethod
    def _startup_watchdog_detail() -> str:
        return (
            "GPU engine did not begin reporting valid search progress within "
            f"{int(ENGINE_STARTUP_TIMEOUT_SECONDS)} seconds; "
            "restarting the stalled initialization"
        )

    def _start_progress_watchdog(self) -> None:
        if self.progress_watchdog_thread is not None:
            return
        self.progress_watchdog_thread = threading.Thread(
            target=self._progress_watchdog_loop,
            name="engine-progress-watchdog",
            daemon=True,
        )
        self.progress_watchdog_thread.start()

    def _arm_progress_watchdog(self) -> None:
        self._arm_watchdog("searching", ENGINE_PROGRESS_TIMEOUT_SECONDS)

    def _arm_startup_watchdog(self) -> None:
        self._arm_watchdog("startup", ENGINE_STARTUP_TIMEOUT_SECONDS)

    def _arm_watchdog(self, phase: str, timeout: float) -> None:
        with self.progress_watchdog_condition:
            if self.progress_watchdog_closed or self.progress_watchdog_error:
                return
            self.progress_watchdog_phase = phase
            self.progress_watchdog_deadline = time.monotonic() + timeout
            self.progress_watchdog_condition.notify_all()

    def _disarm_progress_watchdog(self) -> None:
        with self.progress_watchdog_condition:
            self.progress_watchdog_deadline = None
            self.progress_watchdog_phase = None
            self.progress_watchdog_condition.notify_all()

    def _stop_progress_watchdog(self) -> None:
        with self.progress_watchdog_condition:
            self.progress_watchdog_closed = True
            self.progress_watchdog_deadline = None
            self.progress_watchdog_phase = None
            self.progress_watchdog_condition.notify_all()
        thread = self.progress_watchdog_thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)
        self.progress_watchdog_thread = None

    def _progress_watchdog_loop(self) -> None:
        while True:
            with self.progress_watchdog_condition:
                while (
                    not self.progress_watchdog_closed
                    and self.progress_watchdog_deadline is None
                ):
                    self.progress_watchdog_condition.wait()
                if self.progress_watchdog_closed:
                    return
                assert self.progress_watchdog_deadline is not None
                remaining = self.progress_watchdog_deadline - time.monotonic()
                if remaining > 0.0:
                    self.progress_watchdog_condition.wait(timeout=remaining)
                    continue
                if (
                    self.stop_requested.is_set()
                    or self.received_result
                    or self.cleanup_handoff_started
                ):
                    self.progress_watchdog_deadline = None
                    self.progress_watchdog_phase = None
                    continue
                process = self.process
                if process is None or process.poll() is not None:
                    self.progress_watchdog_deadline = None
                    self.progress_watchdog_phase = None
                    continue
                detail = (
                    self._startup_watchdog_detail()
                    if self.progress_watchdog_phase == "startup"
                    else self._progress_watchdog_detail()
                )
                self.progress_watchdog_error = detail
                self.progress_watchdog_deadline = None
                self.progress_watchdog_phase = None

            # Persist the reason before terminating only this controller's
            # Popen child.  Never depend on process-name matching here: another
            # authorized benchmark may be running on the same host.
            try:
                self.update(
                    state="error",
                    heartbeat_state="error",
                    detail=detail,
                )
            except ControllerError:
                # The main controller thread raises the same reason after the
                # child exits, while termination must still proceed if status
                # persistence itself failed.
                pass
            try:
                process.terminate()
                process.wait(timeout=ENGINE_WATCHDOG_TERMINATE_GRACE_SECONDS)
            except ProcessLookupError:
                pass
            except subprocess.TimeoutExpired:
                process.kill()
            except OSError:
                pass
            return

    def start_engine(self) -> None:
        engine = Path(self.args.engine).expanduser().resolve()
        if not engine.is_file() or not os.access(engine, os.X_OK):
            raise ControllerError(f"engine is missing or not executable: {engine}")
        metadata = engine.stat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o022
        ):
            raise ControllerError("engine path, link count, or permissions are unsafe")
        if is_formal_run(self.args):
            if engine != DEFAULT_ENGINE.resolve() or metadata.st_uid != 0:
                raise ControllerError(
                    "formal search must use the fixed root-owned Linux GPU engine"
                )
        command = [str(engine), "--server", "--profile", self.args.profile]
        for option, value in (
            ("--batch-size", self.args.batch_size),
            ("--cpu-workers", self.args.cpu_workers),
            ("--cuda-block-size", self.args.cuda_block_size),
        ):
            if value is not None:
                command.extend((option, str(value)))
        try:
            self.process = subprocess.Popen(
                command,
                cwd=str(APP_DIR),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
        except OSError as error:
            raise ControllerError("could not start the Linux GPU engine") from error
        if self.stop_requested.is_set():
            # Close the signal/Popen publication race.  request_stop() may have
            # run while self.process was still None.
            self.exit_code = 130
            self.send_engine("STOP")
            self._schedule_stop_guard()
        threading.Thread(target=self._drain_stderr, name="engine-stderr", daemon=True).start()

    def _handle_ready(self, fields: Sequence[str]) -> bool:
        self.update(
            state="ready",
            heartbeat_state="ready",
            detail="GPU and CPU engine ready",
            **parse_engine_ready_status(fields, self.args.profile),
        )
        if self.stop_requested.is_set():
            self.exit_code = 130
            self.send_engine("EXIT")
            return False
        if not self.started_search:
            self.started_search = True
            self.send_engine(f"START\t\t{self.args.suffix}")
            # A signal handler can run between the first stop check and START.
            # In that ordering, put a final STOP after START and leave the read
            # loop so finally also closes the engine. STOP-before-START alone is
            # intentionally restartable in the engine protocol.
            if self.stop_requested.is_set():
                self.exit_code = 130
                self.send_engine("STOP")
                return False
        return True

    def run(self) -> int:
        try:
            self.start_monitor()
            self.heartbeat.start()
            try:
                self.heartbeat.send(state_override="starting")
            except ControllerError:
                self.update(heartbeat_ok=False, heartbeat_at=utc_now())
            self._start_progress_watchdog()
            self._arm_startup_watchdog()
            if self.stop_requested.is_set():
                self.exit_code = 130
                return 130
            self.start_engine()
            assert self.process.stdout is not None
            for raw_line in self.process.stdout:
                line = raw_line.rstrip("\r\n")
                if not line:
                    continue
                fields = line.split("\t")
                kind = fields[0]
                if kind == "INIT":
                    detail = fields[2][:300] if len(fields) >= 3 else "engine initialization"
                    self.update(state="starting", heartbeat_state="starting", detail=detail)
                elif kind == "READY":
                    if not self._handle_ready(fields):
                        break
                elif kind == "SEARCHING":
                    self._arm_progress_watchdog()
                    self.update(
                        state="searching",
                        heartbeat_state="searching",
                        detail="GPU and CPU parallel search is running",
                    )
                    try:
                        self.heartbeat.send(
                            event="search_started",
                            event_detail=f"search started for suffix {self.args.suffix}",
                            state_override="searching",
                        )
                    except ControllerError:
                        self.update(heartbeat_ok=False, heartbeat_at=utc_now())
                elif kind == "PROGRESS":
                    if self._handle_progress(fields):
                        self._arm_progress_watchdog()
                elif kind == "RESULT":
                    self.received_result = True
                    self._disarm_progress_watchdog()
                    self.exit_code = self._handle_result(fields)
                    break
                elif kind == "STOPPED":
                    self._disarm_progress_watchdog()
                    if self.stop_requested.is_set():
                        self.exit_code = 130
                        break
                    self.update(
                        state="ready",
                        heartbeat_state="ready",
                        detail="search stopped without a result",
                    )
                elif kind == "ERROR":
                    self._disarm_progress_watchdog()
                    detail = fields[1][:500] if len(fields) >= 2 else "unknown engine error"
                    raise ControllerError(f"GPU engine error: {detail}")
            if self.progress_watchdog_error:
                raise ControllerError(self.progress_watchdog_error)
            if not self.received_result and not self.stop_requested.is_set():
                return_code = self.process.poll()
                raise ControllerError(f"GPU engine exited before a result (code {return_code})")
            return self.exit_code
        except BackupError as error:
            self._backup_failure(str(error))
            return 3
        except ControllerError as error:
            if self.stop_requested.is_set():
                self.exit_code = 130
                return 130
            if not self.cleanup_handoff_started:
                self.update(state="error", heartbeat_state="error", detail=str(error)[:800])
                try:
                    self.heartbeat.send(
                        event="engine_exit",
                        event_detail=str(error)[:800],
                        state_override="error",
                    )
                except ControllerError:
                    pass
            else:
                print(f"Controller error after cleanup handoff: {error}", file=sys.stderr)
            return 2
        finally:
            self.controller_done.set()
            self._stop_progress_watchdog()
            self.send_engine("EXIT")
            if self.process:
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
            self.heartbeat.stop()
            if not self.cleanup_handoff_started:
                try:
                    self.heartbeat.send(
                        event_detail=(
                            "controller exited normally"
                            if self.exit_code == 0
                            else "controller stopped"
                        ),
                        state_override="closing",
                    )
                except ControllerError:
                    pass
            self.stop_monitor()
            wipe(self.key)

    def _handle_progress(self, fields) -> bool:  # noqa: ANN001
        if len(fields) < 4:
            return False
        if 4 < len(fields) < 7:
            return False
        if not re.fullmatch(r"[0-9]{1,20}", fields[1]):
            return False
        try:
            attempts = int(fields[1], 10)
            speed = float(fields[2])
            elapsed = float(fields[3])
        except ValueError:
            return False
        if (
            attempts > 0xFFFFFFFFFFFFFFFF
            or not math.isfinite(speed)
            or not math.isfinite(elapsed)
            or speed < 0.0
            or elapsed < 0.0
        ):
            return False

        changes: Dict[str, Any] = {
            "state": "searching",
            "heartbeat_state": "searching",
            "detail": "GPU and CPU parallel search is running",
            "attempts": min(
                0xFFFFFFFFFFFFFFFF,
                int(self.public_status().get("run_attempt_offset", 0)) + attempts,
            ),
            "speed": speed,
            "elapsed_seconds": (
                float(self.public_status().get("run_elapsed_offset_seconds", 0.0))
                + elapsed
            ),
        }
        if len(fields) >= 7:
            batch_size = _ready_uint(
                fields, 6, minimum=128, maximum=0xFFFFFFFF, multiple=128
            )
            capacity = int(self.public_status().get("engine_batch_capacity", 0))
            if batch_size == 0 or (capacity > 0 and batch_size > capacity):
                return False
            changes["engine_batch_size"] = batch_size
        self.update(**changes)
        return True

    def _handle_result(self, fields) -> int:  # noqa: ANN001
        if len(fields) < 6:
            raise ControllerError("engine returned an incomplete result")
        address = fields[1]
        mnemonic = fields[2]
        if (
            not re.fullmatch(r"T[1-9A-HJ-NP-Za-km-z]{33}", address)
            or not address.endswith(self.args.suffix)
        ):
            raise ControllerError("engine result did not match the requested suffix")
        if not re.fullmatch(r"[a-z]+(?: [a-z]+){11}", mnemonic):
            raise ControllerError("engine result did not contain a valid 12-word mnemonic")
        try:
            attempts = int(fields[3], 10)
            elapsed = float(fields[4])
        except ValueError as error:
            raise ControllerError("engine result counters were invalid") from error
        if (
            attempts < 0
            or attempts > 0xFFFFFFFFFFFFFFFF
            or not math.isfinite(elapsed)
            or elapsed < 0.0
        ):
            raise ControllerError("engine result counters were invalid")
        created_utc = utc_now()
        record = {
            "format": "trx-vanity-mnemonic-backup",
            "address": address,
            "mnemonic": mnemonic,
            "derivationPath": DERIVATION_PATH,
            "createdUtc": created_utc,
            "prefix": "",
            "suffix": self.args.suffix,
        }
        self.update(
            state="verifying",
            heartbeat_state="searching",
            detail="result found; encrypting and verifying remote backup",
            attempts=min(
                0xFFFFFFFFFFFFFFFF,
                int(self.public_status().get("run_attempt_offset", 0)) + attempts,
            ),
            elapsed_seconds=(
                float(self.public_status().get("run_elapsed_offset_seconds", 0.0))
                + elapsed
            ),
            result_address=address,
            backup_state="encrypting",
        )
        envelope = encrypt_backup(record, self.key, self.aes)
        envelope_digest = hashlib.sha256(envelope).digest()
        digest_text = envelope_digest.hex()
        formal_retry = is_formal_run(self.args)
        filename = ""
        retry_number = 0
        while True:
            try:
                if not filename:
                    self.update(backup_state="uploading", backup_sha256=digest_text)
                    filename = self.remote.upload(envelope)
                self.update(backup_state="downloading", backup_file=filename)
                downloaded = self.remote.download(filename)
                if not hmac.compare_digest(
                    hashlib.sha256(downloaded).digest(), envelope_digest
                ):
                    filename = ""
                    self.update(backup_file="")
                    raise BackupError(
                        "downloaded ciphertext hash did not match the uploaded bytes"
                    )
                self.update(backup_state="decrypting")
                try:
                    decoded = decrypt_backup(downloaded, self.key, self.aes)
                except BackupError:
                    filename = ""
                    self.update(backup_file="")
                    raise
                for field, expected in record.items():
                    actual = decoded.get(field)
                    if not isinstance(actual, str) or not hmac.compare_digest(
                        actual, expected
                    ):
                        filename = ""
                        self.update(backup_file="")
                        raise BackupError(
                            "downloaded backup fields did not match the in-memory result"
                        )
                self.update(
                    state="result",
                    heartbeat_state="result",
                    detail=(
                        "encrypted backup uploaded, downloaded, authenticated, "
                        "and decrypted successfully"
                    ),
                    backup_state="verified",
                    backup_verified=True,
                )
                response = self.heartbeat.send(
                    event="result",
                    event_detail="result backup round-trip verified",
                    address=address,
                    state_override="result",
                )
                notifications = max(0, int(response.get("notifications", 0)))
                if notifications < 1:
                    raise BackupError(
                        "server did not report a successful result email notification"
                    )
                break
            except ControllerError as error:
                if not formal_retry:
                    raise
                retry_number += 1
                self._backup_failure(
                    "verified formal result retained in protected process memory; "
                    f"remote verification or notification attempt {retry_number} failed: {error}"
                )
                if self.stop_requested.wait(60.0):
                    raise ControllerError(
                        "operator stopped while a verified result was awaiting remote confirmation"
                    ) from error
                self.update(
                    state="verifying",
                    heartbeat_state="searching",
                    detail=(
                        "verified result remains in protected process memory; "
                        "retrying remote backup and email confirmation"
                    ),
                    backup_state="downloading" if filename else "uploading",
                    backup_verified=False,
                )
        if self._should_cleanup():
            if not self._authorize_and_start_cleanup(filename):
                return 4
        return 0

    def _backup_failure(self, detail: str) -> None:
        self.update(
            state="error",
            heartbeat_state="error",
            detail=detail[:800],
            backup_state="failed",
            backup_verified=False,
        )
        address = str(self.public_status().get("result_address", ""))
        try:
            self.heartbeat.send(
                event="backup_error",
                event_detail=detail[:800],
                address=address,
                state_override="error",
            )
        except ControllerError:
            pass

    def _should_cleanup(self) -> bool:
        return is_formal_run(self.args) and not self.args.no_cleanup

    def _authorize_and_start_cleanup(self, filename: str) -> bool:
        work_dir = self.runtime_dir.resolve()
        marker: Dict[str, Any] = {
            "version": 1,
            "authorized": True,
            "reason": "verified_upload_roundtrip",
            "job_id": str(uuid.uuid4()),
            "verified_at": utc_now(),
            "work_dir": str(work_dir),
            "filesystem_device": int(os.stat(work_dir).st_dev),
            "backup_file": filename,
            "marker_nonce": secrets.token_hex(32),
            "target_suffix": self.args.suffix,
            "verification": {
                "upload_success": True,
                "download_hash_match": True,
                "decrypt_match": True,
            },
        }
        canonical = json.dumps(
            marker, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        marker["marker_hmac"] = hmac.new(self.key, canonical, hashlib.sha256).hexdigest()
        atomic_json(self.marker_path, marker, 0o600)
        self.update(
            state="cleanup_launching",
            heartbeat_state="result",
            detail="verified result authorized; validating constrained secure cleanup",
            cleanup_authorized=True,
        )
        cleanup_script = Path(self.args.cleanup_script).expanduser().resolve()
        if not cleanup_script.is_file():
            raise ControllerError("verified cleanup marker written, but cleanup script is missing")
        try:
            cleanup_metadata = cleanup_script.lstat()
        except OSError as error:
            raise ControllerError("verified cleanup marker written, but cleanup script is unreadable") from error
        if (
            cleanup_script != APP_DIR / "secure_cleanup.sh"
            or not stat.S_ISREG(cleanup_metadata.st_mode)
            or cleanup_metadata.st_uid != 0
            or cleanup_metadata.st_mode & 0o022
        ):
            raise ControllerError("formal cleanup wrapper path, owner, or permissions are unsafe")

        # Verify every fixed-path, mount, ownership, marker-HMAC and tree
        # invariant before the controller stops its monitor and permanently
        # hands control to the destructive cleanup process.  The wrapper keeps
        # the volatile key file during this dry run.
        try:
            preflight = subprocess.run(
                ["/bin/bash", str(cleanup_script), "--passes", "5"],
                cwd=str(APP_DIR),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=120,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ControllerError("secure cleanup preflight could not run") from error
        if preflight.returncode != 0:
            detail = (preflight.stderr or preflight.stdout).strip()[:500]
            raise ControllerError(
                "secure cleanup preflight refused the handoff"
                + (f": {detail}" if detail else "")
            )

        self.update(
            detail="secure cleanup preflight passed; handing off five overwrite passes",
            cleanup_started=True,
        )

        try:
            cleanup_status_metadata = CLEANUP_STATUS_PATH.lstat()
        except FileNotFoundError:
            pass
        else:
            if (
                stat.S_ISLNK(cleanup_status_metadata.st_mode)
                or not stat.S_ISREG(cleanup_status_metadata.st_mode)
                or cleanup_status_metadata.st_uid != 0
            ):
                raise ControllerError("existing cleanup status path is unsafe")
            CLEANUP_STATUS_PATH.unlink()

        # From this point onward no controller thread may recreate a runtime
        # file after cleanup removes it.  The already-sent result heartbeat is
        # the final external event; monitoring intentionally goes offline.
        self.cleanup_handoff_started = True
        with self.status_lock:
            self.status_persist_enabled = False
        self.heartbeat.stop()
        self.stop_monitor()

        # Keep the same PID as the formal service and replace the entire
        # controller address space with the cleanup program.  This has three
        # important properties: screen observes the real exit status
        # only after runtime-file overwrite finishes, no detached child can be
        # orphaned, and Python objects that held the mnemonic are not kept
        # alive after the handoff.
        self.send_engine("EXIT")
        if self.process:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        wipe(self.key)
        sys.stdout.flush()
        sys.stderr.flush()
        command = [
            "/bin/bash",
            str(cleanup_script),
            "--execute",
            "--passes",
            "5",
        ]
        try:
            os.execv(command[0], command)
        except OSError as error:
            # Do not re-enable persistence or recreate runtime files here: the
            # controller has already completed the one-way secure handoff.
            print(
                f"verified cleanup handoff could not exec: {error}",
                file=sys.stderr,
                flush=True,
            )
            return False
        return False  # os.execv never returns on success


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="TRX Vanity Linux engine controller and local status monitor"
    )
    parser.add_argument(
        "--env-file",
        help=(
            "optional owner-only environment file "
            "(formal path: /dev/shm/trxvanity-secrets.env)"
        ),
    )
    subparsers = parser.add_subparsers(dest="mode", required=True)

    def common(subparser: argparse.ArgumentParser, suffix: str) -> None:
        subparser.add_argument("--suffix", default=suffix)
        subparser.add_argument(
            "--engine", default=os.environ.get("TRX_ENGINE_PATH", str(DEFAULT_ENGINE))
        )
        subparser.add_argument("--profile", default=os.environ.get("TRX_ENGINE_PROFILE", "smart"))
        subparser.add_argument("--batch-size", type=int)
        subparser.add_argument("--cpu-workers", type=int)
        subparser.add_argument("--cuda-block-size", type=int)
        subparser.add_argument(
            "--runtime-dir", default=os.environ.get("TRX_RUNTIME_DIR", str(APP_DIR / "runtime"))
        )
        subparser.add_argument(
            "--upload-endpoint", default=os.environ.get("TRX_UPLOAD_ENDPOINT")
        )
        subparser.add_argument(
            "--http-host", default=os.environ.get("TRX_MONITOR_HOST", "127.0.0.1")
        )
        subparser.add_argument(
            "--http-port", type=int, default=int(os.environ.get("TRX_MONITOR_PORT", "8787"))
        )
        subparser.add_argument("--no-http", action="store_true")
        subparser.add_argument(
            "--cleanup-script",
            default=os.environ.get("TRX_CLEANUP_SCRIPT", str(APP_DIR / "secure_cleanup.sh")),
        )

    run_parser = subparsers.add_parser("run", help="run the formal or specified search")
    common(run_parser, FORMAL_SUFFIX)
    run_parser.add_argument(
        "--no-cleanup",
        action="store_true",
        help="operator recovery switch; formal suffix normally starts verified cleanup automatically",
    )
    run_parser.set_defaults(no_cleanup=False)
    return parser


def validate_args(args: argparse.Namespace) -> None:
    if not BASE58_PATTERN.fullmatch(args.suffix):
        raise ControllerError("suffix must contain 1 to 10 TRON Base58 characters")
    configured_suffix = load_formal_suffix()
    if args.mode == "run" and args.suffix == configured_suffix:
        try:
            formal_install_root = FORMAL_INSTALL_ROOT.resolve(strict=True)
        except OSError as error:
            raise ControllerError(
                "formal shared runtime is unavailable at "
                "/root/autodl-fs/TRXVanityLinux"
            ) from error
        if APP_DIR != formal_install_root:
            raise ControllerError(
                "formal search must run from /root/autodl-fs/TRXVanityLinux"
            )
        if Path(args.runtime_dir).expanduser().resolve() != FORMAL_RUNTIME_DIR:
            raise ControllerError(
                "formal search runtime must be /root/autodl-tmp/TRXVanityLinux/runtime"
            )
        if Path(args.cleanup_script).expanduser().resolve() != APP_DIR / "secure_cleanup.sh":
            raise ControllerError("formal search must use the fixed secure_cleanup.sh wrapper")
        if not args.env_file or Path(args.env_file).expanduser() != VOLATILE_SECRETS_PATH:
            raise ControllerError(
                "formal search must load /dev/shm/trxvanity-secrets.env"
            )
        if args.no_cleanup:
            raise ControllerError("formal search may not disable verified cleanup")
        if args.no_http or args.http_host != "127.0.0.1" or args.http_port != 8787:
            raise ControllerError(
                "formal search monitor must remain on 127.0.0.1:8787"
            )
        if not args.upload_endpoint:
            raise ControllerError(
                "formal search must load TRX_UPLOAD_ENDPOINT from the volatile secrets file"
            )
        validate_upload_endpoint(args.upload_endpoint)
        if args.profile != "smart":
            raise ControllerError("formal RTX 5090 search must use the validated smart profile")
        if any(
            value is not None
            for value in (args.batch_size, args.cpu_workers, args.cuda_block_size)
        ):
            raise ControllerError(
                "formal search must use the validated automatic batch, CPU, and CUDA settings"
            )
    if args.profile not in {"smart", "rtx5070", "rtx4090"}:
        raise ControllerError("profile must be smart, rtx5070, or rtx4090")
    if not 0 <= args.http_port <= 65535:
        raise ControllerError("HTTP monitor port must be between 0 and 65535")
    if args.http_host not in {"127.0.0.1", "::1", "localhost"}:
        raise ControllerError("HTTP monitor must listen on a loopback address")
    for name in ("batch_size", "cuda_block_size"):
        value = getattr(args, name)
        if value is not None and value <= 0:
            raise ControllerError(f"--{name.replace('_', '-')} must be positive")
    if args.cpu_workers is not None and not 0 <= args.cpu_workers <= 256:
        raise ControllerError("--cpu-workers must be between 0 and 256")


def main(argv=None) -> int:  # noqa: ANN001
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        harden_process()
        load_env_file(args.env_file)
        # Environment-file values are intentionally resolved after argparse.
        if not args.upload_endpoint:
            args.upload_endpoint = os.environ.get("TRX_UPLOAD_ENDPOINT")
        validate_args(args)
        acquire_instance_lock()
        controller = Controller(args)
        signal.signal(signal.SIGINT, controller.request_stop)
        signal.signal(signal.SIGTERM, controller.request_stop)
        return controller.run()
    except ControllerError as error:
        print(f"Controller error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
