# TRX Vanity

[English](README.md)

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

用 GPU 搜索 **TRON 靓号地址**。可在 NVIDIA CUDA / OpenCL 或 Apple Metal 上匹配自定义 Base58 后缀（macOS 还可匹配前缀）。命中后先由 CPU 独立重算，通过后才显示密钥。

本仓库包含两个独立版本，以及共用的备份与 Windows 辅助工具。

| 版本 | 命中结果 | 适用场景 |
|---|---|---|
| [**私钥版**](TRXVanity-PrivateKey/TRXVanityWindows/README.zh.md) | 256 位原始私钥 | 速度最快。覆盖 Windows、Linux（分离密钥）、macOS |
| [**助记词版**](TRXVanity-Mnemonic/README.zh.md) | 12 词 BIP39 助记词 | 可导入 TronLink。Windows / Linux CUDA，慢几个数量级 |

TRON 主网地址以 `T` 开头。后缀为 1–10 位 TRON Base58 字符（不含 `0`、`O`、`I`、`l`）：

```text
123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
```

## 为什么有两个版本

**私钥版**直接枚举 secp256k1 私钥并生成 TRON 地址：

```text
secp256k1 → Keccak-256 → 0x41 → 双 SHA-256 → Base58Check
```

当前 RTX 4090 上大约是 **10⁹ 候选/秒**。Linux 变体不会把基准私钥传到 GPU 主机：客户端保存 `b`，服务端只搜公开增量 `t`，客户端再合成 `x = b + t` 并复验。

**助记词版**为每个候选生成合法的 BIP39 英文助记词，passphrase 为空，固定 TronLink 路径：

```text
m/44'/195'/0'/0/0
```

每个候选都要走 2048 轮 PBKDF2 和 BIP32，因此速度慢几个数量级（RTX 4090 大约 **10⁶/秒**）。结果可按普通 12 词钱包导入 TronLink。

靓号条件会缩小有效密钥集合。后缀每多一位，平均候选数约按 `58ⁿ` 增长。长后缀用于高价值资产时要谨慎。

## 仓库结构

```text
.
├── TRXVanity-PrivateKey/      快速私钥搜索
│   ├── TRXVanityWindows/      NVIDIA OpenCL 图形界面（Windows 10/11 x64）
│   ├── TRXVanityLinux/        分离密钥客户端 + GPU 服务端
│   └── TRXVanityMac/          原生 SwiftUI + Metal 应用
├── TRXVanity-Mnemonic/        BIP39 / TronLink 搜索
│   ├── TRXVanityWindows/      NVIDIA CUDA 图形界面
│   ├── TRXVanityLinux/        CUDA 部署与正式搜索
│   └── MACGUI/                macOS 多机监控
├── EncryptedBackupServer/     接收 .trxv 密文和心跳的 PHP 站点
├── AES-Decrypt/               本机解密 .trxv 备份
└── Windows-OpenCL-Registry-Fix/   部分云主机 OpenCL 注册表修复
```

各目录都有 `README.md`（英文）和 `README.zh.md`（中文）。

## 特性

- **强制 GPU。** Windows 私钥版和助记词版都要求真实 NVIDIA 显卡，不会悄悄降级到 CPU 搜索。
- **CPU 独立复验。** 命中后用仓库内的 `libsecp256k1`（以及独立地址实现）重算，通过才显示密钥。
- **密钥尽量不进 GPU。** 随机私钥/熵基值在 CPU 生成（`BCryptGenRandom`、`SecRandomCopyBytes` 或 Linux 客户端）。GPU 只接收公开曲线点和偏移量。
- **可选密文备份。** 客户端可上传 AES-256 密文（`.trxv`）和状态心跳。PHP 服务器没有 AES 密钥，也不会解密。
- **默认无遥测。** 只有你填写上传地址和自己的 64 位 HEX 密钥后，才会发送心跳或密文。

## 共用工具

| 工具 | 作用 |
|---|---|
| [`EncryptedBackupServer`](EncryptedBackupServer/README.zh.md) | HTTPS PHP 7.4+ 站点：保存、列出、下载、删除 `.trxv`，以及心跳和断连邮件。部署前先改 `config.php`。 |
| [`AES-Decrypt`](AES-Decrypt/README.zh.md) | Python 3.8+ 脚本，macOS / Windows / Linux 通用。用同一把 AES 密钥在内存中解开 `.trxv`。 |
| [`Windows-OpenCL-Registry-Fix`](Windows-OpenCL-Registry-Fix/README.zh.md) | PowerShell 修复脚本。部分云 Windows 主机有 NVIDIA 驱动，但未注册 Khronos OpenCL ICD。 |

## 安全

- 助记词或私钥等于钱包控制权。不要截图、发到聊天软件，或存到自动同步网盘。
- AES 密钥丢失后，服务器无法恢复 `.trxv` 备份。
- 标准 BIP-39 助记词**不是**把 32 字节私钥直接编成英文单词。不要把命中的私钥交给「私钥转助记词」工具。
- 先用小额资产验证收款和转出。大额资产优先使用经过审计的硬件钱包或多签。

## 文档

| 从这里开始 | 说明 |
|---|---|
| 私钥版 Windows | [`TRXVanity-PrivateKey/TRXVanityWindows`](TRXVanity-PrivateKey/TRXVanityWindows/README.zh.md) |
| 私钥版 Linux 分离密钥 | [`TRXVanity-PrivateKey/TRXVanityLinux`](TRXVanity-PrivateKey/TRXVanityLinux/README.zh.md) |
| 私钥版 macOS | [`TRXVanity-PrivateKey/TRXVanityMac`](TRXVanity-PrivateKey/TRXVanityMac/README.zh.md) |
| 助记词版总览 | [`TRXVanity-Mnemonic`](TRXVanity-Mnemonic/README.zh.md) |
| 助记词版 Windows | [`TRXVanity-Mnemonic/TRXVanityWindows`](TRXVanity-Mnemonic/TRXVanityWindows/README.zh.md) |
| 助记词版 Linux | [`TRXVanity-Mnemonic/TRXVanityLinux`](TRXVanity-Mnemonic/TRXVanityLinux/README.zh.md) |

OpenSSL、CUDA mnemonic recovery、Profanity2、libsecp256k1 等第三方许可证在各版本的 `ThirdPartyLicenses/`（或 `Vendor/`）目录。

## Star History

<a href="https://www.star-history.com/?repos=ArtiSheng%2FTRXVanity&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ArtiSheng/TRXVanity&type=date&theme=dark&legend=top-left&sealed_token=90wO7CVJALpHdsa2dUaewqU1ULQYVaPYdrOggKnG81epXuSON9yZbjS9YdbKdTkjvFq1F8hmTkvvWNY0-NMBqcBlMX195e-FBCgqtFQtUYBTeMS1A9-sdqtqCi_PW2EWzfT5cexmxwH76QERqwaIaz-oB2zimYtrqUF2WqD9j2nsLl2z5JVDyBj2-uxg" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ArtiSheng/TRXVanity&type=date&legend=top-left&sealed_token=90wO7CVJALpHdsa2dUaewqU1ULQYVaPYdrOggKnG81epXuSON9yZbjS9YdbKdTkjvFq1F8hmTkvvWNY0-NMBqcBlMX195e-FBCgqtFQtUYBTeMS1A9-sdqtqCi_PW2EWzfT5cexmxwH76QERqwaIaz-oB2zimYtrqUF2WqD9j2nsLl2z5JVDyBj2-uxg" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=ArtiSheng/TRXVanity&type=date&legend=top-left&sealed_token=90wO7CVJALpHdsa2dUaewqU1ULQYVaPYdrOggKnG81epXuSON9yZbjS9YdbKdTkjvFq1F8hmTkvvWNY0-NMBqcBlMX195e-FBCgqtFQtUYBTeMS1A9-sdqtqCi_PW2EWzfT5cexmxwH76QERqwaIaz-oB2zimYtrqUF2WqD9j2nsLl2z5JVDyBj2-uxg" />
 </picture>
</a>
