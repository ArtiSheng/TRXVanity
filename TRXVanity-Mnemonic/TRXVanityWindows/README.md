# TRX Vanity for Windows — TronLink Mnemonic Edition

[中文说明](README.zh.md)

This is an NVIDIA CUDA TRON suffix vanity generator for Windows 10/11 x64. Every candidate is a valid 12-word BIP39 English mnemonic. The BIP39 passphrase is empty, and the path is the TronLink/TRON default:

```text
m/44'/195'/0'/0/0
```

## How it works

1. Windows `BCryptGenRandom` creates independent 128-bit entropy bases for the GPU and CPU.
2. CUDA runs BIP39, 2048 rounds of PBKDF2-HMAC-SHA512, fixed-path BIP32, TRON Base58Check, and suffix matching for each candidate.
3. Lower-priority OpenSSL CPU workers search another candidate range at the same time and do not block the CUDA control thread.
4. After either path hits, an independent CPU implementation recomputes the address from the entropy and mnemonic, and only then is the result shown.

Ordinary GPU candidates are not copied back to the host. In the address-derivation stage each CUDA thread handles four candidates and uses batched finite-field inversion to reduce secp256k1 cost. The BIP32 master key uses a precomputed HMAC state for the fixed `Bitcoin seed` label; the result matches the standard algorithm exactly.

## Three run profiles

- `rtx5070` — **RTX 5070 profile**: RTX 5070 only. Uses 256/256 staged thread blocks and automatic batching.
- `rtx4090` — **RTX 4090 profile**: RTX 4090 only. Uses the fastest measured PBKDF2 256 / address 384 thread blocks, dual CUDA streams, and automatic batching.
- `smart` — **smart fastest (any RTX)**: Measures occupancy of the two CUDA kernels separately, then picks a safe capacity and batch from SM count and free VRAM. The GUI uses this profile by default.

All three profiles use every logical CPU thread, but CPU workers stay below normal priority so CUDA submit/reclaim threads go first.

Command-line debug flags:

```text
--profile rtx5070|rtx4090|smart
--batch-size <max candidates>
--cpu-workers <0–256>
--cuda-block-size <multiple of 32 from 32–1024, comparison tests only>
```

Dedicated profiles check the GPU model. Use `smart` if the model does not match. Manual flags are only for repeated measurements; the default staged parameters are usually faster.

## GPU compatibility and build

The build machine needs:

- Visual Studio 2022 Build Tools (MSVC x64) and the Windows 10/11 SDK
- NVIDIA CUDA Toolkit 12.6 or later
- .NET Framework 4.8
- The bundled OpenSSL CPU acceleration DLL in this repository

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\build.ps1 -Clean
```

The build script embeds native code for `sm_75`, `sm_86`, and `sm_89` (RTX 20/30/40). If the toolkit supports `sm_120`, RTX 50 native code is added automatically; otherwise `compute_89` PTX is embedded for JIT on RTX 50 drivers. The run machine only needs an NVIDIA driver, not the CUDA Toolkit.

Output:

```text
TRXVanityWindows\build\TRXVanity.exe
```

The same directory also has `trxvanity-gpu.exe`, `TRXVanityBackupDecrypt.exe`, `libcrypto-3-x64.dll`, `bip39-english.txt`, and licenses. Intermediate `.obj` files are in `build\obj`.

Run the full self-test alone:

```powershell
.\TRXVanityWindows\build\trxvanity-gpu.exe --self-test --batch-size 128
```

Repeat console benchmarks (console only, no report file):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TRXVanityWindows\tools\benchmark.ps1 `
  -Profile rtx4090 -WarmupSeconds 5 -SecondsPerRun 15 -Runs 3
```

Build self-tests include the BIP39 all-zero entropy vector, TronLink address vectors, GPU/CPU master-key cross-checks, four-candidate batched-inversion address checks, and AES backup tamper detection.

## Import into TronLink

1. Reveal and copy the 12 English words in the result area.
2. In TronLink, choose import mnemonic.
3. Paste them in the original order. Do not set an extra BIP39 passphrase.
4. The first TRON account should show the address from the program.
5. Verify receive and send with a small amount first.

Do not send funds if the address does not match. Confirm word order, an empty passphrase, and the default TRON account path.

## Data and backups

- Mnemonics in local history are encrypted with DPAPI for the current Windows user.
- After a mnemonic is copied, the clipboard is cleared in 30 seconds if another program has not overwritten it.
- TXT export contains the plaintext mnemonic and derivation path. Store it only in a trusted offline place.
- Optional AES-256-CBC + HMAC-SHA256 ciphertext backups store the address, mnemonic, and derivation path.
- Heartbeats include only status, speed, attempt count, errors, and public addresses. They do not include the mnemonic or AES key.

Decrypt a downloaded `.trxv` locally:

```powershell
.\TRXVanityWindows\build\TRXVanityBackupDecrypt.exe <file.trxv>
```

macOS / Linux / Windows can also use `AES-Decrypt/decrypt.py` in this repository. Server deploy notes are in `EncryptedBackupServer/README.md`. Disconnect alerts are sent by running `check-heartbeats.php` every minute with BaoTa or crontab. There is no WebCron.

If the AES key is lost, the server cannot recover the contents.

## Performance and security

A current RTX 4090 (450 W) measures about `1.46 × 10^6` full mnemonic candidates/sec under long full-load runs. Driver, temperature, power, and other GPU use will change this. Every candidate must run 2048 rounds of PBKDF2 and 5 BIP32 layers, so this cannot reach the billion-scale speed of raw private-key search.

Suffixes may be 1–10 TRON Base58 characters. `0`, `O`, `I`, and `l` are not Base58. The average candidate count is about `58^n`:

| Suffix length | Average candidates | Approx. time on 4090 |
|---:|---:|---:|
| 1 | 58 | under 1 second |
| 2 | 3,364 | under 1 second |
| 3 | 195,112 | 0.13 seconds |
| 4 | 11,316,496 | 8 seconds |
| 5 | 656,356,768 | 7.5 minutes |
| 6 | 38,068,692,544 | 7.2 hours |
| 7 | 2,207,984,167,552 | 17.5 days |
| 8 | 128,063,081,718,016 | 2.8 years |

These are probability averages, not deadlines. A mnemonic is wallet control. Do not screenshot it, send it in chat, or save it to a syncing cloud drive. A vanity condition also shrinks the valid key set. Use long suffixes carefully for high-value funds.

CUDA PBKDF2 code comes from Apache-2.0 `XopMC/CUDA_Mnemonic_Recovery`. CPU acceleration uses Apache-2.0 OpenSSL. The CPU curve implementation uses MIT `bitcoin-core/libsecp256k1`. Licenses are in the release `ThirdPartyLicenses/` directory.
