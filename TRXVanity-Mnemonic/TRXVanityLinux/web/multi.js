"use strict";

const $ = (id) => document.getElementById(id);
const stateNames = {
  starting: "启动中",
  ready: "已就绪",
  searching: "搜索中",
  verifying: "正在复验",
  result: "已命中",
  stopping: "正在停止",
  error: "异常",
  cleanup_launching: "安全清理交接中",
  cleanup_started: "安全清理已启动"
};

function numeric(value) {
  const result = Number(value);
  return Number.isFinite(result) && result >= 0 ? result : 0;
}

function number(value) {
  return new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 0 }).format(numeric(value));
}

function chineseUnit(value) {
  const n = numeric(value);
  const formatter = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 2 });
  if (n >= 1e12) return `${formatter.format(n / 1e12)} 万亿`;
  if (n >= 1e8) return `${formatter.format(n / 1e8)} 亿`;
  if (n >= 1e4) return `${formatter.format(n / 1e4)} 万`;
  return number(n);
}

function duration(value) {
  let seconds = Math.max(0, Math.floor(numeric(value)));
  const units = [[31557600, "年"], [86400, "天"], [3600, "时"], [60, "分"], [1, "秒"]];
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

function optionalDuration(value) {
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds >= 0 ? duration(seconds) : "暂无法计算";
}

function percentage(value, clampAtOne = true) {
  const rawValue = Number(value || 0);
  const ratio = clampAtOne
    ? Math.max(0, Math.min(1, rawValue))
    : Math.max(0, rawValue);
  const percent = ratio * 100;
  if (percent > 0 && percent < 1e-8) return "< 0.00000001%";
  const maximumFractionDigits = percent >= 10
    ? 4
    : percent >= 1
      ? 5
      : percent >= 0.01
        ? 6
        : 8;
  return `${new Intl.NumberFormat("zh-CN", {
    minimumFractionDigits: 2,
    maximumFractionDigits
  }).format(percent)}%`;
}

function dateTime(value) {
  if (!value) return "尚未报告";
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "尚未报告"
    : date.toLocaleString("zh-CN", { hour12: false });
}

function node(tag, className, text) {
  const result = document.createElement(tag);
  if (className) result.className = className;
  if (text !== undefined) result.textContent = text;
  return result;
}

function definition(label, value) {
  const row = node("div", "definition");
  row.append(node("dt", "", label), node("dd", "", value));
  return row;
}

function metric(label, value) {
  const item = node("div", "machine-metric");
  item.append(node("span", "", label), node("strong", "", value));
  return item;
}

function unavailableCard(machine) {
  const card = node("article", "panel machine-card offline");
  const heading = node("div", "machine-heading");
  const identity = node("div");
  identity.append(node("h3", "", machine.name || "未命名机器"), node("p", "source", machine.source || "—"));
  heading.append(identity, node("span", "state-badge offline", "连接中断"));
  card.append(heading, node("p", "offline-message", "本地隧道或远端监控暂时无法连接，其他机器仍会继续刷新。"));
  return card;
}

function machineCard(machine) {
  if (!machine.ok) return unavailableCard(machine);
  const data = machine.status || {};
  const state = data.state || "unknown";
  const card = node("article", `panel machine-card ${state}`);
  const heading = node("div", "machine-heading");
  const identity = node("div");
  identity.append(node("h3", "", machine.name || "未命名机器"), node("p", "source", machine.source || "—"));
  heading.append(identity, node("span", `state-badge ${state}`, stateNames[state] || state));

  const speed = node("div", "machine-speed");
  speed.append(node("strong", "", chineseUnit(data.speed)), node("span", "", " 次 / 秒"));

  const metrics = node("div", "machine-metrics");
  metrics.append(
    metric("累计尝试", chineseUnit(data.attempts)),
    metric("搜索时间", duration(data.elapsed_seconds)),
    metric("CPU", Number.isInteger(data.engine_cpu_workers) ? `${data.engine_cpu_workers} 线程` : "未报告"),
    metric("心跳", data.heartbeat_ok ? "已确认" : "未确认")
  );

  const details = node("dl", "machine-details");
  const batch = numeric(data.engine_batch_size) > 0
    ? `${number(data.engine_batch_size)}${numeric(data.engine_batch_capacity) > 0 ? ` / 容量 ${number(data.engine_batch_capacity)}` : ""}`
    : "未报告";
  const blocks = numeric(data.engine_cuda_master_block_size) > 0 && numeric(data.engine_cuda_address_block_size) > 0
    ? `${number(data.engine_cuda_master_block_size)} / ${number(data.engine_cuda_address_block_size)}（BIP39 / 地址）`
    : "未报告";
  const cpuBudget = numeric(data.engine_cpu_budget) > 0
    ? `${number(data.engine_cpu_budget)} 核${data.engine_cpu_budget_source ? `（${data.engine_cpu_budget_source}）` : ""}`
    : "未报告";
  details.append(
    definition("GPU", data.engine_device || "正在初始化"),
    definition("CPU 可用配额", cpuBudget),
    definition("CUDA 批次", batch),
    definition("CUDA 线程块", blocks),
    definition("计算方案", data.engine_profile || "未报告"),
    definition("内核模式", data.engine_kernel_mode || "未报告"),
    definition("状态更新时间", dateTime(data.updated_at)),
    definition("心跳时间", dateTime(data.heartbeat_at)),
    definition("本地拉取耗时", machine.latency_ms === null ? "—" : `${number(machine.latency_ms)} ms`)
  );
  card.append(heading, speed, metrics, details);
  return card;
}

function renderForecast(summary) {
  const forecast = summary.forecast;
  $("searchedElapsed").textContent = optionalDuration(summary.elapsed_seconds);
  if (!forecast || typeof forecast !== "object") {
    $("progress").textContent = "—";
    $("probability").textContent = "—";
    $("until50").textContent = "—";
    $("until100").textContent = "—";
    $("progressBar").style.width = "0";
    $("progressBar").parentElement.setAttribute("aria-valuenow", "0");
    return;
  }

  const workProgress = numeric(forecast.work_progress);
  $("progress").textContent = percentage(workProgress, false);
  $("probability").textContent = percentage(forecast.cumulative_probability);
  $("until50").textContent = workProgress >= 0.5
    ? "已达到"
    : optionalDuration(forecast.until_50_seconds);
  $("until100").textContent = workProgress >= 1
    ? "已达到"
    : optionalDuration(forecast.until_100_seconds);
  const barPercent = Math.min(100, workProgress * 100);
  $("progressBar").style.width = `${barPercent}%`;
  $("progressBar").parentElement.setAttribute("aria-valuenow", String(barPercent));
}

function render(data) {
  const summary = data.summary || {};
  const machines = Array.isArray(data.machines) ? data.machines : [];
  const online = numeric(summary.online_count);
  const configured = numeric(summary.configured_count);
  $("dot").className = online > 0 ? "online" : "offline";
  $("connection").textContent = online > 0
    ? `${number(online)} 台监控已连接`
    : "所有机器暂时断线";
  $("totalSpeed").textContent = chineseUnit(summary.total_speed);
  $("runningCount").textContent = `${number(summary.running_count)} / ${number(configured)} 台`;
  $("onlineCount").textContent = `${number(online)} 台在线`;
  $("totalAttempts").textContent = chineseUnit(summary.total_attempts);
  $("targetSuffix").textContent = summary.common_suffix
    ? `共同目标尾号 ${summary.common_suffix}`
    : "各机器目标不同或等待状态";
  renderForecast(summary);

  const container = $("machines");
  container.replaceChildren(...machines.map(machineCard));
  if (!machines.length) container.append(node("article", "panel placeholder", "尚未配置机器"));
}

async function refresh() {
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) throw new Error("status unavailable");
    render(await response.json());
  } catch (_) {
    $("dot").className = "offline";
    $("connection").textContent = "聚合服务暂时无法连接";
  }
}

refresh();
setInterval(refresh, 2000);
