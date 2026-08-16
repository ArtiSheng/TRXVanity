#!/usr/bin/env python3
"""Cross-platform Linux deployer for Windows, macOS, and Linux operators.

Asks for a search suffix, AES key, upload/delete URLs, then one or more SSH
targets. Each host is locked exclusively before upload, hash verification,
and a remote engine self-test. The AES key is written only to remote /dev/shm
over SSH and is never stored in the uploaded source tree. After the exclusive
lock is released, each host starts formal search in a detached screen session.
"""

from __future__ import annotations

import concurrent.futures
import getpass
import hashlib
import io
from pathlib import Path
import re
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Iterable, List, Optional, Sequence, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_DIR = SCRIPT_DIR.parent
VENDOR_DIR = WORKSPACE_DIR / "Vendor"
REMOTE_DATA = "/root/autodl-tmp"
REMOTE_APP = f"{REMOTE_DATA}/TRXVanityLinux"
REMOTE_APP_NAME = "TRXVanityLinux"
REMOTE_VENDOR_NAME = "Vendor"
FORMAL_SUFFIX_NAME = "formal-suffix"
REMOTE_SECRETS = "/dev/shm/trxvanity-secrets.env"
BASE58_PATTERN = re.compile(r"\A[1-9A-HJ-NP-Za-km-z]{1,10}\Z")
AES_KEY_PATTERN = re.compile(r"\A[0-9a-fA-F]{64}\Z")
TEXT_SUFFIXES = {
    ".c",
    ".cmake",
    ".cpp",
    ".css",
    ".cu",
    ".cuh",
    ".example",
    ".h",
    ".hpp",
    ".html",
    ".js",
    ".json",
    ".md",
    ".py",
    ".service",
    ".sh",
    ".txt",
    ".xml",
}
TEXT_NAMES = frozenset(
    {
        "CMakeLists.txt",
        "Dockerfile",
        "Makefile",
        "formal-suffix",
    }
)
SKIP_DIR_NAMES = frozenset({"__pycache__", "build", "runtime"})
_PRINT_LOCK = threading.Lock()


class DeployError(RuntimeError):
    """Raised when a local or remote deploy step fails."""


@dataclass(frozen=True)
class SshTarget:
    user: str
    host: str
    port: int
    auth: str
    password: Optional[str] = None
    key_path: Optional[str] = None

    @property
    def label(self) -> str:
        return f"{self.user}@{self.host}:{self.port}"


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            try:
                reconfigure(encoding="utf-8")
            except (OSError, ValueError):
                pass


def log(message: str, *, host: str = "") -> None:
    prefix = f"[{host}] " if host else ""
    with _PRINT_LOCK:
        print(f"{prefix}{message}", flush=True)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: ANN001, ANN002
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(_NoRedirect)


def validate_suffix(text: str) -> str:
    suffix = (text or "").strip()
    if not BASE58_PATTERN.fullmatch(suffix):
        raise DeployError("后缀必须是 1 到 10 位 TRON Base58 字符，不能包含 0、O、I、l")
    return suffix


def validate_aes_key(text: str) -> str:
    key = (text or "").strip()
    if not AES_KEY_PATTERN.fullmatch(key):
        raise DeployError("AES 密钥必须正好是 64 位十六进制字符")
    return key


def _split_token_url(text: str, kind: str) -> urllib.parse.SplitResult:
    raw = (text or "").strip()
    if not raw:
        raise DeployError(f"{kind}地址不能为空")
    parsed = urllib.parse.urlsplit(raw)
    if parsed.scheme.lower() != "https":
        raise DeployError(f"{kind}地址必须使用 HTTPS")
    if not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise DeployError(f"{kind}地址无效")
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    if len(query.get("token", [])) != 1 or not query["token"][0]:
        raise DeployError(f"{kind}地址必须带一个非空 token")
    return parsed


def validate_upload_url(text: str) -> str:
    parsed = _split_token_url(text, "上传")
    if parsed.path != "/upload.php" and not parsed.path.endswith("/upload.php"):
        raise DeployError("上传地址路径必须以 upload.php 结尾")
    return urllib.parse.urlunsplit(parsed)


def validate_delete_url(text: str) -> str:
    parsed = _split_token_url(text, "删除")
    path = parsed.path.rstrip("/") or "/"
    if path not in {"/", "/index.php"} and not path.endswith("/index.php"):
        raise DeployError("删除地址路径必须是 index.php")
    return urllib.parse.urlunsplit(parsed)


def upload_probe_accepted(status: int, body: str) -> None:
    if status == 403 or "上传令牌错误" in body:
        raise DeployError("上传地址令牌错误")
    if status in {400, 413}:
        return
    raise DeployError(f"上传地址连通测试失败：HTTP {status}")


def delete_probe_accepted(status: int, body: str) -> None:
    if status != 200:
        raise DeployError(f"删除地址连通测试失败：HTTP {status}")
    if "删除令牌错误" in body:
        raise DeployError("删除地址令牌错误")
    if "解锁删除" in body:
        raise DeployError("删除令牌未能解锁后台")
    if "AES 密文备份" not in body:
        raise DeployError("删除地址不是密文备份页")


def http_request(url: str, method: str, data: Optional[bytes] = None) -> Tuple[int, str]:
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/octet-stream")
    try:
        with NO_REDIRECT_OPENER.open(request, timeout=20) as response:
            body = response.read().decode("utf-8", "replace")
            return int(response.status), body
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        return int(error.code), body
    except urllib.error.URLError as error:
        raise DeployError(f"无法连接：{error.reason}") from error


def secrets_file_bytes(aes_key: str, upload_endpoint: str) -> bytes:
    return (
        f"TRX_AES_KEY_HEX={aes_key}\n"
        f"TRX_BACKUP_ENABLED=true\n"
        f"TRX_UPLOAD_ENDPOINT={upload_endpoint}\n"
    ).encode("ascii")


def parse_ssh_target(
    text: str, default_user: str = "root", default_port: int = 22
) -> Tuple[str, str, int]:
    raw = (text or "").strip()
    if not raw:
        raise DeployError("SSH 地址不能为空")
    user = default_user
    hostport = raw
    if "@" in raw:
        user, hostport = raw.rsplit("@", 1)
        user = user.strip()
        if not user or any(ch.isspace() for ch in user) or "/" in user:
            raise DeployError("SSH 用户名无效")
    host = hostport.strip()
    port = default_port
    if host.startswith("[") and "]" in host:
        end = host.index("]")
        maybe_port = host[end + 1 :]
        host = host[1:end]
        if maybe_port.startswith(":"):
            port = _parse_port(maybe_port[1:])
    elif host.count(":") == 1:
        host, port_text = host.rsplit(":", 1)
        port = _parse_port(port_text)
    host = host.strip()
    if not host or any(ch.isspace() for ch in host) or "/" in host:
        raise DeployError("SSH 主机名无效")
    if not 1 <= port <= 65535:
        raise DeployError("SSH 端口必须在 1 到 65535 之间")
    return user, host, port


def _parse_port(text: str) -> int:
    if not text.isdigit():
        raise DeployError("SSH 端口必须是数字")
    return int(text)


def should_skip_relative(parts: Sequence[str], *, vendor: bool) -> bool:
    if not parts or any(part in {".", ".."} for part in parts):
        return True
    if parts[-1] in {".DS_Store", FORMAL_SUFFIX_NAME} or parts[-1].endswith(".pyc"):
        return True
    skip_names = {"__pycache__"} if vendor else SKIP_DIR_NAMES
    return any(part in skip_names for part in parts[:-1])


def normalize_payload_bytes(path: Path, data: bytes) -> bytes:
    if path.name in TEXT_NAMES or path.suffix.lower() in TEXT_SUFFIXES:
        return data.replace(b"\r\n", b"\n")
    return data


def iter_payload_files(
    linux_dir: Path = SCRIPT_DIR, vendor_dir: Path = VENDOR_DIR
) -> Iterable[Tuple[str, Path, bytes]]:
    if not linux_dir.is_dir():
        raise DeployError(f"找不到 Linux 源码目录: {linux_dir}")
    if not vendor_dir.is_dir():
        raise DeployError(f"找不到 Vendor 目录: {vendor_dir}")
    for root, directory, prefix, vendor in (
        (linux_dir, linux_dir, REMOTE_APP_NAME, False),
        (vendor_dir, vendor_dir, REMOTE_VENDOR_NAME, True),
    ):
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(directory)
            parts = relative.parts
            if should_skip_relative(parts, vendor=vendor):
                continue
            payload = normalize_payload_bytes(path, path.read_bytes())
            yield f"{prefix}/{relative.as_posix()}", path, payload


def local_manifest_text(files: Sequence[Tuple[str, Path, bytes]]) -> str:
    lines = [
        f"{hashlib.sha256(payload).hexdigest()}  {name}"
        for name, _path, payload in files
    ]
    lines.sort()
    return "\n".join(lines) + ("\n" if lines else "")


def write_payload_tar(files: Sequence[Tuple[str, Path, bytes]], destination: Path) -> None:
    with tarfile.open(destination, "w") as archive:
        for name, path, payload in files:
            info = tarfile.TarInfo(name=name)
            info.size = len(payload)
            info.mtime = int(path.stat().st_mtime)
            info.mode = 0o700 if path.suffix == ".sh" or path.name.endswith(".sh") else 0o600
            archive.addfile(info, io.BytesIO(payload))


def prompt_line(message: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    try:
        value = input(f"{message}{suffix}: ").strip()
    except EOFError as error:
        raise DeployError("输入已结束，无法继续交互") from error
    return value or default


def prompt_suffix() -> str:
    raw = prompt_line("要搜索的后缀（1-10 位 TRON Base58，必须自己输入）")
    if not raw:
        raise DeployError("必须输入搜索后缀，没有默认值")
    suffix = validate_suffix(raw)
    if len(suffix) <= 3:
        space = 58 ** len(suffix)
        log(
            f"警告：{len(suffix)} 位后缀平均约 {space} 次就会命中；"
            "正式搜索命中并完成回环校验后会启动安全收尾。"
        )
        confirm = prompt_line("请再输入一次相同后缀以确认")
        if confirm != suffix:
            raise DeployError("两次输入的后缀不一致")
    return suffix


def prompt_aes_key() -> str:
    first = getpass.getpass("AES-256 密钥（64 位十六进制，输入不显示）: ")
    key = validate_aes_key(first)
    second = getpass.getpass("再输入一次同一把 AES 密钥: ")
    if second.strip() != key:
        raise DeployError("两次输入的 AES 密钥不一致")
    return key


def prompt_upload_url() -> str:
    raw = prompt_line("带令牌的上传地址（https://域名/upload.php?token=...）")
    url = validate_upload_url(raw)
    log("正在测试上传地址连通…")
    payload = b"TRXVANITY-DEPLOY-PROBE" + (b"\x00" * 56)
    status, body = http_request(url, "POST", payload)
    upload_probe_accepted(status, body)
    log("上传地址连通测试通过")
    return url


def prompt_delete_url() -> str:
    raw = prompt_line("带令牌的删除地址（https://域名/index.php?token=...）")
    url = validate_delete_url(raw)
    log("正在测试删除地址连通…")
    status, body = http_request(url, "GET")
    delete_probe_accepted(status, body)
    log("删除地址连通测试通过")
    return url


def remind_cron_then_wait() -> None:
    log("务必前往邮件通知服务器设置每分钟计划任务，用本机 PHP 运行 check-heartbeats.php。")
    log("宝塔：计划任务 → Shell 脚本 → 每分钟。没有这条任务，客户端掉线后不会发告警邮件。")
    log("3 秒后继续部署…")
    time.sleep(3)


def prompt_targets() -> List[SshTarget]:
    targets: List[SshTarget] = []
    while True:
        index = len(targets) + 1
        log(f"第 {index} 台服务器")
        address = prompt_line("SSH 地址（user@host 或 host，可写 host:端口）")
        user, host, parsed_port = parse_ssh_target(address)
        port_text = prompt_line("SSH 端口", str(parsed_port))
        _, _, port = parse_ssh_target(f"{user}@{host}:{port_text}")
        method = prompt_line("认证方式：1=私钥或本机 SSH 代理，2=密码", "1")
        if method not in {"1", "2"}:
            raise DeployError("认证方式只能是 1 或 2")
        if method == "1":
            key_path = prompt_line("私钥路径（留空则使用本机 SSH 代理/默认密钥）")
            targets.append(
                SshTarget(
                    user=user,
                    host=host,
                    port=port,
                    auth="key",
                    key_path=str(Path(key_path).expanduser()) if key_path else None,
                )
            )
        else:
            password = getpass.getpass(f"输入 {user}@{host} 的 SSH 密码（不会保存）: ")
            if not password:
                raise DeployError("密码不能为空")
            targets.append(
                SshTarget(
                    user=user,
                    host=host,
                    port=port,
                    auth="password",
                    password=password,
                )
            )
        if prompt_line("再添加一台服务器？", "n").lower() not in {"y", "yes"}:
            break
    if not targets:
        raise DeployError("至少需要一台 SSH 服务器")
    return targets


def require_interactive() -> None:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise DeployError("部署必须在交互终端里运行，按提示输入后缀、密钥、地址和 SSH")


def require_paramiko():
    try:
        import paramiko
    except ImportError as error:
        raise DeployError(
            "本机需要先安装 paramiko：python3 -m pip install -r requirements-deploy.txt"
        ) from error
    return paramiko


def connect_ssh(target: SshTarget):
    paramiko = require_paramiko()

    class AcceptNewHostKeyPolicy(paramiko.MissingHostKeyPolicy):
        def missing_host_key(self, client, hostname, key) -> None:  # noqa: ANN001
            fingerprint = hashlib.sha256(key.asbytes()).hexdigest()[:16]
            log(f"接受新的 SSH 主机密钥 {hostname} {key.get_name()} {fingerprint}")
            client.get_host_keys().add(hostname, key.get_name(), key)

    client = paramiko.SSHClient()
    try:
        client.load_system_host_keys()
    except OSError:
        pass
    client.set_missing_host_key_policy(AcceptNewHostKeyPolicy())
    kwargs = {
        "hostname": target.host,
        "port": target.port,
        "username": target.user,
        "timeout": 20,
        "banner_timeout": 30,
        "auth_timeout": 30,
        "allow_agent": target.auth != "password",
        "look_for_keys": target.auth != "password",
    }
    if target.key_path:
        kwargs["key_filename"] = target.key_path
        kwargs["look_for_keys"] = False
    if target.password:
        kwargs["password"] = target.password
        kwargs["allow_agent"] = False
        kwargs["look_for_keys"] = False
    try:
        client.connect(**kwargs)
    except Exception as error:
        client.close()
        raise DeployError(f"SSH 连接失败: {error}") from error
    return client


def ssh_run(client, command: str, check: bool = True) -> Tuple[int, str, str]:
    _stdin, stdout, stderr = client.exec_command(command)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if check and code != 0:
        detail = (err or out).strip() or f"exit {code}"
        raise DeployError(f"远程命令失败: {detail}")
    return code, out, err


LOCK_COMMAND = (
    "set -eu; command -v flock >/dev/null; "
    "install -d -m 700 -o root -g root /run/trxvanity; "
    "exec 8>/run/trxvanity/formal-supervisor.lock; "
    "chmod 600 /run/trxvanity/formal-supervisor.lock; "
    "if ! flock -n 8; then printf 'TRXVANITY_DEPLOY_BUSY\\n'; exit 2; fi; "
    "exec 9>/run/trxvanity/search.lock; "
    "chmod 600 /run/trxvanity/search.lock; "
    "if ! flock -n 9; then printf 'TRXVANITY_DEPLOY_BUSY\\n'; exit 2; fi; "
    "printf 'TRXVANITY_DEPLOY_LOCKED\\n'; cat >/dev/null"
)


def hold_remote_lock(client):
    transport = client.get_transport()
    if transport is None:
        raise DeployError("SSH 传输层不可用")
    channel = transport.open_session()
    channel.exec_command(LOCK_COMMAND)
    line = b""
    while b"\n" not in line:
        chunk = channel.recv(256)
        if not chunk:
            break
        line += chunk
    status = line.split(b"\n", 1)[0].decode("utf-8", "replace")
    if status != "TRXVANITY_DEPLOY_LOCKED":
        channel.close()
        raise DeployError("正式搜索、自动重启 supervisor 或安全收尾仍在运行，已拒绝部署")
    return channel


def remote_extract_and_sync() -> str:
    return f"""
set -eu
command -v rsync >/dev/null
command -v tar >/dev/null
stage="$(mktemp -d {REMOTE_DATA}/.trxvanity-deploy.XXXXXX)"
trap 'rm -rf -- "$stage" {REMOTE_DATA}/.trxvanity-deploy-payload.tar' EXIT
tar -C "$stage" -xf {REMOTE_DATA}/.trxvanity-deploy-payload.tar
test -d "$stage/{REMOTE_APP_NAME}" && test -d "$stage/{REMOTE_VENDOR_NAME}"
install -d -m 700 '{REMOTE_APP}' '{REMOTE_APP}/runtime' '{REMOTE_DATA}/Vendor'
rsync -a --delete --exclude '.DS_Store' --exclude '__pycache__/' --exclude 'build/' --exclude 'runtime/' --exclude '{FORMAL_SUFFIX_NAME}' "$stage/{REMOTE_APP_NAME}/" '{REMOTE_APP}/'
rsync -a --delete --exclude '.DS_Store' --exclude '__pycache__/' "$stage/{REMOTE_VENDOR_NAME}/" '{REMOTE_DATA}/Vendor/'
"""


def remote_hash_command() -> str:
    return (
        f"set -eu; cd '{REMOTE_DATA}'; "
        "find TRXVanityLinux Vendor -type f "
        "! -name '.DS_Store' ! -name 'formal-suffix' "
        "! -path '*/__pycache__/*' "
        "! -path 'TRXVanityLinux/build/*' "
        "! -path 'TRXVanityLinux/runtime/*' -print0 "
        "| LC_ALL=C sort -z | while IFS= read -r -d '' file; do "
        "digest=$(sha256sum -- \"$file\" | awk '{print $1}'); "
        "printf '%s  %s\\n' \"$digest\" \"$file\"; done"
    )


def remote_finish_command(suffix: str) -> str:
    # suffix is already Base58-validated; keep it in single quotes.
    return f"""
set -eu
printf '%s\\n' '{suffix}' > '{REMOTE_APP}/{FORMAL_SUFFIX_NAME}'
chown -R root:root '{REMOTE_APP}' '{REMOTE_DATA}/Vendor'
chmod 600 '{REMOTE_APP}/{FORMAL_SUFFIX_NAME}'
chmod 700 '{REMOTE_APP}' '{REMOTE_APP}/runtime'
chmod 700 '{REMOTE_APP}'/*.sh '{REMOTE_APP}'/scripts/*.sh '{REMOTE_APP}'/scripts/*.py '{REMOTE_APP}/deploy.py'
'{REMOTE_APP}/scripts/install-production-build.sh'
'{REMOTE_APP}/scripts/preflight-server.sh'
"""


def preflight_busy_command() -> str:
    return (
        "set -eu; "
        f"if pgrep -f '^([^[:space:]]*/)?python3 {REMOTE_APP}/controller[.]py([[:space:]]|$)' >/dev/null "
        f"|| pgrep -f '^([^[:space:]]*/)?python3 {REMOTE_APP}/scripts/secure_cleanup[.]py([[:space:]]|$)' >/dev/null; "
        "then echo 'Refusing deployment while search or cleanup is running.' >&2; exit 2; fi; "
        f"test -d '{REMOTE_DATA}' && test ! -L '{REMOTE_DATA}'; "
        f"install -d -m 700 '{REMOTE_APP}' '{REMOTE_APP}/runtime' '{REMOTE_DATA}/Vendor'"
    )


def write_remote_secrets(client, aes_key: str, upload_endpoint: str) -> None:
    ssh_run(
        client,
        "set -eu; test -d /dev/shm; test ! -L /dev/shm; "
        f"if test -L '{REMOTE_SECRETS}'; then echo 'secrets path is a symlink' >&2; exit 2; fi",
    )
    content = secrets_file_bytes(aes_key, upload_endpoint)
    sftp = client.open_sftp()
    try:
        with sftp.open(REMOTE_SECRETS, "wb") as handle:
            handle.write(content)
        sftp.chmod(REMOTE_SECRETS, 0o600)
    finally:
        sftp.close()
    ssh_run(client, f"set -eu; chown root:root '{REMOTE_SECRETS}'; chmod 600 '{REMOTE_SECRETS}'")


def remote_start_search_command() -> str:
    return f"""
set -eu
if ! command -v screen >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y screen
fi
if screen -ls 2>/dev/null | grep -q '[.]trxvanity-formal[[:space:]]'; then
    screen -S trxvanity-formal -X quit || true
    sleep 1
fi
screen -dmS trxvanity-formal bash -lc 'cd {REMOTE_APP} && exec ./run-formal.sh'
sleep 2
screen -ls 2>/dev/null | grep -q '[.]trxvanity-formal[[:space:]]' \\
    || {{ echo 'screen failed to start trxvanity-formal' >&2; exit 2; }}
pgrep -f '[.]/run-formal[.]sh|{REMOTE_APP}/controller[.]py' >/dev/null \\
    || {{ echo 'screen started but formal search exited immediately' >&2; exit 2; }}
echo 'started screen session trxvanity-formal'
"""


def start_remote_search(client) -> None:
    ssh_run(client, remote_start_search_command())


def deploy_one(
    target: SshTarget,
    suffix: str,
    aes_key: str,
    upload_endpoint: str,
    files: Sequence[Tuple[str, Path, bytes]],
    manifest: str,
    payload_tar: Path,
) -> None:
    label = target.label
    log("正在连接", host=label)
    client = connect_ssh(target)
    lock_channel = None
    search_ready = False
    try:
        lock_channel = hold_remote_lock(client)
        log("已独占 supervisor/search 锁", host=label)
        ssh_run(client, preflight_busy_command())
        sftp = client.open_sftp()
        try:
            sftp.put(str(payload_tar), f"{REMOTE_DATA}/.trxvanity-deploy-payload.tar")
        finally:
            sftp.close()
        log("正在同步源码和 Vendor", host=label)
        ssh_run(client, remote_extract_and_sync())
        _code, remote_manifest, _err = ssh_run(client, remote_hash_command())
        if remote_manifest != manifest:
            raise DeployError("本地与远程文件清单或 SHA-256 不一致")
        log("文件清单和 SHA-256 已核对", host=label)
        _code, finish_out, _err = ssh_run(client, remote_finish_command(suffix))
        if finish_out.strip():
            for line in finish_out.strip().splitlines():
                log(line, host=label)
        write_remote_secrets(client, aes_key, upload_endpoint)
        log(f"部署完成，正式后缀 {suffix}。已写入内存密钥和上传地址。", host=label)
        search_ready = True
    finally:
        if lock_channel is not None:
            try:
                lock_channel.close()
            except Exception:
                pass
        try:
            if search_ready:
                time.sleep(1)
                log("正在用 screen 启动正式搜索", host=label)
                start_remote_search(client)
                log("正式搜索已在 screen 会话 trxvanity-formal 中运行", host=label)
        finally:
            client.close()


def main() -> int:
    configure_stdio()
    try:
        if len(sys.argv) > 1:
            raise DeployError("部署没有命令行参数，请直接运行后按提示输入")
        require_interactive()
        require_paramiko()
        suffix = prompt_suffix()
        aes_key = prompt_aes_key()
        upload_endpoint = prompt_upload_url()
        prompt_delete_url()
        remind_cron_then_wait()
        targets = prompt_targets()
        files = list(iter_payload_files())
        manifest = local_manifest_text(files)
        log(f"将部署到 {len(targets)} 台服务器，正式搜索后缀 {suffix}")
        log("完成后会用 screen 自动开始正式搜索")
        answer = prompt_line("开始部署？", "y")
        if answer.lower() not in {"y", "yes"}:
            log("已取消")
            return 0
        with tempfile.TemporaryDirectory(prefix="trxvanity-deploy-") as directory:
            payload_tar = Path(directory) / "payload.tar"
            write_payload_tar(files, payload_tar)
            failures = []
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(8, len(targets))
            ) as pool:
                work = {
                    pool.submit(
                        deploy_one,
                        target,
                        suffix,
                        aes_key,
                        upload_endpoint,
                        files,
                        manifest,
                        payload_tar,
                    ): target
                    for target in targets
                }
                for future in concurrent.futures.as_completed(work):
                    target = work[future]
                    try:
                        future.result()
                    except Exception as error:
                        log(f"失败: {error}", host=target.label)
                        failures.append(target.label)
        if failures:
            log("这些服务器部署失败: " + ", ".join(failures))
            return 1
        log("全部服务器部署完成，正式搜索已在 screen 中启动")
        return 0
    except DeployError as error:
        log(str(error))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
