import { describe, expect, test } from "bun:test"
import { buildSessionPhaseFrame, phaseFrameChanged, sendPhaseAfter, sessionPhaseSnapshotFrames } from "./session-phase"

// 进度卡 B（粟粟 10-03「都按推荐」）：CC 的 phase 也发给聊天页（不只终端页 / 灵动岛）
describe("session_phase 帧", () => {
  test("带 phase / 题面 / 开始时刻 / 能不能停", () => {
    const f = JSON.parse(buildSessionPhaseFrame("mp-cc", { phase: "waiting", detail: "选哪个？", since_unix: 100, updated_unix: 130, run_id: "r-1" }, true, "conv-1"))
    expect(f).toEqual({ type: "session_phase", session_name: "mp-cc", chat_id: "conv-1", phase: "waiting", detail: "选哪个？", since_unix: 100, updated_unix: 130, can_stop: true })
  })
  test("没有的字段不带", () => {
    const f = JSON.parse(buildSessionPhaseFrame("mp-cc", { phase: "done", updated_unix: 5 }, false))
    expect(f).toEqual({ type: "session_phase", session_name: "mp-cc", phase: "done", updated_unix: 5, can_stop: false })
  })
  test("只在 phase / 这一轮 / 题面变了才推（看门狗每 tick 改 last_progress_at 不推）", () => {
    const base = { phase: "working" as const, since_unix: 1, run_id: "r-1", updated_unix: 1 }
    expect(phaseFrameChanged(undefined, base)).toBe(true)
    expect(phaseFrameChanged(base, { ...base, updated_unix: 9, last_progress_at: 9 })).toBe(false)
    expect(phaseFrameChanged(base, { ...base, phase: "done" })).toBe(true)
    expect(phaseFrameChanged(base, { ...base, run_id: "r-2" })).toBe(true)
    expect(phaseFrameChanged({ ...base, phase: "waiting", detail: "a" }, { ...base, phase: "waiting", detail: "b" })).toBe(true)
  })
  test("新连上的 app 补一份现状，idle 不发", () => {
    const frames = sessionPhaseSnapshotFrames(new Map([
      ["mp-cc", { phase: "working" as const, since_unix: 1, updated_unix: 1 }],
      ["mp-old", { phase: "idle" as const, updated_unix: 1 }],
    ]), s => s === "mp-cc", s => s === "mp-cc" ? "conv-9" : undefined)
    expect(frames.map(f => JSON.parse(f).session_name)).toEqual(["mp-cc"])
    expect(JSON.parse(frames[0]).chat_id).toBe("conv-9")
    expect(JSON.parse(frames[0]).can_stop).toBe(true)
  })
})

describe("sendPhaseAfter（K3 R1：补数失败照发、不留悬空 rejection）", () => {
  const done = { phase: "done" as const, run_id: "r1", updated_unix: 5 }
  test("补数成功 / 失败都照发当前快照；phase 又跳了不发；send 抛了也不 reject", async () => {
    const unhandled: unknown[] = []
    const onUnhandled = (e: unknown) => { unhandled.push(e) }
    process.on("unhandledRejection", onUnhandled)
    try {
      const sent: string[] = []
      const later = { ...done, updated_unix: 6 }
      await sendPhaseAfter(Promise.resolve(true), done, () => later, (s) => sent.push(`${s.phase}@${s.updated_unix}`))
      await sendPhaseAfter(Promise.reject(new TypeError("transcript 坏了")), done, () => done, (s) => sent.push(`${s.phase}@${s.updated_unix}`))
      await sendPhaseAfter(Promise.resolve(false), done, () => ({ phase: "working", run_id: "r2", updated_unix: 7 }), (s) => sent.push(s.phase))
      await sendPhaseAfter(Promise.resolve(false), done, () => undefined, (s) => sent.push(s.phase))
      expect(sent).toEqual(["done@6", "done@5"])
      await expect(sendPhaseAfter(Promise.resolve(false), done, () => done, () => { throw new Error("ws 炸了") })).resolves.toBeUndefined()
      await new Promise((r) => setTimeout(r, 10))
      expect(unhandled).toEqual([])
    } finally { process.off("unhandledRejection", onUnhandled) }
  })
})
