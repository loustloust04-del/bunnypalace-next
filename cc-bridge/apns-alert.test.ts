// characterization：锁住 sendAPNs 的现有行为（header / payload / 传输 / JWT 缓存 / 结果归一）。
// 这个文件的存在意义是「重构 apns.ts 时它必须继续全绿」——不是在描述理想行为，是在描述**现状**。
// 全程假 http2，不连真 APNs，不读仓库 secrets/。
import { afterEach, expect, test } from "bun:test"
import { __setAPNsTestHooks, postAPNs, sendAPNs } from "./apns.ts"
import { installTransport, respondWith } from "./apns-fake-transport.ts"

const EXPECTED_HOST = process.env.MP_APNS_HOST || "https://api.sandbox.push.apple.com"
const EXPECTED_TOPIC = process.env.MP_APNS_TOPIC || "com.susu.MemoryPalace.ios"
const TOKEN = "a".repeat(64)

afterEach(() => { __setAPNsTestHooks() })

test("cert 不存在 → cert-missing 早退，一个字节都不上网", async () => {
  const t = installTransport(respondWith(200))
  // 只翻 enabled，传输仍是假的：连一次都不该发生
  __setAPNsTestHooks({ ...t.hooks, enabled: false })

  expect(await sendAPNs({ token: TOKEN }, "t", "b", "chat1")).toEqual({ ok: false, status: 0, reason: "cert-missing" })
  expect(t.connects.length).toBe(0)
})

test("header 形状：POST /3/device/<token> + topic + push-type alert + bearer + json，且没有 apns-priority", async () => {
  const t = installTransport(respondWith(200))
  await sendAPNs({ token: TOKEN }, "标题", "正文", "chat1")

  const h = t.clients[0].headers!
  expect(h[":method"]).toBe("POST")
  expect(h[":path"]).toBe(`/3/device/${TOKEN}`)
  expect(h["apns-topic"]).toBe(EXPECTED_TOPIC)
  expect(h["apns-push-type"]).toBe("alert")
  expect(h["content-type"]).toBe("application/json")
  expect(h.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/)
  // 现状就是没有 apns-priority（APNs 默认 10）。别顺手加。
  expect(h["apns-priority"]).toBeUndefined()
  expect(Object.keys(h).sort()).toEqual(
    [":method", ":path", "apns-push-type", "apns-topic", "authorization", "content-type"],
  )
})

test("payload 形状：aps.alert + sound default + mutable-content 1 + chat_id + 平铺 metadata", async () => {
  const t = installTransport(respondWith(200))
  await sendAPNs({ token: TOKEN }, "标题", "正文", "chat-42", { agora_room_id: "r1", kind: "mention" })

  expect(t.clients[0].stream.payloads.length).toBe(1)
  expect(JSON.parse(t.clients[0].stream.payloads[0])).toEqual({
    aps: { alert: { title: "标题", body: "正文" }, sound: "default", "mutable-content": 1 },
    chat_id: "chat-42",
    agora_room_id: "r1",
    kind: "mention",
  })
})

test("http2.connect 钉死 IPv4（family:4）并连 HOST", async () => {
  const t = installTransport(respondWith(200))
  await sendAPNs({ token: TOKEN }, "t", "b", "chat1")

  expect(t.connects.length).toBe(1)
  expect(t.connects[0].authority).toBe(EXPECTED_HOST)
  expect(t.connects[0].options).toEqual({ family: 4 })
})

test("JWT 在 3000s 内复用：两次发送拿到同一个 bearer；重置缓存后才换新", async () => {
  const t = installTransport(respondWith(200))
  await sendAPNs({ token: TOKEN }, "t", "b", "chat1")
  await sendAPNs({ token: TOKEN }, "t", "b", "chat1")
  const first = t.clients[0].headers!.authorization
  const second = t.clients[1].headers!.authorization
  expect(second).toBe(first)

  // ECDSA 签名带随机 k，重新签必然不同 —— 相同即证明走的是缓存。
  const t2 = installTransport(respondWith(200))
  await sendAPNs({ token: TOKEN }, "t", "b", "chat1")
  expect(t2.clients[0].headers!.authorization).not.toBe(first)
})

test("结果归一 · status 200 → ok，不带 reason", async () => {
  installTransport(respondWith(200))
  expect(await sendAPNs({ token: TOKEN }, "t", "b", "chat1")).toEqual({ ok: true, status: 200 })
})

test("结果归一 · 非 200 带 JSON reason → {ok:false,status,reason}", async () => {
  installTransport(respondWith(400, JSON.stringify({ reason: "BadDeviceToken" })))
  expect(await sendAPNs({ token: TOKEN }, "t", "b", "chat1")).toEqual({ ok: false, status: 400, reason: "BadDeviceToken" })
})

test("结果归一 · 非 200 且 body 不是 JSON → reason 退化成原始 body", async () => {
  installTransport(respondWith(503, "service unavailable"))
  expect(await sendAPNs({ token: TOKEN }, "t", "b", "chat1")).toEqual({ ok: false, status: 503, reason: "service unavailable" })
})

test("结果归一 · client error 事件 → {ok:false,status:0,reason:msg}", async () => {
  installTransport((c) => { queueMicrotask(() => c.emit("error", new Error("h2 is not supported"))) })
  expect(await sendAPNs({ token: TOKEN }, "t", "b", "chat1")).toEqual({ ok: false, status: 0, reason: "h2 is not supported" })
})

test("结果归一 · req error 事件带上已收到的 status", async () => {
  installTransport((c) => {
    c.stream.onEnd = (s) => { s.emit("response", { ":status": 429 }); s.emit("error", new Error("stream reset")) }
  })
  expect(await sendAPNs({ token: TOKEN }, "t", "b", "chat1")).toEqual({ ok: false, status: 429, reason: "stream reset" })
})

test("settled 只结算一次：end 之后再来 error 不改结果，client.close() 也只调一次", async () => {
  const t = installTransport((c) => {
    c.stream.onEnd = (s) => {
      s.emit("response", { ":status": 200 })
      s.emit("end")
      s.emit("error", new Error("late boom"))
      c.emit("error", new Error("later boom"))
    }
  })
  expect(await sendAPNs({ token: TOKEN }, "t", "b", "chat1")).toEqual({ ok: true, status: 200 })
  expect(t.clients[0].closeCount).toBe(1)
})

// ——— 以下是 ② 抽 postAPNs 时**新加**的行为（不是 characterization）———

test("postAPNs 超时 → {ok:false,status:0,reason:timeout} 并 close 掉连接", async () => {
  const t = installTransport(() => {})  // 永远不回响应
  const r = await postAPNs(
    { host: EXPECTED_HOST, path: "/3/device/x", headers: {}, payload: "{}" },
    { timeoutMs: 20 },
  )
  expect(r).toEqual({ ok: false, status: 0, reason: "timeout" })
  expect(t.clients[0].closeCount).toBe(1)
})

test("postAPNs 正常结算后定时器被清掉，不会到点再结算一次", async () => {
  const t = installTransport(respondWith(200))
  const r = await postAPNs(
    { host: EXPECTED_HOST, path: "/3/device/x", headers: {}, payload: "{}" },
    { timeoutMs: 20 },
  )
  expect(r).toEqual({ ok: true, status: 200 })
  await new Promise((res) => setTimeout(res, 60))
  expect(t.clients[0].closeCount).toBe(1)
})

test("postAPNs 不让调用方覆盖 authorization / content-type", async () => {
  const t = installTransport(respondWith(200))
  await postAPNs({
    host: EXPECTED_HOST,
    path: "/3/device/x",
    headers: { "apns-topic": "x.push-type.liveactivity", authorization: "bearer HIJACKED", "content-type": "text/plain" },
    payload: "{}",
  })
  const h = t.clients[0].headers!
  expect(h.authorization).not.toBe("bearer HIJACKED")
  expect(h.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/)
  expect(h["content-type"]).toBe("application/json")
  expect(h["apns-topic"]).toBe("x.push-type.liveactivity")
})

// ——— per-token topic / env（同一个 hub 下 .ios 开发包和 .susu Ad Hoc 包并存）———

test("不同 token 用各自的 topic 和环境：老记录 sandbox+默认 topic，新记录 production+自带 topic", async () => {
  const t = installTransport(respondWith(200))
  await sendAPNs({ token: "a".repeat(64), env: "sandbox" }, "t", "b", "chat1")
  await sendAPNs({ token: "b".repeat(64), env: "production", topic: "com.susu.MemoryPalace.susu" }, "t", "b", "chat1")

  const override = process.env.MP_APNS_HOST
  expect(t.connects.map((c) => c.authority)).toEqual([
    override || "https://api.sandbox.push.apple.com",
    override || "https://api.push.apple.com",
  ])
  expect(t.clients.map((c) => c.headers!["apns-topic"])).toEqual([EXPECTED_TOPIC, "com.susu.MemoryPalace.susu"])
  expect(t.clients.map((c) => c.headers![":path"])).toEqual([`/3/device/${"a".repeat(64)}`, `/3/device/${"b".repeat(64)}`])
  // header 键集合不因 per-token 选路变化
  for (const c of t.clients) {
    expect(Object.keys(c.headers!).sort()).toEqual(
      [":method", ":path", "apns-push-type", "apns-topic", "authorization", "content-type"],
    )
  }
})
