# TRX Vanity OpenCL Registry Fix

[中文说明](README.zh.md)

Some cloud GPU hosts do not register the NVIDIA OpenCL ICD. If the Windows EXE reports a missing OpenCL vendor, run this script to repair the registry.

## Repair the registry

1. Open the folder that contains this file.
2. Right-click and choose **Open in Terminal**, or open Windows PowerShell as Administrator.
3. Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\OpenCL-Registry-Fix.ps1"
```

The script requests Administrator rights if it is not already elevated. After it finishes, you do not need to restart Windows. Close and reopen TRXVanity.

## What the script changes

The script does not hard-code an NVIDIA driver version. It reads `OpenCLDriverName` and `OpenCLDriverNameWow` from the current NVIDIA display adapter, then creates or updates:

```text
HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\OpenCL\Vendors
HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Khronos\OpenCL\Vendors
```

Each value name is the full path of the current `nvopencl64.dll` / `nvopencl32.dll`. The value type is `REG_DWORD`, and the data is `0`.

If the script reports that the NVIDIA OpenCL driver files are missing, reinstall the NVIDIA GPU driver on this machine. Do not copy the DLLs from another computer.
