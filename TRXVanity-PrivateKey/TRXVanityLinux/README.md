# TRX Vanity Linux (Split-Key Edition)

[中文说明](README.zh.md)

The client generates a base private key and sends only the public key and suffix to the Linux GPU server. The server returns only the public increment `t`. The client then combines and re-verifies the final private key.

Only **1–10 character, case-sensitive** TRON Base58 suffixes are supported:

```text
123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
```

There is no `0`, `I`, `O`, or `l`. Prefixes are not supported. Every job must run `prepare` again. One base private key can produce only one result.

---

## Quick start

The client is a zero-dependency Python 3 script that runs on macOS, Linux, and Windows. It generates and combines private keys. The server needs Ubuntu x86_64 and an NVIDIA GPU for the public search.

On Windows, replace `python3` below with `py -3`.

### 1. Check the client

```bash
cd TRXVanityLinux
python3 client/trxvanity_client.py --self-test
```

Or run `./tools/build-client.sh`. The effect is the same.

### 2. Build the server

Dependencies: `build-essential cmake ocl-icd-opencl-dev`, plus an NVIDIA driver. A full CUDA Toolkit is not required.

To deploy only the public search side without uploading client source, package first:

```bash
./tools/package-server-source.sh /tmp/trxvanity-linux-server-source.tgz
```

On the GPU host:

```bash
cd TRXVanityLinux
./tools/build-server.sh
```

Output: `build-linux/bin/trxvanity-linux-gpu` and `kernels/` in the same directory.

### 3. Create a job

The output paths must not already exist. Extensions must be `.secret` / `.request`.

```bash
python3 client/trxvanity_client.py prepare \
  --suffix Az1 \
  --secret job.secret \
  --request job.request
```

- `job.secret`: contains the base private key. Do not send it to the server. Mode is `0600` on POSIX. Windows tries to restrict it to the current user.
- `job.request`: job ID, public key, and suffix. This can go to the server.

### 4. Search

The server uses only `job.request`:

```bash
set -o pipefail
./build-linux/bin/trxvanity-linux-gpu --request job.request | tee job.result
```

`Ctrl-C` waits for the current GPU batch to finish. Use `screen` for long runs.

### 5. Combine the wallet

Bring `job.result` back to the client:

```bash
python3 client/trxvanity_client.py finalize \
  --secret job.secret \
  --result job.result \
  --output wallet.wallet
```

After re-verification, `wallet.wallet` is written. The private key is not printed to the terminal. On success, `job.secret` becomes `job.secret.consumed` and cannot be reused.

Do not treat the GPU host as a wallet. Keep `wallet.wallet` only in the trusted environment that runs the client, and verify import and send with a small amount first.

---

## Commands and flags

### Client

Needs Python 3.8+ and no third-party packages.

```text
python3 client/trxvanity_client.py prepare  --suffix TEXT --secret FILE --request FILE
python3 client/trxvanity_client.py finalize --secret FILE --result FILE --output FILE
python3 client/trxvanity_client.py --self-test
```

| Flag | Command | Meaning |
|---|---|---|
| `--suffix` | prepare | 1–10 character Base58 suffix |
| `--secret` | both | `.secret` file |
| `--request` | prepare | `.request` file |
| `--result` | finalize | server output; extension must be `.result` |
| `--output` | finalize | new `.wallet` file; overwrite is refused |

### Server

```text
trxvanity-linux-gpu --request FILE [--inverse-multiple N] [--max-batches N]
trxvanity-linux-gpu --self-test [--inverse-multiple N]
```

| Flag | Default | Meaning |
|---|---|---|
| `--request` | required | file from client `prepare` |
| `--inverse-multiple` | auto | GPU batch multiple, `lanes = 255 × N`. Auto picks from compute units and VRAM, minimum `16384`. A manual value must be a multiple of 128 |
| `--max-batches` | unlimited | stop after N batches with no hit |
| `--self-test` | — | GPU self-test; cannot be used with `--request` |

Production search usually needs no extra flags. Add `--max-batches` to cap runtime.

Exit codes: `0` hit or self-test passed; `1` request/GPU/re-verify failed; `2` bad arguments; `3` aborted or batches exhausted.

---

## Dashboard (optional)

The dashboard listens only on `127.0.0.1`. It reads GPU status and hit results over read-only SSH. It does not read `.secret` / `.wallet`.

Fill in `dashboard/state/config.json` first (the repo values are examples):

```json
{
  "host": "gpu.example.com",
  "port": 22,
  "user": "demo",
  "identity_file": "/absolute/path/to/dashboard/state/monitor_ed25519",
  "known_hosts_file": "/absolute/path/to/dashboard/state/known_hosts",
  "result_directory": "/absolute/path/to/TRXVanityLinux/local-jobs",
  "poll_interval_seconds": 2
}
```

Put SSH keys in gitignored `dashboard/state/`. Then:

```bash
./tools/start-dashboard.sh              # default http://127.0.0.1:8787/
./tools/start-dashboard.sh --port 9000
./tools/start-dashboard.sh --no-open
./tools/stop-dashboard.sh
```

`start-dashboard.sh` is for the current macOS login session only. It does not install a login item. Closing the browser or a brief network drop does not stop the service. After reboot, logout, or a manual stop, start it again. The running copy and fetched `.result` files live in `~/Library/Application Support/TRXVanityDashboard/`.

---

## Security model

```text
Client                                GPU server
Generate base key b
Compute P = bG
Save b (0600)         ──send only──>  P, job ID, suffix
                                      Search Q = P + tG
Final key x = b+t     <──return only── address, public increment t
Client re-derives the address and checks it
```

The server has no argument or file field that accepts a private key. A host admin can see the job and forge a result. Forgery is rejected by client re-verification, but denial of service cannot be prevented. This design protects private-key confidentiality. It does not hide the search job itself.

Do not edit `.request` and then search multiple addresses with the same `BASE_PUBLIC`.

---

## Other notes

- Layout: `client/trxvanity_client.py` generates and combines keys on any platform; `server/` is the public search; `common/` is encode/decode and matching; `kernels/` is OpenCL; `../Vendor/secp256k1/` is the server curve library.
- If a slim CUDA container is missing an ICD, the program sets process-level `OCL_ICD_FILENAMES=libnvidia-opencl.so.1` and does not change system config.
- Re-run GPU self-test / audit alone:

```bash
./build-linux/bin/trxvanity-linux-gpu --self-test --inverse-multiple 16384
./tools/security-audit.sh ./build-linux/bin/trxvanity-linux-gpu
```
