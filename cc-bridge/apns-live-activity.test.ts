// Live Activity 远程更新路径：payload builder（纯函数）+ sendLiveActivityAPNs 的 host/header 选路。
// 同样全程假 http2，不连真 APNs。
import { afterEach, expect, test } from "bun:test"
import { __setAPNsTestHooks, buildLiveActivityPayload, LA_PAYLOAD_MAX_BYTES, LaPayloadTooLargeError, sendLiveActivityAPNs } from "./apns.ts"
import { installTransport, respondWith } from "./apns-fake-transport.ts"

const EXPECTED_TOPIC = process.env.MP_APNS_TOPIC || "com.susu.MemoryPalace.ios"
const TOKEN = "b".repeat(64)
const TS_UNIX = 1756472400

afterEach(() => { __setAPNsTestHooks() })

test("update：aps 只有 timestamp / event / content-state", () => {
  const p = buildLiveActivityPayload({ event: "update", contentState: { phase: "working" } }, TS_UNIX)
  expect(JSON.parse(p)).toEqual({
    aps: { timestamp: TS_UNIX, event: "update", "content-state": { phase: "working" } },
  })
})

test("update：stale-date / relevance-score / alert 用 Apple 的连字符键名", () => {
  const p = buildLiveActivityPayload({
    event: "update",
    contentState: { phase: "waiting" },
    staleDateUnix: TS_UNIX + 600,
    relevanceScore: 75,
    alert: { title: "要批注", body: "M4 拆两步？" },
  }, TS_UNIX)
  expect(JSON.parse(p)).toEqual({
    aps: {
      timestamp: TS_UNIX,
      event: "update",
      "content-state": { phase: "waiting" },
      "stale-date": TS_UNIX + 600,
      "relevance-score": 75,
      alert: { title: "要批注", body: "M4 拆两步？" },
    },
  })
})

test("end：dismissal-date，且不带 stale-date / relevance-score", () => {
  const p = buildLiveActivityPayload({
    event: "end",
    contentState: { phase: "done" },
    dismissalDateUnix: TS_UNIX + 60,
  }, TS_UNIX)
  expect(JSON.parse(p)).toEqual({
    aps: { timestamp: TS_UNIX, event: "end", "content-state": { phase: "done" }, "dismissal-date": TS_UNIX + 60 },
  })
})

test("start：attributes-type / attributes / input-push-token 落 1（M5 用，本 lane 不发）", () => {
  const p = buildLiveActivityPayload({
    event: "start",
    contentState: { phase: "idle" },
    attributesType: "CCSessionAttributes",
    attributes: { session_name: "mp-cc" },
    alert: { title: "mp-cc 开工", body: "Opus 5" },
    inputPushToken: true,
  }, TS_UNIX)
  expect(JSON.parse(p)).toEqual({
    aps: {
      timestamp: TS_UNIX,
      event: "start",
      "content-state": { phase: "idle" },
      "attributes-type": "CCSessionAttributes",
      attributes: { session_name: "mp-cc" },
      "input-push-token": 1,
      alert: { title: "mp-cc 开工", body: "Opus 5" },
    },
  })
})

test("start：inputPushToken 没给就不落键", () => {
  const p = buildLiveActivityPayload({
    event: "start",
    contentState: { phase: "idle" },
    attributesType: "A",
    attributes: {},
    alert: { title: "t", body: "b" },
  }, TS_UNIX)
  expect(JSON.parse(p).aps["input-push-token"]).toBeUndefined()
})

test("4 KB 边界：恰好 4096 合法，4097 就 throw", () => {
  const empty = buildLiveActivityPayload({ event: "update", contentState: { phase: "working", detail: "" } }, TS_UNIX)
  const pad = LA_PAYLOAD_MAX_BYTES - Buffer.byteLength(empty, "utf8")

  const exact = buildLiveActivityPayload(
    { event: "update", contentState: { phase: "working", detail: "x".repeat(pad) } },
    TS_UNIX,
  )
  expect(Buffer.byteLength(exact, "utf8")).toBe(LA_PAYLOAD_MAX_BYTES)

  expect(() => buildLiveActivityPayload(
    { event: "update", contentState: { phase: "working", detail: "x".repeat(pad + 1) } },
    TS_UNIX,
  )).toThrow(LaPayloadTooLargeError)
})

test("4 KB 防线按 UTF-8 字节算，不是按 JS 字符数", () => {
  // 中文一个字 3 字节：1400 字 ≈ 4200 字节，字符数才 1400
  let thrown: unknown
  try {
    buildLiveActivityPayload({ event: "update", contentState: { phase: "working", detail: "宫".repeat(1400) } }, TS_UNIX)
  } catch (e) { thrown = e }
  expect(thrown).toBeInstanceOf(LaPayloadTooLargeError)
  expect((thrown as LaPayloadTooLargeError).bytes).toBeGreaterThan(LA_PAYLOAD_MAX_BYTES)
})

test("content-state 走 encodeContentState：键字母序、undefined 不落键", () => {
  const p = buildLiveActivityPayload({
    event: "update",
    contentState: { phase: "waiting", ctx: 47, model: undefined, run_id: "r1" },
  }, TS_UNIX)
  // 逐字节：content-state 段必须是排序后的紧凑 JSON
  expect(p).toContain('"content-state":{"ctx":47,"phase":"waiting","run_id":"r1"}')
})

test("sendLiveActivityAPNs：header = 派生 topic + liveactivity + priority", async () => {
  const t = installTransport(respondWith(200))
  const r = await sendLiveActivityAPNs(
    { token: TOKEN, env: "sandbox" },
    { event: "update", contentState: { phase: "working" } },
    { priority: 10, timestampUnix: TS_UNIX },
  )
  expect(r).toEqual({ ok: true, status: 200 })

  const h = t.clients[0].headers!
  expect(h[":method"]).toBe("POST")
  expect(h[":path"]).toBe(`/3/device/${TOKEN}`)
  expect(h["apns-topic"]).toBe(`${EXPECTED_TOPIC}.push-type.liveactivity`)
  expect(h["apns-push-type"]).toBe("liveactivity")
  expect(h["apns-priority"]).toBe("10")
  expect(h["content-type"]).toBe("application/json")
  expect(h.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/)
})

test("sendLiveActivityAPNs：priority 5 原样落到 header", async () => {
  const t = installTransport(respondWith(200))
  await sendLiveActivityAPNs(
    { token: TOKEN, env: "sandbox" },
    { event: "update", contentState: { phase: "idle" } },
    { priority: 5, timestampUnix: TS_UNIX },
  )
  expect(t.clients[0].headers!["apns-priority"]).toBe("5")
})

test("host 按 record.env 选：sandbox / production 各连各的", async () => {
  const t = installTransport(respondWith(200))
  await sendLiveActivityAPNs({ token: TOKEN, env: "sandbox" }, { event: "update", contentState: { phase: "idle" } }, { priority: 10 })
  await sendLiveActivityAPNs({ token: TOKEN, env: "production" }, { event: "update", contentState: { phase: "idle" } }, { priority: 10 })

  expect(t.connects.map((c) => c.authority)).toEqual([
    "https://api.sandbox.push.apple.com",
    "https://api.push.apple.com",
  ])
  expect(t.connects[0].options).toEqual({ family: 4 })
})

test("timestampUnix 缺省用当前秒", async () => {
  const t = installTransport(respondWith(200))
  const before = Math.floor(Date.now() / 1000)
  await sendLiveActivityAPNs({ token: TOKEN, env: "sandbox" }, { event: "update", contentState: { phase: "idle" } }, { priority: 10 })
  const ts = JSON.parse(t.clients[0].stream.payloads[0]).aps.timestamp
  expect(ts).toBeGreaterThanOrEqual(before)
  expect(ts).toBeLessThanOrEqual(Math.floor(Date.now() / 1000))
})

test("cert 不存在 → cert-missing 早退，不建连接（跟 sendAPNs 同一契约）", async () => {
  const t = installTransport(respondWith(200))
  __setAPNsTestHooks({ ...t.hooks, enabled: false })
  const r = await sendLiveActivityAPNs(
    { token: TOKEN, env: "sandbox" },
    { event: "update", contentState: { phase: "idle" } },
    { priority: 10 },
  )
  expect(r).toEqual({ ok: false, status: 0, reason: "cert-missing" })
  expect(t.connects.length).toBe(0)
})

test("APNs 拒绝时结果照常归一（假 token → BadDeviceToken）", async () => {
  installTransport(respondWith(400, JSON.stringify({ reason: "BadDeviceToken" })))
  const r = await sendLiveActivityAPNs(
    { token: TOKEN, env: "sandbox" },
    { event: "update", contentState: { phase: "idle" } },
    { priority: 10 },
  )
  expect(r).toEqual({ ok: false, status: 400, reason: "BadDeviceToken" })
})

test("不同 record 用各自的 topic 和环境：派生 liveactivity topic 跟着 record.topic 走，没带回退默认", async () => {
  const t = installTransport(respondWith(200))
  const ev = { event: "update", contentState: { phase: "idle" } } as const
  await sendLiveActivityAPNs({ token: TOKEN, env: "sandbox" }, ev, { priority: 10 })
  await sendLiveActivityAPNs({ token: TOKEN, env: "production", topic: "com.susu.MemoryPalace.susu" }, ev, { priority: 10 })

  const override = process.env.MP_APNS_HOST
  expect(t.connects.map((c) => c.authority)).toEqual([
    override || "https://api.sandbox.push.apple.com",
    override || "https://api.push.apple.com",
  ])
  expect(t.clients.map((c) => c.headers!["apns-topic"])).toEqual([
    `${EXPECTED_TOPIC}.push-type.liveactivity`,
    "com.susu.MemoryPalace.susu.push-type.liveactivity",
  ])
})
