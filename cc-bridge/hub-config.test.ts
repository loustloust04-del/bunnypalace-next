import { test, expect } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  BindPrefsCache, parseBindPrefs, tryParseBindPrefs, buildHelloPayload, buildMcpConfig, detectTools, listDirs, loadHubConfig, parseProductName, pickMcpConfig,
  resolveAgentWorkdir, sameDir, saveHubConfig, validateWorkdir,
} from "./hub-config.ts"

const tmp = (p: string) => realpathSync(mkdtempSync(join(tmpdir(), p)))

test("hub-config：坏文件 / 缺文件 / 非法字段都当空；写出来 0600", () => {
  const dir = tmp("hubcfg-")
  const path = join(dir, "hub-config.json")
  expect(loadHubConfig(path)).toEqual({})
  writeFileSync(path, "{not json")
  expect(loadHubConfig(path)).toEqual({})
  writeFileSync(path, JSON.stringify({ agent_workdir: 3, port: 70000 }))
  expect(loadHubConfig(path)).toEqual({})
  saveHubConfig(path, { agent_workdir: "/x", port: 51234 })
  expect(loadHubConfig(path)).toEqual({ agent_workdir: "/x", port: 51234 })
  expect(statSync(path).mode & 0o777).toBe(0o600)
})

test("hub-config：目标是软链就拒写", () => {
  const dir = tmp("hubcfg-link-")
  const real = join(dir, "real.json")
  writeFileSync(real, "{}")
  const link = join(dir, "hub-config.json")
  symlinkSync(real, link)
  expect(() => saveHubConfig(link, { port: 1 })).toThrow()
  expect(readFileSync(real, "utf-8")).toBe("{}")
})

test("validateWorkdir：~ 展开、相对路径拒、不存在拒、文件拒、返回 realpath", () => {
  const home = tmp("vw-home-")
  mkdirSync(join(home, "proj"))
  writeFileSync(join(home, "file.txt"), "x")
  symlinkSync(join(home, "proj"), join(home, "link"))
  expect(validateWorkdir("~/proj", home)).toEqual({ ok: true, path: join(home, "proj") })
  expect(validateWorkdir(join(home, "link"), home)).toEqual({ ok: true, path: join(home, "proj") })
  expect(validateWorkdir("proj", home).ok).toBe(false)
  expect(validateWorkdir("~/nope", home).ok).toBe(false)
  expect(validateWorkdir("~/file.txt", home).ok).toBe(false)
})

test("resolveAgentWorkdir：配置的目录还在就用，没了 / 没设回到家", () => {
  const home = tmp("raw-")
  mkdirSync(join(home, "proj"))
  expect(resolveAgentWorkdir({}, "/home/cc-rp")).toBe("/home/cc-rp")
  expect(resolveAgentWorkdir({ agent_workdir: join(home, "proj") }, "/home/cc-rp")).toBe(join(home, "proj"))
  expect(resolveAgentWorkdir({ agent_workdir: join(home, "gone") }, "/home/cc-rp")).toBe("/home/cc-rp")
})

test("sameDir：软链和真身算同一个", () => {
  const home = tmp("sd-")
  mkdirSync(join(home, "a"))
  symlinkSync(join(home, "a"), join(home, "b"))
  expect(sameDir(join(home, "a"), join(home, "b"))).toBe(true)
  expect(sameDir(join(home, "a"), home)).toBe(false)
})

test("listDirs：只列文件夹、跳过点开头、排序、软链文件夹算、上限截断、读不了给中文错误", () => {
  const home = tmp("ld-")
  for (const d of ["b", "a", ".hidden", "c"]) mkdirSync(join(home, d))
  writeFileSync(join(home, "file.txt"), "x")
  symlinkSync(join(home, "a"), join(home, "zlink"))
  const all = listDirs("~", home)
  expect(all).toEqual({ path: home, parent: join(home, ".."), dirs: ["a", "b", "c", "zlink"], truncated: false } as never)
  const capped = listDirs(home, home, 2)
  expect("dirs" in capped && capped.dirs).toEqual(["a", "b"])
  expect("truncated" in capped && capped.truncated).toBe(true)
  expect(listDirs("~/nope", home)).toEqual({ path: join(home, "nope"), error: "电脑上没有这个目录" })
  const locked = join(home, "locked")
  mkdirSync(locked)
  chmodSync(locked, 0o000)
  const res = listDirs(locked, home)
  chmodSync(locked, 0o755)
  expect("error" in res).toBe(true)
  expect(listDirs("/", home)).toMatchObject({ path: "/", parent: null })
})

test("detectTools：按给的 PATH 找可执行文件，不可执行 / 不存在都算没有", () => {
  const dir = tmp("dt-")
  writeFileSync(join(dir, "tmux"), "#!/bin/sh\n")
  chmodSync(join(dir, "tmux"), 0o755)
  writeFileSync(join(dir, "claude"), "not executable")
  expect(detectTools(`/nonexistent:${dir}`)).toEqual({ tmux: true, claude: false, codex: false })
  expect(detectTools(undefined)).toEqual({ tmux: false, claude: false, codex: false })
})

test("parseProductName：ioreg 输出里抠机型名，没有就 null", () => {
  expect(parseProductName(`  | "product-name" = <"MacBook Air (15-inch, M5)">\n`)).toBe("MacBook Air (15-inch, M5)")
  expect(parseProductName("nothing here")).toBeNull()
})

test.skipIf(process.platform !== "darwin")("readMachineInfo：launchd 的 PATH 没有 /usr/sbin 也拿得到机型", () => {
  // 子进程里跑：bun 起来后再改 process.env.PATH 不影响查命令，得一开始就是 launchd 那份 PATH（com.susu.cc-bridge-hub.plist）
  const script = `import { readMachineInfo } from ${JSON.stringify(join(import.meta.dir, "hub-config.ts"))}; console.log(JSON.stringify(readMachineInfo()))`
  const out = Bun.spawnSync([process.execPath, "-e", script], { env: { PATH: "/opt/homebrew/bin:/sbin:/usr/bin:/bin" } })
  const info = JSON.parse(out.stdout.toString())
  expect(info.host_model_id).toMatch(/\d+,\d+/)
})

test("hello 帧：字段齐全；机型拿不到就不带那两个键", () => {
  const base = {
    hubVersion: "t3", claudeHome: "/h/cc-rp", codexHome: "/h/gpt-rp", agentWorkdir: null,
    tools: { tmux: true, claude: true, codex: null }, capabilities: ["hello"],
  }
  const full = JSON.parse(buildHelloPayload({ ...base, machine: { host_name: "mimiair", host_model_id: "Mac17,4", host_model_name: "MacBook Air (15-inch, M5)" } }))
  expect(full).toEqual({
    type: "hello", hub_version: "t3", host_name: "mimiair", host_model_id: "Mac17,4", host_model_name: "MacBook Air (15-inch, M5)",
    dirs: { claude_home: "/h/cc-rp", codex_home: "/h/gpt-rp", agent_workdir: null },
    tools: { tmux: true, claude: true, codex: null }, capabilities: ["hello"],
  })
  const bare = JSON.parse(buildHelloPayload({ ...base, machine: { host_name: "x", host_model_id: null, host_model_name: null } }))
  expect("host_model_id" in bare).toBe(false)
  expect("host_model_name" in bare).toBe(false)
})

test("MCP 配置：生成的连本 hub 真实端口；cwd 的 .mcp.json 优先，都没有给 null", () => {
  expect(buildMcpConfig("/App/mcp-server-arm64", 51234, "tok")).toEqual({
    mcpServers: { "cc-bridge": { command: "/App/mcp-server-arm64", args: [], env: { MP_CC_HUB_URL: "ws://127.0.0.1:51234/mcp", MP_CC_HUB_TOKEN: "tok" } } },
  })
  const dir = tmp("mcp-")
  const cwdCfg = join(dir, ".mcp.json")
  const gen = join(dir, "secrets", "mcp.json")
  expect(pickMcpConfig(cwdCfg, gen)).toBeNull()
  mkdirSync(join(dir, "secrets"))
  writeFileSync(gen, "{}")
  expect(pickMcpConfig(cwdCfg, gen)).toBe(gen)
  expect(pickMcpConfig(cwdCfg, null)).toBeNull()   // 这次启动没写成：上次留下的旧文件不用
  writeFileSync(cwdCfg, "{}")
  expect(pickMcpConfig(cwdCfg, gen)).toBe(cwdCfg)
})

test("astra #1：循环软链 / 带 NUL 的路径 / 断链都不抛，回人话或跳过", () => {
  const home = tmp("loop-")
  mkdirSync(join(home, "real"))
  symlinkSync(join(home, "loopA"), join(home, "loopB"))
  symlinkSync(join(home, "loopB"), join(home, "loopA"))
  symlinkSync(join(home, "gone"), join(home, "dangling"))
  expect(listDirs(home, home)).toMatchObject({ dirs: ["real"], truncated: false })
  expect(validateWorkdir(join(home, "loopA"), home).ok).toBe(false)
  expect(validateWorkdir("/tmp/\u0000x", home)).toEqual({ ok: false, reason: "要填完整路径（以 / 或 ~ 开头）" })
  expect(resolveAgentWorkdir({ agent_workdir: join(home, "loopA") }, "/home")).toBe("/home")
  const bin = tmp("bin-")
  symlinkSync(join(bin, "tmux"), join(bin, "tmux"))   // 自指软链
  expect(detectTools(bin)).toEqual({ tmux: false, claude: false, codex: false })
})

test("bind-config 缓存（K3）：启动读一次；没变不重读；手改文件 mtime 变了才重读；save 期间在途的读作废", async () => {
  const dir = tmp("bindcfg-")
  const path = join(dir, "bind-config.json")
  expect(parseBindPrefs(undefined)).toEqual({ lan: true, tailscale: true })
  expect(parseBindPrefs("{坏")).toEqual({ lan: true, tailscale: true })
  writeFileSync(path, JSON.stringify({ lan: false }))
  const c = new BindPrefsCache(path)
  expect(c.get()).toEqual({ lan: false, tailscale: true })
  expect(await c.refresh()).toEqual({ lan: false, tailscale: true })
  // 手改：mtime 变了 → 重读
  writeFileSync(path, JSON.stringify({ lan: true, tailscale: false }))
  utimesSync(path, new Date(), new Date(Date.now() + 5_000))
  expect(c.get()).toEqual({ lan: false, tailscale: true })   // 还没 refresh：缓存
  expect(await c.refresh()).toEqual({ lan: true, tailscale: false })
  // set_bind：立刻生效 + 落盘
  c.save({ lan: false, tailscale: false })
  expect(c.get()).toEqual({ lan: false, tailscale: false })
  expect(JSON.parse(readFileSync(path, "utf-8"))).toEqual({ lan: false, tailscale: false })
  expect(await c.refresh()).toEqual({ lan: false, tailscale: false })
  // refresh 在途时 save：旧读数不能盖掉新开关
  const p = c.refresh()
  c.save({ lan: true, tailscale: true })
  expect(await p).toEqual({ lan: true, tailscale: true })
  expect(c.get()).toEqual({ lan: true, tailscale: true })
  // 文件没了：按默认（都开）
  const gone = new BindPrefsCache(join(dir, "missing.json"))
  expect(gone.get()).toEqual({ lan: true, tailscale: true })
  expect(await gone.refresh()).toEqual({ lan: true, tailscale: true })
})

test("bind-config 缓存（审查 R1-4）：读失败 / 解析失败保留上次有效开关、不提交 mtime，恢复后（mtime 不变）照样纠正", async () => {
  const dir = tmp("bindcfg3-")
  const path = join(dir, "bind-config.json")
  writeFileSync(path, JSON.stringify({ lan: false }))
  const c = new BindPrefsCache(path)
  expect(await c.refresh()).toEqual({ lan: false, tailscale: true })
  // 手改成 tailscale 也关，但文件暂时读不了
  writeFileSync(path, JSON.stringify({ lan: false, tailscale: false }))
  const t = new Date(Date.now() + 10_000)
  utimesSync(path, t, t)
  chmodSync(path, 0o000)
  expect(await c.refresh()).toEqual({ lan: false, tailscale: true })   // 不是「默认全开」
  chmodSync(path, 0o600)                                              // 恢复权限不改 mtime
  expect(await c.refresh()).toEqual({ lan: false, tailscale: false })
  // 坏 JSON / 不是对象：同上
  for (const bad of ["{坏", "null", "42"]) {
    writeFileSync(path, bad)
    const t2 = new Date(Date.now() + 20_000)
    utimesSync(path, t2, t2)
    expect(await c.refresh()).toEqual({ lan: false, tailscale: false })
    writeFileSync(path, JSON.stringify({ lan: true, tailscale: false }))
    utimesSync(path, t2, t2)
    expect(await c.refresh()).toEqual({ lan: true, tailscale: false })
    writeFileSync(path, JSON.stringify({ lan: false, tailscale: false }))
    const t3 = new Date(Date.now() + 30_000)
    utimesSync(path, t3, t3)
    expect(await c.refresh()).toEqual({ lan: false, tailscale: false })
  }
  // 目录读不了（stat 非 ENOENT）：保留
  chmodSync(dir, 0o000)
  try { expect(await c.refresh()).toEqual({ lan: false, tailscale: false }) } finally { chmodSync(dir, 0o700) }
  expect(tryParseBindPrefs("null")).toBeUndefined()
  expect(parseBindPrefs("null")).toEqual({ lan: true, tailscale: true })
})

test("bind-config 缓存：mtime 没变就不重读（内容被偷换也不读）", async () => {
  const dir = tmp("bindcfg2-")
  const path = join(dir, "bind-config.json")
  writeFileSync(path, JSON.stringify({ lan: false }))
  const t = new Date(Date.now() - 60_000)
  utimesSync(path, t, t)
  const c = new BindPrefsCache(path)
  await c.refresh()
  writeFileSync(path, JSON.stringify({ lan: true }))
  utimesSync(path, t, t)
  expect(await c.refresh()).toEqual({ lan: false, tailscale: true })
})
