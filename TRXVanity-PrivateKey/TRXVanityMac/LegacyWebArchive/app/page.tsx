"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { tronAddressFromPrivateKey } from "./lib/tron";
import VanityWorker from "./vanity.worker?worker";

type SearchStatus = "idle" | "running" | "stopped" | "found" | "error";

type SearchResult = {
  address: string;
  privateKey: string;
  attempts: number;
  elapsedMs: number;
};

type WorkerEvent = {
  type: "progress" | "found" | "error";
  jobId: number;
  workerId: number;
  attempts: number;
  sampleAddress?: string;
  address?: string;
  privateKey?: string;
  message?: string;
};

const LENGTH_OPTIONS = [1, 2, 3, 4, 5, 6];
const DIGITS_PATTERN = /^[1-9]+$/;

function formatNumber(value: number): string {
  if (!Number.isFinite(value)) return "—";
  if (value < 1_000_000) return new Intl.NumberFormat("zh-CN").format(value);
  if (value < 1_000_000_000) return `${(value / 1_000_000).toFixed(2)} 百万`;
  if (value < 1_000_000_000_000)
    return `${(value / 1_000_000_000).toFixed(2)} 十亿`;
  return value.toExponential(2).replace("e+", "e");
}

function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "等待实测";
  if (seconds < 1) return "少于 1 秒";
  if (seconds < 60) return `约 ${Math.ceil(seconds)} 秒`;
  if (seconds < 3_600) return `约 ${Math.ceil(seconds / 60)} 分钟`;
  if (seconds < 86_400) return `约 ${(seconds / 3_600).toFixed(1)} 小时`;
  if (seconds < 31_536_000) return `约 ${(seconds / 86_400).toFixed(1)} 天`;
  return `约 ${(seconds / 31_536_000).toExponential(2)} 年`;
}

function formatClock(milliseconds: number): string {
  const totalSeconds = Math.max(0, Math.floor(milliseconds / 1_000));
  const hours = Math.floor(totalSeconds / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);
  const seconds = totalSeconds % 60;
  return [hours, minutes, seconds]
    .map((part) => part.toString().padStart(2, "0"))
    .join(":");
}

function validateDigits(
  enabled: boolean,
  value: string,
  expectedLength: number,
  label: string,
): string | null {
  if (!enabled) return null;
  if (value.length !== expectedLength) {
    return `${label}需要填写 ${expectedLength} 位数字。`;
  }
  if (!DIGITS_PATTERN.test(value)) {
    return `${label}只能使用 1–9；TRON Base58 地址不包含数字 0。`;
  }
  return null;
}

function subscribeHardwareThreads(): () => void {
  return () => undefined;
}

function getHardwareThreads(): number {
  return Math.max(1, Math.min(32, navigator.hardwareConcurrency || 2));
}

function getServerHardwareThreads(): number {
  return 2;
}

export default function Home() {
  const [prefixEnabled, setPrefixEnabled] = useState(true);
  const [suffixEnabled, setSuffixEnabled] = useState(true);
  const [prefixLength, setPrefixLength] = useState(1);
  const [suffixLength, setSuffixLength] = useState(1);
  const [prefix, setPrefix] = useState("8");
  const [suffix, setSuffix] = useState("8");
  const hardwareThreads = useSyncExternalStore(
    subscribeHardwareThreads,
    getHardwareThreads,
    getServerHardwareThreads,
  );
  const [threadPreference, setThreadPreference] = useState<number | null>(null);
  const threadCount =
    threadPreference ?? Math.max(1, hardwareThreads - 1);
  const [status, setStatus] = useState<SearchStatus>("idle");
  const [attempts, setAttempts] = useState(0);
  const [elapsedMs, setElapsedMs] = useState(0);
  const [speed, setSpeed] = useState(0);
  const [sampleAddress, setSampleAddress] = useState(
    "T—————————————————————————————————",
  );
  const [result, setResult] = useState<SearchResult | null>(null);
  const [privateKeyVisible, setPrivateKeyVisible] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const workersRef = useRef<Worker[]>([]);
  const workerAttemptsRef = useRef<Map<number, number>>(new Map());
  const jobIdRef = useRef(0);
  const startedAtRef = useRef(0);
  const tickerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const foundRef = useRef(false);

  const terminateWorkers = useCallback(() => {
    for (const worker of workersRef.current) worker.terminate();
    workersRef.current = [];
    if (tickerRef.current) {
      clearInterval(tickerRef.current);
      tickerRef.current = null;
    }
  }, []);

  useEffect(() => terminateWorkers, [terminateWorkers]);

  const activeDigits =
    (prefixEnabled ? prefixLength : 0) +
    (suffixEnabled ? suffixLength : 0);
  const expectedAttempts = useMemo(
    () => (activeDigits > 0 ? 58 ** activeDigits : 0),
    [activeDigits],
  );

  const difficulty =
    activeDigits <= 2
      ? "快速"
      : activeDigits <= 4
        ? "中等"
        : activeDigits <= 6
          ? "耗时"
          : "极难";

  const validate = useCallback((): string | null => {
    if (!prefixEnabled && !suffixEnabled) return "请至少开启一项匹配条件。";
    return (
      validateDigits(prefixEnabled, prefix, prefixLength, "前段数字") ||
      validateDigits(suffixEnabled, suffix, suffixLength, "尾号数字")
    );
  }, [prefix, prefixEnabled, prefixLength, suffix, suffixEnabled, suffixLength]);

  const stopSearch = useCallback(() => {
    if (status !== "running") return;
    const finalElapsed = performance.now() - startedAtRef.current;
    terminateWorkers();
    setElapsedMs(finalElapsed);
    setStatus("stopped");
    setNotice("搜索已停止，当前进度不会保存。");
  }, [status, terminateWorkers]);

  const startSearch = useCallback(() => {
    const validationError = validate();
    if (validationError) {
      setError(validationError);
      return;
    }
    if (typeof Worker === "undefined") {
      setError("当前浏览器不支持 Web Workers，无法启动并发生成。");
      return;
    }

    terminateWorkers();
    jobIdRef.current += 1;
    const jobId = jobIdRef.current;
    foundRef.current = false;
    workerAttemptsRef.current.clear();
    startedAtRef.current = performance.now();
    setAttempts(0);
    setElapsedMs(0);
    setSpeed(0);
    setResult(null);
    setPrivateKeyVisible(false);
    setError(null);
    setNotice(null);
    setStatus("running");

    const handleWorkerMessage = (event: MessageEvent<WorkerEvent>) => {
      const message = event.data;
      if (message.jobId !== jobIdRef.current || foundRef.current) return;

      if (message.type === "error") {
        terminateWorkers();
        setStatus("error");
        setError(message.message || "生成线程发生未知错误。");
        return;
      }

      workerAttemptsRef.current.set(message.workerId, message.attempts);
      if (message.sampleAddress) setSampleAddress(message.sampleAddress);

      if (message.type !== "found") return;
      if (!message.address || !message.privateKey) return;

      try {
        const verifiedAddress = tronAddressFromPrivateKey(message.privateKey);
        const expectedPrefix = prefixEnabled ? prefix : "";
        const expectedSuffix = suffixEnabled ? suffix : "";
        const patternMatches =
          (!expectedPrefix || message.address.startsWith(expectedPrefix, 2)) &&
          (!expectedSuffix || message.address.endsWith(expectedSuffix));

        if (verifiedAddress !== message.address || !patternMatches) {
          throw new Error("生成结果校验失败，已为你停止搜索。");
        }

        foundRef.current = true;
        const totalAttempts = [...workerAttemptsRef.current.values()].reduce(
          (sum, value) => sum + value,
          0,
        );
        const finalElapsed = performance.now() - startedAtRef.current;
        terminateWorkers();
        setAttempts(totalAttempts);
        setElapsedMs(finalElapsed);
        setSpeed(totalAttempts / Math.max(finalElapsed / 1_000, 0.001));
        setSampleAddress(message.address);
        setResult({
          address: message.address,
          privateKey: message.privateKey,
          attempts: totalAttempts,
          elapsedMs: finalElapsed,
        });
        setStatus("found");
      } catch (verificationError) {
        terminateWorkers();
        setStatus("error");
        setError(
          verificationError instanceof Error
            ? verificationError.message
            : "生成结果校验失败。",
        );
      }
    };

    try {
      const count = Math.max(1, Math.min(hardwareThreads, threadCount));
      for (let workerId = 0; workerId < count; workerId += 1) {
        const worker = new VanityWorker({
          name: `trx-vanity-${workerId + 1}`,
        });
        worker.addEventListener("message", handleWorkerMessage);
        worker.addEventListener("error", () => {
          if (jobIdRef.current !== jobId || foundRef.current) return;
          terminateWorkers();
          setStatus("error");
          setError("并发生成线程启动失败。");
        });
        workersRef.current.push(worker);
        worker.postMessage({
          type: "start",
          jobId,
          workerId,
          prefix: prefixEnabled ? prefix : "",
          suffix: suffixEnabled ? suffix : "",
          prefixOffset: 2,
        });
      }

      tickerRef.current = setInterval(() => {
        const total = [...workerAttemptsRef.current.values()].reduce(
          (sum, value) => sum + value,
          0,
        );
        const currentElapsed = performance.now() - startedAtRef.current;
        setAttempts(total);
        setElapsedMs(currentElapsed);
        setSpeed(total / Math.max(currentElapsed / 1_000, 0.001));
      }, 250);
    } catch (workerError) {
      terminateWorkers();
      setStatus("error");
      setError(
        workerError instanceof Error
          ? workerError.message
          : "无法启动并发生成线程。",
      );
    }
  }, [
    hardwareThreads,
    prefix,
    prefixEnabled,
    suffix,
    suffixEnabled,
    terminateWorkers,
    threadCount,
    validate,
  ]);

  const copyText = useCallback(async (value: string, label: string) => {
    try {
      await navigator.clipboard.writeText(value);
      setNotice(`${label}已复制到剪贴板。`);
      setTimeout(() => setNotice(null), 2_400);
    } catch {
      setError("复制失败，请允许浏览器使用剪贴板。");
    }
  }, []);

  const downloadResult = useCallback(() => {
    if (!result) return;
    const text = [
      "TRON (TRX) 靓号地址",
      `地址: ${result.address}`,
      `私钥: ${result.privateKey}`,
      "",
      "警告：获得此私钥的人可以控制该地址中的全部资产。请离线加密保管。",
    ].join("\n");
    const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `TRX-${result.address}.txt`;
    link.click();
    URL.revokeObjectURL(url);
    setNotice("已导出密钥文件，请将它移到安全的离线位置。");
  }, [result]);

  const clearResult = useCallback(() => {
    setResult(null);
    setPrivateKeyVisible(false);
    setNotice("页面中的地址和私钥已清除。");
    setStatus("idle");
  }, []);

  const updatePattern = (
    value: string,
    maxLength: number,
    setter: (next: string) => void,
  ) => setter(value.replace(/\D/g, "").slice(0, maxLength));

  const estimatedRemaining =
    speed > 0 ? Math.max(expectedAttempts - attempts, 0) / speed : 0;

  return (
    <main className="app-shell">
      <header className="topbar">
        <a className="brand" href="#top" aria-label="TRX 靓号生成器首页">
          <span className="brand-mark" aria-hidden="true">
            T
          </span>
          <span>
            <strong>TRX Vanity</strong>
            <small>本地多线程工具</small>
          </span>
        </a>
        <div className="security-badges" aria-label="安全特性">
          <span><i className="status-dot" />100% 本地计算</span>
          <span>Web Workers 并发</span>
          <span>私钥不上传</span>
        </div>
      </header>

      <section className="hero" id="top">
        <div className="eyebrow"><span /> TRON MAINNET ADDRESS LAB</div>
        <h1>把你喜欢的数字，<br /><em>留在链上地址里。</em></h1>
        <p>
          浏览器调用本机多核 CPU 并发穷举，匹配成功后当场给出
          TRON 地址和对应的 64 位十六进制私钥。
        </p>
      </section>

      <section className="workspace" aria-label="靓号生成器">
        <div className="config-panel panel">
          <div className="panel-heading">
            <div>
              <span className="step-label">01 / 设置规则</span>
              <h2>自定义数字</h2>
            </div>
            <span className={`difficulty difficulty-${difficulty}`}>难度·{difficulty}</span>
          </div>

          <div className="pattern-card">
            <div className="pattern-header">
              <label className="toggle-label">
                <input
                  type="checkbox"
                  checked={prefixEnabled}
                  disabled={status === "running"}
                  onChange={(event) => setPrefixEnabled(event.target.checked)}
                />
                <span className="toggle" aria-hidden="true" />
                <span>前段数字</span>
              </label>
              <code>T?{prefixEnabled ? prefix || "•".repeat(prefixLength) : ""}…</code>
            </div>
            <p className="field-note">
              从地址第 3 位开始匹配；<code>T</code> 是固定网络位，第 2 位受 Base58 编码范围限制。
            </p>
            <div className="length-row" aria-label="前段数字位数">
              {LENGTH_OPTIONS.map((length) => (
                <button
                  type="button"
                  key={length}
                  className={prefixLength === length ? "active" : ""}
                  disabled={!prefixEnabled || status === "running"}
                  onClick={() => {
                    setPrefixLength(length);
                    setPrefix((current) => current.slice(0, length));
                  }}
                >{length}</button>
              ))}
              <span>位</span>
            </div>
            <div className="input-wrap">
              <input
                aria-label="前段数字"
                inputMode="numeric"
                pattern="[1-9]*"
                placeholder={`输入 ${prefixLength} 位 1–9`}
                value={prefix}
                maxLength={prefixLength}
                disabled={!prefixEnabled || status === "running"}
                onChange={(event) => updatePattern(event.target.value, prefixLength, setPrefix)}
              />
              <span>{prefix.length}/{prefixLength}</span>
            </div>
          </div>

          <div className="pattern-card">
            <div className="pattern-header">
              <label className="toggle-label">
                <input
                  type="checkbox"
                  checked={suffixEnabled}
                  disabled={status === "running"}
                  onChange={(event) => setSuffixEnabled(event.target.checked)}
                />
                <span className="toggle" aria-hidden="true" />
                <span>尾号数字</span>
              </label>
              <code>…{suffixEnabled ? suffix || "•".repeat(suffixLength) : ""}</code>
            </div>
            <p className="field-note">从地址最后一位向前精确匹配。</p>
            <div className="length-row" aria-label="尾号数字位数">
              {LENGTH_OPTIONS.map((length) => (
                <button
                  type="button"
                  key={length}
                  className={suffixLength === length ? "active" : ""}
                  disabled={!suffixEnabled || status === "running"}
                  onClick={() => {
                    setSuffixLength(length);
                    setSuffix((current) => current.slice(0, length));
                  }}
                >{length}</button>
              ))}
              <span>位</span>
            </div>
            <div className="input-wrap">
              <input
                aria-label="尾号数字"
                inputMode="numeric"
                pattern="[1-9]*"
                placeholder={`输入 ${suffixLength} 位 1–9`}
                value={suffix}
                maxLength={suffixLength}
                disabled={!suffixEnabled || status === "running"}
                onChange={(event) => updatePattern(event.target.value, suffixLength, setSuffix)}
              />
              <span>{suffix.length}/{suffixLength}</span>
            </div>
          </div>

          <div className="thread-control">
            <div className="thread-title">
              <div>
                <span>并发线程</span>
                <small>检测到 {hardwareThreads} 个逻辑核心</small>
              </div>
              <output>{threadCount}</output>
            </div>
            <input
              aria-label="并发线程数"
              type="range"
              min="1"
              max={hardwareThreads}
              value={threadCount}
              disabled={status === "running"}
              onChange={(event) => setThreadPreference(Number(event.target.value))}
            />
            <div className="range-labels"><span>1</span><span>{hardwareThreads} 线程</span></div>
          </div>

          <div className="estimate-card">
            <div><span>理论平均尝试</span><strong>{formatNumber(expectedAttempts)}</strong></div>
            <div><span>按当前实测速度</span><strong>{formatDuration(estimatedRemaining)}</strong></div>
          </div>

          {activeDigits >= 7 && (
            <div className="warning-box" role="note">
              <strong>高难度提醒</strong>
              <span>前后共 {activeDigits} 位时，期望尝试量约为 58<sup>{activeDigits}</sup>，普通 CPU 可能需要极长时间。</span>
            </div>
          )}

          <div className="action-row">
            {status === "running" ? (
              <button type="button" className="stop-button" onClick={stopSearch}>
                <span className="stop-square" />停止生成
              </button>
            ) : (
              <button type="button" className="start-button" onClick={startSearch}>
                <span aria-hidden="true">▶</span>开始并发生成
              </button>
            )}
          </div>
          <p className="cpu-note">生成时 CPU 占用会明显上升；保留 1 个核心可让系统更流畅。</p>
        </div>

        <div className="monitor-column">
          <div className={`monitor-panel panel monitor-${status}`}>
            <div className="panel-heading">
              <div>
                <span className="step-label">02 / 运行状态</span>
                <h2>{status === "running" ? "正在穷举地址" : status === "found" ? "已找到匹配" : "等待开始"}</h2>
              </div>
              <span className="live-status">
                <i />{status === "running" ? `${threadCount} 线程运行中` : status === "found" ? "校验通过" : "未占用 CPU"}
              </span>
            </div>

            <div className="address-stream" aria-live="polite">
              <span>最新生成地址</span>
              <code>{sampleAddress}</code>
              <div className={status === "running" ? "scan-line active" : "scan-line"} />
            </div>

            <div className="metrics-grid">
              <div><span>已尝试</span><strong>{formatNumber(attempts)}</strong><small>个地址</small></div>
              <div><span>实时速度</span><strong>{speed > 0 ? formatNumber(Math.round(speed)) : "—"}</strong><small>{speed > 0 ? "地址 / 秒" : "等待样本"}</small></div>
              <div><span>运行时间</span><strong>{formatClock(elapsedMs)}</strong><small>{threadCount} 个 Web Workers</small></div>
            </div>

            <div className="probability-block">
              <div className="probability-title">
                <span>搜索参考进度</span>
                <strong>{expectedAttempts > 0 ? `${Math.min(100, (attempts / expectedAttempts) * 100).toFixed(4)}%` : "0%"}</strong>
              </div>
              <div className="progress-track"><span style={{ width: `${Math.min(100, (attempts / Math.max(expectedAttempts, 1)) * 100)}%` }} /></div>
              <p>随机搜索没有固定完成点；这里只是相对于期望尝试量的参考。</p>
            </div>
          </div>

          {result ? (
            <div className="result-panel panel" aria-live="assertive">
              <div className="success-mark" aria-hidden="true">✓</div>
              <div className="result-title">
                <span>匹配成功 · 私钥校验通过</span>
                <h2>你的 TRON 靓号已生成</h2>
                <p>{formatNumber(result.attempts)} 次尝试 · {formatClock(result.elapsedMs)}</p>
              </div>

              <div className="result-field">
                <div className="result-label">TRON 地址</div>
                <div><code>{result.address}</code><button type="button" onClick={() => copyText(result.address, "地址")}>复制</button></div>
              </div>
              <div className="result-field private-field">
                <div className="result-label">私钥 <span>64 位 HEX</span></div>
                <div>
                  <code>{privateKeyVisible ? result.privateKey : "•".repeat(32)}</code>
                  <button type="button" onClick={() => setPrivateKeyVisible((visible) => !visible)}>{privateKeyVisible ? "隐藏" : "显示"}</button>
                  <button type="button" onClick={() => copyText(result.privateKey, "私钥")}>复制</button>
                </div>
              </div>

              <div className="danger-note">
                <strong>私钥 = 资产控制权</strong>
                <span>请在断网环境备份，不要发给任何人，也不要截图上传。</span>
              </div>
              <div className="result-actions">
                <button type="button" className="download-button" onClick={downloadResult}>导出 TXT</button>
                <button type="button" className="clear-button" onClick={clearResult}>清除密钥</button>
              </div>
            </div>
          ) : (
            <div className="empty-result panel">
              <span className="step-label">03 / 生成结果</span>
              <div className="key-placeholder" aria-hidden="true"><span /><span /><span /></div>
              <h2>匹配后在这里显示私钥</h2>
              <p>页面不会记录、上传或自动保存你的生成结果。</p>
            </div>
          )}
        </div>
      </section>

      {(error || notice) && (
        <div className={error ? "toast toast-error" : "toast"} role={error ? "alert" : "status"}>
          <span>{error ? "!" : "✓"}</span>
          <p>{error || notice}</p>
          <button type="button" aria-label="关闭提示" onClick={() => { setError(null); setNotice(null); }}>×</button>
        </div>
      )}

      <footer>
        <p><strong>离线安全原则：</strong>生成前可断开网络；大额资产请优先使用经审计的硬件钱包。</p>
        <p>算法：secp256k1 → Keccak-256 → 0x41 网络前缀 → Base58Check</p>
      </footer>
    </main>
  );
}
