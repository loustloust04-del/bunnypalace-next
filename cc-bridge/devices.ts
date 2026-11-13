#!/usr/bin/env bun
/// 这台 hub 认的设备（docs/plan-hub-keypair-auth.md K1-D）：只调 hub 的本机管理接口，不读写任何状态文件（运行时只有 hub 写 devices.json）。
///
///   bun cc-bridge/devices.ts list | revoke <设备 id 前缀> | rename <设备 id 前缀> <名字> | pair   [--port 7890]
///
/// 管理口令取法同 mcp-server：MP_CC_HUB_TOKEN > MP_CC_HUB_TOKEN_FILE > launchd plist；端口 --port > MP_CC_HUB_PORT > 7890
import { readdirSync, readFileSync } from "node:fs"

const argv = process.argv.slice(2)
const pi = argv.indexOf("--port")
const port = pi >= 0 ? argv.splice(pi, 2)[1] : process.env.MP_CC_HUB_PORT || "7890"
const [cmd, ...args] = argv

function hubToken(): string {
  if (process.env.MP_CC_HUB_TOKEN) return process.env.MP_CC_HUB_TOKEN
  if (process.env.MP_CC_HUB_TOKEN_FILE) { try { return readFileSync(process.env.MP_CC_HUB_TOKEN_FILE, "utf8").trim() } catch { return "" } }
  try {
    const dir = `${process.env.HOME}/Library/LaunchAgents`
    const name = readdirSync(dir).filter((n) => n.endsWith(".cc-bridge-hub.plist")).sort()[0]
    const m = name ? readFileSync(`${dir}/${name}`, "utf8").match(/<key>MP_CC_HUB_TOKEN<\/key>\s*<string>([^<]+)<\/string>/) : null
    return m?.[1] ?? ""
  } catch { return "" }
}

function die(msg: string): never { console.error(msg); process.exit(1) }

async function call(path: string, body?: object): Promise<Record<string, unknown>> {
  const token = hubToken()
  if (!token) die("拿不到 hub 口令：设 MP_CC_HUB_TOKEN 或 MP_CC_HUB_TOKEN_FILE")
  let res: Response
  try {
    res = await fetch(`http://127.0.0.1:${port}${path}?token=${encodeURIComponent(token)}`, body ? { method: "POST", body: JSON.stringify(body) } : {})
  } catch { die(`hub 没在跑（127.0.0.1:${port} 连不上），先启动它`) }
  if (res.status === 401) die("hub 不认这个口令")
  const out = await res.json().catch(() => ({})) as Record<string, unknown>
  if (!res.ok) die(`失败：${String(out.reason ?? out.error ?? res.status)}`)
  return out
}

interface Device { id: string; name: string; platform: string; added_at: number; added_via: string; last_used_at: number | null; last_from: string | null }
const when = (ms: number | null) => ms ? new Date(ms).toLocaleString() : "-"

async function resolveId(prefix: string | undefined): Promise<string> {
  if (!prefix) die("要给设备 id（list 里那一列的前几位就行）")
  const { devices } = await call("/admin/devices") as { devices: Device[] }
  const hits = devices.filter((d) => d.id.startsWith(prefix))
  if (hits.length !== 1) die(hits.length ? `「${prefix}」对上了 ${hits.length} 台，多给几位` : `没有以「${prefix}」开头的设备`)
  return hits[0].id
}

if (cmd === "list") {
  const r = await call("/admin/devices") as { available: boolean; devices: Device[]; legacy_last: { at: number; from: string } | null }
  if (!r.available) console.log("⚠️ 设备表暂时不可用（hub 日志里有原因）")
  for (const d of r.devices) console.log(`${d.id}  ${d.name}  ${d.platform}  配于 ${when(d.added_at)}（${d.added_via}）  最后 ${when(d.last_used_at)} ${d.last_from ?? ""}`)
  if (!r.devices.length) console.log("（还没有设备用设备钥登记过）")
  console.log(r.legacy_last ? `最后一次有设备用口令登录：${when(r.legacy_last.at)}，来自 ${r.legacy_last.from}` : "还没有设备用口令登录过")
} else if (cmd === "revoke") {
  const id = await resolveId(args[0])
  const r = await call("/admin/devices/revoke", { device_id: id })
  console.log(`已移除 ${id}（踢掉在线连接 ${String(r.kicked)} 条）。它如果还记着口令仍能重新连上——要彻底不让它连，换口令。`)
} else if (cmd === "rename") {
  const id = await resolveId(args[0])
  await call("/admin/devices/rename", { device_id: id, name: args.slice(1).join(" ") })
  console.log("改好了")
} else if (cmd === "pair") {
  const token = hubToken()
  const p = await call("/pair")
  const qr = JSON.stringify(p)
  // 没装 qrencode 时 spawnSync 直接抛 ENOENT：接住，手填信息照样打
  let drawn = false
  try {
    const q = Bun.spawnSync(["qrencode", "-t", "ANSIUTF8", "-o", "-"], { stdin: new TextEncoder().encode(qr), stdout: "pipe", stderr: "pipe" })
    if (q.exitCode === 0) { console.log(q.stdout.toString()); drawn = true }
  } catch { /* 没装 / 起不来 */ }
  if (!drawn) console.log("（画不了二维码：没装 qrencode 或它出错了；用下面的手填）")
  if (typeof p.mc === "string") console.log(`手填配对码：${p.mc}（10 分钟内有效，用一次就作废）`)
  console.log(`地址：${String(p.u ?? p.u2 ?? "（hub 只听本机，见 deploy/VPS.md）")}`)
  console.log(`口令：${token}`)
  console.log("⚠️ 口令等于 hub 的密码——别发到公开聊天")
} else {
  die("用法：bun devices.ts list | revoke <id 前缀> | rename <id 前缀> <名字> | pair   [--port N]")
}
