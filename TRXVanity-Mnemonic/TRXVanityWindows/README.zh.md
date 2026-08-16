# TRX Vanity for Windows — TronLink 助记词版

[English](README.md)

这是 Windows 10/11 x64 的 NVIDIA CUDA TRON 后缀靓号生成器。每个候选都是有效的 12 词 BIP39 英文助记词，BIP39 passphrase 为空，固定使用 TronLink/TRON 默认路径：

```text
m/44'/195'/0'/0/0
```

## 工作方式

1. Windows `BCryptGenRandom` 为 GPU 和 CPU 生成独立的 128 位随机熵基值；
2. CUDA 为每个候选执行 BIP39、2048 轮 PBKDF2-HMAC-SHA512、固定路径 BIP32、TRON Base58Check 和后缀匹配；
3. 低优先级 OpenSSL CPU 工作者同时搜索另一段候选空间，不阻塞 CUDA 控制线程；
4. 任一路径命中后，独立 CPU 实现会从熵和助记词重算地址，通过复验才输出。

普通 GPU 候选不会传回主机。地址派生阶段每个 CUDA 线程处理四个候选，通过批量有限域求逆减少 secp256k1 开销；BIP32 主密钥使用固定 `Bitcoin seed` HMAC 预计算状态，结果与标准算法完全一致。

## 三种运行方案

- `rtx5070` — **RTX 5070 方案**：仅允许 RTX 5070，使用 256/256 分阶段线程块及自动批量；
- `rtx4090` — **RTX 4090 方案**：仅允许 RTX 4090，使用实测最快的 PBKDF2 256 / 地址 384 线程块、双 CUDA 流和自动批量；
- `smart` — **智能最高速（任意 RTX）**：分别分析两个 CUDA 内核的占用率，并按 SM 数和可用显存自动确定安全容量和批量。图形界面默认使用此方案。

三种方案都会使用全部逻辑 CPU 线程，但 CPU 工作者保持低于正常优先级，让 CUDA 提交和回收线程优先。

命令行调试参数：

```text
--profile rtx5070|rtx4090|smart
--batch-size <最大候选数>
--cpu-workers <0–256>
--cuda-block-size <32–1024 的 32 倍数，仅用于对照测试>
```

专用方案会核对显卡型号；型号不符时请使用 `smart`。手动参数只应在重复实测时使用，默认的分阶段参数通常更快。

## GPU 兼容与构建

构建机需要：

- Visual Studio 2022 Build Tools（MSVC x64）和 Windows 10/11 SDK；
- NVIDIA CUDA Toolkit 12.6 或更新版本；
- .NET Framework 4.8；
- 仓库内随附的 OpenSSL CPU 加速 DLL。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -Clean
```

构建脚本默认加入 `sm_75`、`sm_86`、`sm_89` 原生代码，对应 RTX 20/30/40 系列。若工具包支持 `sm_120`，会自动加入 RTX 50 原生代码；否则嵌入 `compute_89` PTX，供 RTX 50 驱动即时编译。运行机器只需要 NVIDIA 驱动，不需要 CUDA Toolkit。

产物位于：

```text
TRXVanityWindows\build\TRXVanity.exe
```

同目录还会有 `trxvanity-gpu.exe`、`TRXVanityBackupDecrypt.exe`、`libcrypto-3-x64.dll`、`bip39-english.txt` 和许可证。中间 `.obj` 在 `build\obj`。

单独运行完整自检：

```powershell
.\TRXVanityWindows\build\trxvanity-gpu.exe --self-test --batch-size 128
```

控制台重复测速（只输出到控制台，不生成报告文件）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\tools\benchmark.ps1 `
  -Profile rtx4090 -WarmupSeconds 5 -SecondsPerRun 15 -Runs 3
```

构建自检包括 BIP39 全零熵向量、TronLink 地址向量、GPU/CPU 主密钥交叉验证、四候选批量求逆地址对照和 AES 备份篡改检测。

## 导入 TronLink

1. 在结果区显示并复制 12 个英文单词；
2. TronLink 中选择导入助记词；
3. 按原顺序粘贴，不设置额外 BIP39 passphrase；
4. 首个 TRON 账户应显示程序给出的地址；
5. 先用小额资产验证收款与转出。

地址不一致时不要转入资产。请确认单词顺序、空 passphrase 和默认 TRON 账户路径都正确。

## 数据与备份

- 本机历史中的助记词由当前 Windows 用户的 DPAPI 加密；
- 助记词复制后 30 秒自动清除剪贴板，前提是内容未被其他程序覆盖；
- TXT 导出包含明文助记词和派生路径，只应保存到可信离线位置；
- 可选 AES-256-CBC + HMAC-SHA256 密文备份保存地址、助记词和派生路径；
- 心跳只包含状态、速度、尝试次数、错误和公开地址，不包含助记词或 AES 密钥。

下载 `.trxv` 后可在本机解密：

```powershell
.\TRXVanityWindows\build\TRXVanityBackupDecrypt.exe <文件.trxv>
```

macOS / Linux / Windows 也可以使用仓库里的 `AES-Decrypt/decrypt.py`。服务端部署说明见 `EncryptedBackupServer/README.md`。断连告警由邮件服务器用宝塔或 crontab 每分钟跑 `check-heartbeats.php`，没有 WebCron。

AES 密钥丢失后服务器无法恢复内容。

## 性能与安全

当前 RTX 4090（450 W）长时间满载实测约 `1.46 × 10^6` 个完整助记词候选/秒；驱动、温度、功耗和后台 GPU 使用会造成波动。每个候选都必须执行 2048 轮 PBKDF2 和 5 层 BIP32，因此不能达到仅枚举私钥的十亿级速度。

后缀支持 1–10 位 TRON Base58 字符；`0`、`O`、`I`、`l` 不属于 Base58。平均候选数近似为 `58^n`：

| 后缀长度 | 平均候选数 |  4090 约需时间 |
|---:|---:|---:|
| 1 | 58 | 小于 1 秒 |
| 2 | 3,364 | 小于 1 秒 |
| 3 | 195,112 | 0.13 秒 |
| 4 | 11,316,496 | 8 秒 |
| 5 | 656,356,768 | 7.5 分钟 |
| 6 | 38,068,692,544 | 7.2 小时 |
| 7 | 2,207,984,167,552 | 17.5 天 |
| 8 | 128,063,081,718,016 | 2.8 年 |

这些是概率平均值，不是完成期限。助记词等同于钱包控制权，不要截图、发送到聊天软件或保存到自动同步网盘。靓号条件也会缩小有效密钥集合，长后缀应谨慎用于高价值资产。

CUDA PBKDF2 代码来自 Apache-2.0 的 `XopMC/CUDA_Mnemonic_Recovery`；CPU 加速使用 Apache-2.0 的 OpenSSL；CPU 曲线实现使用 MIT 的 `bitcoin-core/libsecp256k1`。许可证见发布目录 `ThirdPartyLicenses/`。
