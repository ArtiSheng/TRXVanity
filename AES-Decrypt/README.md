# TRX Vanity AES Backup Decrypt

[中文说明](README.zh.md)

Requires **Python 3.8 or later**. macOS, Windows, and Linux all use the same `decrypt.py`.

## Usage

Change into this directory, then run:

```bash
# macOS / Linux
python3 decrypt.py

# Windows (use the py launcher)
py decrypt.py
```

When prompted, drag the `.trxv` file into the window or type the full path, then press Enter. Enter the 64-character hexadecimal AES key (it will not be shown), then press Enter.

You can also pass the file path directly:

```bash
# macOS / Linux
python3 decrypt.py /path/to/backup.trxv

# Windows
py decrypt.py C:\path\to\backup.trxv
```

A successful decrypt prints the address, suffix, derivation path, creation time, and mnemonic.

## Notes

- The AES key must be exactly 64 characters from `0-9` / `a-f` / `A-F`.
- A wrong key or a modified file produces an authentication failure.
- Do not screenshot the output, copy it into chat apps, or store it on a networked cloud drive.
- After you finish, close the terminal and clear the scrollback.
