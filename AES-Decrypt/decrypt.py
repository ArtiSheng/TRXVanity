#!/usr/bin/env python3
"""Decrypt a TRX Vanity .trxv mnemonic backup on macOS, Windows, or Linux.

Plaintext stays in memory and is never written to a file. The only dependency
is Python 3.8+ from the standard library.
"""

from __future__ import annotations

import argparse
import getpass
import hmac
import hashlib
import json
import os
import re
import sys
from typing import Any, Dict, Mapping, Optional


MAGIC = b"TRXMNEMO"
AUTHENTICATION_LABEL = b"TRXVanity mnemonic backup authentication"
HEADER_LENGTH = 28
TAG_LENGTH = 32
FORMAT_NAME = "trx-vanity-mnemonic-backup"
MNEMONIC_PATTERN = re.compile(r"^[a-z]+(?: [a-z]+){11}$")
ADDRESS_PATTERN = re.compile(r"^T[1-9A-HJ-NP-Za-km-z]{33}$")


class DecryptError(Exception):
    pass


# AES-256 from FIPS-197. Kept in this file so the decryptor has no third-party
# packages to install on a machine that should not receive extra software.
_SBOX = bytes(
    [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
    ]
)
_INV_SBOX = bytes(
    [
        0x52, 0x09, 0x6A, 0xD5, 0x30, 0x36, 0xA5, 0x38, 0xBF, 0x40, 0xA3, 0x9E, 0x81, 0xF3, 0xD7, 0xFB,
        0x7C, 0xE3, 0x39, 0x82, 0x9B, 0x2F, 0xFF, 0x87, 0x34, 0x8E, 0x43, 0x44, 0xC4, 0xDE, 0xE9, 0xCB,
        0x54, 0x7B, 0x94, 0x32, 0xA6, 0xC2, 0x23, 0x3D, 0xEE, 0x4C, 0x95, 0x0B, 0x42, 0xFA, 0xC3, 0x4E,
        0x08, 0x2E, 0xA1, 0x66, 0x28, 0xD9, 0x24, 0xB2, 0x76, 0x5B, 0xA2, 0x49, 0x6D, 0x8B, 0xD1, 0x25,
        0x72, 0xF8, 0xF6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xD4, 0xA4, 0x5C, 0xCC, 0x5D, 0x65, 0xB6, 0x92,
        0x6C, 0x70, 0x48, 0x50, 0xFD, 0xED, 0xB9, 0xDA, 0x5E, 0x15, 0x46, 0x57, 0xA7, 0x8D, 0x9D, 0x84,
        0x90, 0xD8, 0xAB, 0x00, 0x8C, 0xBC, 0xD3, 0x0A, 0xF7, 0xE4, 0x58, 0x05, 0xB8, 0xB3, 0x45, 0x06,
        0xD0, 0x2C, 0x1E, 0x8F, 0xCA, 0x3F, 0x0F, 0x02, 0xC1, 0xAF, 0xBD, 0x03, 0x01, 0x13, 0x8A, 0x6B,
        0x3A, 0x91, 0x11, 0x41, 0x4F, 0x67, 0xDC, 0xEA, 0x97, 0xF2, 0xCF, 0xCE, 0xF0, 0xB4, 0xE6, 0x73,
        0x96, 0xAC, 0x74, 0x22, 0xE7, 0xAD, 0x35, 0x85, 0xE2, 0xF9, 0x37, 0xE8, 0x1C, 0x75, 0xDF, 0x6E,
        0x47, 0xF1, 0x1A, 0x71, 0x1D, 0x29, 0xC5, 0x89, 0x6F, 0xB7, 0x62, 0x0E, 0xAA, 0x18, 0xBE, 0x1B,
        0xFC, 0x56, 0x3E, 0x4B, 0xC6, 0xD2, 0x79, 0x20, 0x9A, 0xDB, 0xC0, 0xFE, 0x78, 0xCD, 0x5A, 0xF4,
        0x1F, 0xDD, 0xA8, 0x33, 0x88, 0x07, 0xC7, 0x31, 0xB1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xEC, 0x5F,
        0x60, 0x51, 0x7F, 0xA9, 0x19, 0xB5, 0x4A, 0x0D, 0x2D, 0xE5, 0x7A, 0x9F, 0x93, 0xC9, 0x9C, 0xEF,
        0xA0, 0xE0, 0x3B, 0x4D, 0xAE, 0x2A, 0xF5, 0xB0, 0xC8, 0xEB, 0xBB, 0x3C, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2B, 0x04, 0x7E, 0xBA, 0x77, 0xD6, 0x26, 0xE1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0C, 0x7D,
    ]
)
_RCON = (0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _xtime(value: int) -> int:
    value <<= 1
    if value & 0x100:
        value ^= 0x11B
    return value


def _mul(value: int, factor: int) -> int:
    result = 0
    current = value
    while factor:
        if factor & 1:
            result ^= current
        current = _xtime(current)
        factor >>= 1
    return result


def _sub_word(word: int) -> int:
    return (
        (_SBOX[(word >> 24) & 0xFF] << 24)
        | (_SBOX[(word >> 16) & 0xFF] << 16)
        | (_SBOX[(word >> 8) & 0xFF] << 8)
        | _SBOX[word & 0xFF]
    )


def _rot_word(word: int) -> int:
    return ((word << 8) & 0xFFFFFFFF) | (word >> 24)


def _expand_key(key: bytes) -> list:
    if len(key) != 32:
        raise DecryptError("AES 密钥必须是 32 字节。")
    words = [int.from_bytes(key[index : index + 4], "big") for index in range(0, 32, 4)]
    for index in range(8, 60):
        temp = words[index - 1]
        if index % 8 == 0:
            temp = _sub_word(_rot_word(temp)) ^ (_RCON[index // 8] << 24)
        elif index % 8 == 4:
            temp = _sub_word(temp)
        words.append(words[index - 8] ^ temp)
    return words


def _add_round_key(state: bytearray, words: list, round_index: int) -> None:
    offset = round_index * 4
    for column in range(4):
        word = words[offset + column]
        state[column * 4] ^= (word >> 24) & 0xFF
        state[column * 4 + 1] ^= (word >> 16) & 0xFF
        state[column * 4 + 2] ^= (word >> 8) & 0xFF
        state[column * 4 + 3] ^= word & 0xFF


def _shift_rows(state: bytearray, inverse: bool) -> None:
    rows = [state[index::4] for index in range(4)]
    for row in range(1, 4):
        shift = (-row if inverse else row) % 4
        rows[row] = rows[row][shift:] + rows[row][:shift]
    for row in range(4):
        for column in range(4):
            state[column * 4 + row] = rows[row][column]


def _mix_columns(state: bytearray, inverse: bool) -> None:
    matrix = (
        ((0x0E, 0x0B, 0x0D, 0x09), (0x09, 0x0E, 0x0B, 0x0D), (0x0D, 0x09, 0x0E, 0x0B), (0x0B, 0x0D, 0x09, 0x0E))
        if inverse
        else ((0x02, 0x03, 0x01, 0x01), (0x01, 0x02, 0x03, 0x01), (0x01, 0x01, 0x02, 0x03), (0x03, 0x01, 0x01, 0x02))
    )
    for column in range(4):
        block = state[column * 4 : column * 4 + 4]
        mixed = bytearray(4)
        for row in range(4):
            mixed[row] = (
                _mul(block[0], matrix[row][0])
                ^ _mul(block[1], matrix[row][1])
                ^ _mul(block[2], matrix[row][2])
                ^ _mul(block[3], matrix[row][3])
            )
        state[column * 4 : column * 4 + 4] = mixed


def _aes_block(block: bytes, words: list, decrypt: bool) -> bytes:
    state = bytearray(block)
    if decrypt:
        _add_round_key(state, words, 14)
        for round_index in range(13, 0, -1):
            _shift_rows(state, True)
            for index in range(16):
                state[index] = _INV_SBOX[state[index]]
            _add_round_key(state, words, round_index)
            _mix_columns(state, True)
        _shift_rows(state, True)
        for index in range(16):
            state[index] = _INV_SBOX[state[index]]
        _add_round_key(state, words, 0)
    else:
        _add_round_key(state, words, 0)
        for round_index in range(1, 14):
            for index in range(16):
                state[index] = _SBOX[state[index]]
            _shift_rows(state, False)
            _mix_columns(state, False)
            _add_round_key(state, words, round_index)
        for index in range(16):
            state[index] = _SBOX[state[index]]
        _shift_rows(state, False)
        _add_round_key(state, words, 14)
    return bytes(state)


def aes256_cbc(data: bytes, key: bytes, iv: bytes, decrypt: bool) -> bytes:
    if len(iv) != 16:
        raise DecryptError("AES 初始化向量长度无效。")
    if decrypt and (len(data) < 16 or len(data) % 16):
        raise DecryptError("AES 分组长度无效。")
    words = _expand_key(key)
    output = bytearray()
    previous = iv
    if decrypt:
        for offset in range(0, len(data), 16):
            block = data[offset : offset + 16]
            plain = bytes(left ^ right for left, right in zip(_aes_block(block, words, True), previous))
            output.extend(plain)
            previous = block
        if not output:
            raise DecryptError("AES 解密失败。")
        padding = output[-1]
        if padding < 1 or padding > 16 or output[-padding:] != bytes([padding]) * padding:
            raise DecryptError("AES 解密失败。")
        del output[-padding:]
        return bytes(output)

    padding = 16 - (len(data) % 16)
    padded = data + bytes([padding]) * padding
    for offset in range(0, len(padded), 16):
        block = bytes(left ^ right for left, right in zip(padded[offset : offset + 16], previous))
        cipher = _aes_block(block, words, False)
        output.extend(cipher)
        previous = cipher
    return bytes(output)


def wipe(buffer: bytearray) -> None:
    for index in range(len(buffer)):
        buffer[index] = 0
    buffer.clear()


def parse_aes_key(text: str) -> bytearray:
    key = text.strip()
    if len(key) != 64 or any(character not in "0123456789abcdefABCDEF" for character in key):
        raise DecryptError("AES 密钥必须正好是 64 位十六进制字符。")
    return bytearray.fromhex(key)


def normalize_path(raw: str) -> str:
    path = raw.strip()
    if len(path) >= 2 and path[0] == path[-1] and path[0] in {'"', "'"}:
        path = path[1:-1]
    if os.name != "nt":
        path = path.replace("\\ ", " ")
    return os.path.expanduser(path)


def read_backup(path: str) -> bytes:
    if not os.path.isfile(path):
        raise DecryptError("找不到该文件，请重新指定 .trxv 备份路径。")
    size = os.path.getsize(path)
    if size < HEADER_LENGTH + 16 + TAG_LENGTH or size > 2 * 1024 * 1024:
        raise DecryptError("文件大小不是有效的 TRX Vanity AES 备份。")
    with open(path, "rb") as handle:
        envelope = handle.read()
    if len(envelope) != size:
        raise DecryptError("无法完整读取备份文件。")
    return envelope


def decrypt_backup(envelope: bytes, key: bytearray) -> Dict[str, Any]:
    if len(envelope) < HEADER_LENGTH + 16 + TAG_LENGTH or envelope[:8] != MAGIC:
        raise DecryptError("文件头不正确，不是当前助记词版 TRX Vanity AES 备份。")
    cipher_length = int.from_bytes(envelope[24:28], "big")
    if (
        cipher_length < 16
        or cipher_length % 16
        or len(envelope) != HEADER_LENGTH + cipher_length + TAG_LENGTH
    ):
        raise DecryptError("密文长度不正确，文件可能不完整或已损坏。")
    authenticated = envelope[: HEADER_LENGTH + cipher_length]
    authentication_key = bytearray(hmac.new(key, AUTHENTICATION_LABEL, hashlib.sha256).digest())
    try:
        expected = hmac.new(authentication_key, authenticated, hashlib.sha256).digest()
    finally:
        wipe(authentication_key)
    if not hmac.compare_digest(expected, envelope[-TAG_LENGTH:]):
        raise DecryptError("AES 密钥错误，或者备份文件已被修改。")
    clear = bytearray(aes256_cbc(envelope[28:-TAG_LENGTH], bytes(key), envelope[8:24], True))
    try:
        decoded = json.loads(clear.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DecryptError("密文已通过认证，但明文不是有效 JSON。") from error
    finally:
        wipe(clear)
    if not isinstance(decoded, dict):
        raise DecryptError("密文已通过认证，但其中不包含有效的助记词记录。")
    return decoded


def present_record(record: Mapping[str, Any]) -> None:
    format_name = str(record.get("format", "")).strip()
    mnemonic = str(record.get("mnemonic", "")).strip()
    address = str(record.get("address", "")).strip()
    if format_name != FORMAT_NAME or not MNEMONIC_PATTERN.fullmatch(mnemonic):
        raise DecryptError("密文已通过认证，但其中不包含有效的助记词记录。")
    if address and not ADDRESS_PATTERN.fullmatch(address):
        address = ""

    print("\n解密成功。")
    if address:
        print(f"地址：{address}")
    suffix = str(record.get("suffix", "")).strip()
    if suffix:
        print(f"尾号：{suffix}")
    path = str(record.get("derivationPath", "")).strip()
    if path:
        print(f"派生路径：{path}")
    created = str(record.get("createdUtc", "")).strip()
    if created:
        print(f"创建时间：{created}")
    print(f"\n助记词：\n{mnemonic}\n")
    print("请勿截图、复制到聊天软件或保存到联网云盘；关闭窗口后仍应清理终端滚动记录。")


def prompt_path() -> str:
    print("请把 .trxv AES 备份文件拖入此窗口，或输入完整路径，然后按回车：")
    try:
        raw = input("> ")
    except EOFError as error:
        raise DecryptError("没有读到备份文件路径。") from error
    return normalize_path(raw)


def prompt_key() -> bytearray:
    print("请输入 64 位 HEX AES 密钥（输入不会显示），然后按回车：")
    try:
        return parse_aes_key(getpass.getpass("> "))
    except EOFError as error:
        raise DecryptError("没有读到 AES 密钥。") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="解密 TRX Vanity 助记词版 .trxv AES 备份。明文不会写入磁盘。"
    )
    parser.add_argument("backup", nargs="?", help=".trxv 备份文件路径")
    return parser


def main(argv: Optional[list] = None) -> int:
    args = build_parser().parse_args(argv)

    print()
    print("TRX Vanity AES 备份解密（macOS / Windows / Linux）")
    print("明文不会写入磁盘；助记词会显示在当前终端中。")
    print()

    path = normalize_path(args.backup) if args.backup else prompt_path()
    envelope = read_backup(path)
    key = prompt_key()
    try:
        record = decrypt_backup(envelope, key)
        present_record(record)
        return 0
    finally:
        wipe(key)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DecryptError as error:
        print(f"\n错误：{error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n已取消。", file=sys.stderr)
        sys.exit(130)
