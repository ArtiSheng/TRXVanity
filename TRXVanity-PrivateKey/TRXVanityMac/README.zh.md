# TRX Vanity for macOS

[English](README.md)

原生 macOS TRON（TRX）靓号地址生成器。使用 SwiftUI + Metal 在本机 GPU 上并行搜索，命中后由 CPU 独立重新派生地址，通过校验后才显示私钥。

## 功能

- 前段数字从 TRON 地址第 3 位开始匹配
- 尾号从地址末尾精确匹配
- 前段、尾号分别支持 1–10 位，可同时开启
- 节能、平衡、极速三种 GPU 档位
- Metal 不可用时自动使用原生 CPU 并发后备
- 结果包含 34 位 TRON 地址和 64 位 HEX 私钥
- 私钥默认遮挡，复制后 30 秒自动清除剪贴板
- CPU 复验通过后自动保存到本机历史，私钥单独放入 macOS 钥匙串
- 历史支持遮挡查看、复制地址/私钥、单条或全部导出与删除
- 可由用户主动导出权限为 `0600` 的本地 TXT 文件

Base58 字母表不包含数字 `0`，因此数字条件只允许 `1–9`。
尾号的 10 位 Base58 模数为 `58^10 = 430804206899405824`，可安全容纳于 `UInt64`。
前后位数可同时设为 10，但每增加 1 位理论平均搜索量约增加 58 倍；较长条件可能在现有硬件上无法于可实用时间内完成。
应用默认使用“极速”档。正式测速请运行 Release 构建并确认界面仍选中“极速”；Debug 构建的数据不代表最终性能。

## 实测性能

在 10 核 Apple M5 GPU 上使用 Release＋极速档，按 GPU 实际完成的候选数计数，持续测试结果为：

- 纯前缀：约 `64.77 M/s`
- 纯后缀：约 `54.66 M/s`
- 前后组合：约 `62.61 M/s`

后缀模式需要对更多候选计算 Base58Check 校验和取模，因此速度略低。这些是当前机器的实测数据，其他 Mac 会随 GPU 型号、温度和后台负载浮动。即使按这个速度，单侧 10 位条件的理论平均时间仍以百年计，前 10＋后 10 不具有现实可完成性。

## 环境

- Apple Silicon Mac（M1 或更新）
- macOS 13.0 或更新
- Xcode 16 或更新
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（只在重新生成工程文件时需要）

仓库已包含 `TRXVanity.xcodeproj`，日常使用可直接用 Xcode 打开，无需安装 Node.js 或 Rust。

## 旧网页文件归档

旧网页只作为源码文件保留在 `LegacyWebArchive/`，不参与原生 App 的构建或运行：

- `LegacyWebArchive/app/page.tsx`：旧网页页面结构（JSX/HTML）
- `LegacyWebArchive/app/layout.tsx`：旧网页 HTML 外层布局
- `LegacyWebArchive/app/globals.css`：旧网页完整 CSS

旧 Worker、网页加密代码及历史构建配置也放在该归档目录中，仅供查阅。

## 构建

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

生成的 App 位于：

```text
.build/DerivedData/Build/Products/Release/TRX Vanity.app
```

## 测试

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

测试包含 secp256k1/Keccak/Base58 已知向量、前尾匹配区间、CPU 后备，以及 Metal 纯前缀、纯尾号和前后组合实机命中后的 CPU 二次校验。

## 密钥安全

- 随机私密标量由 `SecRandomCopyBytes` 生成。
- Metal 从随机基点开始，用固定生成元 `G...1024G` 的仿射窗口和批量求逆并行前进。
- GPU 只接收公开曲线点、匹配条件和索引；随机私钥基值不进入 `MTLBuffer`。
- App Sandbox 未申请网络权限，不包含遥测或上传代码。
- 通过 CPU 复验的结果会自动保存到本机：私钥使用 `WhenUnlockedThisDeviceOnly` 钥匙串项，不同步到 iCloud；地址、时间和匹配条件保存于 App Sandbox 的 Application Support 目录，不含私钥。
- 删除 App 内历史不会删除你已手动导出的 TXT 文件；TXT 含明文私钥，请移到安全的离线位置。

靓号条件会缩小符合条件的密钥集合。请先用小额资产验证导入、转入和转出流程；大额资产建议使用经过审计的硬件钱包。

## 助记词兼容性

当前版本搜索的是独立的 256 位私钥，并输出对应私钥，不输出助记词。不要把命中的私钥交给所谓“私钥转助记词”工具：标准 BIP-39 助记词不是把此处生成的 32 字节私钥直接编码成单词，二者不可混用。
