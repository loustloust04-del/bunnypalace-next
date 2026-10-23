import { expect, test } from "bun:test"
import { existsSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { DirtyDirScanner } from "./dir-watch"
import { drainThinkingSpool } from "./hub"

const waitFor = async (cond: () => boolean, ms = 3_000) => {
  for (const t0 = Date.now(); !cond() && Date.now() - t0 < ms;) await new Promise((r) => setTimeout(r, 20))
  return cond()
}

test("DirtyDirScanner：首轮必扫；没动静不扫；目录有新文件才扫；扫完有剩的下轮接着扫", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-bridge-dirwatch-"))
  let scans = 0, left = 0
  const s = new DirtyDirScanner(dir, async () => { scans++; return left }, 60_000)
  s.arm()
  expect(s.watching).toBe(true)
  expect(await s.tick()).toBe(true)
  expect(await s.tick()).toBe(false)
  expect(scans).toBe(1)
  writeFileSync(join(dir, "a.json"), "{}")
  expect(await waitFor(() => { void s.tick(); return scans === 2 })).toBe(true)
  left = 1
  writeFileSync(join(dir, "b.json"), "{}")
  expect(await waitFor(() => { void s.tick(); return scans === 3 })).toBe(true)
  await new Promise((r) => setTimeout(r, 20))
  left = 0
  expect(await s.tick()).toBe(true)              // 上一轮留了 1 个：接着扫
  expect(scans).toBe(4)
  s.close()
})

test("DirtyDirScanner：兜底周期 / 目录不在就每次都扫 / 扫的时候不重入 / scan 抛了下轮再扫", async () => {
  let clock = 0
  const dir = mkdtempSync(join(tmpdir(), "cc-bridge-dirwatch-"))
  let scans = 0
  const s = new DirtyDirScanner(dir, async () => { scans++; return 0 }, 1_000, () => clock)
  s.arm()
  await s.tick()
  clock = 999; expect(await s.tick()).toBe(false)
  clock = 1_000; expect(await s.tick()).toBe(true)
  expect(scans).toBe(2)
  s.close()

  const missing = new DirtyDirScanner(join(dir, "nope"), async () => { scans++; return 0 }, 60_000)
  scans = 0
  await missing.tick(); await missing.tick()
  expect(missing.watching).toBe(false)
  expect(scans).toBe(2)

  let release!: () => void
  const slow = new DirtyDirScanner(join(dir, "nope"), () => new Promise<number>((r) => { release = () => r(0) }), 60_000)
  const first = slow.tick()
  expect(await slow.tick()).toBe(false)
  release(); expect(await first).toBe(true)

  let fail = true
  scans = 0
  const flaky = new DirtyDirScanner(dir, async () => { scans++; if (fail) throw new Error("EIO"); return 0 }, 60_000)
  flaky.arm()
  await flaky.tick(); fail = false
  await flaky.tick(); await flaky.tick()
  expect(scans).toBe(2)
  flaky.close()
})

test("drainThinkingSpool（K3 异步）：刚写的留着、坏文件留着（7 天后删）、能投的投完删掉", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-bridge-spool-"))
  const old = (p: string, ageMs: number) => { const t = new Date(Date.now() - ageMs); utimesSync(p, t, t) }
  writeFileSync(join(dir, "1-fresh.json"), JSON.stringify({ chat_id: "c" }))
  writeFileSync(join(dir, "2-invalid.json"), JSON.stringify({}));            old(join(dir, "2-invalid.json"), 60_000)
  writeFileSync(join(dir, "3-bad.json"), "{坏");                             old(join(dir, "3-bad.json"), 60_000)
  writeFileSync(join(dir, "4-ancient.json"), "{坏");                         old(join(dir, "4-ancient.json"), 8 * 86_400_000)
  writeFileSync(join(dir, "ignored.txt"), "x")
  expect(await drainThinkingSpool(dir)).toEqual({ delivered: 1, left: 2 })
  expect(existsSync(join(dir, "1-fresh.json"))).toBe(true)
  expect(existsSync(join(dir, "2-invalid.json"))).toBe(false)   // 400 也算投过（和原来一样删掉）
  expect(existsSync(join(dir, "3-bad.json"))).toBe(true)
  expect(existsSync(join(dir, "4-ancient.json"))).toBe(false)
  rmSync(dir, { recursive: true })
  expect(await drainThinkingSpool(dir)).toEqual({ delivered: 0, left: 0 })
})
