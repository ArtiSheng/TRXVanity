# TRX Vanity for macOS

[中文说明](README.zh.md)

A native macOS TRON (TRX) vanity address generator. It searches in parallel on the local GPU with SwiftUI + Metal. After a hit, the CPU independently re-derives the address and shows the private key only if that check passes.

## Features

- Prefix digits match starting at the 3rd character of the TRON address
- Suffix matches the end of the address exactly
- Prefix and suffix each support 1–10 characters and can be enabled together
- Three GPU profiles: saver, balanced, and fastest
- Falls back to native CPU concurrency when Metal is unavailable
- Results include a 34-character TRON address and a 64-character HEX private key
- The private key is hidden by default. After copy, the clipboard is cleared in 30 seconds
- After CPU re-verification, the result is saved to local history. The private key goes into the macOS Keychain separately
- History supports hidden view, copy address/key, and export or delete of one or all items
- The user can export a local TXT file with mode `0600`

The Base58 alphabet has no digit `0`, so numeric conditions allow only `1–9`.
A 10-character Base58 suffix modulus is `58^10 = 430804206899405824`, which fits in `UInt64`.
Prefix and suffix can both be set to 10, but each extra character multiplies the theoretical average search by about 58. Long conditions may not finish in a practical time on current hardware.
The app defaults to the fastest profile. For formal benchmarks, run a Release build and keep “最快” selected. Debug numbers are not final performance.

## Measured performance

On a 10-core Apple M5 GPU, Release + fastest profile, counted by candidates the GPU actually finished:

- Prefix only: about `64.77 M/s`
- Suffix only: about `54.66 M/s`
- Prefix and suffix: about `62.61 M/s`

Suffix mode is a bit slower because more candidates need a Base58Check checksum and modulo. These numbers are from this machine. Other Macs will change with GPU model, temperature, and background load. Even at this speed, a single-side 10-character condition still averages centuries. Prefix 10 + suffix 10 is not realistically completable.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 13.0 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (only when regenerating the project file)

The repo already includes `TRXVanity.xcodeproj`. Day-to-day use can open it in Xcode. Node.js and Rust are not required.

## Legacy web archive

The old web app is kept as source files in `LegacyWebArchive/` and is not part of the native app build or run:

- `LegacyWebArchive/app/page.tsx`: old page structure (JSX/HTML)
- `LegacyWebArchive/app/layout.tsx`: old HTML outer layout
- `LegacyWebArchive/app/globals.css`: old full CSS

Old workers, web crypto, and historical build config are also in that archive, for reference only.

## Build

```bash
xcodegen generate --spec project.yml

xcodebuild \
  -project TRXVanity.xcodeproj \
  -scheme TRXVanity \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The app is at:

```text
.build/DerivedData/Build/Products/Release/TRX Vanity.app
```

## Tests

```bash
xcodebuild \
  -project TRXVanity.xcodeproj \
  -scheme TRXVanity \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Tests cover known secp256k1/Keccak/Base58 vectors, prefix/suffix match ranges, the CPU fallback, and CPU re-verification after live Metal hits for prefix-only, suffix-only, and combined conditions.

## Key security

- Random secret scalars come from `SecRandomCopyBytes`.
- Metal starts from a random base point and advances in parallel with an affine window of fixed generators `G...1024G` and batched inversion.
- The GPU receives only public curve points, match conditions, and indexes. The random private-key base never enters an `MTLBuffer`.
- App Sandbox does not request network access. There is no telemetry or upload code.
- CPU-verified results are saved locally: the private key uses a `WhenUnlockedThisDeviceOnly` Keychain item and does not sync to iCloud. Address, time, and match conditions go to the App Sandbox Application Support directory and do not include the private key.
- Deleting in-app history does not delete TXT files you already exported. Those TXT files contain plaintext private keys. Move them to a safe offline place.

A vanity condition shrinks the matching key set. Verify import, receive, and send with a small amount first. Prefer an audited hardware wallet for large funds.

## Mnemonic compatibility

This version searches independent 256-bit private keys and outputs those keys. It does not output a mnemonic. Do not give a hit private key to a “private key to mnemonic” tool: a standard BIP-39 mnemonic is not these 32-byte keys encoded as words. Do not mix the two.
