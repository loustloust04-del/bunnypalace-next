import { test, expect } from "bun:test"
import { mkdtempSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import {
  OpencliBridge, PAGE_CHARS, PER_MINUTE, UNTRUSTED_HEADER, buildSiteArgs, hostBlocked, humanError, pageSlice, parseOpencliReq, readOnlyCommands, renderData,
  type OpencliReq, type RunResult,
} from "./opencli-bridge.ts"

const youtubeHelp = {
  site: "youtube",
  commands: [
    {
      name: "transcript", access: "read", description: "Get transcript", domain: "www.youtube.com",
      positionals: [{ name: "url", required: true }],
      command_options: [{ name: "lang" }, { name: "mode" }, { name: "window" }],
    },
    { name: "video", access: "read", description: "Video info", domain: "www.youtube.com", positionals: [{ name: "url", required: true }], command_options: [] },
    { name: "comment", access: "write", description: "Post a comment", domain: "www.youtube.com", positionals: [{ name: "url" }, { name: "text" }], command_options: [] },
  ],
}

function fakeBridge(reply: (args: string[]) => RunResult, now = () => 1_000_000) {
  const calls: string[][] = []
  const bridge = new OpencliBridge({
    bin: () => "/x/opencli",
    now,
    runner: async (_bin, args) => { calls.push(args); return reply(args) },
  })
  return { bridge, calls }
}
const ok = (stdout: string): RunResult => ({ code: 0, stdout, timedOut: false, tooLarge: false })

test("readOnlyCommands 只留 access=read，丢掉浏览器公共参数", () => {
  const specs = readOnlyCommands(youtubeHelp)
  expect(specs.map(s => s.name)).toEqual(["transcript", "video"])
  expect(specs[0].options.map(o => o.name)).toEqual(["lang", "mode"])
})

test("readOnlyCommands：存到 Mac 硬盘的命令和路径参数不放", () => {
  const specs = readOnlyCommands({
    commands: [
      { name: "download", access: "read", positionals: [], command_options: [{ name: "output" }] },
      { name: "bookmark-download", access: "read", positionals: [], command_options: [] },
      { name: "export-all", access: "read", positionals: [], command_options: [] },
      { name: "downloads", access: "read", positionals: [], command_options: [] },
      { name: "bookmarks", access: "read", positionals: [], command_options: [{ name: "limit" }, { name: "output-file" }, { name: "resume-file" }, { name: "path" }] },
    ],
  })
  expect(specs.map(s => s.name)).toEqual(["downloads", "bookmarks"])
  expect(specs[1].options.map(o => o.name)).toEqual(["limit"])
})

test("buildSiteArgs：位置参数按序、选项拼 --name、没声明的丢、- 开头拒", () => {
  const [transcript] = readOnlyCommands(youtubeHelp)
  expect(buildSiteArgs("youtube", transcript, { url: "dQw4w9WgXcQ", lang: "en", evil: "x", window: "foreground" }))
    .toEqual(["youtube", "transcript", "dQw4w9WgXcQ", "--lang", "en", "-f", "json", "--window", "background"])
  expect(buildSiteArgs("youtube", transcript, {})).toBe("缺参数 url")
  expect(buildSiteArgs("youtube", transcript, { url: "--execute" })).toBe("参数 url 不能以 - 开头")
  expect(buildSiteArgs("youtube", transcript, { url: "a", lang: "-x" })).toBe("参数 lang 不能以 - 开头")
})

test("parseOpencliReq：网址只收 http(s)，站点名 / 命令名收紧", () => {
  expect(parseOpencliReq({ tool: "chrome_read", url: "file:///etc/passwd" })).toBe("网址要以 http:// 或 https:// 开头")
  expect(parseOpencliReq({ tool: "chrome_read", url: "https://a.com/x", start: 5, blocked: ["B.com"] }))
    .toEqual({ tool: "chrome_read", url: "https://a.com/x", start: 5, blocked: ["b.com"] })
  expect(parseOpencliReq({ tool: "site_query", site: "../x" })).toBe("站点名不对")
  expect(parseOpencliReq({ tool: "site_query", site: "zhihu", command: "hot; rm" })).toBe("命令名不对")
  expect(parseOpencliReq({ tool: "run" })).toBe("不认识的工具")
})

test("hostBlocked 后缀子域匹配，同 app", () => {
  expect(hostBlocked("mail.google.com", ["google.com"])).toBe(true)
  expect(hostBlocked("notgoogle.com", ["google.com"])).toBe(false)
  expect(hostBlocked(null, ["google.com"])).toBe(false)
})

test("pageSlice 截断给 next_start，续读接上", () => {
  const text = "a".repeat(PAGE_CHARS + 10)
  const first = pageSlice(text, 0)
  expect(first.text.length).toBe(PAGE_CHARS)
  expect(first.next_start).toBe(PAGE_CHARS)
  const rest = pageSlice(text, first.next_start!)
  expect(rest.text.length).toBe(10)
  expect(rest.next_start).toBeUndefined()
})

test("humanError：扩展没连上说人话", () => {
  expect(humanError(JSON.stringify({ ok: false, error: { code: "BROWSER_CONNECT", message: "Browser Bridge extension not connected" } })))
    .toContain("Chrome 没连上")
})

test("chrome_read：带不可信标记、分段、黑名单不跑", async () => {
  const { bridge, calls } = fakeBridge(() => ok("# 标题\n" + "正".repeat(PAGE_CHARS)))
  const r = await bridge.handle(parseOpencliReq({ tool: "chrome_read", url: "https://example.com/p" }) as OpencliReq, "c")
  expect(r.ok).toBe(true)
  if (r.ok) {
    expect(r.text.startsWith(UNTRUSTED_HEADER)).toBe(true)
    expect(r.next_start).toBe(PAGE_CHARS)
  }
  expect(calls[0]).toEqual(["web", "read", "--url", "https://example.com/p", "--stdout", "true", "--download-images", "false", "--window", "background", "-f", "json"])
  const blocked = await bridge.handle(parseOpencliReq({ tool: "chrome_read", url: "https://mail.google.com/", blocked: ["google.com"] }) as OpencliReq, "c")
  expect(blocked).toEqual({ ok: false, error: "这个网站在黑名单里" })
  expect(calls.length).toBe(1)
})

test("site_query：写命令不放、不给命令回清单、help 缓存、站点只按黑名单拦", async () => {
  const { bridge, calls } = fakeBridge(args => args[1] === "--help"
    ? ok(JSON.stringify(youtubeHelp))
    : ok(JSON.stringify({ ok: true, data: [{ text: "never gonna give you up" }] })))
  const list = await bridge.handle({ tool: "site_query", site: "youtube", command: null, args: {}, blocked: [] }, "c")
  expect(list.ok && list.text).toContain("transcript(url, lang?, mode?)")
  expect(list.ok && list.text).not.toContain("comment")
  expect(await bridge.handle({ tool: "site_query", site: "web", command: "read", args: { url: "https://a.com" }, blocked: [] }, "c"))
    .toEqual({ ok: false, error: "读网页用 chrome_read" })
  const write = await bridge.handle({ tool: "site_query", site: "youtube", command: "comment", args: { url: "x", text: "hi" }, blocked: [] }, "c")
  expect(write.ok).toBe(false)
  const read = await bridge.handle({ tool: "site_query", site: "youtube", command: "transcript", args: { url: "dQw4w9WgXcQ" }, blocked: [] }, "c")
  expect(read.ok && read.text).toContain("never gonna give you up")
  expect(calls.filter(a => a[1] === "--help").length).toBe(1)
  const domainBlocked = await bridge.handle({ tool: "site_query", site: "youtube", command: "video", args: { url: "x" }, blocked: ["youtube.com"] }, "c")
  expect(domainBlocked).toEqual({ ok: false, error: "这个网站在黑名单里" })
})

test("opencli 结构化报错照实回", async () => {
  const { bridge } = fakeBridge(() => ({ code: 69, stdout: JSON.stringify({ ok: false, error: { code: "BROWSER_CONNECT", message: "x" } }), timedOut: false, tooLarge: false }))
  const r = await bridge.handle({ tool: "chrome_read", url: "https://a.com", start: 0, blocked: [] }, "c")
  expect(r.ok).toBe(false)
  if (!r.ok) expect(r.error).toContain("Chrome 没连上")
})

test("超时 / 超大 / 没装 opencli", async () => {
  const timeout = fakeBridge(() => ({ code: null, stdout: "", timedOut: true, tooLarge: false }))
  expect(await timeout.bridge.handle({ tool: "chrome_read", url: "https://a.com", start: 0, blocked: [] }, "c"))
    .toEqual({ ok: false, error: "opencli 超时（90 秒）" })
  const big = fakeBridge(() => ({ code: null, stdout: "", timedOut: false, tooLarge: true }))
  expect(await big.bridge.handle({ tool: "chrome_read", url: "https://a.com", start: 0, blocked: [] }, "c"))
    .toEqual({ ok: false, error: "结果太大（超过 200KB）" })
  const missing = new OpencliBridge({ bin: () => null })
  expect(await missing.handle({ tool: "chrome_read", url: "https://a.com", start: 0, blocked: [] }, "c"))
    .toEqual({ ok: false, error: "这台 Mac 上没装 opencli" })
})

test("每连接每分钟上限，过一分钟恢复", async () => {
  let t = 0
  const { bridge } = fakeBridge(() => ok("正文"), () => t)
  const req: OpencliReq = { tool: "chrome_read", url: "https://a.com", start: 0, blocked: [] }
  for (let i = 0; i < PER_MINUTE; i++) expect((await bridge.handle(req, "phone")).ok).toBe(true)
  expect((await bridge.handle(req, "phone")).ok).toBe(false)
  expect((await bridge.handle(req, "mac")).ok).toBe(true)
  t = 61_000
  expect((await bridge.handle(req, "phone")).ok).toBe(true)
})

test("并发最多 2 条", async () => {
  let running = 0
  let peak = 0
  const bridge = new OpencliBridge({
    bin: () => "/x/opencli",
    runner: async () => {
      running++; peak = Math.max(peak, running)
      await new Promise(r => setTimeout(r, 10))
      running--
      return ok("正文")
    },
  })
  const req: OpencliReq = { tool: "chrome_read", url: "https://a.com", start: 0, blocked: [] }
  await Promise.all([1, 2, 3, 4, 5].map(i => bridge.handle(req, `c${i}`)))
  expect(peak).toBe(2)
})

test("日志只记元数据，不记正文", async () => {
  const dir = mkdtempSync(join(tmpdir(), "opencli-log-"))
  const logPath = join(dir, "log.jsonl")
  const bridge = new OpencliBridge({ bin: () => "/x/opencli", logPath, runner: async () => ok("机密正文") })
  await bridge.handle({ tool: "chrome_read", url: "https://a.com/secret?q=1", start: 0, blocked: [] }, "phone")
  const line = readFileSync(logPath, "utf-8")
  expect(line).toContain("\"host\":\"a.com\"")
  expect(line).not.toContain("机密正文")
  expect(line).not.toContain("secret")
})

test("renderData：数组一行一条、截在整行上；对象整段", () => {
  expect(renderData([{ t: "0:00", text: "a" }, { t: "0:05", text: "b" }])).toBe('{"t":"0:00","text":"a"}\n{"t":"0:05","text":"b"}')
  const many = Array.from({ length: 2000 }, (_, i) => ({ text: `第 ${i} 句` }))
  const out = renderData(many)
  expect(out.length).toBeLessThanOrEqual(PAGE_CHARS)
  for (const line of out.split("\n")) expect(() => JSON.parse(line)).not.toThrow()
  expect(renderData({ a: 1 })).toBe('{"a":1}')
})
