// 刀 K2（docs/plan-hub-perf.md）：warroom 普查扫描的 Worker 线程入口（主线程一侧见 warroom-scan-client.ts）。
// 自己开一条连接到同一个 warroom.db（WAL），跑 scanAllBatched；结果 + 这一轮的阻塞账送回主线程。
// K2 开时主连接关了自动检查点：这里每轮扫完（不论有没有写）无条件做一次 PASSIVE 检查点，另有只做检查点的请求（扫描被跳过时）
// 这里的同步 stat / 读文件 / sqlite 只卡这个线程，站点名是 warroom-worker …，不进主线程的卡顿归因。
declare var self: Worker
import { blockLedger, type BlockStat } from "./block-ledger"
import { realLiveness, WarroomIndexer, WORKER_BUSY_TIMEOUT_MS } from "./warroom-indexer"
import type { ScanReply, ScanRequest } from "./warroom-scan-client"

let indexer: WarroomIndexer | null = null

/// 送回去的是这一轮的增量：送完清空，主线程那边累加
function takeBlock(): Array<[string, BlockStat]> {
  const b = [...blockLedger.stats]
  blockLedger.stats.clear()
  return b
}

self.onmessage = async (ev: MessageEvent<ScanRequest>) => {
  const req = ev.data
  const t0 = Date.now()
  let reply: ScanReply
  try {
    if (!indexer) {
      indexer = new WarroomIndexer({ ...req.opts, busyTimeoutMs: WORKER_BUSY_TIMEOUT_MS })
      // 普查表随时能从 transcript 重建，提交不必等 fsync（WAL 下 NORMAL 断电最多丢最后几批，不会坏库）：
      // 写锁只占「几条写 + 追加 WAL」那一下，主线程账本写撞上时少等。主连接的提交照旧 FULL
      indexer.db.exec("PRAGMA synchronous = NORMAL")
    }
    const r = req.kind === "checkpoint" ? { scanned: 0, changed: 0 } : await indexer.scanAllBatched(req.liveness === "none" ? async () => [] : realLiveness)
    const checkpoint = indexer.checkpoint()
    reply = { type: "done", id: req.id, scanned: r.scanned, changed: r.changed, ms: Date.now() - t0, block: takeBlock(), checkpoint }
  } catch (e) {
    // 连接坏了下一轮重开
    try { indexer?.close() } catch {}
    indexer = null
    reply = { type: "fail", id: req.id, error: (e as Error)?.message ?? String(e), block: takeBlock() }
  }
  postMessage(reply)
}

// K2 审查 R1-4：import 都成功、handler 装好了才算启动成功（ModuleNotFound / 加载就崩都发生在这之前）
postMessage({ type: "ready" } satisfies ScanReply)
