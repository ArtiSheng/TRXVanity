# TRX Vanity Linux 助记词版

[English](README.md)

这是 Linux/CUDA 服务器版。引擎使用标准 12 词 BIP39 英文助记词，BIP39 passphrase 为空，TRON/TronLink 派生路径固定为：

```text
m/44'/195'/0'/0/0
```

Linux 必须开启 AES 密文上传，不能关掉。命中后只在内存中组装地址与助记词，生成 `TRXMNEMO` AES-256-CBC + HMAC-SHA256 密文再上传；助记词不写磁盘、不写日志、不写 `runtime/`。没有「关闭上传后结果落到某个文件夹」这条路。上传或回环校验失败时，正式搜索会把结果留在受保护进程内存里每 60 秒重试，直到成功或人工停止。

AES 密钥要你在服务器上自己输入（64 位十六进制），写入 `/dev/shm/trxvanity-secrets.env`。Linux 不会生成或下载这把密钥。本机解密 `.trxv` 时必须用同一串；密钥只存在内存盘里，重启或正式收尾后会消失。任一步失败都不会授权安全收尾。正式部署路径：`/root/autodl-tmp/TRXVanityLinux`。

## 快速开始

服务器需要 Linux x86_64、NVIDIA 驱动、CUDA Toolkit 12.8 或更高版本、CMake、C/C++ 构建工具、OpenSSL 3 开发包及 Python 3。Ubuntu：

```bash
apt-get update
apt-get install -y build-essential cmake libssl-dev python3 rsync ca-certificates screen
```

本机先安装部署依赖（Windows / macOS / Linux 都可以）：

```bash
python3 -m pip install -r requirements-deploy.txt
```

Windows 没有 `python3` 时用 `py -3 -m pip install -r requirements-deploy.txt`。然后在 `TRXVanityLinux` 目录运行：

```bash
./deploy.sh
```

```powershell
.\deploy.ps1
```
邮件服务器的断连告警用宝塔每分钟跑 `check-heartbeats.php`。

脚本会按顺序问：搜索后缀（1–10 位 TRON Base58，必须自己输入）、AES 密钥（64 位十六进制，输入不显示）、带令牌的上传地址并做连通测试、带令牌的删除地址并做连通测试。然后提示务必在邮件服务器用宝塔或 crontab 设置每分钟 `check-heartbeats.php`，等待 3 秒后再问 SSH。连上后会独占该机的 supervisor/search 锁，上传源码和 `Vendor/`，核对 SHA-256，远程编译并做引擎自检，再把 AES 密钥和上传地址只写入该机 `/dev/shm/trxvanity-secrets.env`（root、`0600`，重启后消失）。锁释放后，每台成功部署的机器会自动用 `screen` 会话 `trxvanity-formal` 启动正式搜索。某台机器已经在正式搜索、自动重启或安全收尾时，那一台会失败，其他机器继续。不要把 SSH 密码或 AES 密钥写进脚本。

看正在跑的搜索：`screen -r trxvanity-formal`。SSH 断开或按 `Ctrl-A` 再按 `D` 脱离，搜索还在跑，不用重开。`run-formal.sh` 在控制器短暂故障时会 30 秒后自动拉起。机器重启、你关掉了 screen、或 `/dev/shm` 密钥没了，才需要再执行一次：

```bash
screen -dmS trxvanity-formal bash -lc \
  'cd /root/autodl-tmp/TRXVanityLinux && exec ./run-formal.sh'
```

## 日常运维

监控默认只监听远程 `127.0.0.1:8787`，不暴露到公网。本机另开终端建隧道：

```bash
ssh -N -L 8787:127.0.0.1:8787 -p 端口 root@你的主机
```

浏览器打开 [http://127.0.0.1:8787/](http://127.0.0.1:8787/)。页面每 2 秒请求 `/api/status`，只显示速度、尝试数、运行时间、CPU 配额/工作线程、CUDA 批次与线程块、上传/邮件/收尾状态和公开地址，不显示助记词、AES 密钥或带 token 的完整上传 URL。

本机聚合页默认只读 RTX 5090 隧道 `8787`，监听 `127.0.0.1:8790`：

```bash
cd TRXVanityLinux
python3 tools/multi_monitor.py
open http://127.0.0.1:8790/
```

可重复传入 `--machine '机器名=http://127.0.0.1:本地隧道端口'`。聚合页显示总速度、运行机器数、总尝试、已搜索时间、距离 50%/100% 工作量、当前搜索百分比和累计命中概率，以及每台机器的 GPU、CPU 配额、批次、线程块和心跳。100% 表示完成一份 `58^尾号长度` 的平均工作量，命中概率约 63.21%，不保证命中。聚合服务只转发白名单中的公开性能字段。

终端只读状态：

```bash
cd /root/autodl-tmp/TRXVanityLinux
./status.sh
```

停止搜索：`screen -r trxvanity-formal` 后按 `Ctrl-C`。按 `Ctrl-A` 再按 `D` 只是脱离，不是停止。收尾期间的 SIGTERM/SIGINT 会在当前写入块边界停止，保留签名授权标记，并把状态写到 `/run/trxvanity/cleanup-status.json`。

启动脚本会把该服务器的 `/root/miniconda3/bin` 加入 PATH，同时兼容系统 `python3`，因此非交互 SSH 和 `screen` 不依赖 shell 自动激活 Conda。

单独重新构建：

```bash
cd /root/autodl-tmp/TRXVanityLinux
./scripts/preflight-server.sh
./build-engine.sh --self-test
```

“构建成功”、“引擎自检成功”、“真实上传/邮件成功”是三种不同的验证层级。

## 附录

### 持续性能基准

`tools/benchmark.py` 只启动 `trxvanity-gpu` 并通过引擎的 stdin/stdout 协议测量；不启动 `controller.py`、不读取 AES 密钥，也不访问 `runtime/`。默认使用极难命中的合法 10 位 Base58 后缀，预热 30 秒后做 3 轮、每轮 120 秒：

```bash
cd /root/autodl-tmp/TRXVanityLinux
python3 tools/benchmark.py \
  --engine ./build/trxvanity-gpu \
  --profile smart \
  --cpu-workers 8 \
  --warmup 30 --duration 120 --runs 3 \
  > benchmark-workers-8.json
```

每轮的总/GPU/CPU 稳态速度显示在终端（stderr），完整 READY 参数、原始尝试数、分项速度及中位数/均值/标准差汇总写到 stdout JSON。可用 `--batch-size`、`--cuda-master-block-size`、`--cuda-address-block-size` 和 `--suffix` 固定其他参数做 A/B 测试：

```bash
python3 tools/benchmark.py \
  --cpu-workers 8 \
  --cuda-master-block-size 256 \
  --cuda-address-block-size 384
```

正式 `smart` 模式不需要手工传 CPU 线程数：引擎会同时检查 sched affinity 与 cgroup quota。已实测的自动档位是 16 核配额使用 8 线程、25 核及更大配额封顶 20 线程，避免再因宿主机可见 CPU 数而启动 128/208 个忙线程。

只设置其中一个时，另一阶段仍使用 profile/设备推荐值。旧的 `--cuda-block-size` 仍保留，作为同时设置两阶段的简写；不能和两个分阶段参数混用。工具同时保留 `--master-block-size` 和 `--address-block-size` 短别名。中断基准时，工具会先发送 `STOP`，然后发送 `EXIT`，超时后才终止子进程。

CMake 默认生成 RTX 50 Blackwell `sm_120` cubin 与 PTX。CUDA Toolkit 应使用 NVIDIA 官方源或云服务器已配置的 CUDA 镜像安装。构建完成后，运行时引擎仅依赖 `build/trxvanity-gpu` 及同目录的 `bip39-english.txt`。

### 目录、密钥与正式搜索约束

运行时一律使用混合模式：AES 密钥保留在 `/dev/shm`，命中助记词只保留在禁止 dump 的进程内存中，`/root/autodl-tmp` 只写入搜索次数、速度和监控状态等公开数据。适用于独立数据盘、共享文件系统和 overlay 容器。不主动向文件或日志写入密钥、助记词或派生私钥。

预检和运行脚本都会拒绝在 swap 仍活动时开始：

```bash
swapoff -a
ulimit -c 0
```

云容器宿主的 swap 策略由服务商控制，容器内无权关闭时不阻止启动。进程仍会关闭 core dump 并禁止普通 ptrace 读取。这只降低意外落盘风险；Python/OpenSSL/CUDA/驱动和云平台本身的内存实现仍无法给出“密钥从未在 RAM 中留存副本”的绝对保证。

正式七位命中已经很稀有，因此上传、回下载、解密或邮件确认遇到短暂故障时不会丢弃该结果并重新搜索；控制器会在禁用 swap/core dump 的受保护进程内保留结果，每 60 秒继续闭环验证，直到成功或人工停止。不会为重试把助记词明文写到磁盘。

正式搜索使用部署时选定的后缀，并固定已验证的 GPU 引擎、`smart` 计算方案、上传端点、`127.0.0.1:8787` 监控地址和自动清理入口；它拒绝 `--no-cleanup`、`--no-http` 以及手工改写批大小、CPU 线程数、CUDA block 或环境文件中的关键参数。进程持有 `/run/trxvanity/search.lock` 单实例锁，该锁会跨 `exec` 一直保留到运行文件清理结束。若未命中且没有清理授权，临时驱动、网络或控制器故障会在 30 秒后自动重启；初始化在 600 秒内未进入搜索会被判定为卡住，进入 `SEARCHING` 后 90 秒没有一条完整、有限且批次合法的 `PROGRESS` 也会重启。人工停止、密钥已消费或出现任何清理标记时不会启动或重启。

Base58 尾号的平均候选数是 `58^N`。实际时间是概率分布，不是保证时限；服务器计费、温度、功耗、GPU 型号和驱动都会影响速度。

### 命中后的授权与安全收尾

只有正式 `run` 使用部署时的正式后缀，并完成上传、重新下载、密文哈希一致、HMAC 正确、AES 解密成功且所有明文字段一致后，控制器才会原子写入 `runtime/cleanup-authorized.json`。标记是 root/`0600`，包含下列强制字段：

- `reason=verified_upload_roundtrip`；
- `target_suffix` 等于部署时的正式后缀；
- `verification.upload_success/download_hash_match/decrypt_match=true`；
- 固定 runtime 绝对路径与当前数据盘设备号；
- UUID 任务号、时间、一次性 nonce 和服务器密文文件名；
- 使用 AES 密钥对规范 JSON 计算的 HMAC-SHA256。

`secure_cleanup.py` 会重新校验上述全部内容、属主、权限、硬链接数、设备号和时效。不能只创建一个同名文件来触发清理。

授权通过后，控制器会停止 GPU、心跳和本地监控，并用 `exec` 将自身替换为安全收尾程序。screen 会因此一直跟踪同一个进程。执行顺序是：

1. 覆写并 unlink `/dev/shm` 密钥文件；
2. 对 `runtime/` 中每个普通文件覆写至少 5 轮，`fsync`、截断再删除；
3. 消费授权标记并记录完成状态。

命中且完成加密备份验证后，清理流程会替换持有助记词的进程，并覆写删除内存 AES 密钥和公开运行文件。

如果收尾被中止，密钥 tmpfs 文件已被删除，但签名标记保留。在服务器上用同一把 AES 密钥和同一条上传地址重新运行 `scripts/create-volatile-secrets.sh`，检查 `/run/trxvanity/cleanup-status.json` 后才可人工续跑：

```bash
cd /root/autodl-tmp/TRXVanityLinux
./secure_cleanup.sh --execute --passes 5
```
