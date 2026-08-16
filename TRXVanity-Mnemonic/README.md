# TRX Vanity Mnemonic Edition

[中文说明](README.zh.md)

This edition searches for TRON vanity suffixes the same way as the private-key edition, but every candidate is a standard 12-word BIP39 English mnemonic. The passphrase is empty, and the derivation path is fixed:

```text
m/44'/195'/0'/0/0
```

The result can be imported into TronLink. The private-key edition enumerates raw keys and is much faster. This edition must run 2048 rounds of PBKDF2 and BIP32 for every candidate, so it is several orders of magnitude slower.

## Directories

| Directory | Purpose |
|---|---|
| `TRXVanityLinux` | Linux/CUDA server search. Run `deploy.sh` locally to deploy to a GPU host and start searching. |
| `TRXVanityWindows` | Windows GUI for searching on a local NVIDIA GPU. |
| `MACGUI` | macOS multi-host monitor for speed and status of Linux machines. |
| `EncryptedBackupServer` | PHP site that receives `.trxv` ciphertext, heartbeats, and disconnect emails. The server never decrypts. |
| `AES-Decrypt` | Local tool that uses the same AES key to open a `.trxv` file and show the mnemonic. |
| `Vendor` | Third-party CUDA BIP39 / secp256k1 sources used by the engine. |
| `ThirdPartyLicenses` | Third-party licenses. |
| `本地私密备份` | Local backup of real server config (tokens, mailbox password). Do not commit or upload. |

See each directory’s `README.md` / `README.zh.md` for usage.

## Release build of the Mac monitor

Do not use Debug. In the `MACGUI` directory run:

```bash
xcodebuild -project TRXVanityMonitor.xcodeproj \
  -scheme TRXVanityMonitor \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

Then open `build/TRX Vanity Monitor.app`.
