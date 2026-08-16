import Darwin
import CryptoKit
import Foundation

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

enum ConnectionPreparation: Equatable, Sendable {
    case running
    case started
    case missingFiles([String])
    case secretMissing
}

enum SSHServiceError: LocalizedError {
    case askPassMissing
    case commandTimedOut
    case launchFailed(String)
    case connectionFailed(String)
    case invalidResponse(String)
    case localPortUnavailable
    case runtimePackageMissing
    case runtimePackageInvalid(String)
    case uploadFailed(String)
    case uploadStalled(TimeInterval)
    case uploadAlreadyRunning
    case runtimeAESKeyUnavailable(String)
    case runtimeAESKeyInvalid
    case runtimeSecretInstallFailed(String)
    case privateKeyFileFailed(String)
    case invalidSuffix

    var errorDescription: String? {
        switch self {
        case .askPassMissing: return "App 内的 SSH 密码辅助程序缺失。"
        case .commandTimedOut: return "SSH 操作超时。"
        case .launchFailed(let message): return "无法启动 SSH：\(message)"
        case .connectionFailed(let message): return message.isEmpty ? "SSH 连接失败。" : message
        case .invalidResponse(let message): return message
        case .localPortUnavailable: return "无法分配本地监控端口。"
        case .runtimePackageMissing: return "App 内置生产运行包不完整。"
        case .runtimePackageInvalid(let message): return "App 内置生产运行包校验失败：\(message)"
        case .uploadFailed(let message): return "上传运行包失败：\(message)"
        case .uploadStalled(let seconds):
            return "上传已连续 \(Int(seconds)) 秒没有任何进展，已中止。请检查网络或代理（VPN/TUN）设置。"
        case .uploadAlreadyRunning:
            return "该机器已有上传任务正在进行，请等待它结束。"
        case .runtimeAESKeyUnavailable(let message):
            return "无法读取本机运行 AES 密钥：\(message)"
        case .runtimeAESKeyInvalid:
            return "本机运行 AES 密钥不是 64 位十六进制格式。"
        case .runtimeSecretInstallFailed(let message):
            return "自动创建远程内存密钥文件失败：\(message)"
        case .privateKeyFileFailed(let message):
            return "无法准备 SSH 私钥：\(message)"
        case .invalidSuffix:
            return FormalSearchError.invalidSuffix.errorDescription
                ?? "尾号必须是 1 到 10 位 TRON Base58 字符。"
        }
    }
}

protocol SSHSession: Sendable {
    func prepareAndStart() async throws -> ConnectionPreparation
    func uploadBundledRuntime(progress: @escaping @Sendable (RuntimeUploadProgress) -> Void) async throws
    func startTunnel() async throws
    func fetchSnapshot() async throws -> MachineSnapshot
    func disconnect() async
}

/// Prevents a second upload to the same server while one is still in flight, even if the
/// caller has meanwhile replaced its `SSHConnection` instance.
actor RuntimeUploadCoordinator {
    static let shared = RuntimeUploadCoordinator()

    private var activeTargets: Set<String> = []

    func begin(_ target: String) -> Bool {
        activeTargets.insert(target).inserted
    }

    func end(_ target: String) {
        activeTargets.remove(target)
    }
}

struct RuntimeManifestEntry: Equatable, Sendable {
    let sha256: String
    let relativePath: String
}

struct ValidatedRuntimePackage: Sendable {
    let directoryURL: URL
    let entries: [RuntimeManifestEntry]
    let manifestSHA256: String
}

enum RuntimePackageManifest {
    static let requiredPaths: Set<String> = [
        "build/bip39-english.txt",
        "build/cuda-tuning-config.txt",
        "build/trxvanity-gpu",
        "controller.py",
        "run-formal.sh",
        "scripts/create-volatile-secrets.sh",
        "scripts/preflight-server.sh",
        "scripts/secure_cleanup.py",
        "secure_cleanup.sh",
        "status.sh",
        "web/app.js",
        "web/index.html",
        "web/style.css"
    ]

    static func validate(
        at directoryURL: URL,
        requiredPaths: Set<String> = requiredPaths
    ) throws -> ValidatedRuntimePackage {
        let manifestURL = directoryURL.appendingPathComponent("runtime-manifest.sha256")
        guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw SSHServiceError.runtimePackageMissing
        }

        var entries: [RuntimeManifestEntry] = []
        var seenPaths: Set<String> = []
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.utf8.count > 66 else {
                throw SSHServiceError.runtimePackageInvalid("清单行格式错误。")
            }
            let digest = String(line.prefix(64)).lowercased()
            let separator = line.dropFirst(64).prefix(2)
            let listedPath = String(line.dropFirst(66))
            guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  separator == "  ",
                  listedPath.hasPrefix("./")
            else {
                throw SSHServiceError.runtimePackageInvalid("清单行格式错误。")
            }

            let relativePath = String(listedPath.dropFirst(2))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            let isSafePath = !relativePath.isEmpty
                && !relativePath.hasPrefix("/")
                && relativePath.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil
                && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            guard isSafePath, seenPaths.insert(relativePath).inserted else {
                throw SSHServiceError.runtimePackageInvalid("清单包含不安全或重复路径。")
            }

            let fileURL = directoryURL.appendingPathComponent(relativePath)
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw SSHServiceError.runtimePackageInvalid("缺少清单文件 \(relativePath)。")
            }
            let actualDigest = try sha256Hex(of: fileURL)
            guard actualDigest == digest else {
                throw SSHServiceError.runtimePackageInvalid("文件 \(relativePath) 的 SHA-256 不匹配。")
            }
            entries.append(RuntimeManifestEntry(sha256: digest, relativePath: relativePath))
        }

        guard !entries.isEmpty else {
            throw SSHServiceError.runtimePackageInvalid("清单为空。")
        }
        let missingRequiredPaths = requiredPaths.subtracting(seenPaths).sorted()
        guard missingRequiredPaths.isEmpty else {
            throw SSHServiceError.runtimePackageInvalid(
                "清单缺少 \(missingRequiredPaths.joined(separator: "、"))。"
            )
        }

        return ValidatedRuntimePackage(
            directoryURL: directoryURL,
            entries: entries,
            manifestSHA256: try sha256Hex(of: manifestURL)
        )
    }

    /// macOS `tar` archives `com.apple.provenance` as PAX `LIBARCHIVE.xattr.*` headers.
    /// `COPYFILE_DISABLE=1` alone does not suppress that; GNU tar on Linux then warns
    /// (and some versions exit non-zero) with "Ignoring unknown extended header keyword".
    static func portableCreateArguments(
        archivePath: String,
        directoryPath: String,
        members: [String]
    ) -> (executable: String, arguments: [String]) {
        (
            "/usr/bin/env",
            [
                "COPYFILE_DISABLE=1",
                "/usr/bin/tar",
                "--no-xattrs",
                "--no-mac-metadata",
                "--no-acls",
                "--no-fflags",
                "-cf", archivePath,
                "-C", directoryPath
            ] + members
        )
    }

    static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads both output pipes of a child process while it is still running, so a process that writes
/// more than one pipe buffer cannot deadlock against a parent that only reads after exit.
private final class OutputDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    init(stdout: Pipe, stderr: Pipe) {
        read(stdout) { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            self.stdoutData = data
            self.lock.unlock()
        }
        read(stderr) { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            self.stderrData = data
            self.lock.unlock()
        }
    }

    func finish() -> (stdout: String, stderr: String) {
        _ = group.wait(timeout: .now() + 5)
        lock.lock()
        defer { lock.unlock() }
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func read(_ pipe: Pipe, store: @escaping @Sendable (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [group] in
            store(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
    }
}

enum ChildProcess {
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let grace = Date().addingTimeInterval(1)
        while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// A blocked write to a pipe whose reader has exited would otherwise kill the whole app.
    static func ignoreSIGPIPEOnce() {
        _ = sigpipeIgnored
    }

    private static let sigpipeIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()
}

enum ProcessStreamer {
    /// Streams a local file into the standard input of a child process, reporting how many bytes
    /// the transfer has accepted so far and aborting early once it stops making progress.
    static func send(
        fileURL: URL,
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        stallTimeout: TimeInterval,
        overallTimeout: TimeInterval,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            ChildProcess.ignoreSIGPIPEOnce()
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                throw SSHServiceError.launchFailed(error.localizedDescription)
            }
            let drain = OutputDrain(stdout: output, stderr: error)

            let descriptor = input.fileHandleForWriting.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL, 0)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

            let deadline = Date().addingTimeInterval(overallTimeout)
            var lastProgressAt = Date()
            var lastReportAt = Date.distantPast
            var sent: Int64 = 0
            var failure: SSHServiceError?

            streaming: while true {
                let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                var offset = 0
                while offset < chunk.count {
                    if Date() >= deadline {
                        failure = .commandTimedOut
                        break streaming
                    }
                    if Date().timeIntervalSince(lastProgressAt) >= stallTimeout {
                        failure = .uploadStalled(stallTimeout)
                        break streaming
                    }
                    var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptors, 1, 500)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        failure = .uploadFailed(String(cString: strerror(errno)))
                        break streaming
                    }
                    if ready == 0 { continue }
                    if descriptors.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { break streaming }

                    let written = chunk.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return Darwin.write(descriptor, base.advanced(by: offset), chunk.count - offset)
                    }
                    if written < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        if errno == EPIPE { break streaming }
                        failure = .uploadFailed(String(cString: strerror(errno)))
                        break streaming
                    }
                    offset += written
                    sent += Int64(written)
                    lastProgressAt = Date()
                    if Date().timeIntervalSince(lastReportAt) >= 0.2 {
                        lastReportAt = Date()
                        progress(sent)
                    }
                }
            }
            progress(sent)
            try? input.fileHandleForWriting.close()

            if let failure {
                ChildProcess.terminate(process)
                _ = drain.finish()
                throw failure
            }

            let exitDeadline = min(deadline, Date().addingTimeInterval(stallTimeout))
            while process.isRunning, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                ChildProcess.terminate(process)
                _ = drain.finish()
                throw SSHServiceError.commandTimedOut
            }
            let collected = drain.finish()
            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: collected.stdout,
                stderr: collected.stderr
            )
        }.value
    }
}

actor SSHConnection: SSHSession {
    private static let uploadStallTimeout: TimeInterval = 90

    private let record: MachineRecord
    private let suffix: String
    private var tunnelProcess: Process?
    private var tunnelErrorPipe: Pipe?
    private var controlSocketPath: String?
    private var localMonitorPort: UInt16?
    private var privateKeyURL: URL?
    private var previousCPUSample: (total: Double, idle: Double)?

    init(record: MachineRecord, suffix: String = FormalSearch.persistedSuffix) {
        self.record = record
        self.suffix = suffix
    }

    deinit {
        tunnelProcess?.terminate()
        if let privateKeyURL { try? FileManager.default.removeItem(at: privateKeyURL) }
    }

    func prepareAndStart() async throws -> ConnectionPreparation {
        try await prepareAndStart(allowSecretRepair: true)
    }

    private func prepareAndStart(allowSecretRepair: Bool) async throws -> ConnectionPreparation {
        let localPackage = try Self.validatedBundledRuntime()
        let expectedManifestSHA256 = localPackage.manifestSHA256
        let suffix = self.suffix
        if !suffix.isEmpty, !FormalSearch.isValid(suffix) {
            throw SSHServiceError.invalidSuffix
        }
        let script = #"""
	set -u
	export PATH=/root/miniconda3/bin:/usr/local/bin:/usr/bin:/bin:$PATH
	export TRX_WANTED_SUFFIX='\#(suffix)'
	wanted="$TRX_WANTED_SUFFIX"
	suffix_ok=0
	printf '%s' "$wanted" | grep -Eq '^[1-9A-HJ-NP-Za-km-z]{1,10}$' && suffix_ok=1
app=/root/autodl-fs/TRXVanityLinux
runtime=/root/autodl-tmp/TRXVanityLinux/runtime
missing=""
need_file() {
    if [ ! -f "$app/$1" ]; then missing="${missing}${missing:+,}$1"; fi
}
need_exec() {
    if [ ! -x "$app/$1" ]; then missing="${missing}${missing:+,}$1"; fi
	}
	need_exec build/trxvanity-gpu
	need_file build/bip39-english.txt
	need_file build/cuda-tuning-config.txt
	need_file controller.py
	need_exec run-formal.sh
	need_exec secure_cleanup.sh
	need_exec status.sh
	need_exec scripts/preflight-server.sh
	need_exec scripts/create-volatile-secrets.sh
	need_file scripts/secure_cleanup.py
	need_file web/index.html
	need_file web/app.js
	need_file web/style.css
	need_file runtime-manifest.sha256
	if [ -n "$missing" ]; then
	    printf 'MISSING|%s\n' "$missing"
	    exit 42
	fi
	if ! printf '%s  runtime-manifest.sha256\n' '\#(expectedManifestSHA256)' \
	    | (cd "$app" && sha256sum -c - >/dev/null 2>&1); then
	    printf 'MISSING|runtime-manifest.sha256 (版本不匹配)\n'
	    exit 42
	fi
	if ! (cd "$app" && sha256sum -c runtime-manifest.sha256 >/dev/null 2>&1); then
	    printf 'MISSING|运行包 SHA-256 校验失败\n'
	    exit 42
	fi
	if ! command -v screen >/dev/null 2>&1; then
    installed=0
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 \
            && apt-get install -y -qq screen >/dev/null 2>&1 \
            && installed=1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q screen >/dev/null 2>&1 && installed=1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q screen >/dev/null 2>&1 && installed=1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache screen >/dev/null 2>&1 && installed=1
    fi
    if [ "$installed" -ne 1 ] || ! command -v screen >/dev/null 2>&1; then
        printf 'ERROR|自动安装 screen 失败，请确认服务器可以访问软件源\n'
        exit 44
    fi
fi
if [ ! -f /dev/shm/trxvanity-secrets.env ]; then
    printf 'SECRET_MISSING\n'
    exit 43
fi
controller_pid=""
find_controller() {
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
        case "${exe##*/}" in
            python|python[0-9]*|python3*) ;;
            *) continue ;;
        esac
        args=$(tr '\000' '\n' < "$proc/cmdline")
        printf '%s\n' "$args" | grep -Fx '/root/autodl-fs/TRXVanityLinux/controller.py' >/dev/null || continue
        printf '%s\n' "$args" | grep -Fx 'run' >/dev/null || continue
        printf '%s\n' "$args" | grep -Fx -- '--suffix' >/dev/null || continue
        if [ "$suffix_ok" -eq 1 ]; then
            printf '%s\n' "$args" | grep -Fx "$wanted" >/dev/null || continue
        fi
        controller_pid=${proc#/proc/}
        return 0
    done
    return 1
}
monitor_searching() {
    curl -fsS --max-time 2 http://127.0.0.1:8787/api/status 2>/dev/null \
        | python3 -c 'import json,os,sys; d=json.load(sys.stdin); want=os.environ.get("TRX_WANTED_SUFFIX",""); raise SystemExit(0 if d.get("state")=="searching" and (want=="" or d.get("suffix")==want) else 1)' 2>/dev/null
}
if find_controller; then
    for _ in $(seq 1 10); do
        if monitor_searching; then
            printf 'RUNNING\n'
            exit 0
        fi
        sleep 1
    done
    printf 'ERROR|搜索进程存在，但 8787 监控接口未就绪\n'
    exit 45
fi
if [ "$suffix_ok" -ne 1 ]; then
    printf 'ERROR|请先在 App 中设置 1 到 10 位 TRON Base58 尾号\n'
    exit 45
fi
printf '%s\n' "$wanted" > "$app/formal-suffix"
chown root:root "$app/formal-suffix"
chmod 600 "$app/formal-suffix"
install -d -m 700 /root/autodl-tmp/TRXVanityLinux/runtime /run/trxvanity
screen -wipe >/dev/null 2>&1 || true
start_epoch=$(date +%s)
TRX_RUNTIME_STORAGE_MODE=hybrid-public-runtime \
    screen -dmS trxvanity-formal bash -lc 'cd /root/autodl-fs/TRXVanityLinux && exec ./run-formal.sh >> /root/autodl-tmp/TRXVanityLinux/runtime/formal.log 2>&1'
for _ in $(seq 1 30); do
    status_mtime=$(stat -c %Y "$runtime/status.json" 2>/dev/null || printf 0)
    if [ "$status_mtime" -ge "$start_epoch" ] \
        && python3 -c 'import json,os; d=json.load(open("/root/autodl-tmp/TRXVanityLinux/runtime/status.json")); want=os.environ.get("TRX_WANTED_SUFFIX",""); raise SystemExit(0 if d.get("state")=="searching" and (want=="" or d.get("suffix")==want) else 1)' 2>/dev/null \
        && monitor_searching; then
        printf 'STARTED\n'
        exit 0
    fi
    sleep 1
done
detail=$(python3 -c 'import json; print(json.load(open("/root/autodl-tmp/TRXVanityLinux/runtime/status.json")).get("detail", "启动后未进入搜索状态"))' 2>/dev/null || printf '启动后未生成状态')
printf 'ERROR|%s\n' "$detail"
exit 45
"""#
        let result = try await runSSH(command: script, timeout: 180)
        let line = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if line == "RUNNING" { return .running }
        if line == "STARTED" { return .started }
        if line == "SECRET_MISSING" {
            guard allowSecretRepair else { return .secretMissing }
            let aesKey = try await loadRuntimeAESKey()
            try await installVolatileSecrets(aesKey: aesKey)
            return try await prepareAndStart(allowSecretRepair: false)
        }
        if line.hasPrefix("MISSING|") {
            return .missingFiles(String(line.dropFirst("MISSING|".count)).split(separator: ",").map(String.init))
        }
        if line.hasPrefix("ERROR|") {
            throw SSHServiceError.connectionFailed(String(line.dropFirst("ERROR|".count)))
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SSHServiceError.connectionFailed(detail.isEmpty ? "远端没有返回可识别的状态。" : detail)
    }

    private func loadRuntimeAESKey() async throws -> String {
        let result = try await Self.runProcess(
            executable: "/usr/bin/security",
            arguments: [
                "find-generic-password",
                "-a", "88888888-fleet-20260814",
                "-s", "TRXVanity-Mnemonic-AES",
                "-w"
            ],
            password: nil,
            timeout: 10
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.runtimeAESKeyUnavailable(detail.isEmpty ? "未找到指定的钥匙串项。" : detail)
        }
        let key = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^[0-9A-Fa-f]{64}$"#, options: .regularExpression) != nil else {
            throw SSHServiceError.runtimeAESKeyInvalid
        }
        return key
    }

    private func installVolatileSecrets(aesKey: String) async throws {
        let script = #"""
set -eu
secrets=/dev/shm/trxvanity-secrets.env
tmp=$(mktemp /dev/shm/.trxvanity-secrets.XXXXXX)
trap 'rm -f "$tmp"' EXIT HUP INT TERM
umask 077
IFS= read -r key
if [ "${#key}" -ne 64 ]; then
    printf 'INVALID_KEY\n'
    exit 46
fi
case "$key" in
    *[!0-9A-Fa-f]*) printf 'INVALID_KEY\n'; exit 46 ;;
esac
printf 'TRX_AES_KEY_HEX=%s\nTRX_BACKUP_ENABLED=true\n' "$key" > "$tmp"
unset key
chown root:root "$tmp"
chmod 600 "$tmp"
if [ -e "$secrets" ] || [ -L "$secrets" ]; then
    if [ -f "$secrets" ] && [ ! -L "$secrets" ] && cmp -s "$tmp" "$secrets"; then
        printf 'SECRET_READY\n'
        exit 0
    fi
    printf 'SECRET_MISMATCH\n'
    exit 47
fi
mv "$tmp" "$secrets"
trap - EXIT HUP INT TERM
printf 'SECRET_CREATED\n'
"""#
        let input = Data((aesKey + "\n").utf8)
        let result = try await runSSH(command: script, timeout: 15, standardInputData: input)
        guard result.exitCode == 0,
              result.stdout.contains("SECRET_CREATED") || result.stdout.contains("SECRET_READY")
        else {
            let output = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = output.isEmpty ? fallback : output
            throw SSHServiceError.runtimeSecretInstallFailed(detail.isEmpty ? "远程未返回可识别结果。" : detail)
        }
    }

    func uploadBundledRuntime(progress: @escaping @Sendable (RuntimeUploadProgress) -> Void) async throws {
        let target = "\(record.user)@\(record.host):\(record.port)"
        guard await RuntimeUploadCoordinator.shared.begin(target) else {
            throw SSHServiceError.uploadAlreadyRunning
        }
        defer { Task.detached { await RuntimeUploadCoordinator.shared.end(target) } }

        let package = try Self.validatedBundledRuntime()
        let uploadID = UUID().uuidString.lowercased()
        let stagingPath = "/root/autodl-fs/.TRXVanityLinux.upload-\(uploadID)"
        let remoteArchivePath = "\(stagingPath).tar"
        let localArchiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TRXVanityLinux-\(uploadID).tar")
        defer { try? FileManager.default.removeItem(at: localArchiveURL) }

        var members = ["runtime-manifest.sha256"]
        members.append(contentsOf: package.entries.map(\.relativePath))
        let archiveCommand = RuntimePackageManifest.portableCreateArguments(
            archivePath: localArchiveURL.path,
            directoryPath: package.directoryURL.path,
            members: members
        )
        let archived = try await Self.runProcess(
            executable: archiveCommand.executable,
            arguments: archiveCommand.arguments,
            password: nil,
            timeout: 120
        )
        guard archived.exitCode == 0 else {
            throw SSHServiceError.runtimePackageInvalid(
                archived.stderr.isEmpty ? "无法生成受管上传归档。" : archived.stderr
            )
        }
        let archiveSHA256 = try RuntimePackageManifest.sha256Hex(of: localArchiveURL)
        guard let fileSize = try? localArchiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0
        else {
            throw SSHServiceError.runtimePackageInvalid("受管上传归档为空。")
        }
        let archiveSize = Int64(fileSize)
        let uploadTimeout = max(1_800, Double(archiveSize) / 8_192 + 300)

        let prepare = #"""
	set -eu
	umask 077
	test ! -e '\#(stagingPath)'
	test ! -e '\#(remoteArchivePath)'
	install -d -m 700 /root/autodl-fs '\#(stagingPath)'
	printf 'READY\n'
	"""#
        let prepareResult = try await runSSH(command: prepare, timeout: 15)
        guard prepareResult.exitCode == 0, prepareResult.stdout.contains("READY") else {
            throw SSHServiceError.uploadFailed(Self.commandDetail(prepareResult))
        }

        var arguments = try authenticationOptions(portFlag: "-p")
        arguments.append("-C")
        arguments.append("\(record.user)@\(record.host)")
        arguments.append("umask 077; cat > '\(remoteArchivePath)'")
        let environment = try processPassword.map { try Self.passwordEnvironment($0) }
        progress(RuntimeUploadProgress(bytesSent: 0, totalBytes: archiveSize))
        do {
            let copied = try await ProcessStreamer.send(
                fileURL: localArchiveURL,
                executable: "/usr/bin/ssh",
                arguments: arguments,
                environment: environment,
                stallTimeout: Self.uploadStallTimeout,
                overallTimeout: uploadTimeout
            ) { bytesSent in
                progress(RuntimeUploadProgress(bytesSent: bytesSent, totalBytes: archiveSize))
            }
            guard copied.exitCode == 0 else {
                throw SSHServiceError.uploadFailed(Self.commandDetail(copied))
            }
        } catch {
            await cleanupUploadArtifacts(stagingPath: stagingPath, archivePath: remoteArchivePath)
            if let serviceError = error as? SSHServiceError { throw serviceError }
            throw SSHServiceError.uploadFailed(error.localizedDescription)
        }

        let expectedFileCount = package.entries.count + 1
        let install = #"""
	set -eu
	export PATH=/root/miniconda3/bin:/usr/local/bin:/usr/bin:/bin:$PATH
	app=/root/autodl-fs/TRXVanityLinux
	stage='\#(stagingPath)'
	archive='\#(remoteArchivePath)'
	cleanup_upload() {
	    rm -rf -- "$stage"
	    rm -f -- "$archive"
	}
	trap cleanup_upload EXIT HUP INT TERM
	validate_tree() {
	    tree=$1
	    [ -d "$tree" ] && [ ! -L "$tree" ]
	    unsafe=$(find "$tree" ! -type d ! -type f -print -quit)
	    [ -z "$unsafe" ]
	    cd "$tree"
	    printf '%s  runtime-manifest.sha256\n' '\#(package.manifestSHA256)' \
	        | sha256sum -c - >/dev/null
	    sha256sum -c runtime-manifest.sha256 >/dev/null
	    actual_files=$(find . -type f -printf '%P\n' | LC_ALL=C sort)
	    expected_files=$(
	        {
	            printf 'runtime-manifest.sha256\n'
	            awk 'length($1) == 64 && substr($0, 65, 2) == "  " { print substr($0, 69) }' runtime-manifest.sha256
	        } | LC_ALL=C sort
	    )
	    [ "$actual_files" = "$expected_files" ]
	    [ "$(printf '%s\n' "$actual_files" | sed '/^$/d' | wc -l)" -eq \#(expectedFileCount) ]
	}
	exchange_directories() {
	    python3 -c 'import ctypes, os, sys; lib = ctypes.CDLL(None, use_errno=True); rc = lib.renameat2(-100, os.fsencode(sys.argv[1]), -100, os.fsencode(sys.argv[2]), 2); err = ctypes.get_errno(); print(os.strerror(err), file=sys.stderr) if rc else None; sys.exit(1 if rc else 0)' "$1" "$2"
	}
	printf '%s  %s\n' '\#(archiveSHA256)' "$archive" | sha256sum -c - >/dev/null
	tar --warning=no-unknown-keyword -xf "$archive" -C "$stage"
	validate_tree "$stage"
	chown -R root:root "$stage"
	chmod 700 "$stage" "$stage/build" "$stage/scripts" "$stage/web"
	chmod 700 "$stage/build/trxvanity-gpu" "$stage/run-formal.sh" "$stage/secure_cleanup.sh" "$stage/status.sh" "$stage/scripts/preflight-server.sh" "$stage/scripts/create-volatile-secrets.sh" "$stage/scripts/secure_cleanup.py"
	chmod 600 "$stage/build/bip39-english.txt" "$stage/build/cuda-tuning-config.txt" "$stage/controller.py" "$stage/runtime-manifest.sha256" "$stage/web/index.html" "$stage/web/app.js" "$stage/web/style.css"
	install -d -m 700 /run/trxvanity
	exec 7>/run/trxvanity/cleanup.lock
	flock -n 7 || { printf 'cleanup is active; refusing to replace the runtime\n' >&2; exit 1; }
	is_formal_search_pid() {
	    args=$(tr '\000' '\n' < "$1/cmdline")
	    printf '%s\n' "$args" | grep -Fx '/root/autodl-fs/TRXVanityLinux/run-formal.sh' >/dev/null && return 0
	    printf '%s\n' "$args" | grep -Fx './run-formal.sh' >/dev/null && return 0
	    printf '%s\n' "$args" | grep -Fx '/root/autodl-fs/TRXVanityLinux/controller.py' >/dev/null \
	        && printf '%s\n' "$args" | grep -Fx 'run' >/dev/null \
	        && printf '%s\n' "$args" | grep -Fx -- '--suffix' >/dev/null
	}
	stop_formal_search() {
	    screen -S trxvanity-formal -X quit >/dev/null 2>&1 || true
	    screen -wipe >/dev/null 2>&1 || true
	    pids=""
	    for proc in /proc/[0-9]*; do
	        [ -r "$proc/cmdline" ] || continue
	        is_formal_search_pid "$proc" || continue
	        pids="$pids ${proc#/proc/}"
	    done
	    for pid in $pids; do
	        kill -TERM "$pid" 2>/dev/null || true
	    done
	    for _ in $(seq 1 20); do
	        alive=0
	        for pid in $pids; do
	            if kill -0 "$pid" 2>/dev/null; then alive=1; fi
	        done
	        [ "$alive" -eq 0 ] && return 0
	        sleep 1
	    done
	    for pid in $pids; do
	        kill -KILL "$pid" 2>/dev/null || true
	    done
	}
	stop_formal_search
	exec 8>/run/trxvanity/formal-supervisor.lock
	exec 9>/run/trxvanity/search.lock
	flock -w 45 8 || { printf 'formal search did not release its lock\n' >&2; exit 1; }
	flock -w 45 9 || { printf 'search did not release its lock\n' >&2; exit 1; }
	if [ -e "$app" ] || [ -L "$app" ]; then
	    exchange_directories "$app" "$stage"
	    if ! validate_tree "$app"; then
	        exchange_directories "$app" "$stage" || true
	        printf 'post-install verification failed; previous package restored\n' >&2
	        exit 1
	    fi
	else
	    mv -- "$stage" "$app"
	    if ! validate_tree "$app"; then
	        mv -- "$app" "$stage" || true
	        printf 'post-install verification failed\n' >&2
	        exit 1
	    fi
	fi
	rm -rf -- "$stage" || true
	rm -f -- "$archive" || true
	trap - EXIT HUP INT TERM
	printf 'UPLOADED|%s|%s\n' '\#(package.manifestSHA256)' '\#(expectedFileCount)'
	"""#
        do {
            let installed = try await runSSH(command: install, timeout: 180)
            let receipt = "UPLOADED|\(package.manifestSHA256)|\(expectedFileCount)"
            guard installed.exitCode == 0, installed.stdout.contains(receipt) else {
                throw SSHServiceError.uploadFailed(Self.commandDetail(installed))
            }
        } catch {
            await cleanupUploadArtifacts(stagingPath: stagingPath, archivePath: remoteArchivePath)
            if let serviceError = error as? SSHServiceError { throw serviceError }
            throw SSHServiceError.uploadFailed(error.localizedDescription)
        }
    }

    private static func validatedBundledRuntime() throws -> ValidatedRuntimePackage {
        guard let packageURL = Bundle.main.resourceURL?
            .appendingPathComponent("RuntimePackage", isDirectory: true)
        else { throw SSHServiceError.runtimePackageMissing }
        return try RuntimePackageManifest.validate(at: packageURL)
    }

    private static func commandDetail(_ result: CommandResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        return "远端操作失败（退出码 \(result.exitCode)）。"
    }

    private func cleanupUploadArtifacts(stagingPath: String, archivePath: String) async {
        let cleanup = "rm -rf -- '\(stagingPath)'; rm -f -- '\(archivePath)'"
        _ = try? await runSSH(command: cleanup, timeout: 30)
    }

    func startTunnel() async throws {
        if let tunnelProcess, tunnelProcess.isRunning, localMonitorPort != nil { return }
        await disconnect()
        guard let port = Self.availableLoopbackPort() else {
            throw SSHServiceError.localPortUnavailable
        }
        let socket = "/tmp/trxvm-\(record.id.uuidString.prefix(8))-\(getpid()).sock"
        try? FileManager.default.removeItem(atPath: socket)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = try authenticationOptions(portFlag: "-p")
        arguments.append(contentsOf: [
            "-M", "-S", socket, "-N",
            "-o", "ControlPersist=no",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "127.0.0.1:\(port):127.0.0.1:8787",
            "\(record.user)@\(record.host)"
        ])
        process.arguments = arguments
        if let password = processPassword {
            process.environment = try Self.passwordEnvironment(password)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw SSHServiceError.launchFailed(error.localizedDescription)
        }
        tunnelProcess = process
        tunnelErrorPipe = errorPipe
        controlSocketPath = socket
        localMonitorPort = port

        let tunnelDeadline = Date().addingTimeInterval(12)
        while Date() < tunnelDeadline {
            if !process.isRunning { break }
            if (try? await fetchMonitorStatus(port: port)) != nil { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let message: String
        if process.isRunning {
            process.terminate()
            message = "SSH 隧道建立后监控接口未响应。"
        } else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "SSH 隧道启动失败。"
        }
        throw SSHServiceError.connectionFailed(message)
    }

    func fetchSnapshot() async throws -> MachineSnapshot {
        guard let port = localMonitorPort,
              let process = tunnelProcess,
              process.isRunning
        else { throw SSHServiceError.connectionFailed("SSH 监控隧道已断开。") }
        let status = try await fetchMonitorStatus(port: port)
        let telemetry = try await fetchTelemetry()
        return MachineSnapshot(status: status, telemetry: telemetry)
    }

    func disconnect() async {
        if let process = tunnelProcess, process.isRunning {
            process.terminate()
            for _ in 0..<10 where process.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        if let socket = controlSocketPath { try? FileManager.default.removeItem(atPath: socket) }
        if let privateKeyURL { try? FileManager.default.removeItem(at: privateKeyURL) }
        tunnelProcess = nil
        tunnelErrorPipe = nil
        controlSocketPath = nil
        localMonitorPort = nil
        privateKeyURL = nil
        previousCPUSample = nil
    }

    private func fetchMonitorStatus(port: UInt16) async throws -> MonitorStatus {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/status") else {
            throw SSHServiceError.invalidResponse("本地监控地址无效。")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SSHServiceError.invalidResponse("远程监控接口未返回 HTTP 200。")
        }
        return try JSONDecoder().decode(MonitorStatus.self, from: data)
    }

    private func fetchTelemetry() async throws -> RemoteTelemetry {
        guard let socket = controlSocketPath else {
            throw SSHServiceError.connectionFailed("SSH 控制连接不存在。")
        }
        let script = #"""
awk '/^cpu / { total=0; for (i=2; i<=NF; i++) total += $i; idle=$5+$6; printf "CPU|%.0f|%.0f\n", total, idle; exit }' /proc/stat
gpu=$(nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1)
printf 'GPU|%s\n' "$gpu"
"""#
        let result = try await runControl(socket: socket, command: script, timeout: 5)
        guard result.exitCode == 0 else { throw SSHServiceError.connectionFailed(result.stderr) }
        var telemetry = RemoteTelemetry()
        for line in result.stdout.components(separatedBy: .newlines) {
            if line.hasPrefix("CPU|") {
                let values = line.split(separator: "|")
                if values.count == 3, let total = Double(values[1]), let idle = Double(values[2]) {
                    if let previous = previousCPUSample {
                        let deltaTotal = total - previous.total
                        let deltaIdle = idle - previous.idle
                        if deltaTotal > 0 { telemetry.cpuPercent = min(100, max(0, (deltaTotal - deltaIdle) / deltaTotal * 100)) }
                    }
                    previousCPUSample = (total, idle)
                }
            } else if line.hasPrefix("GPU|") {
                let payload = String(line.dropFirst(4))
                let values = payload.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if values.count == 4 {
                    telemetry.gpuPercent = Double(values[0])
                    telemetry.gpuMemoryPercent = Double(values[1])
                    telemetry.gpuMemoryUsedMiB = Double(values[2])
                    telemetry.gpuMemoryTotalMiB = Double(values[3])
                }
            }
        }
        return telemetry
    }

    private func runSSH(
        command: String,
        timeout: TimeInterval,
        standardInputData: Data? = nil
    ) async throws -> CommandResult {
        var arguments = try authenticationOptions(portFlag: "-p")
        arguments.append(contentsOf: ["\(record.user)@\(record.host)", command])
        return try await Self.runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            password: processPassword,
            timeout: timeout,
            standardInputData: standardInputData
        )
    }

    private func runControl(socket: String, command: String, timeout: TimeInterval) async throws -> CommandResult {
        let arguments = [
            "-S", socket,
            "-o", "BatchMode=yes",
            "-p", String(record.port),
            "\(record.user)@\(record.host)",
            command
        ]
        return try await Self.runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            password: nil,
            timeout: timeout
        )
    }

    private var processPassword: String? {
        guard record.privateKey == nil else { return nil }
        return record.password
    }

    private func authenticationOptions(portFlag: String) throws -> [String] {
        var arguments = [
            portFlag, String(record.port),
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4"
        ]
        if let privateKey = record.privateKey, !privateKey.isEmpty {
            let keyURL = try ensurePrivateKeyFile(contents: privateKey)
            arguments.append(contentsOf: [
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "IdentitiesOnly=yes",
                "-i", keyURL.path
            ])
        } else if let password = record.password, !password.isEmpty {
            arguments.append(contentsOf: [
                "-o", "PreferredAuthentications=password",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ])
        } else {
            throw SSHServiceError.connectionFailed("该机器没有已保存的密码或私钥。")
        }
        return arguments
    }

    private func ensurePrivateKeyFile(contents: String) throws -> URL {
        if let privateKeyURL, FileManager.default.fileExists(atPath: privateKeyURL.path) {
            return privateKeyURL
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trxvm-\(record.id.uuidString)-\(UUID().uuidString).key")
        let data = Data(contents.utf8)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SSHServiceError.privateKeyFileFailed("无法创建本地密钥文件。")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw SSHServiceError.privateKeyFileFailed(error.localizedDescription)
        }
        privateKeyURL = url
        return url
    }

    private static func passwordEnvironment(_ password: String) throws -> [String: String] {
        guard let askPass = Bundle.main.path(forResource: "askpass", ofType: "sh") else {
            throw SSHServiceError.askPassMissing
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askPass
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "TRXVanityMonitor"
        environment["TRX_SSH_PASSWORD"] = password
        return environment
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        password: String?,
        timeout: TimeInterval,
        standardInputData: Data? = nil
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let password { process.environment = try passwordEnvironment(password) }
            let inputPipe: Pipe? = standardInputData == nil ? nil : Pipe()
            if let inputPipe {
                process.standardInput = inputPipe
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                throw SSHServiceError.launchFailed(error.localizedDescription)
            }
            let drain = OutputDrain(stdout: output, stderr: error)
            if let standardInputData, let inputPipe {
                inputPipe.fileHandleForWriting.write(standardInputData)
                try? inputPipe.fileHandleForWriting.close()
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                ChildProcess.terminate(process)
                _ = drain.finish()
                throw SSHServiceError.commandTimedOut
            }
            let collected = drain.finish()
            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: collected.stdout,
                stderr: collected.stderr
            )
        }.value
    }

    private static func availableLoopbackPort() -> UInt16? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }
}
