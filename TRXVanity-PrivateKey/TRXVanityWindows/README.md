# TRX Vanity for Windows

[中文说明](README.zh.md)

A GPU-required TRON vanity generator for Windows 10/11 x64.

## Features

- Requires an NVIDIA OpenCL GPU. Without a hardware GPU it errors out and does not fall back to CPU search.
- The UI scales from the current display DPI and supports Windows 125%–300% scaling. Small screens enable scrolling so monitor values are not clipped when fonts grow.
- The TRON mainnet prefix is fixed as `T`. The UI only lets you set the address suffix.
- Suffixes may be 1–10 characters from the full TRON Base58 alphabet: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`.
- The GPU uses Profanity2’s high-throughput batched inversion / curve-step core. The TRON address path is `secp256k1 → Keccak-256 → 0x41 → double SHA-256 → Base58Check`.
- The random private-key base is created by Windows `BCryptGenRandom` and stays in CPU memory. The GPU receives only public curve points and public offsets.
- After a hit, the in-repo `libsecp256k1` and an independent CPU address implementation recompute the result. The private key is never shown if re-verification fails.
- History private keys are encrypted with DPAPI for the current Windows user and stored in `%LOCALAPPDATA%\TRXVanity\history.dat`.
- After a private key is copied, the clipboard is cleared in 30 seconds if another program has not overwritten it.
- A user-exported TXT contains the plaintext private key. NTFS ACLs are restricted to the current user when possible.
- Optional AES-256 ciphertext backup and server status heartbeats. Enter an upload URL and your own 64-character HEX key, then click apply to enable them. Hits are encrypted on the client before upload. Heartbeats include only run state, speed, attempt count, errors, and hit public addresses. They do not include the private key or AES key.
- There is no telemetry or auto-update code. Heartbeats and ciphertext backups are not sent until the user applies a server URL and AES key.

## Build environment

- Visual Studio 2022 Build Tools with `Microsoft.VisualStudio.Workload.VCTools`
- NVIDIA GPU driver (provides the OpenCL GPU runtime; a full CUDA Toolkit is not required)
- .NET Framework 4.8 (already on the machine)

In PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1
```

The script compiles the Release x64 engine and desktop UI, then runs CPU crypto vectors and a real GPU hit / private-key recovery self-test. Output:

```text
TRXVanityWindows\dist\TRXVanity.exe
```

The default build targets a Windows 11 x64 CPU. If this machine supports AVX2, you can also build a separate optimized copy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -Clean -CpuTarget AVX2 -OutputName dist-avx2
```

A normal build uses a smaller GPU batch for a fast but complete hit self-test. Add `-FullGpuSelfTest` to self-test at production batch size.

Skip tests (only to speed up repeated compile during development):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -SkipTests
```

Clean and rebuild:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -Clean
```

## Run

Double-click `dist\TRXVanity.exe`. On first launch the OpenCL driver compiles the kernel, then picks a batch and initializes public curve points from GPU compute units and VRAM. The compile result is cached in `%LOCALAPPDATA%\TRXVanity\OpenCLCache`, so later launches are faster.

### Optional AES ciphertext backup

1. In the hit-result area, click `AES 备份：关`.
2. Enter the full HTTPS `upload.php` URL and a 64-character HEX AES key that you keep yourself.
3. Click apply to enable AES ciphertext upload and a server status heartbeat every 15 seconds. Settings last only until the program exits.
4. The server can email on heartbeat loss, stalled progress or speed, app errors, and search hits. Deploy notes are in `EncryptedBackupServer/README.md`.
5. After downloading ciphertext from the server, run `TRXVanityBackupDecrypt.exe <file.trxv>` and enter the same AES key. The tool writes a JSON file next to the ciphertext with the address and private key.

PHP server source and deploy notes are in `EncryptedBackupServer/` in this repository. If the AES key is lost, the server cannot recover the ciphertext. The decrypted JSON contains a plaintext private key and should be kept only in a trusted place.

To keep GPU speed stable:

- Choose a high-performance power plan in the GPU driver.
- Close games, render jobs, or AI work that use a lot of GPU.
- Keep the card cool on long searches.
- Under Windows WDDM the desktop still shares a little GPU time. That is normal.

## Performance

Real search speed depends on GPU model, driver, temperature, power policy, and other GPU load. A stop request is honored after the current GPU batch.

The current GPU path picks a dedicated kernel by suffix length. Short suffixes use a 58³ fast probe. Suffixes of 6–8 characters and longer use the fact that Base58Check has only a 32-bit checksum, and drop threads that cannot hit before the double SHA-256. The 7-character and 8–10-character paths also fuse reverse unrolling of batched inversion with curve stepping and matching, so each candidate avoids a 64-byte VRAM round trip. Every hit is still re-verified independently on the CPU.

On the same RTX 4090 (driver 610.47, 450 W power cap), a 10-character no-hit baseline went from about `1.535 × 10^9`/s to about `2.282 × 10^9`/s, about 48.6% faster, at about 99% GPU utilization. That number only describes this optimization. It is not a guarantee for other machines.

Batch lane count is chosen automatically from GPU compute units, per-allocation limits, and VRAM. The three persistent field buffers use at most 60% of VRAM. This RTX 4090 picks `133,693,440` lanes (inverse-multiple `524288`). You can still override with `--inverse-multiple` when running the engine directly. Tune with the in-repo repeat-measure script:

```powershell
.\TRXVanityWindows\tools\benchmark.ps1 `
  -Engine .\TRXVanityWindows\dist\trxvanity-gpu.exe `
  -WarmupSeconds 5 -SecondsPerRun 10 -Runs 5 `
  -OutputPath .\TRXVanityWindows\build\benchmark-final.json
```

The script prints median, mean, spread, GPU power/temperature/clock, and binary hashes. Test a manual batch with `-InverseMultiple`. Trust the multi-run median, and re-run the full self-test after kernel changes.

The CPU does not join parallel search by default. A full CPU pipeline on this machine would add only about 1–2% and can steal OpenCL driver threads, lowering total throughput. The CPU is kept for the random base, hit recovery, and independent crypto re-verification. That is better for total speed and safety than chasing CPU occupancy.

## Security

A vanity condition shrinks the matching key set. Verify import, receive, and send with a small amount first. Prefer an audited hardware wallet or multisig for large funds. A standard BIP-39 mnemonic is not these 32-byte private keys encoded as words. Do not mix the two.

The GPU math core is derived from [1inch/profanity2](https://github.com/1inch/profanity2), MIT. The CPU curve implementation uses bitcoin-core/libsecp256k1, MIT. Licenses are in `ThirdPartyLicenses/`.
