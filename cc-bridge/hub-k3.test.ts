// K3（plan-hub-perf）：热路径上的同步盘读改异步 / 按需。只测语义保持，不起 hub。
import { expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { scanT1Receipts, serialRound } from "./hub"
import { WarroomLedger } from "./warroom-ledger"

const BASE = { title: "补测试", body: "把 reader-daemon 的测试补完", target_kind: "tmux" as const, engine: "claude" as const, created_by: "zhongshu" }

test("T1 收据：只认在等的单（dispatched / working），坏收据留着下次再看，没单在等不碰目录", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-bridge-k3-receipts-"))
  const l = new WarroomLedger(join(dir, "l.db"))
  const receipts = join(dir, "receipts")
  // 目录不存在、也没单在等：直接 0
  expect(await scanT1Receipts(l, receipts)).toBe(0)
  mkdirSync(receipts)
  const a = l.createTask({ ...BASE, target_ref: "mp-cc-a" }); l.transition(a.task_id, "dispatched", "hub")
  const b = l.createTask({ ...BASE, target_ref: "mp-cc-b" }); l.transition(b.task_id, "dispatched", "hub"); l.transition(b.task_id, "working", "hub")
  const c = l.createTask({ ...BASE, target_ref: "mp-cc-c" }); l.transition(c.task_id, "dispatched", "hub")
  const draft = l.createTask({ ...BASE, target_ref: "mp-cc-d" })
  writeFileSync(join(receipts, `${a.task_id}.json`), JSON.stringify({ status: "done", summary: "a" }))
  writeFileSync(join(receipts, `${b.task_id}.json`), JSON.stringify({ status: "done", summary: "b" }))
  writeFileSync(join(receipts, `${c.task_id}.json`), "{坏的")
  writeFileSync(join(receipts, `${draft.task_id}.json`), JSON.stringify({ status: "done" }))
  writeFileSync(join(receipts, "zz-0000-99.json"), JSON.stringify({ status: "done" }))   // 账本里没有
  expect(await scanT1Receipts(l, receipts)).toBe(2)
  expect(l.getTask(a.task_id)?.status).toBe("evidence_in")
  expect(JSON.parse(l.getTask(a.task_id)!.receipt!).summary).toBe("a")
  expect(l.getTask(b.task_id)?.status).toBe("evidence_in")
  expect(l.getTask(c.task_id)?.status).toBe("dispatched")
  expect(l.getTask(draft.task_id)?.status).toBe("draft")
  // 收下的不再收；坏的修好了下次收
  writeFileSync(join(receipts, `${c.task_id}.json`), JSON.stringify({ status: "blocked", summary: "c" }))
  expect(await scanT1Receipts(l, receipts)).toBe(1)
  expect(l.getTask(c.task_id)?.status).toBe("evidence_in")
  expect(await scanT1Receipts(l, receipts)).toBe(0)
  l.close()
})

test("serialRound（审查 R1-6）：收据还没读完，下一 tick 整轮跳过（不开庭）；开庭总在本轮收据之后；收据抛了照开庭不 reject", async () => {
  const order: string[] = []
  let release!: () => void
  let slow = true
  const errors: unknown[] = []
  const round = serialRound(
    () => slow ? new Promise<void>((r) => { order.push("scan"); release = () => { order.push("scan done"); r() } }) : Promise.reject(new Error("db")),
    () => order.push("inspect"),
    (e) => errors.push(e),
  )
  expect(round()).toBe(true)
  expect(round()).toBe(false)          // 30s 后的 tick：上一轮还在读，整轮跳过
  await new Promise((r) => setTimeout(r, 5))
  expect(order).toEqual(["scan"])      // 没有抢先开庭
  release()
  await new Promise((r) => setTimeout(r, 5))
  expect(order).toEqual(["scan", "scan done", "inspect"])
  slow = false
  expect(round()).toBe(true)
  await new Promise((r) => setTimeout(r, 5))
  expect(order.at(-1)).toBe("inspect")
  expect(errors.length).toBe(1)
  expect(round()).toBe(true)           // 抛过之后不会卡在 running
})

test("T1 收据（审查 R1-3）：501 张在等的单只有最老的有收据，一轮最多 500 单，游标轮转下一轮就收到", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-bridge-k3-receipts-"))
  const l = new WarroomLedger(join(dir, "l.db"))
  const receipts = join(dir, "receipts")
  mkdirSync(receipts)
  // 直接插 501 张 dispatched（createTask 的单号一天只到 99）；task_id 越小越老
  const ins = l.db.query(`INSERT INTO tasks(task_id, title, body, target_kind, target_ref, engine, status, approval, created_by, created_at)
    VALUES (?, 't', 'b', 'tmux', ?, 'claude', 'dispatched', 'auto', 'x', ?)`)
  for (let i = 0; i < 501; i++) ins.run(`zz-0101-${String(i).padStart(4, "0")}`, `mp-cc-${i}`, new Date(1_700_000_000_000 + i * 1000).toISOString())
  writeFileSync(join(receipts, "zz-0101-0000.json"), JSON.stringify({ status: "done", summary: "最老的" }))
  const cursor = { after: "" }
  // 第一轮：0000..0499，最老的那张就在里面
  expect(await scanT1Receipts(l, receipts, cursor)).toBe(1)
  expect(l.getTask("zz-0101-0000")?.status).toBe("evidence_in")
  // 小页模拟：一轮 200 单，收据在最后一张（0500），第三轮轮到它；之后从头再转
  writeFileSync(join(receipts, "zz-0101-0500.json"), JSON.stringify({ status: "done" }))
  const c2 = { after: "" }
  expect(await scanT1Receipts(l, receipts, c2, 200)).toBe(0)
  expect(c2.after).toBe("zz-0101-0200")
  expect(await scanT1Receipts(l, receipts, c2, 200)).toBe(0)
  expect(await scanT1Receipts(l, receipts, c2, 200)).toBe(1)   // 第三轮轮到 0500
  expect(l.getTask("zz-0101-0500")?.status).toBe("evidence_in")
  expect(c2.after).toBe("zz-0101-0100")                        // 0401..0500 不满一页，补转开头 0001..0100 凑满，下一轮从 0101 接着
  l.close()
})
