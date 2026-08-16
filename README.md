# TRX Vanity

[中文说明](README.zh.md)

<p align="center">
  <a href="https://github.com/ArtiSheng/TRXVanity/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/ArtiSheng/TRXVanity?style=for-the-badge&logo=github&color=yellow"></a>
  <img alt="Windows" src="https://img.shields.io/badge/Windows-10%2F11-0078D6?style=for-the-badge&logo=windows&logoColor=white">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-x86__64-FCC624?style=for-the-badge&logo=linux&logoColor=black">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-Apple%20Silicon-000000?style=for-the-badge&logo=apple&logoColor=white">
</p>

<p align="center">
  <img alt="CUDA" src="https://img.shields.io/badge/NVIDIA-CUDA-76B900?style=for-the-badge&logo=nvidia&logoColor=white">
  <img alt="OpenCL" src="https://img.shields.io/badge/OpenCL-GPU-ED1C24?style=for-the-badge&logo=khronos&logoColor=white">
  <img alt="Metal" src="https://img.shields.io/badge/Apple-Metal-000000?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="TRON" src="https://img.shields.io/badge/TRON-TRX-EF0027?style=for-the-badge">
</p>

<p align="center">
  <img alt="C++" src="https://img.shields.io/badge/C%2B%2B-00599C?style=for-the-badge&logo=cplusplus&logoColor=white">
  <img alt="C#" src="https://img.shields.io/badge/C%23-.NET%204.8-512BD4?style=for-the-badge&logo=csharp&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.8%2B-3776AB?style=for-the-badge&logo=python&logoColor=white">
  <img alt="PHP" src="https://img.shields.io/badge/PHP-7.4%2B-777BB4?style=for-the-badge&logo=php&logoColor=white">
  <img alt="BIP39" src="https://img.shields.io/badge/BIP39-12--word-1C7ED6?style=for-the-badge">
  <img alt="AES" src="https://img.shields.io/badge/AES--256-backup-2F9E44?style=for-the-badge">
</p>

GPU-accelerated **TRON vanity address** generators. Search for a custom Base58 suffix (and, on macOS, a prefix) on NVIDIA CUDA / OpenCL or Apple Metal. A hit is re-derived on the CPU before any secret is shown.

This repository has two independent editions, plus shared backup and Windows helper tools.

| Edition | What a hit is | Typical use |
|---|---|---|
| [**Private key**](TRXVanity-PrivateKey/TRXVanityWindows/README.md) | A raw 256-bit key | Fastest search. Windows, Linux (split-key), and macOS |
| [**Mnemonic**](TRXVanity-Mnemonic/README.md) | A 12-word BIP39 phrase | Import into TronLink. Windows and Linux CUDA; much slower |

TRON mainnet addresses start with `T`. Suffixes are 1–10 characters from the TRON Base58 alphabet (no `0`, `O`, `I`, or `l`).

```text
123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
```

## Why two editions

**Private-key edition** enumerates secp256k1 keys and builds the TRON address:

```text
secp256k1 → Keccak-256 → 0x41 → double SHA-256 → Base58Check
```

On a current RTX 4090 this path is on the order of **10⁹ candidates/sec**. The Linux variant never sends the base private key to the GPU host: the client keeps `b`, the server searches a public increment `t`, and the client combines `x = b + t` and re-verifies.

**Mnemonic edition** generates a valid BIP39 English mnemonic for every candidate, empty passphrase, fixed TronLink path:

```text
m/44'/195'/0'/0/0
```

Each candidate runs 2048 rounds of PBKDF2 and BIP32, so throughput is several orders of magnitude lower (about **10⁶/sec** on an RTX 4090). The result imports into TronLink as a normal 12-word wallet.

A vanity condition shrinks the matching key set. Longer suffixes take exponentially longer (`~58ⁿ` average candidates). Use a long suffix carefully for high-value funds.

## Repository layout

```text
.
├── TRXVanity-PrivateKey/      Fast raw-key search
│   ├── TRXVanityWindows/      NVIDIA OpenCL GUI (Windows 10/11 x64)
│   ├── TRXVanityLinux/        Split-key client + GPU server
│   └── TRXVanityMac/          Native SwiftUI + Metal app
├── TRXVanity-Mnemonic/        BIP39 / TronLink search
│   ├── TRXVanityWindows/      NVIDIA CUDA GUI
│   ├── TRXVanityLinux/        CUDA deploy + formal search
│   └── MACGUI/                macOS fleet monitor
├── EncryptedBackupServer/     PHP site for .trxv ciphertext and heartbeats
├── AES-Decrypt/               Local decrypt of .trxv backups
└── Windows-OpenCL-Registry-Fix/   ICD registry repair for some cloud GPUs
```

Each directory has `README.md` (English) and `README.zh.md` (Chinese).

## Features

- **GPU first.** Windows private-key and mnemonic builds require a real NVIDIA GPU. They do not silently fall back to CPU search.
- **Independent CPU re-check.** A hit is recomputed with in-repo `libsecp256k1` (and a separate address path) before the secret is displayed.
- **Secrets stay off the GPU where it matters.** Random key/entropy bases are generated on the CPU (`BCryptGenRandom`, `SecRandomCopyBytes`, or the Linux client). The GPU receives public curve points and offsets.
- **Optional encrypted backup.** Clients can upload AES-256 ciphertext (`.trxv`) and a status heartbeat. The PHP server never has the AES key and never decrypts.
- **No telemetry by default.** Heartbeats and backups are sent only after you set a server URL and your own 64-character HEX key.

## Shared tools

| Tool | Role |
|---|---|
| [`EncryptedBackupServer`](EncryptedBackupServer/README.md) | HTTPS PHP 7.4+ site: store, list, download, and delete `.trxv` files; heartbeats and disconnect email. Configure `config.php` before deploy. |
| [`AES-Decrypt`](AES-Decrypt/README.md) | Python 3.8+ script for macOS, Windows, and Linux. Decrypts a `.trxv` file in memory with the same AES key. |
| [`Windows-OpenCL-Registry-Fix`](Windows-OpenCL-Registry-Fix/README.md) | PowerShell repair when a cloud Windows host has NVIDIA drivers but no Khronos OpenCL ICD registration. |

## Security

- A mnemonic or private key is full wallet control. Do not screenshot it, paste it into chat, or save it to a syncing cloud drive.
- If the AES key is lost, the server cannot recover a `.trxv` backup.
- Standard BIP-39 words are **not** a 32-byte private key encoded as English. Do not run a hit private key through a “key to mnemonic” converter.
- Verify receive and send with a small amount before moving real funds. Prefer an audited hardware wallet or multisig for large balances.

## Documentation

| Start here | Docs |
|---|---|
| Private key, Windows | [`TRXVanity-PrivateKey/TRXVanityWindows`](TRXVanity-PrivateKey/TRXVanityWindows/README.md) |
| Private key, Linux split-key | [`TRXVanity-PrivateKey/TRXVanityLinux`](TRXVanity-PrivateKey/TRXVanityLinux/README.md) |
| Private key, macOS | [`TRXVanity-PrivateKey/TRXVanityMac`](TRXVanity-PrivateKey/TRXVanityMac/README.md) |
| Mnemonic overview | [`TRXVanity-Mnemonic`](TRXVanity-Mnemonic/README.md) |
| Mnemonic, Windows | [`TRXVanity-Mnemonic/TRXVanityWindows`](TRXVanity-Mnemonic/TRXVanityWindows/README.md) |
| Mnemonic, Linux | [`TRXVanity-Mnemonic/TRXVanityLinux`](TRXVanity-Mnemonic/TRXVanityLinux/README.md) |

Third-party licenses for OpenSSL, CUDA mnemonic recovery, Profanity2, and libsecp256k1 are in each edition’s `ThirdPartyLicenses/` (or `Vendor/`) directory.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=ArtiSheng/TRXVanity&type=Date)](https://www.star-history.com/#ArtiSheng/TRXVanity&Date)
