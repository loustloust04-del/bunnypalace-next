import { describe, expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import {
  GOLDEN_FILE, MEMORY_PREFACE, MEMORY_RESULT_LIMIT, MEMORY_TIMEOUT_MS, MEMORY_TOOL_NAMES,
  callMemoryTool, isMemoryTool, loadAppTools, memoryMcpTools, toolsFromGolden,
} from "./memory-tools"

describe("花园记忆工具的定义", () => {
  test("memory-tools.json 和 app 的工具金样一字不差（漂了就跑 bun run memory-tools.ts）", () => {
    if (!existsSync(GOLDEN_FILE)) return   // 装到别处的 hub 目录里没有 app 的测试夹具
    expect(loadAppTools()).toEqual(toolsFromGolden())
  })

  test("发给 CC 的清单：同名、多一个必填的 chat_id、开头说清是花园的记忆", () => {
    const tools = memoryMcpTools()
    expect(tools.map(t => t.name)).toEqual([...MEMORY_TOOL_NAMES])
    const app = Object.fromEntries(loadAppTools().map(t => [t.name, t]))
    for (const t of tools) {
      expect(t.description.startsWith(MEMORY_PREFACE)).toBe(true)
      expect(t.description.endsWith(app[t.name].description)).toBe(true)   // app 的原说明原样在
      expect(t.description.length).toBeLessThanOrEqual(2048)   // Claude Code 截 MCP 工具说明的长度
      expect(t.inputSchema.required[0]).toBe("chat_id")
      expect(t.inputSchema.required.slice(1)).toEqual(app[t.name].input_schema.required)
      expect(Object.keys(t.inputSchema.properties)).toEqual(["chat_id", ...Object.keys(app[t.name].input_schema.properties)])
    }
    expect(isMemoryTool("memory_card")).toBe(true)
    expect(isMemoryTool("fs_write")).toBe(true)   // 写 memory/ 下的文件 = 写那种记忆
    expect(isMemoryTool("run_command")).toBe(false)
  })
})

describe("callMemoryTool", () => {
  const fakeFetch = (reply: unknown, seen: any[] = []) => (async (url: any, init: any) => {
    seen.push({ url: String(url), body: JSON.parse(init.body) })
    if (reply instanceof Error) throw reply
    return new Response(JSON.stringify(reply))
  }) as unknown as typeof fetch

  test("chat_id 提出来、其余原样当 input，带上时限", async () => {
    const seen: any[] = []
    const r = await callMemoryTool("http://hub", "memory_card", { chat_id: "c1", action: "add", content: "岚舟怕打雷。" },
      fakeFetch({ ok: true, result: "加好了" }, seen))
    expect(r).toEqual({ content: [{ type: "text", text: "加好了" }] })
    expect(seen).toEqual([{ url: "http://hub/memory/cmd", body: { chat_id: "c1", tool: "memory_card", input: { action: "add", content: "岚舟怕打雷。" }, timeout_ms: MEMORY_TIMEOUT_MS } }])
  })

  test("没做成一律 isError + 一句明白话：被拒 / app 没连着 / 超时 / hub 连不上", async () => {
    const denied = await callMemoryTool("http://hub", "memory_card", { chat_id: "c1" }, fakeFetch({ ok: false, result: "permission_denied：用户未允许「记忆条目」。" }))
    expect(denied.isError).toBe(true)
    expect(denied.content[0].text).toContain("permission_denied")
    const offline = await callMemoryTool("http://hub", "recall", { chat_id: "c1" }, fakeFetch({ ok: false, error: "花园 app 没连着 hub" }))
    expect(offline.isError).toBe(true)
    expect(offline.content[0].text).toContain("没连着")
    const timeout = await callMemoryTool("http://hub", "recall", { chat_id: "c1" }, fakeFetch({ ok: false, error: "timeout" }))
    expect(timeout.isError).toBe(true)
    expect(timeout.content[0].text).toContain("没回话")
    const down = await callMemoryTool("http://hub", "recall", { chat_id: "c1" }, fakeFetch(new Error("ECONNREFUSED")))
    expect(down.isError).toBe(true)
    expect(down.content[0].text).toContain("连不上")
    const oldHub = await callMemoryTool("http://hub", "recall", { chat_id: "c1" },
      (async () => new Response("upgrade required", { status: 426 })) as unknown as typeof fetch)
    expect(oldHub.isError).toBe(true)
    expect(oldHub.content[0].text).toContain("还没重启")
    const odd = await callMemoryTool("http://hub", "recall", { chat_id: "c1" }, fakeFetch({ ok: true }))
    expect(odd.isError).toBe(true)   // ok 但没有正文：不当成功
  })

  test("太长的回执截断并说明", async () => {
    const r = await callMemoryTool("http://hub", "fs_list", { chat_id: "c1" }, fakeFetch({ ok: true, result: "x".repeat(MEMORY_RESULT_LIMIT + 10) }))
    expect(r.isError).toBeUndefined()
    expect(r.content[0].text.startsWith("x".repeat(MEMORY_RESULT_LIMIT) + "\n…")).toBe(true)
  })
})

describe("mcp-server 里的花园记忆工具（完整 ListTools / CallTool）", () => {
  test("清单里有这 14 个；调用经 hub 的 /memory/cmd；hub 不在时回明白话", async () => {
    // 假 hub：只认 /memory/cmd，绝不连生产 7890
    const seen: any[] = []
    const hub = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(req) {
        const url = new URL(req.url)
        if (req.method !== "POST" || url.pathname !== "/memory/cmd") return new Response("not found", { status: 404 })
        const body = await req.json() as any
        seen.push(body)
        return Response.json({ id: "x", ok: true, result: `做了 ${body.tool}` })
      },
    })
    const spawn = (port: number) => new StdioClientTransport({
      command: "bun",
      args: ["run", "mcp-server.ts"],
      cwd: import.meta.dir,
      env: { ...process.env, MP_CC_HUB_URL: `ws://127.0.0.1:${port}/mcp`, MP_CC_HUB_TOKEN: "test-token" } as Record<string, string>,
    })
    const client = new Client({ name: "memory-tools-test", version: "0" })
    await client.connect(spawn(hub.port!))
    try {
      const names = (await client.listTools()).tools.map(t => t.name)
      for (const n of MEMORY_TOOL_NAMES) expect(names).toContain(n)
      expect(names).toContain("reply")   // 原来的工具还在
      const ok = await client.callTool({ name: "remember", arguments: { chat_id: "c9", name: "纸鸢的约定", description: "星砚答应帮岚舟刻纸鸢", body: "岚舟说「帮我刻一只纸鸢」。" } }) as any
      expect(ok.isError).toBeFalsy()
      expect(ok.content[0].text).toBe("做了 remember")
      expect(seen).toEqual([{ chat_id: "c9", tool: "remember", timeout_ms: MEMORY_TIMEOUT_MS,
        input: { name: "纸鸢的约定", description: "星砚答应帮岚舟刻纸鸢", body: "岚舟说「帮我刻一只纸鸢」。" } }])
    } finally {
      await client.close()
      hub.stop(true)
    }

    // hub 没开：端口上没人听
    const deadPort = hub.port!
    const offline = new Client({ name: "memory-tools-test-offline", version: "0" })
    await offline.connect(spawn(deadPort))
    try {
      const r = await offline.callTool({ name: "memory_card", arguments: { chat_id: "c9", action: "add", content: "岚舟怕打雷。" } }) as any
      expect(r.isError).toBe(true)
      expect(r.content[0].text).toContain("连不上花园的 hub")
    } finally {
      await offline.close()
    }
  }, 30_000)
})
