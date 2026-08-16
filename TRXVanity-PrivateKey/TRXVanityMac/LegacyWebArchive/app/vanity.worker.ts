/// <reference lib="webworker" />

import { generateTronKeypair } from "./lib/tron";

type StartMessage = {
  type: "start";
  jobId: number;
  workerId: number;
  prefix: string;
  suffix: string;
  prefixOffset: number;
};

type StopMessage = {
  type: "stop";
  jobId: number;
};

type WorkerCommand = StartMessage | StopMessage;

const workerScope = self as DedicatedWorkerGlobalScope;
const BATCH_SIZE = 192;
const REPORT_INTERVAL_MS = 220;
let activeJobId: number | null = null;

function pause(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function search(command: StartMessage): Promise<void> {
  const { jobId, workerId, prefix, suffix, prefixOffset } = command;
  let attempts = 0;
  let lastReport = performance.now();
  let sampleAddress = "";

  try {
    while (activeJobId === jobId) {
      for (let index = 0; index < BATCH_SIZE; index += 1) {
        if (activeJobId !== jobId) return;

        const keypair = generateTronKeypair();
        attempts += 1;
        sampleAddress = keypair.address;

        const prefixMatches =
          prefix.length === 0 ||
          keypair.address.startsWith(prefix, prefixOffset);
        const suffixMatches =
          suffix.length === 0 || keypair.address.endsWith(suffix);

        if (prefixMatches && suffixMatches) {
          workerScope.postMessage({
            type: "found",
            jobId,
            workerId,
            attempts,
            address: keypair.address,
            privateKey: keypair.privateKey,
          });
          activeJobId = null;
          return;
        }
      }

      const now = performance.now();
      if (now - lastReport >= REPORT_INTERVAL_MS) {
        workerScope.postMessage({
          type: "progress",
          jobId,
          workerId,
          attempts,
          sampleAddress,
        });
        lastReport = now;
      }

      await pause();
    }
  } catch (error) {
    workerScope.postMessage({
      type: "error",
      jobId,
      workerId,
      message: error instanceof Error ? error.message : "生成线程发生未知错误。",
    });
    activeJobId = null;
  }
}

workerScope.addEventListener("message", (event: MessageEvent<WorkerCommand>) => {
  const command = event.data;

  if (command.type === "stop") {
    if (activeJobId === command.jobId) activeJobId = null;
    return;
  }

  activeJobId = command.jobId;
  void search(command);
});

export {};

