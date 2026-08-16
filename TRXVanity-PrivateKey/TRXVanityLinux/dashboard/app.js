const $ = (id) => document.getElementById(id);
const number = (value) => Number.isFinite(Number(value)) ? Number(value) : 0;
const fmt = (value, compact = false) => new Intl.NumberFormat('zh-CN', {
  notation: compact && number(value) >= 1e6 ? 'compact' : 'standard', maximumFractionDigits: 2,
}).format(number(value));
const fmtYi = (value) => `${new Intl.NumberFormat('zh-CN', {
  minimumFractionDigits: 2, maximumFractionDigits: 2,
}).format(number(value) / 1e8)} 亿次`;
function duration(value) {
  let total = Math.max(0, number(value));
  if (!total) return '—';
  const days = Math.floor(total / 86400); total %= 86400;
  const hours = Math.floor(total / 3600); total %= 3600;
  const minutes = Math.floor(total / 60); const seconds = Math.floor(total % 60);
  return days ? `${days}天 ${hours}小时` : hours ? `${hours}小时 ${minutes}分` : minutes ? `${minutes}分 ${seconds}秒` : `${seconds}秒`;
}
function setText(id, value, fallback = '—') { $(id).textContent = value === '' || value == null ? fallback : value; }
function setBar(id, value) { $(id).style.width = `${Math.min(100, Math.max(0, number(value)))}%`; }
function render(data) {
  $('errorPanel').classList.add('hidden');
  const found = Boolean(data.result?.address);
  const deliveryState = data.delivery?.state || 'waiting';
  const saved = deliveryState === 'saved';
  const saveError = deliveryState === 'error';
  const running = data.state === 'running';
  const stale = Boolean(data.stale);
  const displayState = found ? (saved ? '已命中 · 已保存本地' : saveError ? '已命中 · 保存失败' : '已命中 · 正在保存') : running ? '正在搜索' : '未运行';
  const badgeText = stale ? '连接波动 · 显示缓存' : found ? '搜索已命中' : running ? '远端运行中' : '远端已停止';
  $('connectionBadge').className = `badge ${stale ? 'waiting' : found || running ? 'live' : 'stopped'}`;
  $('connectionBadge').innerHTML = `<span></span>${badgeText}`;
  $('stateDot').className = `dot ${found || running ? 'live' : 'stopped'}`;
  setText('state', displayState);
  if (stale) {
    $('errorPanel').textContent = `本地网络暂时无法连接云端：${data.connection_error || '连接失败'}。搜索进程不依赖本地网络，页面正在显示最近一次成功状态。`;
    $('errorPanel').classList.remove('hidden');
  }
  ['suffix', 'pid'].forEach((id) => setText(id, data[id]));
  setText('jobId', data.job_id); setText('startedAt', data.started_at);
  const attempts = number(data.result?.attempts || data.attempts);
  const speed = number(data.speed); const space = data.suffix ? 58 ** data.suffix.length : 0;
  const chance = space ? 1 - Math.exp(-attempts / space) : 0;
  setText('speed', fmt(speed, true)); setText('attempts', fmtYi(attempts));
  setText('elapsed', duration(data.result?.elapsed || data.elapsed));
  setText('chance', space ? `${(chance * 100).toFixed(chance < .001 ? 5 : 2)}%` : '—');
  const remainingToMedian = Math.max(0, Math.log(2) * space - attempts);
  setBar('chanceBar', chance * 100);
  setText('eta50', speed && space ? (remainingToMedian === 0 ? '已达到' : duration(remainingToMedian / speed)) : '—');
  ['gpu', 'device', 'host', 'os', 'driver'].forEach((id) => setText(id, data[id]));
  setText('lanes', data.lanes ? fmt(data.lanes) : '—');
  setText('utilization', data.utilization_percent ? `${data.utilization_percent}%` : '—'); setBar('utilizationBar', data.utilization_percent);
  const used = number(data.memory_used_mib), total = number(data.memory_total_mib);
  setText('memory', total ? `${used.toFixed(0)} / ${total.toFixed(0)} MiB` : '—'); setBar('memoryBar', total ? used / total * 100 : 0);
  setText('temperature', data.temperature_c ? `${data.temperature_c} °C` : '—'); setText('power', data.power_w ? `${data.power_w} W` : '—');
  setText('securityTitle', data.public_only ? '远端已确认 PUBLIC_ONLY' : '尚未收到 PUBLIC_ONLY 确认');
  $('securityStrip').classList.toggle('unverified', !data.public_only);
  const deliveryLabels = { waiting: '等待命中', saved: '已保存到本地', error: '保存失败' };
  setText('deliveryState', deliveryLabels[deliveryState] || data.delivery?.message || deliveryState);
  $('deliveryState').className = `delivery ${deliveryState}`;
  $('resultCard').classList.toggle('hidden', !found);
  if (found) {
    setText('resultAddress', data.result.address);
    setText('resultSync', saved ? '已安全同步到 Mac' : data.delivery?.message || '正在同步到 Mac');
    $('resultSync').className = `delivery ${saved ? 'saved' : saveError ? 'error' : 'waiting'}`;
    setText('resultPath', data.delivery?.path);
    setText('resultSavedAt', data.delivery?.saved_at);
  }
  setText('log', data.log, '远端尚无日志'); $('log').scrollTop = $('log').scrollHeight;
  const size = number(data.log_size_bytes); setText('logSize', size >= 1048576 ? `${(size / 1048576).toFixed(1)} MB` : size >= 1024 ? `${(size / 1024).toFixed(1)} KB` : `${size} B`);
  setText('lastUpdated', `最后刷新 ${new Date(data.fetched_at * 1000).toLocaleTimeString('zh-CN')}`);
}
function fail(message) { $('connectionBadge').className = 'badge stopped'; $('connectionBadge').innerHTML = '<span></span>本地监控异常'; $('errorPanel').textContent = message; $('errorPanel').classList.remove('hidden'); }
async function refresh() { try { const response = await fetch('/api/status', { cache: 'no-store' }); const data = await response.json(); if (!data.ok) throw new Error(data.error || '状态接口错误'); render(data); } catch (error) { fail(error.message); } }
refresh(); setInterval(refresh, 3000);
