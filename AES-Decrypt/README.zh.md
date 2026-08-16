# TRX Vanity AES 备份解密

[English](README.md)

需要 **Python 3.8 或更新版本**。macOS、Windows、Linux 都用同一个 `decrypt.py`。

## 用法

先进入本目录，再运行：

```bash
# macOS / Linux
python3 decrypt.py

# Windows（推荐用 py 启动器）
py decrypt.py
```

按提示把 `.trxv` 文件拖进窗口，或输入完整路径，回车。再输入 64 位十六进制 AES 密钥（输入时不会显示），回车。

也可以直接带上文件路径：

```bash
# macOS / Linux
python3 decrypt.py /path/to/backup.trxv

# Windows
py decrypt.py C:\path\to\backup.trxv
```

解密成功后会显示地址、尾号、派生路径、创建时间和助记词。

## 注意

- AES 密钥必须正好是 64 个 `0-9` / `a-f` / `A-F` 字符。
- 密钥错误或文件被改过，会提示认证失败。
- 不要截图、不要复制到聊天软件、不要存到联网云盘。
- 看完后关掉终端，并清理滚动记录。
