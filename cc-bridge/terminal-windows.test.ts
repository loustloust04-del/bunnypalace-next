import { test, expect } from "bun:test"
import { mkdtempSync, writeFileSync, rmSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import {
  WINDOW_PREFIX, sessionNameFor, isWindowSession, codeFromSession, newWindowCode,
  addWindow, closeWindow, endWindow, endWindowAfterKill, restoreWindow, openWindows, closedWindows, liveWindows,
  buildTerminalStatePayload, loadWindows, resolveTerminalTitle, saveWindows,
  setWindowCustomTitle, type TerminalWindow, resolveWindowTitle, codexPhaseFromActivity, isDefaultPaneTitle,
} from "./terminal-windows"

const NOW = "2026-08-16T10:00:00.000Z"

test("#046 T13：shell 没名字、pane 标题还是主机名 → 「shell · 目录名」；家目录写 ~；有真标题照旧", () => {
  const hosts = ["mimiair.local", "mimiair"]
  expect(isDefaultPaneTitle("mimiair", hosts)).toBe(true)
  expect(isDefaultPaneTitle(" ", hosts)).toBe(true)
  expect(resolveWindowTitle(undefined, "mimiair", "shell", "/Users/u/proj/app", hosts, "/Users/u")).toBe("shell · app")
  expect(resolveWindowTitle(undefined, "mimiair.local", "shell", "/Users/u", hosts, "/Users/u")).toBe("shell · ~")
  expect(resolveWindowTitle(undefined, "vim README", "shell", "/Users/u/proj", hosts, "/Users/u")).toBe("vim README")
  expect(resolveWindowTitle("我的", "mimiair", "shell", "/x", hosts, "/u")).toBe("我的")
  expect(resolveWindowTitle(undefined, "mimiair", "claude", "/x", hosts, "/u")).toBe("claude")
  expect(resolveWindowTitle(undefined, undefined, "shell", undefined, hosts, "/u")).toBeNull()
  expect(resolveWindowTitle(undefined, "mimiair", "shell", "/", hosts, "/u")).toBe("shell · /")
})

test("#046 T22：codex 10 秒内有输出算在干活，否则空闲；没数据算空闲", () => {
  expect(codexPhaseFromActivity(1000, 1005)).toBe("working")
  expect(codexPhaseFromActivity(1000, 1010)).toBe("working")
  expect(codexPhaseFromActivity(1000, 1011)).toBe("idle")
  expect(codexPhaseFromActivity(undefined, 1000)).toBe("idle")
  expect(codexPhaseFromActivity(0, 1000)).toBe("idle")
})
const scratch = () => mkdtempSync(join(tmpdir(), "term-win-"))

test("前缀跟现有三个白名单零重叠 —— 这是全局窗口免疫 keepalive/reap/agora 的根据", () => {
  expect(isWindowSession("mp-win-abc123")).toBe(true)
  // 现有命名空间一个都不能被误判成全局窗口
  expect(isWindowSession("mp-cc")).toBe(false)
  expect(isWindowSession("mp-cc-t1")).toBe(false)
  expect(isWindowSession("mp-cc-a1b2c3d4")).toBe(false)
  expect(isWindowSession("mp-codex-1")).toBe(false)
  // 反过来，全局窗口不能命中现有白名单的前缀判断
  expect("mp-win-abc123".startsWith("mp-cc")).toBe(false)
  expect("mp-win-abc123".startsWith("mp-cc-")).toBe(false)
  expect("mp-win-abc123".startsWith("mp-codex")).toBe(false)
})

test("session 名 ↔ code 双向", () => {
  expect(sessionNameFor("abc123")).toBe("mp-win-abc123")
  expect(codeFromSession("mp-win-abc123")).toBe("abc123")
  expect(codeFromSession("mp-cc-t1")).toBeNull()
})

test("code 不跟已有的撞", () => {
  const code = newWindowCode([])
  expect(code).toHaveLength(6)
  expect(code).toMatch(/^[0-9a-f]{6}$/)

  // 把它自己塞进 existing，再抽必须换一个
  const second = newWindowCode([code])
  expect(second).not.toBe(code)

  // 批量抽 200 个不重复
  const seen = new Set<string>()
  for (let i = 0; i < 200; i++) seen.add(newWindowCode(seen))
  expect(seen.size).toBe(200)
})

test("关闭 = 打标记，记录不删 —— 否则恢复不回来", () => {
  let ws = addWindow([], "aaa111", NOW)
  expect(openWindows(ws)).toHaveLength(1)

  ws = closeWindow(ws, "aaa111", "2026-08-16T11:00:00.000Z")
  expect(ws).toHaveLength(1)                 // 记录还在
  expect(openWindows(ws)).toHaveLength(0)    // 但不在导航里
  expect(closedWindows(ws)).toHaveLength(1)
  expect(ws[0].closedAt).toBe("2026-08-16T11:00:00.000Z")
})

test("恢复 = 清掉 closedAt，createdAt 不变（身份连续）", () => {
  let ws = addWindow([], "bbb222", NOW)
  ws = closeWindow(ws, "bbb222", "2026-08-16T11:00:00.000Z")
  ws = restoreWindow(ws, "bbb222")

  expect(openWindows(ws)).toHaveLength(1)
  expect(ws[0].closedAt).toBeUndefined()
  expect(ws[0].createdAt).toBe(NOW)          // 恢复的是同一个窗口，不是新建
  expect(ws[0].code).toBe("bbb222")
})

test("重复关闭不覆盖首次 closedAt；重复添加同 code 不产生第二条", () => {
  let ws = addWindow([], "ccc333", NOW)
  ws = addWindow(ws, "ccc333", "2026-08-16T12:00:00.000Z")
  expect(ws).toHaveLength(1)

  ws = closeWindow(ws, "ccc333", "2026-08-16T11:00:00.000Z")
  ws = closeWindow(ws, "ccc333", "2026-08-16T13:00:00.000Z")
  expect(ws[0].closedAt).toBe("2026-08-16T11:00:00.000Z")
})

test("窗口注册表记住 engine，旧调用缺省 shell", () => {
  expect(addWindow([], "shell1", NOW)[0].engine).toBe("shell")
  expect(addWindow([], "agent1", NOW, "claude")[0].engine).toBe("claude")
  expect(addWindow([], "agent2", NOW, "codex")[0].engine).toBe("codex")
})

test("对不存在的 code 操作是 no-op，不抛", () => {
  const ws = addWindow([], "ddd444", NOW)
  expect(closeWindow(ws, "nope", NOW)).toEqual(ws)
  expect(restoreWindow(ws, "nope")).toEqual(ws)
})

test("落盘往返", () => {
  const dir = scratch()
  const p = join(dir, "windows.json")

  expect(loadWindows(p)).toEqual([])          // 文件不存在

  const ws: TerminalWindow[] = [
    { code: "aaa111", createdAt: NOW },
    { code: "bbb222", createdAt: NOW, closedAt: "2026-08-16T11:00:00.000Z" },
  ]
  saveWindows(p, ws)
  expect(loadWindows(p)).toEqual(ws)
  rmSync(dir, { recursive: true })
})

test("注册表坏了返回空列表，绝不抛 —— 不能让 hub 起不来", () => {
  const dir = scratch()
  const p = join(dir, "windows.json")

  writeFileSync(p, "{ 这不是 json")
  expect(loadWindows(p)).toEqual([])

  writeFileSync(p, JSON.stringify({ not: "an array" }))
  expect(loadWindows(p)).toEqual([])

  // 混了脏记录 → 只留合法的
  writeFileSync(p, JSON.stringify([
    { code: "good11", createdAt: NOW },
    { code: "", createdAt: NOW },
    { createdAt: NOW },
    null,
    "字符串",
  ]))
  expect(loadWindows(p)).toEqual([{ code: "good11", createdAt: NOW }])
  rmSync(dir, { recursive: true })
})

test("terminal_state 帧包含全字段，缺省 phase 为 idle，死的全局窗口 alive=false", () => {
  const alive = new Set(["mp-cc-chat"])
  const payload = JSON.parse(buildTerminalStatePayload([
    {
      code: "abc123", sessionName: "mp-win-abc123", engine: "shell",
      title: null, includeWhenDead: true,
    },
    {
      code: "mp-cc-chat", sessionName: "mp-cc-chat", engine: "claude",
      title: "claude", includeWhenDead: false,
    },
    {
      code: "mp-codex-dead", sessionName: "mp-codex-dead", engine: "codex",
      title: "codex", includeWhenDead: false,
    },
  ], name => alive.has(name), name => name === "mp-cc-chat" ? "working" : undefined))

  expect(payload).toEqual({
    type: "terminal_state",
    windows: [
      { code: "abc123", title: null, engine: "shell", phase: "idle", alive: false },
      { code: "mp-cc-chat", title: "claude", engine: "claude", phase: "working", alive: true },
    ],
  })
})

test("标题链按手动 > pane_title > engine > null 降级", () => {
  expect(resolveTerminalTitle("手动名", "pane 名", "claude")).toBe("手动名")
  expect(resolveTerminalTitle(undefined, "pane\u0007 标题", "codex")).toBe("pane 标题")
  expect(resolveTerminalTitle(undefined, undefined, "claude")).toBe("claude")
  expect(resolveTerminalTitle(undefined, undefined, "shell")).toBeNull()
  expect(resolveTerminalTitle(undefined, "甲".repeat(65), "shell")).toBe("甲".repeat(64))
})

test("rename 改写 terminal_state 标题，空串清除手动名", () => {
  const original = addWindow([], "abc123", NOW)
  const renamed = setWindowCustomTitle(original, "abc123", "我的窗口")
  const renamedTitle = resolveTerminalTitle(renamed[0].customTitle, "pane 名", "shell")
  const frame = JSON.parse(buildTerminalStatePayload([{
    code: "abc123", sessionName: "mp-win-abc123", engine: "shell",
    title: renamedTitle, includeWhenDead: true,
  }], () => true, () => undefined))
  expect(frame.windows[0].title).toBe("我的窗口")

  const cleared = setWindowCustomTitle(renamed, "abc123", "")
  expect(cleared[0].customTitle).toBeUndefined()
  expect(resolveTerminalTitle(cleared[0].customTitle, "pane 名", "shell")).toBe("pane 名")
})

test("结束 = 打 endedAt：开着的、收起的列表都不再有它，也恢复不回来", () => {
  let ws = addWindow([], "aaa111", NOW)
  ws = addWindow(ws, "bbb222", NOW)
  ws = closeWindow(ws, "bbb222", NOW)
  ws = endWindow(ws, "aaa111", NOW)
  ws = endWindow(ws, "bbb222", NOW)
  expect(ws).toHaveLength(2)
  expect(ws.every(w => w.endedAt === NOW)).toBe(true)
  expect(openWindows(ws)).toEqual([])
  expect(closedWindows(ws)).toEqual([])
  expect(liveWindows(ws)).toEqual([])
  expect(restoreWindow(ws, "bbb222")).toEqual(ws)
})

test("结束只动目标窗口，重复结束不改时间", () => {
  let ws = addWindow([], "aaa111", NOW)
  ws = addWindow(ws, "bbb222", NOW)
  ws = endWindow(ws, "aaa111", NOW)
  const again = endWindow(ws, "aaa111", "2026-08-17T00:00:00.000Z")
  expect(again[0].endedAt).toBe(NOW)
  expect(openWindows(again).map(w => w.code)).toEqual(["bbb222"])
  expect(liveWindows(again).map(w => w.code)).toEqual(["bbb222"])
})

test("结束先 kill：session 真没了才算成", async () => {
  const ws = addWindow([], "aaa111", NOW)
  const calls: string[] = []
  const killed = new Set<string>()
  const ok = await endWindowAfterKill(ws, "aaa111", {
    kill: session => { calls.push(`kill ${session}`); killed.add(session) },
    hasSession: session => !killed.has(session),
  })
  expect(calls).toEqual(["kill mp-win-aaa111"])
  expect(ok).toBe(true)
})

test("kill 没成（session 还在）：false", async () => {
  const ws = addWindow([], "aaa111", NOW)
  expect(await endWindowAfterKill(ws, "aaa111", { kill: () => {}, hasSession: () => true })).toBe(false)
})

test("结束未知 code：不 kill，false", async () => {
  const ws = addWindow([], "aaa111", NOW)
  let killed = 0
  expect(await endWindowAfterKill(ws, "zzz999", { kill: () => { killed++ }, hasSession: () => false })).toBe(false)
  expect(killed).toBe(0)
})

// K1-0 审查 R1-3：kill 要 await，同栈并发结束 A、B，各自在最新的表上打 endedAt，谁也不盖掉谁（同 hub end_window 处理）
test("并发结束两个窗口：两个都打上 endedAt", async () => {
  let current = addWindow(addWindow([], "aaa111", NOW), "bbb222", NOW)
  const killed = new Set<string>()
  const tmux = { kill: async (session: string) => { killed.add(session) }, hasSession: (session: string) => !killed.has(session) }
  const end = async (code: string) => {
    if (await endWindowAfterKill(current, code, tmux)) current = endWindow(current, code, NOW)
  }
  await Promise.all([end("aaa111"), end("bbb222")])
  expect(current.map(w => w.endedAt)).toEqual([NOW, NOW])
  expect(openWindows(current)).toEqual([])
})
