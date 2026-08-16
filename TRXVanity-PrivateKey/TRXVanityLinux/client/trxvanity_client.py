#!/usr/bin/env python3
"""Cross-platform split-key client for TRX Vanity Linux."""

from __future__ import annotations

import argparse
import hashlib
import math
import os
import stat
import sys
from pathlib import Path

BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
SECP256K1_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
SECP256K1_GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
SECP256K1_GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
SECRET_HEADER = "TRXVANITY-SPLIT-SECRET-V1"
REQUEST_HEADER = "TRXVANITY-SPLIT-REQUEST-V1"
WALLET_HEADER = "TRXVANITY-WALLET-V1"
IS_WINDOWS = os.name == "nt"


def wipe(buffer: bytearray) -> None:
    for index in range(len(buffer)):
        buffer[index] = 0


def hex_upper(data: bytes | bytearray) -> str:
    return data.hex().upper()


def parse_hex_exact(value: str, size: int) -> bytearray:
    if len(value) != size * 2:
        raise ValueError("Unexpected hexadecimal field length.")
    try:
        parsed = bytearray.fromhex(value)
    except ValueError as exc:
        raise ValueError("A hexadecimal field contains an invalid character.") from exc
    if len(parsed) != size:
        wipe(parsed)
        raise ValueError("Unexpected hexadecimal field length.")
    return parsed


def sha256(data: bytes | bytearray) -> bytes:
    return hashlib.sha256(data).digest()


def _rotate_left(value: int, count: int) -> int:
    return ((value << count) | (value >> (64 - count))) & 0xFFFFFFFFFFFFFFFF


def keccak256(data: bytes | bytearray) -> bytes:
    rate = 136
    state = [0] * 25
    offset = 0
    while len(data) - offset >= rate:
        for lane in range(rate // 8):
            word = int.from_bytes(data[offset + lane * 8 : offset + lane * 8 + 8], "little")
            state[lane] ^= word
        _keccak_permute(state)
        offset += rate
    remaining = data[offset:]
    block = bytearray(rate)
    block[: len(remaining)] = remaining
    block[len(remaining)] ^= 0x01
    block[rate - 1] ^= 0x80
    for lane in range(rate // 8):
        word = int.from_bytes(block[lane * 8 : lane * 8 + 8], "little")
        state[lane] ^= word
    _keccak_permute(state)
    return b"".join(state[index].to_bytes(8, "little") for index in range(4))


def _keccak_permute(state: list[int]) -> None:
    round_constants = (
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    )
    rotation_offsets = (
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8,
        25, 43, 62, 18, 39, 61, 20, 44,
    )
    pi_destinations = (
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13,
        12, 2, 20, 14, 22, 9, 6, 1,
    )
    for constant in round_constants:
        c = [
            state[column] ^ state[column + 5] ^ state[column + 10]
            ^ state[column + 15] ^ state[column + 20]
            for column in range(5)
        ]
        d = [c[(column + 4) % 5] ^ _rotate_left(c[(column + 1) % 5], 1) for column in range(5)]
        for index in range(25):
            state[index] ^= d[index % 5]
        carried = state[1]
        for index, destination in enumerate(pi_destinations):
            displaced = state[destination]
            state[destination] = _rotate_left(carried, rotation_offsets[index])
            carried = displaced
        for row in range(0, 25, 5):
            a0, a1, a2, a3, a4 = state[row : row + 5]
            state[row] = a0 ^ ((~a1) & a2)
            state[row + 1] = a1 ^ ((~a2) & a3)
            state[row + 2] = a2 ^ ((~a3) & a4)
            state[row + 3] = a3 ^ ((~a4) & a0)
            state[row + 4] = a4 ^ ((~a0) & a1)
        state[0] ^= constant


def base58_encode(data: bytes | bytearray) -> str:
    zero_count = 0
    while zero_count < len(data) and data[zero_count] == 0:
        zero_count += 1
    number = int.from_bytes(data, "big")
    encoded = ""
    while number:
        number, remainder = divmod(number, 58)
        encoded = BASE58_ALPHABET[remainder] + encoded
    return ("1" * zero_count) + encoded


def base58_digit(value: str) -> int:
    if len(value) != 1:
        return -1
    character = value[0]
    if "1" <= character <= "9":
        return ord(character) - ord("1")
    if "A" <= character <= "H":
        return ord(character) - ord("A") + 9
    if "J" <= character <= "N":
        return ord(character) - ord("J") + 17
    if "P" <= character <= "Z":
        return ord(character) - ord("P") + 22
    if "a" <= character <= "k":
        return ord(character) - ord("a") + 33
    if "m" <= character <= "z":
        return ord(character) - ord("m") + 44
    return -1


def validate_suffix(suffix: str) -> None:
    if not suffix or len(suffix) > 10:
        raise ValueError("The suffix must contain 1 to 10 TRON Base58 characters.")
    for character in suffix:
        if base58_digit(character) < 0:
            raise ValueError("The suffix must contain 1 to 10 TRON Base58 characters.")


def matches_suffix(address: str, suffix: str) -> bool:
    return bool(suffix) and address.endswith(suffix)


def _mod_inverse(value: int, modulus: int) -> int:
    return pow(value, -1, modulus)


def _point_add(
    left: tuple[int, int] | None,
    right: tuple[int, int] | None,
) -> tuple[int, int] | None:
    if left is None:
        return right
    if right is None:
        return left
    x1, y1 = left
    x2, y2 = right
    if x1 == x2 and (y1 + y2) % SECP256K1_P == 0:
        return None
    if left == right:
        slope = (3 * x1 * x1) * _mod_inverse((2 * y1) % SECP256K1_P, SECP256K1_P)
    else:
        slope = (y2 - y1) * _mod_inverse((x2 - x1) % SECP256K1_P, SECP256K1_P)
    slope %= SECP256K1_P
    x3 = (slope * slope - x1 - x2) % SECP256K1_P
    y3 = (slope * (x1 - x3) - y1) % SECP256K1_P
    return x3, y3


def _point_multiply(scalar: int) -> tuple[int, int]:
    if not 0 < scalar < SECP256K1_N:
        raise ValueError("The local base private key is invalid.")
    result: tuple[int, int] | None = None
    addend: tuple[int, int] | None = (SECP256K1_GX, SECP256K1_GY)
    while scalar:
        if scalar & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        scalar >>= 1
    if result is None:
        raise ValueError("The local base private key is invalid.")
    return result


def valid_secret_scalar(value: bytes | bytearray) -> bool:
    scalar = int.from_bytes(value, "big")
    return 0 < scalar < SECP256K1_N


def random_private_key() -> bytearray:
    for _ in range(128):
        candidate = bytearray(os.urandom(32))
        if valid_secret_scalar(candidate):
            return candidate
        wipe(candidate)
    raise RuntimeError("The operating system did not produce a valid secp256k1 scalar.")


def public_key_from_private(private_key: bytes | bytearray) -> bytes:
    x, y = _point_multiply(int.from_bytes(private_key, "big"))
    return b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")


def add_private_tweak(base: bytes | bytearray, tweak: bytes | bytearray) -> bytearray:
    if not valid_secret_scalar(base) or not valid_secret_scalar(tweak):
        raise ValueError(
            "The returned GPU offset cannot be combined with the local private key."
        )
    total = (int.from_bytes(base, "big") + int.from_bytes(tweak, "big")) % SECP256K1_N
    if total == 0:
        raise ValueError(
            "The returned GPU offset cannot be combined with the local private key."
        )
    return bytearray(total.to_bytes(32, "big"))


def tron_address_from_public_key(public_key: bytes | bytearray) -> str:
    if len(public_key) != 65 or public_key[0] != 0x04:
        raise ValueError("The public key must use 65-byte uncompressed secp256k1 format.")
    public_hash = keccak256(public_key[1:])
    raw = bytearray(25)
    raw[0] = 0x41
    raw[1:21] = public_hash[12:]
    checksum = sha256(sha256(raw[:21]))
    raw[21:] = checksum[:4]
    return base58_encode(raw)


def tron_address_from_private(private_key: bytes | bytearray) -> str:
    public_key = bytearray(public_key_from_private(private_key))
    try:
        return tron_address_from_public_key(public_key)
    finally:
        wipe(public_key)


def same_path(left: Path, right: Path) -> bool:
    return left.expanduser().resolve() == right.expanduser().resolve()


def _open_flags(write: bool) -> int:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL if write else os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def read_bounded_file(path: Path, maximum_size: int, require_private_mode: bool) -> bytes:
    if path.is_symlink():
        raise OSError("The input must be a non-symlink regular file within the allowed size.")
    descriptor = os.open(path, _open_flags(False))
    try:
        metadata = os.fstat(descriptor)
        unix_private = False
        if not IS_WINDOWS:
            unix_private = (
                stat.S_ISREG(metadata.st_mode)
                and metadata.st_uid == os.geteuid()
                and stat.S_IMODE(metadata.st_mode) == 0o600
            )
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size < 0
            or metadata.st_size > maximum_size
            or (require_private_mode and not IS_WINDOWS and not unix_private)
        ):
            if require_private_mode and not IS_WINDOWS:
                raise OSError(
                    "The local secret file must be a non-symlink regular file owned by the current user with mode 0600 and a valid size."
                )
            raise OSError("The input must be a non-symlink regular file within the allowed size.")
        chunks = []
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                raise OSError("The input file changed or could not be read completely.")
            chunks.append(chunk)
            remaining -= len(chunk)
        extra = os.read(descriptor, 1)
        if extra:
            raise OSError("The input file changed while it was being read.")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def write_exclusive(path: Path, content: str, mode: int) -> None:
    payload = content.encode("ascii")
    descriptor = os.open(path, _open_flags(True), mode)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, mode)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("The filesystem did not preserve the required file permissions.")
        if not IS_WINDOWS and hasattr(os, "fchmod") and stat.S_IMODE(metadata.st_mode) != mode:
            raise OSError("The filesystem did not preserve the required file permissions.")
        written = 0
        while written < len(payload):
            count = os.write(descriptor, payload[written:])
            if count <= 0:
                raise OSError(f"Unable to write {path}")
            written += count
        os.fsync(descriptor)
    except Exception:
        os.close(descriptor)
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    os.close(descriptor)
    if IS_WINDOWS:
        os.chmod(path, stat.S_IREAD | stat.S_IWRITE)


def mark_secret_consumed(secret_path: Path) -> None:
    consumed_path = Path(str(secret_path) + ".consumed")
    try:
        os.link(secret_path, consumed_path)
    except OSError:
        os.replace(secret_path, consumed_path)
        return
    try:
        os.unlink(secret_path)
    except OSError:
        try:
            os.unlink(consumed_path)
        except OSError:
            pass
        raise OSError("Unable to retire the consumed base secret.")


def write_secret_file(
    path: Path,
    job_id: str,
    private_key: bytearray,
    public_key: bytes,
    suffix: str,
) -> None:
    content = (
        f"{SECRET_HEADER}\nJOB_ID={job_id}\nBASE_PRIVATE={hex_upper(private_key)}\n"
        f"BASE_PUBLIC={hex_upper(public_key)}\nSUFFIX={suffix}\n"
    )
    write_exclusive(path, content, 0o600)


def write_request_file(path: Path, job_id: str, public_key: bytes, suffix: str) -> None:
    content = (
        f"{REQUEST_HEADER}\nJOB_ID={job_id}\nBASE_PUBLIC={hex_upper(public_key)}\n"
        f"SUFFIX={suffix}\n"
    )
    write_exclusive(path, content, 0o644)


def read_secret_file(path: Path) -> tuple[str, bytearray, bytes, str]:
    raw = read_bounded_file(path, 4096, True)
    text = raw.decode("ascii")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if (
        len(lines) != 5
        or lines[0] != SECRET_HEADER
        or not lines[1].startswith("JOB_ID=")
        or not lines[2].startswith("BASE_PRIVATE=")
        or not lines[3].startswith("BASE_PUBLIC=")
        or not lines[4].startswith("SUFFIX=")
    ):
        raise ValueError("The local secret file format is invalid.")
    job_id = lines[1][7:]
    private_key = parse_hex_exact(lines[2][13:], 32)
    public_key = bytes(parse_hex_exact(lines[3][12:], 65))
    parse_hex_exact(job_id, 16)
    return job_id, private_key, public_key, lines[4][7:]


def read_server_result(path: Path) -> tuple[str, str, bytearray]:
    raw = read_bounded_file(path, 64 * 1024 * 1024, False)
    text = raw.decode("utf-8")
    found = None
    for line in text.splitlines():
        if not line.startswith("RESULT\t"):
            continue
        if found is not None:
            raise ValueError("The server output contains more than one RESULT line.")
        fields = line.split("\t")
        if len(fields) != 7 or fields[1] != "1":
            raise ValueError("The server RESULT line format is invalid.")
        job_id, address, tweak_hex, attempts, elapsed_text = fields[2:7]
        parse_hex_exact(job_id, 16)
        if len(address) != 34 or not attempts.isdigit():
            raise ValueError("The server RESULT metadata is invalid.")
        elapsed = float(elapsed_text)
        if not math.isfinite(elapsed) or elapsed < 0:
            raise ValueError("The server RESULT metadata is invalid.")
        found = (job_id, address, parse_hex_exact(tweak_hex, 32))
    if found is None:
        raise ValueError("The server output contains no RESULT line.")
    return found


def encoding_self_test() -> None:
    if hex_upper(keccak256(b"")) != "C5D2460186F7233C927E7DB2DCC703C0E500B653CA82273B7BFAD8045D85A470":
        raise RuntimeError("Keccak-256 empty-input vector failed.")
    if hex_upper(keccak256(b"abc")) != "4E03657AEA45A94FC7D47BA826C8D667C0D1E6E33A64A036EC44F58FA12D6C45":
        raise RuntimeError("Keccak-256 abc vector failed.")
    if hex_upper(sha256(b"abc")) != "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD":
        raise RuntimeError("SHA-256 abc vector failed.")
    if base58_encode(bytes([0, 0, 0, 1])) != "1112":
        raise RuntimeError("Base58 leading-zero vector failed.")
    parsed = parse_hex_exact("A" * 64, 32)
    if hex_upper(parsed) != "A" * 64:
        wipe(parsed)
        raise RuntimeError("Hexadecimal round-trip vector failed.")
    wipe(parsed)


def match_plan_self_test() -> None:
    validate_suffix("Az1")
    validate_suffix("Az1zY9mN2x")
    try:
        validate_suffix("12345678912")
        raise RuntimeError("An eleven-digit suffix was not rejected.")
    except ValueError:
        pass
    try:
        validate_suffix("TR0N")
        raise RuntimeError("A non-Base58 suffix was not rejected.")
    except ValueError:
        pass


def private_crypto_self_test() -> None:
    one = bytearray(31) + bytearray([1])
    public_one = public_key_from_private(one)
    if hex_upper(public_one) != (
        "0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"
        "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8"
    ):
        raise RuntimeError("secp256k1 private-key-one public vector failed.")
    if tron_address_from_private(one) != "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC":
        raise RuntimeError("TRON private-key-one address vector failed.")
    tweak = bytearray(31) + bytearray([1])
    two = add_private_tweak(one, tweak)
    public_two = public_key_from_private(two)
    if hex_upper(public_two) != (
        "04C6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5"
        "1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A"
    ):
        raise RuntimeError("Split-key private tweak-add vector failed.")
    wipe(one)
    wipe(two)
    wipe(tweak)


def client_startup_self_test() -> None:
    encoding_self_test()
    match_plan_self_test()
    private_crypto_self_test()


def prepare(suffix: str, secret_path: Path, request_path: Path) -> int:
    if secret_path.suffix != ".secret" or request_path.suffix != ".request":
        print("Secret and request files must use .secret and .request extensions.", file=sys.stderr)
        return 2
    if same_path(secret_path, request_path):
        print("Secret and request paths must be different.", file=sys.stderr)
        return 2
    private_key = bytearray()
    try:
        client_startup_self_test()
        validate_suffix(suffix)
        job_id = hex_upper(os.urandom(16))
        private_key = random_private_key()
        public_key = public_key_from_private(private_key)
        write_secret_file(secret_path, job_id, private_key, public_key, suffix)
        try:
            write_request_file(request_path, job_id, public_key, suffix)
        except Exception:
            try:
                os.unlink(secret_path)
            except OSError:
                pass
            raise
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2 if "suffix" in str(exc).lower() else 1
    except (OSError, RuntimeError) as exc:
        print(f"Unable to prepare a local split-key job: {exc}", file=sys.stderr)
        return 1
    finally:
        wipe(private_key)
    print(f"PREPARED\t1\t{job_id}\t{suffix}\t{request_path}\t{secret_path}")
    return 0


def finalize(secret_path: Path, result_path: Path, output_path: Path) -> int:
    if (
        secret_path.suffix != ".secret"
        or result_path.suffix != ".result"
        or output_path.suffix != ".wallet"
    ):
        print(
            "Secret, result and wallet files must use .secret, .result and .wallet extensions.",
            file=sys.stderr,
        )
        return 2
    if (
        same_path(secret_path, result_path)
        or same_path(secret_path, output_path)
        or same_path(result_path, output_path)
    ):
        print("Secret, result and wallet paths must all be different.", file=sys.stderr)
        return 2
    private_key = bytearray()
    tweak = bytearray()
    final_private = bytearray()
    try:
        client_startup_self_test()
        job_id, private_key, stored_public, suffix = read_secret_file(secret_path)
        result_job, address, tweak = read_server_result(result_path)
        if result_job != job_id:
            raise ValueError("The server result belongs to a different job ID.")
        if public_key_from_private(private_key) != stored_public:
            raise ValueError("The local secret file failed its public-key binding check.")
        final_private = add_private_tweak(private_key, tweak)
        local_address = tron_address_from_private(final_private)
        if local_address != address or not matches_suffix(local_address, suffix):
            raise ValueError("The untrusted server result failed local address verification.")
        wallet = (
            f"{WALLET_HEADER}\nJOB_ID={job_id}\nADDRESS={local_address}\n"
            f"PRIVATE_KEY={hex_upper(final_private)}\nSUFFIX={suffix}\n"
        )
        write_exclusive(output_path, wallet, 0o600)
        try:
            mark_secret_consumed(secret_path)
        except OSError as exc:
            removed = True
            try:
                os.unlink(output_path)
            except OSError:
                removed = False
            message = str(exc)
            if not removed:
                message += " The wallet was created but could not be rolled back; do not reuse the base secret."
            print(message, file=sys.stderr)
            return 1
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except (OSError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        wipe(private_key)
        wipe(tweak)
        wipe(final_private)
    print(f"FINALIZED\t1\t{job_id}\t{local_address}\t{output_path}")
    return 0


def self_test() -> int:
    try:
        client_startup_self_test()
    except (ValueError, RuntimeError) as exc:
        print(f"Client self-test failed: {exc}", file=sys.stderr)
        return 1
    print("SELFTEST\tOK\tLOCAL_SECRET_CLIENT")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="trxvanity_client.py",
        description="TRX Vanity split-key client for macOS, Linux, and Windows.",
    )
    parser.add_argument("--self-test", action="store_true")
    subparsers = parser.add_subparsers(dest="command")
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--suffix", required=True)
    prepare_parser.add_argument("--secret", required=True, type=Path)
    prepare_parser.add_argument("--request", required=True, type=Path)
    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--secret", required=True, type=Path)
    finalize_parser.add_argument("--result", required=True, type=Path)
    finalize_parser.add_argument("--output", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv == ["--self-test"]:
        return self_test()
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else 2
    if args.self_test and args.command is None:
        return self_test()
    if args.command == "prepare":
        return prepare(args.suffix, args.secret, args.request)
    if args.command == "finalize":
        return finalize(args.secret, args.result, args.output)
    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
