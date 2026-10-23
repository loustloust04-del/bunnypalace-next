#!/usr/bin/env bun
/// 秒连账本统计：`bun scripts/connect-ledger.ts [--hours 24] [--file <path>] [--trigger terminal]`
/// 秒连率（≤1s）/ p50 / p95 / 最慢，慢的逐条列理由，理由按类计数。分位数 nearest-rank（见 connect-ledger.ts quantile）。
/// 只有「连上了并且报告送到 hub」的样本：永远连不上 / 报告前被杀的进程不在账上。

import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { STATS_REV, describeDist, quantile, rulerGroupKey, rulerMetrics, runTotals } from "../connect-ledger"

const args = process.argv.slice(2)
const opt = (k: string) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined }
const hours = Number(opt("--hours") ?? 24)
const file = opt("--file") ?? join(process.env.MP_CC_SECRETS_DIR ?? join(import.meta.dir, "..", "secrets"), "connect-ledger.jsonl")
if (!existsSync(file)) { console.log(`没有账本：${file}`); process.exit(0) }

const since = Date.now() - hours * 3_600_000
const rows = readFileSync(file, "utf8").split("\n").filter(Boolean)
  .map(l => { try { return JSON.parse(l) } catch { return null } })
  .filter((r): r is any => r && r.at >= since)
  .filter(r => !opt("--trigger") || r.trigger === opt("--trigger"))   // --trigger terminal 只看终端出字
if (!rows.length) { console.log(`近 ${hours}h 没有记录`); process.exit(0) }

// 顶部汇总剔除冷启动预热（预热进程的 t0 退到开始连，不是点开时刻）
const warm = rows.filter(r => r.trigger === "launch" && r.prewarm)
const head = rows.filter(r => !(r.trigger === "launch" && r.prewarm))
const ms = head.map(r => r.totalMs as number).sort((a, b) => a - b)
const fast = head.filter(r => r.fast).length
const clock = (t: number) => new Date(t).toLocaleString("zh-CN", { hour12: false })
console.log(`[${STATS_REV}] 仅成功上报样本（连不上 / 报告前被杀的不在账上）；已剔除冷启动预热 ${warm.length} 次`)
if (ms.length) console.log(`近 ${hours}h 连接 ${head.length} 次 · 秒连（≤1s）${fast}/${head.length} = ${(100 * fast / head.length).toFixed(1)}% · p50 ${quantile(ms, 0.5)}ms · p95 ${quantile(ms, 0.95)}ms · 最慢 ${ms[ms.length - 1]}ms`)

const byTrigger = new Map<string, number[]>()
for (const r of head) byTrigger.set(r.trigger, [...(byTrigger.get(r.trigger) ?? []), r.totalMs])
for (const [t, v] of byTrigger) {
  v.sort((a, b) => a - b)
  console.log(`  ${t.padEnd(10)} ${String(v.length).padStart(4)} 次 · p50 ${quantile(v, 0.5)}ms · 最慢 ${v[v.length - 1]}ms`)
}

// 尺子拆分（connectV2 起的 app 才有；冷启动去掉预热）。分组 = trigger · 平台 · 设备 × 包（LC_UUID）× 开关 · rev
const ruled = rows.filter(r => typeof r.rev === "string" && r.trigger !== "terminal")
if (ruled.length) {
  const groups = new Map<string, any[]>()
  for (const r of ruled) groups.set(rulerGroupKey(r), [...(groups.get(rulerGroupKey(r)) ?? []), r])
  console.log(`\n尺子拆分 [${STATS_REV}]（${ruled.length} 次带新字段；仅成功上报样本；各行分位数各自排序，不能相加；n<5 列原始值）：`)
  for (const [k, g] of [...groups].sort((a, b) => b[1].length - a[1].length)) {
    const split = rulerMetrics(g)
    const t = runTotals(g)
    const src = new Map<string, number>()
    for (const r of g) if (r.trigger === "launch") src.set(r.launchSrc ?? "?", (src.get(r.launchSrc ?? "?") ?? 0) + 1)
    console.log(`  ${k}（${g.length} 次）`)
    console.log(`    进程 ${t.runs} 个：开段 ${t.started} / 连上 ${t.ok} / 被换掉 ${t.replaced} / 报告发送失败 ${t.reportFailed}（失败那份不在账上）`)
    if (src.size) console.log(`    启动来源：${[...src].map(([s, n]) => `${s} ${n}`).join(" · ")}`)
    const skipped = [split.prewarm && `预热 ${split.prewarm}`, split.capped && `忙段窗口截断 ${split.capped}`,
      split.disordered && `启动分段逆序（不可分解）${split.disordered}`, split.invalid && `WS 归属作废 ${split.invalid}`].filter(Boolean)
    if (skipped.length) console.log(`    单列（不进分位数）：${skipped.join(" · ")}`)
    for (const m of split.metrics) console.log(`    ${m.name.padEnd(24)} ${describeDist(m.values)}`)
  }
}

const slow = rows.filter(r => !r.fast)
if (!slow.length) { console.log("没有慢的 ✅"); process.exit(0) }
const kinds = new Map<string, number>()
for (const r of slow) for (const why of r.reasons as string[]) {
  const k = why.replace(/（.*?）/g, "").replace(/\s*\d[\d,]*\s*(ms|次)?/g, "").trim()
  kinds.set(k, (kinds.get(k) ?? 0) + 1)
}
console.log(`\n慢 ${slow.length} 次，理由分布：`)
for (const [k, n] of [...kinds].sort((a, b) => b[1] - a[1])) console.log(`  ${String(n).padStart(4)}  ${k}`)
console.log("\n逐条：")
for (const r of slow) {
  console.log(`  ${clock(r.t0)}  ${String(r.totalMs).padStart(6)}ms  ${r.trigger.padEnd(10)} ${r.platform ?? "?"}@${r.from}${r.session ? ` ${r.session}` : ""}  ${r.reasons.join("；")}`)
}
