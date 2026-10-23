import { test, expect } from "bun:test"
import { shouldRemoteStart, buildStartEvent, activityStartedAt, needsRollover } from "./live-activity-start.ts"
import { buildLiveActivityPayload, LA_PAYLOAD_MAX_BYTES } from "./apns.ts"
import { emptyLaTokenStore, type LaTokenStore, type LaUpdateRecord } from "./live-activity-tokens.ts"

function store(o: { update?: Array<[string, string]>; start?: string[] } = {}): LaTokenStore {
  const s = emptyLaTokenStore()
  for (const [activityId, session] of o.update ?? []) {
    s.update[activityId] = {
      token: "a".repeat(64), session_name: session, install_id: "I1",
      env: "sandbox", preview: "hidden", updated_at: 0,
    }
  }
  for (const installId of o.start ?? []) {
    s.start[installId] = { token: "b".repeat(64), install_id: installId, env: "sandbox", preview: "hidden", updated_at: 0 }
  }
  return s
}

// ── shouldRemoteStart 四象限：有/无 update 记录 × 跳变方向 ──

test("无岛 + idle→working → 起岛", () => {
  expect(shouldRemoteStart(store({ start: ["I1"] }), "mp-cc-a", "idle", "working")).toBe(true)
})

test("无岛 + working→waiting（不是从 idle/done 起跳）→ 不起岛", () => {
  // 这一跳在「已经有岛」的世界里是常态；没岛也不起，起岛只认一轮的开头。
  expect(shouldRemoteStart(store({ start: ["I1"] }), "mp-cc-a", "working", "waiting")).toBe(false)
})

test("有该 session 的 update 记录 + idle→working → 不起岛（单 activity 互斥）", () => {
  const s = store({ update: [["ACT-1", "mp-cc-a"]], start: ["I1"] })
  expect(shouldRemoteStart(s, "mp-cc-a", "idle", "working")).toBe(false)
})

test("有 update 记录 + working→waiting → 不起岛（两条都不满足）", () => {
  const s = store({ update: [["ACT-1", "mp-cc-a"]], start: ["I1"] })
  expect(shouldRemoteStart(s, "mp-cc-a", "working", "waiting")).toBe(false)
})

test("done→waiting 也算一轮的开头", () => {
  expect(shouldRemoteStart(store({ start: ["I1"] }), "mp-cc-a", "done", "waiting")).toBe(true)
})

test("别的 session 的岛不挡本 session 起岛", () => {
  const s = store({ update: [["ACT-1", "mp-cc-OTHER"]], start: ["I1"] })
  expect(shouldRemoteStart(s, "mp-cc-a", "idle", "working")).toBe(true)
})

test("一条 start 记录都没有 → 起不了（没设备报过 push-to-start token）", () => {
  expect(shouldRemoteStart(store(), "mp-cc-a", "idle", "working")).toBe(false)
})

test("working→done / idle→done 不起岛", () => {
  const s = store({ start: ["I1"] })
  expect(shouldRemoteStart(s, "mp-cc-a", "working", "done")).toBe(false)
  expect(shouldRemoteStart(s, "mp-cc-a", "idle", "done")).toBe(false)
})

// ── buildStartEvent → buildLiveActivityPayload 的字节契约 ──

function aps(ev: ReturnType<typeof buildStartEvent>, now = 1_700_000_000) {
  const json = buildLiveActivityPayload(ev, now)
  return { json, aps: JSON.parse(json).aps as Record<string, any> }
}

test("start payload 四件套齐全 + 小于 4KB", () => {
  const { json, aps: a } = aps(buildStartEvent("mp-cc-a", {
    phase: "working", model: "Opus", ctx: 42, five_hour: 7, seven_day: 8,
    since_unix: 1_699_999_000, run_id: "r-1-1", updated_unix: 1_700_000_000,
  }))
  expect(a.event).toBe("start")
  // alert 漏了 → Apple 直接拒绝启动，所以它是硬断言不是可选项
  expect(a.alert).toEqual({ title: "记忆花园", body: "Claude Code 开始干活了" })
  expect(a["attributes-type"]).toBe("CCActivityAttributes")   // 类型名，不是全限定名
  expect(a.attributes).toEqual({ session_name: "mp-cc-a" })
  expect(a["input-push-token"]).toBe(1)                       // 少了它 = 起一个拿不到 update token 的死岛
  expect(a["content-state"].phase).toBe("working")
  expect(a["content-state"].run_id).toBe("r-1-1")
  expect(Buffer.byteLength(json, "utf8")).toBeLessThan(LA_PAYLOAD_MAX_BYTES)
})

test("waiting 换另一句固定文案", () => {
  const { aps: a } = aps(buildStartEvent("mp-cc-a", { phase: "waiting", updated_unix: 1 }))
  expect(a.alert).toEqual({ title: "记忆花园", body: "Claude Code 在等你" })
})

test("alert 永远不带题面（R9：它会真的弹到锁屏上）", () => {
  const secret = "把 axismundi 的仓位表贴出来"
  const { aps: a } = aps(buildStartEvent("mp-cc-a", { phase: "waiting", detail: secret, updated_unix: 1 }))
  expect(JSON.stringify(a.alert)).not.toContain(secret)
  // detail 本身进 content-state 是合法的：它在上游已经按该记录的 preview 过滤过
  expect(a["content-state"].detail).toBe(secret)
})

test("attributes 走 encodeAttributes：只有 session_name 一个键", () => {
  const { aps: a } = aps(buildStartEvent("mp-cc-a", { phase: "working", updated_unix: 1 }))
  expect(Object.keys(a.attributes)).toEqual(["session_name"])
})

// ── ⑤ 8h 滚动换岛的判据 ──

function upd(o: Partial<LaUpdateRecord> = {}): LaUpdateRecord {
  return {
    token: "a".repeat(64), session_name: "mp-cc-a", install_id: "I1",
    env: "sandbox", preview: "hidden", updated_at: 0, ...o,
  }
}

test("started_at 是毫秒，读出来是秒；缺字段退回 updated_at", () => {
  expect(activityStartedAt(upd({ started_at: 1_700_000_000_000, updated_at: 1_700_009_999_000 }))).toBe(1_700_000_000)
  // M5 之前的旧记录
  expect(activityStartedAt(upd({ updated_at: 1_700_000_500_000 }))).toBe(1_700_000_500)
})

test("过阈值 + working/waiting → 换岛；没过 / done / idle → 不换", () => {
  const r = upd({ started_at: 1_700_000_000_000 })
  const now = 1_700_000_000 + 27_001
  expect(needsRollover(r, "working", now, 27_000)).toBe(true)
  expect(needsRollover(r, "waiting", now, 27_000)).toBe(true)
  expect(needsRollover(r, "done", now, 27_000)).toBe(false)
  expect(needsRollover(r, "idle", now, 27_000)).toBe(false)
  expect(needsRollover(r, "working", 1_700_000_000 + 26_999, 27_000)).toBe(false)
})
