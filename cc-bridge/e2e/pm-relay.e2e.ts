// 隔离 e2e（docs/plan-pm-board-app.md P1-4）：测试 hub（随机端口、临时 secrets、tmux 干跑）+ 测试 4793（假目录 + 假 otty-cli），
// 用 WS 客户端走 pm_board / pm_session / pm_send / pm_open（v1 老帧）+ pm_req（v2 通用帧：/api/home、/api/send 收下、/api/outbox）。生产 7890 / 4793 / 粟粟的 Otty 全程不碰。
// 跑法：cd cc-bridge && bun run e2e/pm-relay.e2e.ts
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, openSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { execFileSync } from "node:child_process"
import { WebSocket } from "ws"

const HUB_DIR = join(import.meta.dir, "..")
const PM_DIR = join(HUB_DIR, "..", "scripts", "pm")
const root = mkdtempSync(join(tmpdir(), "pm-relay-e2e-"))
const d = (p: string) => { const x = join(root, p); mkdirSync(x, { recursive: true }); return x }
const HUB_PORT = 17000 + Math.floor(Math.random() * 900)
const PM_PORT = 27000 + Math.floor(Math.random() * 900)
if (HUB_PORT === 7890 || PM_PORT === 4793) throw new Error("端口撞生产")
const TOKEN = "e2e-token"
const A = "aaaaaaaa-0000-4000-8000-00000000000a"

// ---- 测试 4793 的假世界 ----
const repo = d("repo"); d("repo/scripts"); d("repo/.claude/worktrees/page1")
writeFileSync(join(repo, "scripts/zone.sh"), 'ZONES="page1"\n')
writeFileSync(join(repo, "TASK.md"), `# TASK\n\n## 待验（自动）\n\n- [ ] 待验 · 散成灰 · #00161 <!-- pm:req=00161 sid=${A} zone=page1 -->\n`)
mkdirSync(join(repo, "docs"), { recursive: true })
writeFileSync(join(repo, "docs/plan-e2e.html"), `<html><head></head><body><main><input class="bk" data-k="a"></main><script>const KEY='mp-e2e'</script></body></html>`)
const lstart = execFileSync("ps", ["-o", "lstart=", "-p", String(process.pid)], { encoding: "utf8", env: { ...process.env, TZ: "UTC", LC_ALL: "C" } }).trim().replace(/\s+/g, " ")
writeFileSync(join(d("sessions"), `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: A, cwd: join(repo, ".claude/worktrees/page1"), name: "工位A", status: "idle", startedAt: 1, procStart: lstart }))
writeFileSync(join(d("projects/p"), `${A}.jsonl`), JSON.stringify({ type: "user", timestamp: new Date().toISOString(), message: { content: "你好" } }) + "\n")
const q = d("q"); d("metrics")
writeFileSync(join(q, "human.tsv"), `${Math.floor(Date.now() / 1000)}\t09-29 12:00:00\task\tpage1\t要不要合\t${A}\n`)
writeFileSync(join(root, "roles.json"), '{"human":"粟粟","roles":[]}')
writeFileSync(join(root, "state"), "idle\n"); writeFileSync(join(root, "input"), "")
const R = root
writeFileSync(join(root, "otty"), `#!/bin/bash
echo "$*" >> "${R}/otty.log"
case "$1 $2" in
  "pane list") echo "{\\"data\\":[{\\"id\\":\\"p_A\\",\\"tab_id\\":\\"t_A\\",\\"agent_session_id\\":\\"${A}\\",\\"agent_state\\":\\"$(cat "${R}/state")\\"}]}" ;;
  "pane capture") rule=$(printf '─%.0s' {1..40}); printf '⏺ 好的\\n\\n%s\\n> %s\\n%s\\n' "$rule" "$(cat "${R}/input")" "$rule" ;;
  "pane send-text") b=$(cat; echo x); b=\${b%x}; echo "TEXT[$b]" >> "${R}/typed.log"; if [ "$b" = $'\\r' ]; then : > "${R}/input"; else printf '%s' "$b" >> "${R}/input"; fi ;;
  "tab focus") ;;
esac
`)
writeFileSync(join(root, "open"), "#!/bin/sh\nexit 0\n")
chmodSync(join(root, "otty"), 0o755); chmodSync(join(root, "open"), 0o755)
const tokenFile = join(q, "pm-api-token")

const noProxy = { no_proxy: "127.0.0.1,localhost", NO_PROXY: "127.0.0.1,localhost" }
const pmLog = openSync(join(root, "pm.out"), "w")
const pm = Bun.spawn(["bun", "run", join(PM_DIR, "server.ts")], {
  env: { ...process.env, ...noProxy, MP_PM_PORT: String(PM_PORT), MP_PM_REPO: repo, MP_PM_SESSIONS_DIR: join(root, "sessions"), MP_PM_PROJECTS_DIR: join(root, "projects"), MP_PM_Q: q,
    MP_PM_DEVICE_DIR: join(root, "dev"), MP_PM_BUILD_INFO: join(root, "none"), MP_PM_BUILD_Q: join(root, "bq"), MP_PM_ROLES: join(root, "roles.json"), MP_PM_BOOT_CONF: join(root, "none"),
    MP_PM_OTTY: join(root, "otty"), MP_PM_OPEN: join(root, "open"), MP_PM_LOG: join(root, "pm.log"), MP_METRICS_DIR: join(root, "metrics"), MP_PM_API_TOKEN_FILE: tokenFile, MP_PM_SEND_LOG: join(q, "pm-send.tsv"), MP_PM_OUTBOX_EVERY: "300", MP_PM_SILENT_EVERY: "0" },
  stdout: pmLog, stderr: pmLog,
})

// ---- 测试 hub ----
const hubEnv: Record<string, string> = {
  ...(process.env as Record<string, string>), ...noProxy,
  MP_CC_TMUX_DRY_RUN: "1", MP_CC_HUB_TOKEN: TOKEN, MP_CC_HUB_PORT: String(HUB_PORT), MP_CC_HUB_HOST: "127.0.0.1",
  MP_CC_SECRETS_DIR: d("secrets"), MP_CC_AGENT_DIR: d("agent"), MP_CC_WORKDIR: d("work"), MP_CC_THINKING_SPOOL: d("spool"),
  MP_CC_WARROOM: "0", MP_CC_NUDGE_ENABLED: "0", MP_CC_KEEPALIVE: "0", MP_APNS_KEY_PATH: join(root, "no-key.p8"), MP_CC_LA_INTERVAL_MS: "3600000",
  TMUX_TMPDIR: d("tmux"), MP_PM_URL: `http://127.0.0.1:${PM_PORT}`, MP_PM_API_TOKEN_FILE: tokenFile,
}
delete hubEnv.TMUX; delete hubEnv.TMUX_PANE; delete hubEnv.MP_CC_HUB_TOKEN_FILE
const hubLog = openSync(join(root, "hub.out"), "w")
const hub = Bun.spawn(["bun", "run", "hub.ts"], { cwd: HUB_DIR, env: hubEnv, stdout: hubLog, stderr: hubLog })

let fail = 0
const ok = (m: string) => console.log(`✅ ${m}`)
const bad = (m: string) => { console.log(`❌ ${m}`); fail = 1 }
const cleanup = () => { try { hub.kill() } catch {} try { pm.kill() } catch {} }

async function waitUp(url: string, proc: typeof hub, what: string) {
  const t = Date.now() + 15_000
  while (Date.now() < t) {
    if (proc.exitCode !== null) throw new Error(`${what} 没起来（exit=${proc.exitCode}），看 ${root}`)
    try { const r = await fetch(url); if (r.status < 500) return } catch {}
    await Bun.sleep(150)
  }
  throw new Error(`${what} 15 秒没起来，看 ${root}`)
}

try {
  await waitUp(`http://127.0.0.1:${PM_PORT}/api/board?view=phone`, pm, "测试 4793")
  await waitUp(`http://127.0.0.1:${HUB_PORT}/health`, hub, "测试 hub")
  const ws = new WebSocket(`ws://127.0.0.1:${HUB_PORT}/cc?token=${TOKEN}`)
  await new Promise<void>((res, rej) => { ws.on("open", () => res()); ws.on("error", rej); setTimeout(() => rej(new Error("WS 连不上")), 3000) })
  const inbox: Record<string, unknown>[] = []
  ws.on("message", (b) => { try { inbox.push(JSON.parse(b.toString())) } catch {} })
  const ask = async (frame: Record<string, unknown>, ms = 12_000): Promise<Record<string, unknown>> => {
    const want = `${frame.type}_result`, id = String(frame.req_id)
    ws.send(JSON.stringify(frame))
    const t = Date.now() + ms
    while (Date.now() < t) {
      const i = inbox.findIndex((m) => m.type === want && m.req_id === id)
      if (i >= 0) return inbox.splice(i, 1)[0]
      await Bun.sleep(50)
    }
    throw new Error(`${want} ${id} 没回`)
  }

  const dump = process.env.PM_E2E_DUMP   // 给 app 单测做夹具：把真回帧落盘
  if (dump) {
    writeFileSync(join(dump, "pm_board_result.json"), JSON.stringify(await ask({ type: "pm_board", req_id: "d1" }), null, 1))
    writeFileSync(join(dump, "pm_session_result.json"), JSON.stringify(await ask({ type: "pm_session", req_id: "d2", sid: A, turns: 5 }), null, 1))
    writeFileSync(join(dump, "pm_req_home_result.json"), JSON.stringify(await ask({ type: "pm_req", req_id: "d3", method: "GET", path: "/api/home" }), null, 1))
    writeFileSync(join(dump, "pm_req_session_result.json"), JSON.stringify(await ask({ type: "pm_req", req_id: "d4", method: "GET", path: `/api/session?sid=${A}` }), null, 1))
    writeFileSync(join(dump, "pm_req_occupancy_result.json"), JSON.stringify(await ask({ type: "pm_req", req_id: "d5", method: "GET", path: "/api/occupancy" }), null, 1))
    writeFileSync(join(dump, "pm_req_task_result.json"), JSON.stringify(await ask({ type: "pm_req", req_id: "d6", method: "GET", path: "/api/task" }), null, 1))
  }
  const b = await ask({ type: "pm_board", req_id: "b1" }) as { ok: boolean; view: string; sessions: { sid: string; name: string }[] }
  b.ok && b.view === "phone" && b.sessions.some((s) => s.sid === A && s.name === "工位A") ? ok("pm_board → 瘦身看板（经 hub 带 Bearer 到 4793）") : bad(`pm_board 不对：${JSON.stringify(b).slice(0, 300)}`)
  const s = await ask({ type: "pm_session", req_id: "s1", sid: A, turns: 5 }) as { ok: boolean; canSend: { ok: boolean }; turns: unknown[] }
  s.ok && s.canSend?.ok && s.turns.length === 1 ? ok("pm_session → 详情 + canSend ok + 1 轮") : bad(`pm_session 不对：${JSON.stringify(s).slice(0, 300)}`)
  const typedNow = () => { try { return readFileSync(join(root, "typed.log"), "utf8") } catch { return "" } }
  const outboxOf = async (id: string) => {
    const r = await ask({ type: "pm_req", req_id: `o-${id}-${Date.now()}`, method: "GET", path: `/api/outbox?sid=${A}` }) as { outbox?: { id: string; state: string; code: string }[] }
    return r.outbox?.find((x) => x.id === id)
  }
  const waitState = async (id: string, want: string) => { for (let i = 0; i < 40; i++) { const x = await outboxOf(id); if (x?.state === want) return x; await Bun.sleep(200) } return outboxOf(id) }
  writeFileSync(join(root, "state"), "awaiting\n")
  const r1 = await ask({ type: "pm_send", req_id: "x1", sid: A, text: "你好", clientMsgId: "e2e-000001" })
  const q1 = await waitState("e2e-000001", "queued-busy")
  r1.ok === true && r1.accepted === true && r1.result === "queued" && r1.http === 200 && q1?.code === "awaiting" && !typedNow() ? ok("老 pm_send 帧在权限弹窗时 → 收下（v1 app 看成排着了），一个字没打") : bad(`awaiting 不对：${JSON.stringify(r1)} / ${JSON.stringify(q1)}`)
  writeFileSync(join(root, "state"), "idle\n")
  const s1 = await waitState("e2e-000001", "sent")
  s1?.state === "sent" && typedNow().includes("TEXT[【粟粟·手机】你好]") ? ok("弹窗处理完 → 排着的那条自动送出（假 Otty 收到带前缀的字 + 回车）") : bad(`排着的没送：${JSON.stringify(s1)} / ${typedNow()}`)
  const home = await ask({ type: "pm_req", req_id: "h1", method: "GET", path: "/api/home" }) as { ok: boolean; view: string; people: { sid: string; rawName: string }[] }
  home.ok && home.view === "home" && home.people.some((p) => p.sid === A && p.rawName === "工位A") ? ok("pm_req GET /api/home → 对话列表") : bad(`pm_req home 不对：${JSON.stringify(home).slice(0, 300)}`)
  const r2 = await ask({ type: "pm_req", req_id: "x2", method: "POST", path: "/api/send", body: { sid: A, text: "第二句", clientMsgId: "e2e-000002" } })
  const s2 = await waitState("e2e-000002", "sent")
  r2.ok === true && r2.accepted === true && r2.req_id === "x2" && s2?.state === "sent" && typedNow().includes("TEXT[【粟粟·手机】第二句]") ? ok("pm_req POST /api/send → 收下就回，后台送达") : bad(`pm_req 发送不对：${JSON.stringify(r2)} / ${JSON.stringify(s2)}`)
  const sd = await ask({ type: "pm_req", req_id: "d1", method: "GET", path: `/api/session?sid=${A}` }) as { ok: boolean; person?: { rawName: string }; asks?: unknown[]; outbox?: unknown[] }
  sd.ok && sd.person?.rawName === "工位A" && Array.isArray(sd.asks) && sd.outbox?.length === 2 ? ok("pm_req GET /api/session → v2 详情（person / asks / outbox）") : bad(`pm_req 详情不对：${JSON.stringify(sd).slice(0, 300)}`)
  const oc = await ask({ type: "pm_req", req_id: "oc", method: "GET", path: "/api/occupancy" }) as { ok: boolean; zones?: { zone: string }[]; devices?: unknown[] }
  oc.ok && oc.zones?.some((z) => z.zone === "page1") && Array.isArray(oc.devices) ? ok("pm_req GET /api/occupancy → 占用") : bad(`occupancy 不对：${JSON.stringify(oc).slice(0, 300)}`)
  const tk = await ask({ type: "pm_req", req_id: "tk", method: "GET", path: "/api/task" }) as { ok: boolean; sections?: { title: string; groups: { items: { who: { sid: string } | null }[] }[] }[] }
  tk.ok && tk.sections?.[0].groups[0].items[0].who?.sid === A ? ok("pm_req GET /api/task → TASK.md + 谁做的") : bad(`task 不对：${JSON.stringify(tk).slice(0, 300)}`)
  const dw = await ask({ type: "pm_req", req_id: "dw", method: "POST", path: "/api/docstate", body: { doc: "plan-e2e", key: "mp-e2e", patch: { ticks: { a: true } } } })
  const dr = await ask({ type: "pm_req", req_id: "dr", method: "GET", path: "/api/doc?name=plan-e2e" }) as { ok: boolean; html?: string; state?: { version: number } }
  dw.ok === true && dr.ok && dr.state?.version === 1 && dr.html?.includes("pmBoard docstate") && dr.html.includes('\\"a\\":true') ? ok("pm_req POST /api/docstate → 落盘；再拉 /api/doc 垫片里预填了") : bad(`docstate 不对：${JSON.stringify(dw)} / ${JSON.stringify(dr).slice(0, 300)}`)
  const bp = await ask({ type: "pm_req", req_id: "bp", method: "GET", path: "/kpi" })
  bp.ok === false && bp.code === "bad-path" ? ok("pm_req 路径不在 /api/ 下 → hub 直接拒") : bad(`bad-path 不对：${JSON.stringify(bp)}`)
  const r3 = await ask({ type: "pm_send", req_id: "x3", sid: A, text: "x".repeat(4001), clientMsgId: "e2e-000003" })
  r3.ok === false && r3.error === "超过 4000 字" ? ok("超长文本 hub 直接拒") : bad(`超长不对：${JSON.stringify(r3)}`)
  const o = await ask({ type: "pm_open", req_id: "o1", sid: A })
  o.ok === true && readFileSync(join(root, "otty.log"), "utf8").includes("tab focus t_A") ? ok("pm_open → 4793 /api/open 聚焦") : bad(`pm_open 不对：${JSON.stringify(o)}`)
  pm.kill(); await pm.exited
  const down = await ask({ type: "pm_board", req_id: "b2" })
  down.ok === false && down.code === "pm-down" ? ok("4793 停了 → 看板服务没开") : bad(`4793 停了不对：${JSON.stringify(down)}`)
  const h = await fetch(`http://127.0.0.1:${HUB_PORT}/health`)
  h.ok ? ok("hub 还健康") : bad("hub 挂了")
  ws.close()
} catch (e) {
  bad((e as Error).message)
} finally {
  cleanup()
}
console.log(fail ? `FAILED（日志在 ${root}）` : "ALL PASS")
process.exit(fail)
