# TRX Vanity Linux（分离密钥版）

[English](README.md)

客户端生成基准私钥，只把公钥和后缀交给 Linux GPU 服务端搜索靓号。服务端只返回公开增量 `t`，最终私钥由客户端合成并复验。

只支持 **1–10 位、大小写敏感** 的 TRON Base58 后缀：

```text
123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
```

没有 `0`、`I`、`O`、`l`。不支持前缀。每次任务必须重新 `prepare`，一个基准私钥只能出一次结果。

---

## 快速开始

客户端是零依赖的 Python 3 脚本，可在 macOS、Linux、Windows 上直接运行，负责生成和合成私钥。服务端需要 Ubuntu x86_64 与 NVIDIA GPU，负责公开搜索。

Windows 把下面的 `python3` 换成 `py -3`。

### 1. 检查客户端

```bash
cd TRXVanityLinux
python3 client/trxvanity_client.py --self-test
```

或运行 `./tools/build-client.sh`，效果相同。

### 2. 构建服务端

依赖：`build-essential cmake ocl-icd-opencl-dev`，以及 NVIDIA 驱动。不必安装完整 CUDA Toolkit。

若只需部署公开搜索端、不上传客户端源码，先打包：

```bash
./tools/package-server-source.sh /tmp/trxvanity-linux-server-source.tgz
```

在 GPU 主机上：

```bash
cd TRXVanityLinux
./tools/build-server.sh
```

产物：`build-linux/bin/trxvanity-linux-gpu` 和同目录 `kernels/`。

### 3. 生成任务

输出路径必须尚不存在，扩展名必须是 `.secret` / `.request`。

```bash
python3 client/trxvanity_client.py prepare \
  --suffix Az1 \
  --secret job.secret \
  --request job.request
```

- `job.secret`：含基准私钥，不要传到服务端。POSIX 上权限为 `0600`；Windows 会尽量限制为当前用户可读写
- `job.request`：任务 ID、公钥、后缀，可交给服务端

### 4. 搜索

服务端只使用 `job.request`：

```bash
set -o pipefail
./build-linux/bin/trxvanity-linux-gpu --request job.request | tee job.result
```

`Ctrl-C` 会等当前 GPU 批次结束再停。长时间运行建议使用 `screen`。

### 5. 合成钱包

将 `job.result` 交回客户端：

```bash
python3 client/trxvanity_client.py finalize \
  --secret job.secret \
  --result job.result \
  --output wallet.wallet
```

复验通过后写出 `wallet.wallet`，私钥不打印到终端。成功后 `job.secret` 会变成 `job.secret.consumed`，不能再用。

不要把 GPU 主机当作钱包。`wallet.wallet` 只应保存在运行客户端的可信环境，并先用小额资产验证导入和转出。

---

## 命令与参数

### 客户端

需要 Python 3.8+，无第三方依赖。

```text
python3 client/trxvanity_client.py prepare  --suffix TEXT --secret FILE --request FILE
python3 client/trxvanity_client.py finalize --secret FILE --result FILE --output FILE
python3 client/trxvanity_client.py --self-test
```

| 参数 | 命令 | 说明 |
|---|---|---|
| `--suffix` | prepare | 1–10 位 Base58 后缀 |
| `--secret` | 两者 | `.secret` 文件 |
| `--request` | prepare | `.request` 文件 |
| `--result` | finalize | 服务端输出，扩展名必须是 `.result` |
| `--output` | finalize | 新的 `.wallet` 文件，拒绝覆盖 |

### 服务端

```text
trxvanity-linux-gpu --request FILE [--inverse-multiple N] [--max-batches N]
trxvanity-linux-gpu --self-test [--inverse-multiple N]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--request` | 必填 | 客户端 `prepare` 生成的文件 |
| `--inverse-multiple` | 自动 | GPU 批量倍数，`lanes = 255 × N`。自动时按计算单元和显存选择，下限 `16384`。手动指定须为 128 的倍数 |
| `--max-batches` | 不限制 | 跑满 N 个批次仍未命中则停止 |
| `--self-test` | — | GPU 自检，不能和 `--request` 一起用 |

生产搜索一般不用加参数。需要限制时长时加 `--max-batches`。

退出码：`0` 命中或自检通过；`1` 请求/GPU/复验失败；`2` 参数错误；`3` 被中止或批次用尽。

---

## 监控台（可选）

监控页只监听 `127.0.0.1`，通过只读 SSH 读取 GPU 状态和命中结果，不读取 `.secret` / `.wallet`。

先填写 `dashboard/state/config.json`（仓库中的值为示例）：

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

SSH 密钥放在被 gitignore 的 `dashboard/state/`。然后：

```bash
./tools/start-dashboard.sh              # 默认 http://127.0.0.1:8787/
./tools/start-dashboard.sh --port 9000
./tools/start-dashboard.sh --no-open
./tools/stop-dashboard.sh
```

`start-dashboard.sh` 只适用于 macOS 当前登录会话，不安装开机启动项。关闭浏览器或短暂断网不会停止服务；重启、注销或手动停止后需再次启动。运行副本和取回的 `.result` 保存在 `~/Library/Application Support/TRXVanityDashboard/`。

---

## 安全模型

```text
客户端                                GPU 服务端
生成基准私钥 b
计算 P = bG
保存 b（0600）        ──只传递──>    P、任务 ID、后缀
                                      搜索 Q = P + tG
最终私钥 x = b+t      <──只返回──    地址、公开增量 t
客户端重新派生地址并核对
```

服务端没有接收私钥的参数或文件字段。主机管理员能看到任务并伪造结果，伪造会被客户端复验拒绝，但无法阻止拒绝服务。该设计保护私钥机密性，不隐藏搜索任务本身。

不要修改 `.request` 后用同一个 `BASE_PUBLIC` 搜索多个地址。

---

## 其他

- 目录：`client/trxvanity_client.py` 跨平台私钥生成与合成；`server/` 公开搜索；`common/` 编解码和匹配；`kernels/` OpenCL；`../Vendor/secp256k1/` 服务端曲线库。
- 精简 CUDA 容器若缺少 ICD，程序会设置进程级 `OCL_ICD_FILENAMES=libnvidia-opencl.so.1`，不修改系统配置。
- 单独复跑 GPU 自检 / 审计：

```bash
./build-linux/bin/trxvanity-linux-gpu --self-test --inverse-multiple 16384
./tools/security-audit.sh ./build-linux/bin/trxvanity-linux-gpu
```
