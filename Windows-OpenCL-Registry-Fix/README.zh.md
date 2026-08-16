# TRX Vanity OpenCL 注册表修复

[English](README.md)

部分云主机厂商未配置 OpenCL 注册表。在运行 Windows EXE 收到相关提示时，可使用此脚本修复。

## 自动修复注册表

1. 打开本文件所在的文件夹。
2. 右键选择「在终端中打开」，或以管理员身份打开 Windows PowerShell。
3. 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\OpenCL-Registry-Fix.ps1"
```

脚本在没有管理员权限时会请求提升。修复完成后不需要重启 Windows，关闭并重新打开 TRXVanity 即可。

## 脚本修复内容

脚本不会写死 NVIDIA 驱动版本，而是先从当前 NVIDIA 显卡驱动注册项读取 `OpenCLDriverName` 和 `OpenCLDriverNameWow`，然后创建或更新：

```text
HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors
HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Khronos\OpenCL\Vendors
```

值名称是当前 `nvopencl64.dll` / `nvopencl32.dll` 的完整路径，值类型为 `REG_DWORD`，数据为 `0`。

如果脚本提示找不到 NVIDIA OpenCL 驱动文件，需要先在本机重新安装 NVIDIA 显卡驱动，不能从其他机器复制 DLL 代替。
