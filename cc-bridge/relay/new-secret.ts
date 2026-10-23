// #068 生成一对中继密钥：Mac 端的 secrets/relay.json（密钥原文，0600）+ 中继端要填的 MP_RELAY_SECRET_SHA256。
//
//   bun relay/new-secret.ts <中继域名或 IP> <端口> --out secrets/relay.json [--cert 中继证书.pem]
//
// 给了 --cert（自签证书）就顺手算好 pinSpkiSha256 写进 relay.json；正规证书不用给。
// 密钥原文只写进 --out 指定的文件，不打到终端。

import { createHash, randomBytes } from "node:crypto"
import { readFileSync, writeFileSync } from "node:fs"
import { parseRelayConfig } from "../relay-config.ts"
import { spkiSha256 } from "../relay-connector.ts"

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name)
  return i > 0 ? process.argv[i + 1] : undefined
}

const [host, portText] = process.argv.slice(2)
const out = arg("--out")
const certPath = arg("--cert")
if (!host || !portText || !out) {
  console.error("用法：bun relay/new-secret.ts <中继域名或 IP> <端口> --out secrets/relay.json [--cert 中继证书.pem]")
  process.exit(1)
}

const secret = randomBytes(32)
const cfg: Record<string, unknown> = { host, port: Number(portText), secret: secret.toString("hex") }
if (certPath) {
  const pem = readFileSync(certPath, "utf8")
  const first = /-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----/.exec(pem)
  if (!first) { console.error("--cert 里没找到证书"); process.exit(1) }
  cfg.pinSpkiSha256 = spkiSha256(Buffer.from(first[1].replace(/\s+/g, ""), "base64"))
}
const checked = parseRelayConfig(cfg)
if (typeof checked === "string") { console.error(`配置不对：${checked}`); process.exit(1) }

// wx = 排他创建：并发跑两次、或 out 是悬空符号链接都不会覆盖
try { writeFileSync(out, JSON.stringify(checked, null, 2) + "\n", { mode: 0o600, flag: "wx" }) } catch (e: any) {
  console.error(e?.code === "EEXIST" ? `${out} 已存在，不覆盖（换密钥先手动删掉旧的）` : `写不进 ${out}（${e?.code}）`)
  process.exit(1)
}
console.log(`已写 ${out}（0600）。重启 hub 后生效。`)
console.log(`中继那边设：MP_RELAY_SECRET_SHA256=${createHash("sha256").update(secret).digest("hex")}`)
if (cfg.pinSpkiSha256) console.log(`证书 pin（已写进 relay.json，扫码时会带给手机）：${cfg.pinSpkiSha256}`)
