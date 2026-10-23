import { test, expect } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { StreamRunner, buildStreamArgs, type ControlRequest, type Respond } from "./stream-runner.ts"

// 假 claude：按 stream-json 协议应答。init → 每条 user 回显 + assistant + result；
// 内容含 "PERM" 时先发 control_request(can_use_tool Bash)，收到 control_response 后再 result。
const FAKE = `
const out = (o) => process.stdout.write(JSON.stringify(o) + "\\n")
const args = process.argv.slice(2)
const sid = args.includes("--resume") ? args[args.indexOf("--resume") + 1] : (args[args.indexOf("--session-id") + 1] ?? "fresh-id")
let pending = null
let inited = false   // 真实 CLI：system/init 在首条 user 消息之后才发
let buf = ""
process.stdin.on("data", (d) => {
  buf += d.toString()
  let i
  while ((i = buf.indexOf("\\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1)
    if (!line.trim()) continue
    const m = JSON.parse(line)
    if (m.type === "control_request" && m.request?.subtype === "initialize") { out({ type: "control_response", response: { subtype: "success", request_id: m.request_id, response: {} } }); continue }
    if (m.type === "user") {
      const text = m.message.content
      if (!inited) { inited = true; out({ type: "system", subtype: "init", session_id: sid, tools: [] }) }
      out({ type: "user", message: { role: "user", content: text }, isReplay: true })
      if (text.includes("PERM")) {
        pending = "req-1"
        out({ type: "control_request", request_id: "req-1", request: { subtype: "can_use_tool", tool_name: "Bash", input: { command: "rm x" }, tool_use_id: "tu-1" } })
        continue
      }
      out({ type: "assistant", message: { content: [{ type: "text", text: "ok:" + text }] } })
      out({ type: "result", subtype: "success", num_turns: 1 })
      continue
    }
    if (m.type === "control_response" && m.response?.request_id === pending) {
      pending = null
      out({ type: "assistant", message: { content: [{ type: "text", text: "verdict:" + m.response.response.behavior }] } })
      out({ type: "result", subtype: "success", num_turns: 2 })
    }
  }
})
process.stdin.on("end", () => process.exit(0))
`
const dir = mkdtempSync(join(tmpdir(), "stream-runner-"))
const fake = join(dir, "fake-claude.ts")
writeFileSync(fake, FAKE)
const bin = [process.execPath, fake]

test("buildStreamArgs: resume vs fresh", () => {
  expect(buildStreamArgs({ cwd: "/x", model: "m", mcpConfig: "/m.json", resumeId: "abc" }).slice(-2)).toEqual(["--resume", "abc"])
  expect(buildStreamArgs({ cwd: "/x", model: "m", mcpConfig: "/m.json", sessionId: "new" }).slice(-2)).toEqual(["--session-id", "new"])
  expect(buildStreamArgs({ cwd: "/x", model: "m", mcpConfig: "/m.json" })).toContain("--permission-prompt-tool")
  expect(buildStreamArgs({ cwd: "/x", model: "m", mcpConfig: "/m.json" })).toContain("--include-partial-messages")
})

test("spawn → init ready → send 回显送达 → result → kill", async () => {
  const events: string[] = []
  const r = new StreamRunner({
    onReady: (n, sid) => events.push(`ready:${n}:${sid}`),
    onResult: (n, res) => events.push(`result:${res.num_turns}`),
    onEvent: (_n, m) => { if (m.type === "assistant") events.push(`assistant:${m.message.content[0].text}`) },
    onExit: (n, code, wasReady) => events.push(`exit:${wasReady}`),
    log: () => {},
  })
  r.spawn("s1", { cwd: dir, model: "m", mcpConfig: "/m.json", sessionId: "sid-1", bin })
  expect(r.has("s1")).toBe(true)
  await new Promise((res) => setTimeout(res, 300))
  expect(r.isReady("s1")).toBe(true)
  expect(events[0]).toBe("ready:s1:")   // 就绪来自 initialize 应答，此时还没有 session_id
  const t0 = Date.now()
  await r.send("hello", "s1")             // 写入即 resolve（回显只记账）
  expect(Date.now() - t0).toBeLessThan(2000)
  await new Promise((res) => setTimeout(res, 100))
  expect(events).toContain("assistant:ok:hello")
  expect(events).toContain("result:1")
  expect(r.sessionIdOf("s1")).toBe("sid-1")   // init 到了才有 id
  r.kill("s1")
  await new Promise((res) => setTimeout(res, 200))
  expect(r.has("s1")).toBe(false)
  expect(events.some((e) => e.startsWith("exit:"))).toBe(false)   // 主动 kill 不触发 onExit
})

test("control_request → onControlRequest → respond deny 回到进程", async () => {
  const events: string[] = []
  let got: ControlRequest | null = null
  const r = new StreamRunner({
    onControlRequest: (_n, req, respond: Respond) => { got = req; respond({ behavior: "deny", message: "no" }) },
    onEvent: (_n, m) => { if (m.type === "assistant") events.push(m.message.content[0].text) },
    log: () => {},
  })
  r.spawn("s2", { cwd: dir, model: "m", mcpConfig: "/m.json", sessionId: "sid-2", bin })
  await new Promise((res) => setTimeout(res, 200))
  await r.send("please PERM this", "s2")
  await new Promise((res) => setTimeout(res, 200))
  expect(got!.subtype).toBe("can_use_tool")
  expect(got!.tool_name).toBe("Bash")
  expect(got!.tool_use_id).toBe("tu-1")
  expect(events).toContain("verdict:deny")
  r.kill("s2")
})

test("没有权限处理器时默认 deny，不挂死", async () => {
  const events: string[] = []
  const r = new StreamRunner({ onEvent: (_n, m) => { if (m.type === "assistant") events.push(m.message.content[0].text) }, log: () => {} })
  r.spawn("s3", { cwd: dir, model: "m", mcpConfig: "/m.json", sessionId: "sid-3", bin })
  await new Promise((res) => setTimeout(res, 200))
  await r.send("PERM", "s3")
  await new Promise((res) => setTimeout(res, 200))
  expect(events).toContain("verdict:deny")
  r.kill("s3")
})

test("send 到不存在的 session reject；进程死了 has=false 且 onExit(wasReady=false)", async () => {
  const exits: boolean[] = []
  const r = new StreamRunner({ onExit: (_n, _c, wasReady) => exits.push(wasReady), log: () => {} })
  await expect(r.send("x", "nope")).rejects.toThrow()
  r.spawn("s4", { cwd: dir, model: "m", mcpConfig: "/m.json", sessionId: "sid-4", bin: [process.execPath, "-e", "process.exit(3)"] })
  await new Promise((res) => setTimeout(res, 300))
  expect(r.has("s4")).toBe(false)
  expect(exits).toEqual([false])
})

test("isBusy：send 后一轮在跑，result 到了空闲；挂在权限卡上时保持忙", async () => {
  let respond: Respond | null = null
  const r = new StreamRunner({ onControlRequest: (_n, _req, res) => { respond = res }, log: () => {} })
  r.spawn("s5", { cwd: dir, model: "m", mcpConfig: "/m.json", sessionId: "sid-5", bin })
  await new Promise((res) => setTimeout(res, 200))
  expect(r.isBusy("s5")).toBe(false)
  await r.send("hello", "s5")
  await new Promise((res) => setTimeout(res, 100))
  expect(r.isBusy("s5")).toBe(false)          // result 已到
  await r.send("PERM", "s5")
  await new Promise((res) => setTimeout(res, 100))
  expect(r.isBusy("s5")).toBe(true)           // 权限卡没人答，本轮没完
  respond!({ behavior: "deny", message: "no" })
  await new Promise((res) => setTimeout(res, 100))
  expect(r.isBusy("s5")).toBe(false)
  expect(r.isBusy("nope")).toBe(false)
  r.kill("s5")
})

test("onExit 带上 stderr 尾巴（起不来时当报错证据）", async () => {
  const tails: string[] = []
  const r = new StreamRunner({ onExit: (_n, _c, _w, tail) => tails.push(tail), log: () => {} })
  const script = join(dir, "stderr-exit.js")   // 用脚本文件：-e 后面会被接上 -p 等参数，bun 自己会吃掉 -p
  writeFileSync(script, "process.stderr.write('x'.repeat(5000) + ' model bad-9 not found'); process.exit(1)")
  r.spawn("s-err", { cwd: dir, model: "m", mcpConfig: "/m.json", sessionId: "sid-e", bin: [process.execPath, script] })
  await new Promise((res) => setTimeout(res, 500))
  expect(tails.length).toBe(1)
  expect(tails[0].endsWith(" model bad-9 not found")).toBe(true)
  expect(tails[0].length).toBe(4096)
})
