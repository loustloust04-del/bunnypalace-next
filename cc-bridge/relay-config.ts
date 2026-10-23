// #068 中继配置 secrets/relay.json：hub（开入口 / 拉 connector / 配对码 u3）和 relay-connector 共用。
// secret 是 32 字节随机数的 hex（中继那边只存它的 sha256，见 relay/new-secret.ts）。

import { readFileSync } from "node:fs"

export type RelayConfig = {
  host: string
  port: number
  secret: string
  /// false 只给本机测试：中继不开 TLS 时只准连 127.0.0.1 / localhost
  tls: boolean
  /// 中继证书叶子 SPKI 的 sha256（base64）；自签证书时必填，正规证书可不填
  pinSpkiSha256?: string
}

const HOST_RE = /^[A-Za-z0-9.\-:]+$/
const SECRET_RE = /^[0-9a-f]{64}$/
const PIN_RE = /^[A-Za-z0-9+/]{43}=$/

export function parseRelayConfig(raw: unknown): RelayConfig | string {
  if (!raw || typeof raw !== "object") return "不是 JSON 对象"
  const o = raw as Record<string, unknown>
  if (typeof o.host !== "string" || !HOST_RE.test(o.host)) return "host 不合法"
  if (typeof o.port !== "number" || !Number.isInteger(o.port) || o.port < 1 || o.port > 65535) return "port 不合法"
  if (typeof o.secret !== "string" || !SECRET_RE.test(o.secret)) return "secret 必须是 64 位小写 hex"
  const tls = o.tls !== false
  if (!tls && o.host !== "127.0.0.1" && o.host !== "localhost") return "不开 TLS 只准连本机（测试用）"
  if (o.pinSpkiSha256 !== undefined && (typeof o.pinSpkiSha256 !== "string" || !PIN_RE.test(o.pinSpkiSha256))) return "pinSpkiSha256 必须是 base64 的 sha256"
  return { host: o.host, port: o.port, secret: o.secret, tls, ...(o.pinSpkiSha256 ? { pinSpkiSha256: o.pinSpkiSha256 as string } : {}) }
}

/// 没有文件 → null；有但不对 → 原因字符串（不含文件内容）
export function loadRelayConfig(path: string): RelayConfig | string | null {
  let text: string
  try { text = readFileSync(path, "utf8") } catch (e: any) { return e?.code === "ENOENT" ? null : `读不了（${e?.code}）` }
  let raw: unknown
  try { raw = JSON.parse(text) } catch { return "不是合法 JSON" }
  return parseRelayConfig(raw)
}

/// 手机连中继的地址（配对码 u3）。app 只接受 wss，所以没开 TLS 的测试配置不出 u3。
export function relayPhoneURL(c: RelayConfig): string | null {
  if (!c.tls) return null
  const host = c.host.includes(":") ? `[${c.host}]` : c.host
  return `wss://${host}${c.port === 443 ? "" : `:${c.port}`}/cc`
}
