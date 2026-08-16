# TRX Vanity for Windows

[English](README.md)

适用于 Windows 10/11 x64 的 GPU 强制版 TRON 靓号生成器。

## 特性

- 强制使用 NVIDIA OpenCL GPU；没有硬件 GPU 时直接报错，不降级到 CPU 搜索。
- 界面按当前显示器 DPI 显式缩放，适配 Windows 125%–300% 显示缩放；小屏幕会启用滚动，监控数值不会因字体缩放而被裁切。
- TRON 主网地址前缀固定为 `T`，界面仅允许自定义地址后缀。
- 后缀支持 1–10 位，可使用完整 TRON Base58 字符：`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`。
- GPU 使用 Profanity2 的高吞吐批量模逆/曲线点步进核心；TRON 地址路径为 `secp256k1 → Keccak-256 → 0x41 → 双 SHA-256 → Base58Check`。
- 随机私钥基值由 Windows `BCryptGenRandom` 生成并始终留在 CPU 内存。GPU 只接收公开曲线点与公开偏移量。
- 命中后使用仓库内的 `libsecp256k1` 和独立 CPU 地址实现重新计算；复验失败时绝不显示私钥。
- 历史私钥使用当前 Windows 用户的 DPAPI 加密，保存在 `%LOCALAPPDATA%\TRXVanity\history.dat`。
- 私钥复制后 30 秒自动清除剪贴板（仅当剪贴板内容仍未被覆盖）。
- 用户主动导出的 TXT 包含明文私钥，并尽可能把 NTFS ACL 限制为当前用户。
- 可选 AES-256 密文备份与服务器状态心跳；填写上传地址和自己的 64 位 HEX 密钥并点击应用后自动启用。命中结果在客户端加密后上传，心跳只包含运行状态、速度、尝试次数、错误和命中的公开地址，不包含私钥或 AES 密钥。
- 无遥测或自动更新代码；用户未应用服务器地址和 AES 密钥时，不发送心跳或密文备份。

## 构建环境

- Visual Studio 2022 Build Tools，包含 `Microsoft.VisualStudio.Workload.VCTools`
- NVIDIA 显卡驱动（提供 OpenCL GPU 运行时；无需安装完整 CUDA Toolkit）
- .NET Framework 4.8（本机已有）

在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1
```

脚本会编译 Release x64 引擎和桌面界面，并运行 CPU 密码学向量与真实 GPU 命中/私钥恢复自检。产物位于：

```text
TRXVanityWindows\dist\TRXVanity.exe
```

默认生成兼容 Windows 11 x64 CPU 的版本。本机支持 AVX2 时可额外构建独立优化版本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -Clean -CpuTarget AVX2 -OutputName dist-avx2
```

普通构建使用较小 GPU 批次完成快速但完整的命中自检；若要用生产批量执行自检，可加 `-FullGpuSelfTest`。

跳过自检（仅用于开发时加快重复编译）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -SkipTests
```

清理并重建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -Clean
```

## 运行

双击 `dist\TRXVanity.exe`。首次启动会由 OpenCL 驱动编译内核，并按 GPU 计算单元与显存自动选择批量、初始化公开曲线点；编译结果会缓存到 `%LOCALAPPDATA%\TRXVanity\OpenCLCache`，后续启动会更快。

### 可选 AES 密文备份

1. 在“命中结果”区域点击 `AES 备份：关`。
2. 填写完整的 HTTPS `upload.php` 地址，并输入用户自行保管的 64 位 HEX AES 密钥。
3. 点击应用后自动启用 AES 密文上传和每 15 秒一次的服务器状态心跳；设置仅保留到本次程序关闭。
4. 服务器可在心跳断联、搜索进度或速度异常、应用错误和搜索命中时发邮件，具体部署见 `EncryptedBackupServer/README.md`。
5. 从服务器下载密文后运行 `TRXVanityBackupDecrypt.exe <文件.trxv>`，按提示输入同一 AES 密钥；工具会在密文旁生成包含地址和私钥的 JSON。

PHP 服务端源码和部署说明位于仓库的 `EncryptedBackupServer/`。如果 AES 密钥丢失，服务器无法帮助恢复密文；解密后的 JSON 包含明文私钥，应只保存在可信位置。

为了让 GPU 保持稳定速度：

- 在显卡驱动设置中选择高性能电源策略；
- 关闭会大量占用 GPU 的游戏、渲染或 AI 任务；
- 长时间搜索时保证显卡散热；
- Windows WDDM 下桌面仍会共享少量 GPU 时间，这是正常行为。

## 性能说明

实际搜索速度取决于显卡型号、驱动版本、温度、功耗策略和后台 GPU 负载。停止请求会在当前 GPU 批次结束后响应。

当前 GPU 路径按后缀长度选择专用内核：短后缀使用 58³ 快速探针；6–8 位以上后缀利用 Base58Check 仅有 32 位校验和这一性质，在双 SHA-256 前无损排除不可能命中的线程；7 位和 8–10 位路径还会把批量求逆的反向展开与曲线步进、匹配融合，避免每个候选 64 字节的中间显存往返。命中结果仍全部经过 CPU 独立复验。

同一台 RTX 4090（驱动 610.47、450 W 功耗上限）上，10 位后缀无命中基准由约 `1.535 × 10^9` 次/秒提高到约 `2.282 × 10^9` 次/秒，提升约 48.6%；GPU 利用率约 99%。该数字仅用于说明本次优化幅度，不是其他机器的保证值。

批量通道数默认按 GPU 计算单元、单次分配上限和显存自动调整，三个持久字段缓冲合计最多使用 60% 显存；本机 RTX 4090 会选择 `133,693,440` 条通道（inverse-multiple `524288`）。直接运行引擎时仍可用 `--inverse-multiple` 覆盖。可用仓库内的重复测量脚本进行调优：

```powershell
.\TRXVanityWindows\tools\benchmark.ps1 `
  -Engine .\TRXVanityWindows\dist\trxvanity-gpu.exe `
  -WarmupSeconds 5 -SecondsPerRun 10 -Runs 5 `
  -OutputPath .\TRXVanityWindows\build\benchmark-final.json
```

脚本输出中位数、均值、离散度、GPU 功耗/温度/时钟及二进制哈希。手动批量可用 `-InverseMultiple` 测试；应以多轮中位数为准，并在改动内核后重新运行完整自检。

CPU 不默认参与并行搜号：在本机测得的完整 CPU 管线预计只贡献约 1–2%，同时可能抢占 OpenCL 驱动线程并降低总吞吐。CPU 保留给随机基值、命中恢复和独立密码学复验，这比单纯追求 CPU 占用率更有利于总速度和安全性。

## 安全说明

靓号条件会缩小符合条件的密钥集合。请先用小额资产验证导入、转入、转出流程；大额资产优先使用经过审计的硬件钱包或多签方案。标准 BIP-39 助记词不是把此处生成的 32 字节私钥直接编码成单词，二者不可混用。

GPU 数学核心派生自 [1inch/profanity2](https://github.com/1inch/profanity2)，MIT；CPU 曲线实现使用 bitcoin-core/libsecp256k1，MIT。许可证见 `ThirdPartyLicenses/`。
