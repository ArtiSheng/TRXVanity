# TRX Vanity Linux Mnemonic Edition

[中文说明](README.zh.md)

This is the Linux/CUDA server edition. The engine uses standard 12-word BIP39 English mnemonics, an empty BIP39 passphrase, and the fixed TRON/TronLink path:

```text
m/44'/195'/0'/0/0
```

Linux must keep AES ciphertext upload on. After a hit, the address and mnemonic are assembled only in memory, then uploaded as `TRXMNEMO` AES-256-CBC + HMAC-SHA256 ciphertext. The mnemonic is not written to disk, logs, or `runtime/`. There is no “turn off upload and drop the result into a folder” path. If upload or round-trip verification fails, a formal search keeps the result in protected process memory and retries every 60 seconds until success or a manual stop.

You enter the AES key on the server yourself (64 hex characters). It is written to `/dev/shm/trxvanity-secrets.env`. Linux does not generate or download this key. Local decrypt of a `.trxv` file must use the same string. The key lives only on the ramdisk and disappears after reboot or formal cleanup. Any failed step does not authorize secure cleanup. Formal deploy path: `/root/autodl-tmp/TRXVanityLinux`.

## Quick start

The server needs Linux x86_64, an NVIDIA driver, CUDA Toolkit 12.8 or later, CMake, C/C++ build tools, OpenSSL 3 headers, and Python 3. On Ubuntu:

```bash
apt-get update
apt-get install -y build-essential cmake libssl-dev python3 rsync ca-certificates screen
```

Install deploy dependencies on your local machine first (Windows / macOS / Linux):

```bash
python3 -m pip install -r requirements-deploy.txt
```

On Windows without `python3`, use `py -3 -m pip install -r requirements-deploy.txt`. Then run from the `TRXVanityLinux` directory:

```bash
./deploy.sh
```

```powershell
.\deploy.ps1
```

Disconnect alerts on the mail server come from BaoTa running `check-heartbeats.php` every minute.

The script asks, in order, for: the search suffix (1–10 TRON Base58 characters, required), the AES key (64 hex characters, hidden input), an upload URL with token plus a connectivity test, and a delete URL with token plus a connectivity test. It then reminds you to schedule `check-heartbeats.php` every minute with BaoTa or crontab, waits 3 seconds, and asks for SSH. After login it takes the supervisor/search lock on that host, uploads source and `Vendor/`, checks SHA-256, compiles remotely, runs the engine self-test, and writes the AES key and upload URL only to that host’s `/dev/shm/trxvanity-secrets.env` (root, `0600`, gone after reboot). After the lock is released, each successfully deployed machine starts a formal search in the `screen` session `trxvanity-formal`. If a machine is already in formal search, auto-restart, or secure cleanup, that machine fails and the others continue. Do not put SSH passwords or AES keys in scripts.

Attach to a running search with `screen -r trxvanity-formal`. An SSH drop, or `Ctrl-A` then `D`, detaches; the search keeps running and does not need a restart. `run-formal.sh` relaunches the controller after 30 seconds if it fails briefly. Re-run the command below only after a reboot, after you closed screen, or after the `/dev/shm` key is gone:

```bash
screen -dmS trxvanity-formal bash -lc \
  'cd /root/autodl-tmp/TRXVanityLinux && exec ./run-formal.sh'
```

## Day-to-day operations

The monitor listens only on remote `127.0.0.1:8787` and is not exposed to the public internet. Open another local terminal and create a tunnel:

```bash
ssh -N -L 8787:127.0.0.1:8787 -p PORT root@YOUR_HOST
```

Open [http://127.0.0.1:8787/](http://127.0.0.1:8787/) in a browser. The page polls `/api/status` every 2 seconds and shows only speed, attempts, runtime, CPU quota/workers, CUDA batch and block size, upload/mail/cleanup status, and public addresses. It does not show the mnemonic, AES key, or a full upload URL with token.

The local aggregate page defaults to the RTX 5090 tunnel on `8787` and listens on `127.0.0.1:8790`:

```bash
cd TRXVanityLinux
python3 tools/multi_monitor.py
open http://127.0.0.1:8790/
```

You can pass `--machine 'name=http://127.0.0.1:local-tunnel-port'` more than once. The aggregate page shows total speed, running host count, total attempts, searched time, distance to 50%/100% work, current search percent, cumulative hit probability, and each host’s GPU, CPU quota, batch, block size, and heartbeat. 100% means one average workload of `58^suffix-length` is done. Hit probability is about 63.21% and is not a guarantee. The aggregate service forwards only allowlisted public performance fields.

Read-only terminal status:

```bash
cd /root/autodl-tmp/TRXVanityLinux
./status.sh
```

Stop the search: `screen -r trxvanity-formal`, then `Ctrl-C`. `Ctrl-A` then `D` only detaches. During cleanup, SIGTERM/SIGINT stop at the current write-block boundary, keep the signed authorization mark, and write status to `/run/trxvanity/cleanup-status.json`.

Startup scripts add that server’s `/root/miniconda3/bin` to PATH and also accept system `python3`, so non-interactive SSH and `screen` do not depend on Conda auto-activation.

Rebuild alone:

```bash
cd /root/autodl-tmp/TRXVanityLinux
./scripts/preflight-server.sh
./build-engine.sh --self-test
```

“Build succeeded”, “engine self-test succeeded”, and “live upload/mail succeeded” are three different verification levels.

## Appendix

### Sustained performance benchmark

`tools/benchmark.py` starts only `trxvanity-gpu` and measures through the engine’s stdin/stdout protocol. It does not start `controller.py`, read the AES key, or touch `runtime/`. The default suffix is a legal 10-character Base58 string that is extremely unlikely to hit. After a 30-second warmup it runs 3 rounds of 120 seconds each:

```bash
cd /root/autodl-tmp/TRXVanityLinux
python3 tools/benchmark.py \
  --engine ./build/trxvanity-gpu \
  --profile smart \
  --cpu-workers 8 \
  --warmup 30 --duration 120 --runs 3 \
  > benchmark-workers-8.json
```

Each round’s total/GPU/CPU steady speed is printed on the terminal (stderr). Full READY parameters, raw attempt counts, per-source speeds, and median/mean/stddev summaries go to stdout JSON. Fix other parameters for A/B tests with `--batch-size`, `--cuda-master-block-size`, `--cuda-address-block-size`, and `--suffix`:

```bash
python3 tools/benchmark.py \
  --cpu-workers 8 \
  --cuda-master-block-size 256 \
  --cuda-address-block-size 384
```

Formal `smart` mode does not need a manual CPU worker count. The engine checks both sched affinity and cgroup quota. Measured automatic gears use 8 threads for a 16-core quota and cap at 20 threads for 25-core and larger quotas, so a host-visible CPU count does not start 128/208 busy threads.

If you set only one staged block size, the other stage still uses the profile/device recommendation. The old `--cuda-block-size` remains as a shorthand that sets both stages. Do not mix it with the two staged flags. `--master-block-size` and `--address-block-size` are short aliases. On interrupt, the tool sends `STOP`, then `EXIT`, and only then kills the child after timeout.

CMake defaults to RTX 50 Blackwell `sm_120` cubin and PTX. Install the CUDA Toolkit from NVIDIA’s official repo or the cloud image already configured on the host. After the build, the runtime engine needs only `build/trxvanity-gpu` and `bip39-english.txt` in the same directory.

### Directories, keys, and formal-search constraints

Runtime always uses mixed mode: the AES key stays in `/dev/shm`, a hit mnemonic stays only in process memory that forbids dumps, and `/root/autodl-tmp` receives only public data such as attempt counts, speed, and monitor status. This works on a dedicated data disk, a shared filesystem, and overlay containers. Keys, mnemonics, and derived private keys are not written to files or logs on purpose.

Preflight and run scripts refuse to start while swap is still active:

```bash
swapoff -a
ulimit -c 0
```

Cloud-container swap policy is controlled by the provider. If the container cannot turn swap off, startup is not blocked. The process still disables core dumps and ordinary ptrace reads. That only lowers accidental disk-write risk. Python/OpenSSL/CUDA/driver and the cloud platform itself still cannot guarantee that a key never has a copy in RAM.

A formal 7-character hit is already rare, so a brief failure in upload, re-download, decrypt, or mail confirmation does not discard the result and restart the search. The controller keeps the result in a protected process with swap/core dump disabled and continues closed-loop verification every 60 seconds until success or a manual stop. The plaintext mnemonic is not written to disk for retries.

Formal search uses the suffix chosen at deploy time and locks the verified GPU engine, `smart` profile, upload endpoint, `127.0.0.1:8787` monitor address, and automatic cleanup entry. It rejects `--no-cleanup`, `--no-http`, and hand-edited batch size, CPU workers, CUDA block, or critical values in the environment file. The process holds the single-instance lock `/run/trxvanity/search.lock` across `exec` until runtime-file cleanup finishes. If there is no hit and no cleanup authorization, a brief driver, network, or controller fault restarts after 30 seconds. Initialization that does not enter search within 600 seconds is treated as stuck. After `SEARCHING`, 90 seconds without a complete, finite, batch-valid `PROGRESS` also restarts. Manual stop, a consumed key, or any cleanup mark prevents start or restart.

The average Base58 suffix candidate count is `58^N`. Real time is a probability distribution, not a guaranteed deadline. Billing, temperature, power, GPU model, and driver all change speed.

### Authorization and secure cleanup after a hit

Only a formal `run` that uses the deploy-time suffix, then completes upload, re-download, matching ciphertext hash, valid HMAC, successful AES decrypt, and matching plaintext fields, causes the controller to atomically write `runtime/cleanup-authorized.json`. The mark is root/`0600` and must contain:

- `reason=verified_upload_roundtrip`
- `target_suffix` equal to the formal suffix from deploy
- `verification.upload_success/download_hash_match/decrypt_match=true`
- the fixed runtime absolute path and current data-disk device number
- UUID job id, time, one-time nonce, and server ciphertext filename
- HMAC-SHA256 of the canonical JSON using the AES key

`secure_cleanup.py` re-checks all of the above, plus owner, mode, hard-link count, device number, and freshness. Creating a file with the same name is not enough to trigger cleanup.

After authorization, the controller stops the GPU, heartbeat, and local monitor, then `exec`s itself into the secure cleanup program. screen therefore keeps following the same process. Order:

1. Overwrite and unlink the `/dev/shm` key file.
2. Overwrite every regular file in `runtime/` at least 5 times, then `fsync`, truncate, and delete.
3. Consume the authorization mark and record completion.

After a hit and verified encrypted backup, cleanup replaces the process that held the mnemonic and overwrites/deletes the in-memory AES key and public runtime files.

If cleanup is aborted, the key tmpfs file is already gone, but the signed mark remains. On the server, recreate secrets with the same AES key and upload URL via `scripts/create-volatile-secrets.sh`, inspect `/run/trxvanity/cleanup-status.json`, then continue manually:

```bash
cd /root/autodl-tmp/TRXVanityLinux
./secure_cleanup.sh --execute --passes 5
```
