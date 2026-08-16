# TRX Vanity 助记词版

[English](README.md)

和私钥版一样搜 TRON 后缀靓号，但每个候选是标准 12 词 BIP39 英文助记词，passphrase 为空，派生路径固定：

```text
m/44'/195'/0'/0/0
```

可直接导入 TronLink。私钥版枚举私钥，速度快；本版每个候选都要走 2048 轮 PBKDF2 和 BIP32，慢几个数量级。

## 目录

| 目录 | 做什么 |
|---|---|
| `TRXVanityLinux` | Linux/CUDA 服务器搜索。本机跑 `deploy.sh` 部署到 GPU 机器并开搜。 |
| `TRXVanityWindows` | Windows 图形界面，本机 NVIDIA 卡上搜。 |
| `MACGUI` | macOS 多机监控，看多台 Linux 机器的速度和状态。 |
| `EncryptedBackupServer` | PHP 站点：收 `.trxv` 密文、心跳、断连邮件。服务器不解密。 |
| `AES-Decrypt` | 本机用同一把 AES 密钥解开 `.trxv`，看出助记词。 |
| `Vendor` | 引擎用到的第三方 CUDA BIP39 / secp256k1 源码。 |
| `ThirdPartyLicenses` | 第三方许可证。 |
| `本地私密备份` | 本机真实服务器配置备份（令牌、邮箱密码）。不要提交、不要上传。 |

各目录的用法看各自的 `README.md` / `README.zh.md`。

## 正式编译 Mac 监控

不要用 Debug。在 `MACGUI` 目录执行：

```bash
xcodebuild -project TRXVanityMonitor.xcodeproj \
  -scheme TRXVanityMonitor \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

完成后打开 `build/TRX Vanity Monitor.app`。
