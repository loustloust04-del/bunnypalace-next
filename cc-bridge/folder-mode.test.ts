import { describe, expect, test } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  accountPreflight, buildFolderLaunchCommand, buildFolderSettings, defaultAccount, folderRejectsFrame, isFolderTrustPrompt, parseAccounts, parseFolderMode,
  SessionAccounts,
} from "./folder-mode"

describe("parseFolderMode", () => {
  const dir = mkdtempSync(join(tmpdir(), "folder-mode-"))

  test("没设 MP_HUB_MODE = 主 hub", () => {
    expect(parseFolderMode({})).toBeNull()
    expect(parseFolderMode({ MP_HUB_FOLDER: dir })).toBeNull()
    expect(parseFolderMode({ MP_HUB_MODE: "home", MP_HUB_FOLDER: dir })).toBeNull()
  })

  test("文件夹模式：去掉结尾的斜杠", () => {
    expect(parseFolderMode({ MP_HUB_MODE: "folder", MP_HUB_FOLDER: dir })).toEqual({ folder: dir })
    expect(parseFolderMode({ MP_HUB_MODE: "folder", MP_HUB_FOLDER: dir + "//" })).toEqual({ folder: dir })
  })

  test("路径不合法就抛，不带病启动", () => {
    expect(() => parseFolderMode({ MP_HUB_MODE: "folder" })).toThrow("绝对路径")
    expect(() => parseFolderMode({ MP_HUB_MODE: "folder", MP_HUB_FOLDER: "relative/x" })).toThrow("绝对路径")
    expect(() => parseFolderMode({ MP_HUB_MODE: "folder", MP_HUB_FOLDER: join(dir, "nope") })).toThrow("已存在的文件夹")
    const file = join(dir, "a-file")
    writeFileSync(file, "x")
    expect(() => parseFolderMode({ MP_HUB_MODE: "folder", MP_HUB_FOLDER: file })).toThrow("已存在的文件夹")
  })
})

describe("folderRejectsFrame", () => {
  test("只属于家的帧整帧拒", () => {
    for (const t of [
      "voice_note", "voice_call_request", "voice_call_action", "register_call_client", "set_voice_instructions",
      "set_garden_memory", "cc_memory_fetch", "cc_memory_manifest_req", "agent_status", "agent_config_set", "agent_book_note_ack",
      "agora_complete", "warroom_board", "warroom_request", "ticker_research", "trading_watchlist", "trading_report_ack",
      "vocab_archeology", "vocab_status", "reading_context", "reading_status", "twitter_result", "pocket_result",
      "opencli_req", "set_opencli_enabled", "feedback", "status_get", "status_run", "status_quiet_set", "status_alert_ack",
      "set_agent_workdir", "set_transport_policy",
    ]) expect(folderRejectsFrame(t)).toBe(true)
  })

  test("对话、终端、窗口、问题卡、推送、配对这些照常", () => {
    for (const t of [
      "send", "spawn_cc", "command", "edit", "reply", "focus", "client_info", "connect_report", "mcp_hello",
      "ask_user_answer", "list_sessions", "list_windows", "open_window", "close_window", "end_window", "rename_window", "restore_window",
      "terminal_attach", "terminal_detach", "terminal_input", "terminal_paste", "terminal_resize", "terminal_seen", "terminal_active", "terminal_report",
      "register_push_token", "unregister_push_token", "register_la_token", "unregister_la_token", "la_query",
      "get_hub_config", "list_dirs", "set_bind", "set_cc_config", "memory_result",
    ]) expect(folderRejectsFrame(t)).toBe(false)
  })
})

describe("parseAccounts", () => {
  const home = "/Users/x"

  test("没配 = 只有默认账号（~/.claude + claude）", () => {
    expect(parseAccounts(undefined, home)).toEqual({ accounts: [defaultAccount(home)], problems: [] })
    expect(defaultAccount(home)).toEqual({ id: "default", label: "默认", configDir: "/Users/x/.claude", command: "claude" })
  })

  test("多加一个账号：~ 展开，默认账号排第一", () => {
    const { accounts, problems } = parseAccounts(
      [{ id: "xiao", label: "🍆", config_dir: "~/.claude-c/", command: "~/.local/bin/claude-xiao" }], home)
    expect(problems).toEqual([])
    expect(accounts.map((a) => a.id)).toEqual(["default", "xiao"])
    expect(accounts[1]).toEqual({ id: "xiao", label: "🍆", configDir: "/Users/x/.claude-c", command: "/Users/x/.local/bin/claude-xiao" })
  })

  test("同名 default = 覆盖默认账号", () => {
    const { accounts } = parseAccounts([{ id: "default", config_dir: "/opt/cc", command: "claude" }], home)
    expect(accounts).toEqual([{ id: "default", label: "default", configDir: "/opt/cc", command: "claude" }])
  })

  test("坏条目丢掉并说明，不影响别的", () => {
    const { accounts, problems } = parseAccounts([
      { id: "Bad Id", config_dir: "/a", command: "claude" },
      { id: "rel", config_dir: "relative", command: "claude" },
      { id: "inject", config_dir: "/a", command: "claude; rm -rf /" },
      { id: "spaces", config_dir: "/a", command: "claude --dangerously" },
      { id: "ok", config_dir: "/a", command: "claude" },
    ], home)
    expect(accounts.map((a) => a.id)).toEqual(["default", "ok"])
    expect(problems.length).toBe(4)
    expect(parseAccounts({ id: "x" }, home).problems).toEqual(["accounts 不是数组，忽略"])
  })
})

describe("文件夹模式起 claude", () => {
  test("--settings 那份：Stop + 问题卡前后，共三个 hook", () => {
    expect(buildFolderSettings("/repo/cc-bridge")).toEqual({
      showThinkingSummaries: true,
      hooks: {
        Stop: [{ hooks: [{ type: "command", command: "python3 '/repo/cc-bridge/thinking-hook.py'" }] }],
        PreToolUse: [{ matcher: "AskUserQuestion", hooks: [{ type: "command", command: "python3 '/repo/cc-bridge/askuser-hook.py'" }] }],
        PostToolUse: [{ matcher: "AskUserQuestion", hooks: [{ type: "command", command: "python3 '/repo/cc-bridge/askuser-hook.py'" }] }],
      },
    })
  })

  test("新开：不禁工具、不 strict、没选过模型就不传", () => {
    const cmd = buildFolderLaunchCommand({
      command: "claude", mcpConfig: "/s/mcp.json", settingsPath: "/s/folder-settings.json", session: { fresh: "abc" },
    })
    expect(cmd).toBe("claude --mcp-config '/s/mcp.json' --settings '/s/folder-settings.json' --session-id abc")
    expect(cmd).not.toContain("disallowedTools")
    expect(cmd).not.toContain("strict-mcp-config")
    expect(cmd).not.toContain("--model")
  })

  test("认得出「信任这个文件夹吗」的屏（11-16 实测文字），正常的屏不误认", () => {
    const pane = [
      " Accessing workspace:", " /private/tmp/probe-folder",
      " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not,",
      " take a moment to review what's in this folder first.", " Claude Code'll be able to read, edit, and execute files here.",
      " ❯ No, exit", "   Yes, I trust this folder", " Enter to confirm · Esc to cancel",
    ].join("\n")
    expect(isFolderTrustPrompt(pane)).toBe(true)
    expect(isFolderTrustPrompt("╭───╮\n│ > │\n╰───╯\n  ? for shortcuts")).toBe(false)
    expect(isFolderTrustPrompt("")).toBe(false)
  })

  test("账号启动检查：过了回 null；不过带回 stderr 最后一行；超时、跑不起来各有说法", async () => {
    const acct = { id: "xiao", label: "🍆", configDir: "/c", command: "/bin/claude-xiao" }
    const seen: string[] = []
    expect(await accountPreflight(acct, async (cmd) => { seen.push(cmd); return { code: 0, stderr: "warn\n", timedOut: false } })).toBeNull()
    expect(seen).toEqual(["/bin/claude-xiao"])
    expect(await accountPreflight(acct, async () => ({ code: 1, stderr: "curl: (7) failed\n⛔ 出口是「查不到」，不是搬瓦工。不启动。\n\n", timedOut: false })))
      .toBe("⛔ 出口是「查不到」，不是搬瓦工。不启动。")
    expect(await accountPreflight(acct, async () => ({ code: 3, stderr: "", timedOut: false }))).toBe("启动命令退出码 3（/bin/claude-xiao）")
    expect(await accountPreflight(acct, async () => ({ code: null, stderr: "", timedOut: true }))).toBe("启动检查 15 秒没结束（/bin/claude-xiao）")
    expect(await accountPreflight(acct, async () => { throw new Error("ENOENT: no such file\nstack") }))
      .toBe("启动命令跑不起来（/bin/claude-xiao）：ENOENT: no such file")
  })

  test("账号启动检查：真跑一个脚本（不过的那种）", async () => {
    const dir = mkdtempSync(join(tmpdir(), "preflight-"))
    const bad = join(dir, "bad-launcher")
    writeFileSync(bad, "#!/bin/sh\necho '查出口…' >&2\necho '⛔ 出口不对，不启动' >&2\nexit 1\n", { mode: 0o755 })
    expect(await accountPreflight({ id: "x", label: "x", configDir: "/c", command: bad })).toBe("⛔ 出口不对，不启动")
    const good = join(dir, "good-launcher")
    writeFileSync(good, "#!/bin/sh\nexit 0\n", { mode: 0o755 })
    expect(await accountPreflight({ id: "x", label: "x", configDir: "/c", command: good })).toBeNull()
    expect(await accountPreflight({ id: "x", label: "x", configDir: "/c", command: join(dir, "missing") })).toContain("启动命令跑不起来")
  })

  test("会话 ↔ 账号：没定过 = 默认；第一次带账号就记下并落盘，重启还在", () => {
    const { accounts } = parseAccounts([{ id: "xiao", config_dir: "/c", command: "claude-xiao" }], "/Users/x")
    let text: string | undefined
    const store = { read: () => text, write: (t: string) => { text = t } }
    const sa = new SessionAccounts(accounts, store)
    expect(sa.of("mp-cc-1")?.id).toBe("default")
    expect(sa.claim("mp-cc-1", "xiao")).toEqual({ ok: true })
    expect(sa.of("mp-cc-1")?.id).toBe("xiao")
    expect(JSON.parse(text!)).toEqual({ "mp-cc-1": "xiao" })
    expect(new SessionAccounts(accounts, store).of("mp-cc-1")?.id).toBe("xiao")
  })

  test("会话 ↔ 账号：定过就不换——后来带别的账号来不报错，照原来的用", () => {
    const { accounts } = parseAccounts([{ id: "xiao", config_dir: "/c", command: "claude-xiao" }], "/Users/x")
    const sa = new SessionAccounts(accounts)
    expect(sa.claim("a", "xiao")).toEqual({ ok: true })
    expect(sa.claim("a", undefined)).toEqual({ ok: true })
    expect(sa.claim("a", "xiao")).toEqual({ ok: true })
    expect(sa.claim("a", "default")).toEqual({ ok: true })
    expect(sa.of("a")?.id).toBe("xiao")
    // 用默认账号起过的会话也不能再改
    sa.markStarted("b")
    expect(sa.claim("b", "default")).toEqual({ ok: true })
    expect(sa.claim("b", "xiao")).toEqual({ ok: true })
    expect(sa.of("b")?.id).toBe("default")
  })

  test("会话 ↔ 账号：不认识的账号拒；记着的账号从配置里删了 → null，不回落默认", () => {
    const { accounts } = parseAccounts([{ id: "xiao", config_dir: "/c", command: "claude-xiao" }], "/Users/x")
    let text: string | undefined
    const store = { read: () => text, write: (t: string) => { text = t } }
    expect(new SessionAccounts(accounts, store).claim("c", "nope")).toEqual({ ok: false, reason: "这台电脑没有账号「nope」" })
    new SessionAccounts(accounts, store).claim("c", "xiao")
    const later = new SessionAccounts(parseAccounts(undefined, "/Users/x").accounts, store)
    expect(later.of("c")).toBeNull()
    expect(later.of("other")?.id).toBe("default")
    expect(new SessionAccounts(accounts, { read: () => "{not json", write: () => {} }).of("x")?.id).toBe("default")
  })

  test("续接：换账号命令、带她选过的模型；路径里的单引号转义", () => {
    expect(buildFolderLaunchCommand({
      command: "/Users/x/.local/bin/claude-xiao", mcpConfig: null, settingsPath: "/it's/s.json", model: "opus[1m]", session: { resume: "id-1" },
    })).toBe(`/Users/x/.local/bin/claude-xiao --model 'opus[1m]' --settings '/it'\\''s/s.json' --resume id-1`)
  })
})
