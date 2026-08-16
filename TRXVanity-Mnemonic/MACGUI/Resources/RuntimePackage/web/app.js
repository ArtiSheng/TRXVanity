"use strict";

const $ = (id) => document.getElementById(id);
const stateNames = {
  starting: "启动中", ready: "已就绪", searching: "搜索中", verifying: "正在复验",
  result: "已命中", stopping: "正在停止", error: "异常",
  cleanup_launching: "安全清理交接中", cleanup_started: "安全清理已启动"
};
const backupNames = {
  waiting: "等待命中", encrypting: "正在 AES 加密", uploading: "正在上传密文",
  downloading: "正在回下载", decrypting: "正在验证解密", verified: "上传与复验成功", failed: "备份失败"
};
const BASE58_SIZE = 58;

function number(value) {
  return new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 0 }).format(Number(value || 0));
}

function chineseUnit(value) {
  const n = Number(value || 0);
  const formatter = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 2 });
  if (n >= 1e12) return `${formatter.format(n / 1e12)} 万亿`;
  if (n >= 1e8) return `${formatter.format(n / 1e8)} 亿`;
  if (n >= 1e4) return `${formatter.format(n / 1e4)} 万`;
  return number(n);
}

function duration(value) {
  const rawSeconds = Number(value);
  if (!Number.isFinite(rawSeconds)) return "暂无法计算";

  let seconds = Math.max(0, Math.floor(rawSeconds));
  const units = [
    [31557600, "年"], [86400, "天"], [3600, "时"], [60, "分"], [1, "秒"]
  ];
  const parts = [];
  for (const [unitSeconds, label] of units) {
    const count = Math.floor(seconds / unitSeconds);
    if (count || parts.length) {
      parts.push(`${count}${label}`);
      seconds %= unitSeconds;
    }
    if (parts.length === 2) break;
  }
  return parts.length ? parts.join(" ") : "0秒";
}

function percentage(value, clampAtOne = true) {
  const rawValue = Number(value || 0);
  const ratio = clampAtOne ? Math.max(0, Math.min(1, rawValue)) : Math.max(0, rawValue);
  const percent = ratio * 100;
  if (percent > 0 && percent < 1e-8) return "< 0.00000001%";
  const maximumFractionDigits = percent >= 10 ? 4 : percent >= 1 ? 5 : percent >= 0.01 ? 6 : 8;
  return `${new Intl.NumberFormat("zh-CN", {
    minimumFractionDigits: 2,
    maximumFractionDigits
  }).format(percent)}%`;
}

function searchForecast(data) {
  const suffixLength = Array.from(String(data.suffix || "")).length;
  const attempts = Math.max(0, Number(data.attempts || 0));
  const speed = Math.max(0, Number(data.speed || 0));
  const searchSpace = Math.pow(BASE58_SIZE, suffixLength);
  if (!suffixLength || !Number.isFinite(searchSpace) || searchSpace <= 1) return null;

  const logMissPerAttempt = Math.log1p(-1 / searchSpace);
  const probability = -Math.expm1(attempts * logMissPerAttempt);
  const timeUntilWork = (targetWorkRatio) => {
    if (!speed) return Number.NaN;
    return Math.max(0, searchSpace * targetWorkRatio - attempts) / speed;
  };

  return {
    probability,
    workProgress: attempts / searchSpace,
    expectedSeconds: speed ? searchSpace / speed : Number.NaN,
    until50Seconds: timeUntilWork(0.5),
    until100Seconds: timeUntilWork(1)
  };
}

function renderForecast(data) {
  const forecast = searchForecast(data);
  if (!forecast) {
    $("expected").textContent = "等待搜索参数";
    $("progress").textContent = "—";
    $("probability").textContent = "—";
    $("until50").textContent = "—";
    $("until100").textContent = "—";
    $("progressBar").style.width = "0";
    return;
  }

  $("expected").textContent = duration(forecast.expectedSeconds);
  $("progress").textContent = percentage(forecast.workProgress, false);
  $("probability").textContent = percentage(forecast.probability);
  $("until50").textContent = forecast.workProgress >= 0.5 ? "已达到" : duration(forecast.until50Seconds);
  $("until100").textContent = forecast.workProgress >= 1 ? "已达到" : duration(forecast.until100Seconds);
  $("progressBar").style.width = `${Math.min(100, forecast.workProgress * 100)}%`;
}

function render(data) {
  $("dot").className = "online";
  $("connection").textContent = "服务器已连接";
  $("state").textContent = stateNames[data.state] || data.state || "未知";
  $("state").className = `state ${data.state || ""}`;
  $("suffix").textContent = data.suffix ? `尾号 ${data.suffix}` : "";
  $("detail").textContent = data.detail || "—";
  $("updated").textContent = data.updated_at ? new Date(data.updated_at).toLocaleString("zh-CN", { hour12: false }) : "—";
  $("attempts").textContent = chineseUnit(data.attempts);
  $("speed").textContent = chineseUnit(data.speed);
  $("elapsed").textContent = duration(data.elapsed_seconds);
  $("device").textContent = data.engine_device || "正在初始化";
  $("profile").textContent = data.engine_profile || "—";
  $("cpuWorkers").textContent = Number(data.engine_batch_size) > 0
    && Number.isInteger(data.engine_cpu_workers)
    ? `${data.engine_cpu_workers} 线程`
    : "旧引擎未报告";
  $("cpuBudget").textContent = Number(data.engine_cpu_budget) > 0
    ? `${number(data.engine_cpu_budget)} 核${data.engine_cpu_budget_source ? `（${data.engine_cpu_budget_source}）` : ""}`
    : "旧引擎未报告";
  $("batch").textContent = Number(data.engine_batch_size) > 0
    && Number(data.engine_batch_capacity) > 0
    ? `${number(data.engine_batch_size)} / 容量 ${number(data.engine_batch_capacity)}`
    : "旧引擎未报告";
  $("blocks").textContent = Number(data.engine_cuda_master_block_size) > 0
    && Number(data.engine_cuda_address_block_size) > 0
    ? `${number(data.engine_cuda_master_block_size)} / ${number(data.engine_cuda_address_block_size)}（BIP39 / 地址）`
    : "旧引擎未报告";
  $("kernelMode").textContent = data.engine_kernel_mode || "旧引擎未报告";
  $("address").textContent = data.result_address || "尚未命中";
  $("backup").textContent = backupNames[data.backup_state] || data.backup_state || "—";
  $("verified").textContent = data.backup_verified ? "密文哈希、HMAC 和明文字段全部一致" : "未完成";
  $("heartbeat").textContent = data.heartbeat_ok
    ? `服务器已确认${data.heartbeat_notifications ? `，邮件 ${data.heartbeat_notifications} 封` : ""}`
    : "尚未确认";
  renderForecast(data);
}

async function refresh() {
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) throw new Error("status unavailable");
    render(await response.json());
  } catch (_) {
    $("dot").className = "offline";
    $("connection").textContent = "暂时无法连接";
  }
}

refresh();
setInterval(refresh, 2000);
