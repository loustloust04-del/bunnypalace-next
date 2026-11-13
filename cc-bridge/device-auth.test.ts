import { test, expect } from "bun:test"
import { createPrivateKey, createPublicKey, generateKeyPairSync } from "node:crypto"
import { chmodSync, existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  DeviceStore, LEN, LegacySeen, PAIR_CODE_MAX, PAIR_CODE_TTL_MS, PairCodes, b64u, buildTranscript, deviceIdOf, duplicateAuthQuery,
  formatManualCode, hmacB64u, hubKeyOf, importP256Spki, isAud, isB64u, loadOrCreateHubKey, normalizeAud, normalizeManualCode, pairCodeFields,
  parseAuthFrame, parseV2Query, randomNonce, sanitizeDeviceName, signP256, timingSafeEqualB64u, tokenSecret, validDeviceName, verifyP256, type TranscriptFields,
  DeviceAuth, authFailFrame, type AuthOutcome, type ChallengeCtx,
} from "./device-auth.ts"
import { authFrame, challengeValid, expectedHubProof, makeTestDevice, newConn, type Challenge, type Conn, type TestDevice } from "./device-auth-testkit.ts"

interface FixtureCase {
  name: string
  fields: { role: TranscriptFields["role"]; path: TranscriptFields["path"]; kind: TranscriptFields["kind"]; pub: string; result: TranscriptFields["result"]; enrolled: TranscriptFields["enrolled"] }
  transcript: string
  sig_hub?: string
  sig_dev?: string
  sig_dev_swift?: string
  secret?: "token" | "pc" | "mc"
  hmac?: string
}
interface Fixture {
  hub: { hub_id: string; pkcs8_pem: string; pub: string; hk: string }
  device: { pkcs8_pem: string; raw_priv: string; pub: string; did: string }
  secrets: { token: string; token_secret: string; pc: string; mc_display: string; mc_typed: string[]; mc_secret: string }
  conn: { cn: string; sn: string; aud: string }
  aud_cases: { url: string; aud: string }[]
  cases: FixtureCase[]
}
const FX: Fixture = JSON.parse(readFileSync(join(import.meta.dir, "fixtures", "hub-auth-v2.json"), "utf-8"))
const tmp = () => mkdtempSync(join(tmpdir(), "cc-devauth-"))

function fieldsOf(c: FixtureCase): TranscriptFields {
  return { ...c.fields, hubId: FX.hub.hub_id, hubKey: FX.hub.hk, deviceId: FX.device.did, cn: FX.conn.cn, sn: FX.conn.sn, aud: FX.conn.aud }
}
function secretOf(name: "token" | "pc" | "mc"): string {
  return name === "token" ? tokenSecret(FX.secrets.token) : name === "pc" ? FX.secrets.pc : normalizeManualCode(FX.secrets.mc_display)
}
/// Bun（BoringSSL）生成不了 secp256k1，用 node 现生成的一份公钥（只是公钥，测试用）
const SECP256K1_SPKI = "MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAET8PXIxfLAW96o9pFlLnLEjDuJqy_Ccj5M5Evqa5n0vrj0gyeJ1krn_39sVbJbfi942koVNTrgE_gV8_5bieX3Q"
const hubPub = () => importP256Spki(FX.hub.pub)!
const devPub = () => importP256Spki(FX.device.pub)!

// ── 金样 ──

test("金样：transcript 逐字节等于手拼的那份（四种 role、两种 path）", () => {
  expect(FX.cases.length).toBeGreaterThanOrEqual(12)
  for (const c of FX.cases) expect(`${c.name}\n${buildTranscript(fieldsOf(c)).toString("utf8")}`).toBe(`${c.name}\n${c.transcript}`)
})

test("金样：did / hk 由 SPKI 算出、长度固定", () => {
  expect(deviceIdOf(Buffer.from(FX.device.pub, "base64url"))).toBe(FX.device.did)
  expect(hubKeyOf(Buffer.from(FX.hub.pub, "base64url"))).toBe(FX.hub.hk)
  expect(FX.device.did.length).toBe(LEN.did)
  expect(FX.hub.hk.length).toBe(LEN.hk)
  expect(FX.device.pub.length).toBe(LEN.pub)
  // PEM 私钥导出的公钥 == 金样 pub
  expect(b64u(createPublicKey(createPrivateKey(FX.hub.pkcs8_pem)).export({ format: "der", type: "spki" }))).toBe(FX.hub.pub)
  expect(b64u(createPublicKey(createPrivateKey(FX.device.pkcs8_pem)).export({ format: "der", type: "spki" }))).toBe(FX.device.pub)
})

test("金样：sig_hub / sig_dev 能验，CryptoKit 签的那条也能验", () => {
  let swift = 0
  for (const c of FX.cases) {
    const t = Buffer.from(c.transcript, "utf8")
    if (c.sig_hub) expect(verifyP256(hubPub(), t, c.sig_hub)).toBe(true)
    if (c.sig_dev) expect(verifyP256(devPub(), t, c.sig_dev)).toBe(true)
    if (c.sig_dev_swift) { swift++; expect(verifyP256(devPub(), t, c.sig_dev_swift)).toBe(true) }
  }
  expect(swift).toBe(1)
})

test("金样：HMAC 逐字节一致（口令去首尾空白、pc 原样、mc 规范形）", () => {
  let n = 0
  for (const c of FX.cases) {
    if (!c.hmac || !c.secret) continue
    n++
    expect(`${c.name} ${hmacB64u(secretOf(c.secret), buildTranscript(fieldsOf(c)))}`).toBe(`${c.name} ${c.hmac}`)
  }
  expect(n).toBeGreaterThanOrEqual(7)
  expect(tokenSecret(FX.secrets.token)).toBe(FX.secrets.token_secret)
  for (const typed of FX.secrets.mc_typed) expect(normalizeManualCode(typed)).toBe(FX.secrets.mc_secret)
  expect(formatManualCode(FX.secrets.mc_secret)).toBe(FX.secrets.mc_display)
})

test("金样：aud 规范化（host 小写、IPv6 方括号、缺端口按 ws 80 / wss 443）", () => {
  for (const c of FX.aud_cases) {
    expect(normalizeAud(c.url)).toBe(c.aud)
    expect(isAud(c.aud)).toBe(true)
  }
})

test("改任一行 / 换 role / 换 path / 换 kind：签名和 HMAC 都验不过", () => {
  const dev = FX.cases.find((c) => c.name === "dev key /cc")!
  const base = fieldsOf(dev)
  const variants: Partial<TranscriptFields>[] = [
    { role: "secret-dev" }, { role: "hub-challenge" }, { path: "/agora" }, { kind: "token" }, { kind: "code" },
    { hubId: "00000000-0000-4000-8000-000000000000" }, { hubKey: randomNonce() }, { deviceId: FX.device.did.slice(0, 21) + (FX.device.did.endsWith("A") ? "B" : "A") },
    { pub: "-" }, { cn: randomNonce() }, { sn: randomNonce() }, { aud: "hub.example.test:7891" }, { result: "ok" }, { enrolled: "1" },
  ]
  for (const v of variants) {
    const t = buildTranscript({ ...base, ...v })
    expect(`${JSON.stringify(v)} ${verifyP256(devPub(), t, dev.sig_dev!)}`).toBe(`${JSON.stringify(v)} false`)
  }
  const mac = FX.cases.find((c) => c.name === "secret-hub token(token) enrolled=1 /cc")!
  expect(hmacB64u(secretOf("token"), buildTranscript({ ...fieldsOf(mac), enrolled: "0" }))).not.toBe(mac.hmac)
  expect(hmacB64u(secretOf("token"), buildTranscript({ ...fieldsOf(mac), role: "secret-dev" }))).not.toBe(mac.hmac)
  // 原始字节里改一个字节也不过
  const raw = Buffer.from(dev.transcript, "utf8")
  raw[raw.length - 2] ^= 1
  expect(verifyP256(devPub(), raw, dev.sig_dev!)).toBe(false)
})

test("transcript：值里有换行 / 空串直接抛", () => {
  const base = fieldsOf(FX.cases[0])
  expect(() => buildTranscript({ ...base, aud: "a:1\nrole=dev" })).toThrow()
  expect(() => buildTranscript({ ...base, aud: "a:1\r" })).toThrow()
  expect(() => buildTranscript({ ...base, pub: "" })).toThrow()
})

test("signP256 → verifyP256 往返；签名长度固定 86", () => {
  const priv = createPrivateKey(FX.hub.pkcs8_pem)
  const sig = signP256(priv, Buffer.from("x"))
  expect(sig.length).toBe(LEN.sig)
  expect(verifyP256(hubPub(), Buffer.from("x"), sig)).toBe(true)
  expect(verifyP256(hubPub(), Buffer.from("y"), sig)).toBe(false)
  expect(verifyP256(devPub(), Buffer.from("x"), sig)).toBe(false)
  expect(verifyP256(hubPub(), Buffer.from("x"), sig.slice(0, 85))).toBe(false)
})

// ── 格式校验 ──

test("非 P-256 的 SPKI 拒（P-384 / secp256k1 / Ed25519 / RSA / 乱码）", () => {
  const spki = (k: ReturnType<typeof generateKeyPairSync>["publicKey"]) => b64u(k.export({ format: "der", type: "spki" }))
  expect(importP256Spki(spki(generateKeyPairSync("ec", { namedCurve: "secp384r1" }).publicKey))).toBeNull()
  expect(importP256Spki(SECP256K1_SPKI)).toBeNull()
  expect(importP256Spki(spki(generateKeyPairSync("ed25519").publicKey))).toBeNull()
  expect(importP256Spki(spki(generateKeyPairSync("rsa", { modulusLength: 1024 }).publicKey))).toBeNull()
  expect(importP256Spki(b64u(Buffer.alloc(91, 7)))).toBeNull()
  expect(importP256Spki(FX.device.pub)).not.toBeNull()
})

test("isB64u：长度 / 字符集 / 非规范编码 / 非字符串都拒", () => {
  const n = randomNonce()
  expect(isB64u(n, 43)).toBe(true)
  expect(isB64u(n, 42)).toBe(false)
  expect(isB64u(n.slice(0, 42) + "+", 43)).toBe(false)
  expect(isB64u(n.slice(0, 42) + "=", 43)).toBe(false)
  // 32 字节 → 43 字符，最后一个字符只有 4 位有效：低 2 位不为 0 的写法解出来一样但不规范
  const canonicalLast = n[42]
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  const idx = alphabet.indexOf(canonicalLast)
  expect(isB64u(n.slice(0, 42) + alphabet[idx | 1], 43)).toBe(false)
  expect(isB64u(123, 3)).toBe(false)
  expect(isB64u([n], 43)).toBe(false)
})

test("isAud：host:port 形、≤300、端口 1–65535、不带路径 / 空白", () => {
  for (const ok of ["hub.example.test:80", "[::1]:7890", "[fe80::1%en0]:1", "192.0.2.1:65535", "HUB.test:443"]) expect(`${ok} ${isAud(ok)}`).toBe(`${ok} true`)
  for (const bad of ["hub.example.test", "hub:0", "hub:65536", "hub:80/cc", "a b:80", "::1:80", "", "x".repeat(300) + ":80", "hub:80\n", "user@hub:80"]) expect(`${bad} ${isAud(bad)}`).toBe(`${bad} false`)
  expect(isAud(80)).toBe(false)
})

test("query：v/did/cn/aud/bundle/since/token 任一重复即报；v=2 query 解析", () => {
  expect(duplicateAuthQuery(new URLSearchParams("v=2&did=a&cn=b"))).toBeNull()
  for (const k of ["v", "did", "cn", "aud", "bundle", "since", "token"]) expect(duplicateAuthQuery(new URLSearchParams(`${k}=1&x=2&${k}=3`))).toBe(k)
  expect(duplicateAuthQuery(new URLSearchParams("other=1&other=2"))).toBeNull()
  const q = `v=2&did=${FX.device.did}&cn=${FX.conn.cn}&aud=${encodeURIComponent(FX.conn.aud)}`
  expect(parseV2Query(new URLSearchParams(q))).toEqual({ did: FX.device.did, cn: FX.conn.cn, aud: FX.conn.aud })
  expect(parseV2Query(new URLSearchParams(q.replace("v=2", "v=1")))).toBeNull()
  expect(parseV2Query(new URLSearchParams(q.replace(FX.device.did, FX.device.did.slice(1))))).toBeNull()
  expect(parseV2Query(new URLSearchParams(q.replace(FX.conn.cn, FX.conn.cn + "A")))).toBeNull()
  expect(parseV2Query(new URLSearchParams(q.replace(encodeURIComponent(FX.conn.aud), "nope")))).toBeNull()
})

test("parseAuthFrame：三种 kind 正常、类型冒充 / 缺字段 → bad_request、alg 不对 / 非 P-256 → unsupported_alg", () => {
  const dev = FX.cases.find((c) => c.name === "dev key /cc")!
  const proof = FX.cases.find((c) => c.name === "secret-dev token /cc")!.hmac!
  const key = { type: "auth", v: 2, kind: "key", alg: "p256", pub: FX.device.pub, sig_dev: dev.sig_dev, extra: [1] }
  expect(parseAuthFrame(JSON.stringify(key))).toEqual({ ok: true, frame: { kind: "key", pub: FX.device.pub, sigDev: dev.sig_dev! } })
  const tok = { ...key, kind: "token", proof, name: "  iPhone\u0007 Air  ", platform: "ios", reauth: true }
  expect(parseAuthFrame(JSON.stringify(tok))).toEqual({ ok: true, frame: { kind: "token", pub: FX.device.pub, sigDev: dev.sig_dev!, proof, name: "iPhone Air", platform: "ios", reauth: true } })
  const code = { ...key, kind: "code", proof, reauth: true }
  expect(parseAuthFrame(JSON.stringify(code))).toEqual({ ok: true, frame: { kind: "code", pub: FX.device.pub, sigDev: dev.sig_dev!, proof, name: "未命名设备", platform: "unknown" } })
  const bad = { ok: false, reason: "bad_request" }
  for (const b of [
    "not json", "[]", "null", JSON.stringify({ ...key, type: "hello" }), JSON.stringify({ ...key, v: "2" }), JSON.stringify({ ...key, kind: "pass" }),
    JSON.stringify({ ...key, pub: [FX.device.pub] }), JSON.stringify({ ...key, sig_dev: 1 }), JSON.stringify({ ...key, alg: ["p256"] }),
    JSON.stringify({ ...tok, proof: undefined }), JSON.stringify({ ...tok, name: 5 }), JSON.stringify({ ...tok, platform: {} }), JSON.stringify({ ...tok, reauth: "true" }),
  ]) expect(`${b.slice(0, 60)} ${JSON.stringify(parseAuthFrame(b))}`).toBe(`${b.slice(0, 60)} ${JSON.stringify(bad)}`)
  expect(parseAuthFrame(JSON.stringify({ ...key, alg: "ed25519" }))).toEqual({ ok: false, reason: "unsupported_alg" })
  const k384 = b64u(generateKeyPairSync("ec", { namedCurve: "secp384r1" }).publicKey.export({ format: "der", type: "spki" }))
  // P-384 SPKI 长度本来就不是 122 → 先被长度挡成 bad_request；长度对但不是 P-256 的才是 unsupported_alg
  expect(parseAuthFrame(JSON.stringify({ ...key, pub: k384 })).ok).toBe(false)
  // 长度对、字符集对，但点不在曲线上 → 导不进 → unsupported_alg
  const der = Buffer.from(FX.device.pub, "base64url")
  der[der.length - 1] ^= 0xff
  const offCurve = b64u(der)
  expect(offCurve.length).toBe(LEN.pub)
  expect(importP256Spki(offCurve)).toBeNull()
  expect(parseAuthFrame(JSON.stringify({ ...key, pub: offCurve }))).toEqual({ ok: false, reason: "unsupported_alg" })
})

test("sanitizeDeviceName：去控制字符、去首尾空白、截 40 字（按字符不按 UTF-16）、空了给默认名", () => {
  expect(sanitizeDeviceName("  粟粟的 iPad\n")).toBe("粟粟的 iPad")
  expect(sanitizeDeviceName("\u0000\u001f")).toBe("未命名设备")
  expect([...sanitizeDeviceName("🌱".repeat(50))].length).toBe(40)
})

test("timingSafeEqualB64u", () => {
  const a = randomNonce()
  expect(timingSafeEqualB64u(a, a)).toBe(true)
  expect(timingSafeEqualB64u(a, randomNonce())).toBe(false)
  expect(timingSafeEqualB64u(a, a.slice(1))).toBe(false)
})

// ── hub-key.pem ──

test("hub-key.pem：缺 → 生成并以 0600 写盘，再读回同一把", () => {
  const p = join(tmp(), "hub-key.pem")
  const a = loadOrCreateHubKey(p)
  expect(a.ok && a.created).toBe(true)
  expect(statSync(p).mode & 0o777).toBe(0o600)
  const b = loadOrCreateHubKey(p)
  expect(b.ok && !b.created).toBe(true)
  if (!a.ok || !b.ok) throw new Error("unreachable")
  expect(b.key.hk).toBe(a.key.hk)
  expect(a.key.hk).toBe(hubKeyOf(Buffer.from(a.key.pub, "base64url")))
})

test("hub-key.pem：写不进去 → 不开新协议（不用临时钥）", () => {
  const p = join(tmp(), "hub-key.pem")
  const r = loadOrCreateHubKey(p, () => { throw new Error("EACCES") })
  expect(r.ok).toBe(false)
  expect(existsSync(p)).toBe(false)
  // 目录不可写的真实情况
  const dir = tmp()
  chmodSync(dir, 0o500)
  try { expect(loadOrCreateHubKey(join(dir, "sub", "hub-key.pem")).ok).toBe(false) } finally { chmodSync(dir, 0o700) }
})

test("hub-key.pem：坏的 / 不是 P-256 → 不重建、原文件不动", () => {
  const dir = tmp()
  const p = join(dir, "hub-key.pem")
  writeFileSync(p, "garbage")
  expect(loadOrCreateHubKey(p).ok).toBe(false)
  expect(readFileSync(p, "utf-8")).toBe("garbage")
  const p384 = generateKeyPairSync("ec", { namedCurve: "secp384r1" }).privateKey.export({ format: "pem", type: "pkcs8" }).toString()
  writeFileSync(p, p384)
  const r = loadOrCreateHubKey(p)
  expect(r.ok).toBe(false)
  expect(readFileSync(p, "utf-8")).toBe(p384)
  writeFileSync(p, FX.hub.pkcs8_pem)
  const ok = loadOrCreateHubKey(p)
  expect(ok.ok && ok.key.hk).toBe(FX.hub.hk)
})

// ── devices.json ──

const enroll = (s: DeviceStore, now = 1000, via: "token" | "code" | "invite" = "token") =>
  s.upsertEnroll({ id: FX.device.did, pub: FX.device.pub, name: "iPhone", platform: "ios", via, from: "lan", now })

test("devices.json：缺文件 = 空表可用；登记往返；吊销 / 改名 / 重新授权都落盘", () => {
  const p = join(tmp(), "devices.json")
  const s = new DeviceStore(p)
  s.load()
  expect(s.available).toBe(true)
  expect(s.list()).toEqual([])
  expect(enroll(s)).toEqual({ created: true, reauthorized: false })
  expect(statSync(p).mode & 0o777).toBe(0o600)
  const s2 = new DeviceStore(p); s2.load()
  expect(s2.get(FX.device.did)).toMatchObject({ name: "iPhone", platform: "ios", alg: "p256", added_via: "token", added_at: 1000, revoked_at: null, last_from: "lan" })
  expect(s2.rename(FX.device.did, "小手机")).toBe(true)
  expect(s2.revoke(FX.device.did, 2000)).toBe(true)
  expect(s2.revoke(FX.device.did, 2001)).toBe(false)
  expect(s2.list()).toEqual([])
  const s3 = new DeviceStore(p); s3.load()
  expect(s3.get(FX.device.did)).toMatchObject({ name: "小手机", revoked_at: 2000 })
  // 吊销过的再登记 = 重新授权（调用方判过可以）；名字不被覆盖
  expect(enroll(s3, 3000)).toEqual({ created: false, reauthorized: true })
  const s4 = new DeviceStore(p); s4.load()
  expect(s4.get(FX.device.did)).toMatchObject({ name: "小手机", revoked_at: null, reauthorized_at: 3000, added_at: 1000 })
})

test("devices.json：坏文件不当空表，原文件不动；安全变更都拒", () => {
  const dir = tmp()
  for (const raw of ["{", "[]", JSON.stringify({ v: 2, devices: [] }), JSON.stringify({ v: 1 }), JSON.stringify({ v: 1, devices: [{ id: "x" }] }),
    JSON.stringify({ v: 1, devices: [{ id: FX.device.did, name: "a", platform: "ios", alg: "p256", pub: FX.device.pub, added_at: "1", added_via: "token", last_used_at: null, last_from: null, revoked_at: null, reauthorized_at: null }] })]) {
    const p = join(dir, "devices.json")
    writeFileSync(p, raw)
    const s = new DeviceStore(p)
    s.load()
    expect(`${raw.slice(0, 40)} ${s.available}`).toBe(`${raw.slice(0, 40)} false`)
    expect(() => enroll(s)).toThrow()
    expect(() => s.revoke(FX.device.did, 1)).toThrow()
    s.touch(FX.device.did, "lan", 1)
    expect(readFileSync(p, "utf-8")).toBe(raw)
  }
})

test("devices.json：同一个 did 出现两次也算坏", () => {
  const p = join(tmp(), "devices.json")
  const s = new DeviceStore(p); s.load(); enroll(s)
  const o = JSON.parse(readFileSync(p, "utf-8"))
  o.devices.push(o.devices[0])
  writeFileSync(p, JSON.stringify(o))
  const s2 = new DeviceStore(p); s2.load()
  expect(s2.available).toBe(false)
})

test("devices.json：安全变更写盘失败 → 抛错、内存回滚", () => {
  let fail = false
  const writes: unknown[] = []
  const s = new DeviceStore(join(tmp(), "devices.json"), (_p, v) => { if (fail) throw new Error("ENOSPC"); writes.push(v) })
  s.load()
  fail = true
  expect(() => enroll(s)).toThrow("ENOSPC")
  expect(s.get(FX.device.did)).toBeUndefined()
  fail = false
  enroll(s)
  fail = true
  expect(() => s.revoke(FX.device.did, 5)).toThrow()
  expect(s.get(FX.device.did)?.revoked_at).toBeNull()
  expect(() => s.rename(FX.device.did, "新名")).toThrow()
  expect(s.get(FX.device.did)?.name).toBe("iPhone")
  fail = false
  s.revoke(FX.device.did, 6)
  fail = true
  expect(() => enroll(s, 7)).toThrow()
  expect(s.get(FX.device.did)?.revoked_at).toBe(6)
})

test("devices.json：touch 内存即时、落盘 1 小时一次，写失败吞掉", () => {
  let n = 0, fail = false
  const s = new DeviceStore(join(tmp(), "devices.json"), () => { if (fail) throw new Error("x"); n++ })
  s.load()
  enroll(s, 0)
  expect(n).toBe(1)
  s.touch(FX.device.did, "relay", 10_000)
  expect(n).toBe(1)
  expect(s.get(FX.device.did)).toMatchObject({ last_used_at: 10_000, last_from: "relay" })
  s.touch(FX.device.did, "relay", 3_600_000)
  expect(n).toBe(2)
  fail = true
  expect(() => s.touch(FX.device.did, "lan", 8_000_000)).not.toThrow()
  expect(s.get(FX.device.did)?.last_from).toBe("lan")
  fail = false
  s.touch(FX.device.did, "lan", 8_000_001)
  expect(n).toBe(3)
  s.touch("nobody", "lan", 9_000_000)
  expect(n).toBe(3)
})

test("devices.json：吊销与 touch / 登记交错后重启再查，吊销不丢（T10 纯函数部分）", () => {
  const p = join(tmp(), "devices.json")
  const s = new DeviceStore(p); s.load()
  enroll(s, 0)
  s.touch(FX.device.did, "lan", 10)
  s.revoke(FX.device.did, 20)
  s.touch(FX.device.did, "lan", 4_000_000)
  const s2 = new DeviceStore(p); s2.load()
  expect(s2.get(FX.device.did)?.revoked_at).toBe(20)
})

// ── 配对码 ──

const codeProof = (secret: string) => {
  const c = FX.cases.find((x) => x.name === "secret-dev code(pc) /cc")!
  const t = buildTranscript(fieldsOf(c))
  return { t, proof: hmacB64u(secret, t) }
}

test("配对码：pc 32 字节 b64u、mc 10 位 Crockford；字段格式；10 分钟过期", () => {
  const pcs = new PairCodes()
  const rec = pcs.issue({ now: 1_000_000 })
  expect(isB64u(rec.pc, 43)).toBe(true)
  expect(rec.mc).toMatch(/^[0-9A-HJKMNP-TV-Z]{10}$/)
  expect(pairCodeFields(rec)).toEqual({ pc: rec.pc, mc: `${rec.mc.slice(0, 5)}-${rec.mc.slice(5)}`, exp: Math.floor((1_000_000 + PAIR_CODE_TTL_MS) / 1000) })
  const { t, proof } = codeProof(rec.pc)
  expect(pcs.match(t, proof, 1_000_000 + PAIR_CODE_TTL_MS - 1)?.rec).toBe(rec)
  expect(pcs.match(t, proof, 1_000_000 + PAIR_CODE_TTL_MS)).toBeNull()
  expect(pcs.size).toBe(0)
})

test("配对码：pc 原样（不规范化）、mc 用规范形；match 不销，consume 才销、整条作废", () => {
  const pcs = new PairCodes()
  const rec = pcs.issue({ now: 0 })
  const viaPc = codeProof(rec.pc)
  expect(pcs.match(viaPc.t, viaPc.proof, 1)?.rec).toBe(rec)
  expect(pcs.match(viaPc.t, viaPc.proof, 1)?.rec).toBe(rec)   // 没销
  // pc 规范化后（大小写变了）不认
  const lowered = codeProof(rec.pc.toLowerCase() === rec.pc ? rec.pc.toUpperCase() : rec.pc.toLowerCase())
  expect(pcs.match(lowered.t, lowered.proof, 1)).toBeNull()
  // mc：设备那边混写 i l o / 横线 / 空格，规范化后算的 proof 能中
  const typed = ` ${rec.mc.slice(0, 5).toLowerCase()} - ${rec.mc.slice(5).replace(/1/g, "l").replace(/0/g, "o")} `
  const viaMc = codeProof(normalizeManualCode(typed))
  expect(pcs.match(viaMc.t, viaMc.proof, 1)?.rec).toBe(rec)
  expect(pcs.match(viaMc.t, viaMc.proof, 1)?.secret).toBe(rec.mc)
  expect(pcs.match(viaPc.t, viaPc.proof, 1)?.secret).toBe(rec.pc)
  // 原样 typed（没规范化）不中
  const raw = codeProof(typed)
  expect(pcs.match(raw.t, raw.proof, 1)).toBeNull()
  pcs.consume(rec)
  expect(pcs.match(viaMc.t, viaMc.proof, 1)).toBeNull()
  expect(pcs.match(viaPc.t, viaPc.proof, 1)).toBeNull()
})

test("配对码：最多 5 条，多了挤掉最老的；错码不作废（码不作废）", () => {
  const pcs = new PairCodes()
  const recs = Array.from({ length: PAIR_CODE_MAX + 1 }, (_, i) => pcs.issue({ now: i }))
  expect(pcs.size).toBe(PAIR_CODE_MAX)
  const first = codeProof(recs[0].pc)
  expect(pcs.match(first.t, first.proof, 10)).toBeNull()
  const last = codeProof(recs[PAIR_CODE_MAX].pc)
  for (let i = 0; i < 20; i++) expect(pcs.match(last.t, codeProof("wrong" + i).proof, 10)).toBeNull()
  expect(pcs.match(last.t, last.proof, 10)?.rec).toBe(recs[PAIR_CODE_MAX])
})

test("配对码：吊销设备撤它发的未用邀请，别人的不动", () => {
  const pcs = new PairCodes()
  const mine = pcs.issue({ issuer: FX.device.did, now: 0 })
  const other = pcs.issue({ now: 0 })
  expect(mine.issuedBy).toBe(FX.device.did)
  expect(pcs.revokeIssuedBy(FX.device.did)).toBe(1)
  const a = codeProof(mine.pc), b = codeProof(other.pc)
  expect(pcs.match(a.t, a.proof, 1)).toBeNull()
  expect(pcs.match(b.t, b.proof, 1)?.rec).toBe(other)
})

test("配对码：写表失败不销码（调用方先 upsertEnroll 再 consume 的约定）", () => {
  const pcs = new PairCodes()
  const rec = pcs.issue({ now: 0 })
  const s = new DeviceStore(join(tmp(), "devices.json"), () => { throw new Error("ENOSPC") })
  s.load()
  const { t, proof } = codeProof(rec.pc)
  const hit = pcs.match(t, proof, 1)?.rec
  expect(hit).toBe(rec)
  expect(() => enroll(s, 1, "code")).toThrow()
  expect(pcs.match(t, proof, 2)?.rec).toBe(rec)
})

// ── legacy-seen ──

test("LegacySeen：读回、内存即时、落盘 1 小时一次、坏文件当没有", () => {
  const dir = tmp()
  const p = join(dir, "legacy-seen.json")
  const a = new LegacySeen(p)
  expect(a.get()).toBeNull()
  a.touch("lan", 1000)
  expect(JSON.parse(readFileSync(p, "utf-8"))).toEqual({ last_at: 1000, last_from: "lan" })
  a.touch("relay", 2000)
  expect(a.get()).toEqual({ at: 2000, from: "relay" })
  expect(JSON.parse(readFileSync(p, "utf-8")).last_at).toBe(1000)
  a.touch("relay", 1000 + 3_600_000)
  expect(JSON.parse(readFileSync(p, "utf-8")).last_at).toBe(1000 + 3_600_000)
  expect(new LegacySeen(p).get()).toEqual({ at: 1000 + 3_600_000, from: "relay" })
  writeFileSync(p, "{bad")
  expect(new LegacySeen(p).get()).toBeNull()
  const failing = new LegacySeen(join(dir, "x.json"), () => { throw new Error("x") })
  expect(() => failing.touch("lan", 1)).not.toThrow()
  expect(failing.get()).toEqual({ at: 1, from: "lan" })
})

// ── DeviceAuth：§0.4 处理（hub 侧纯逻辑；集成在 hub-device-auth.test.ts）──

const HUB_TOKEN_T = "  da-测试口令-91  "
function makeAuth(o: { write?: (p: string, v: unknown) => void; storeRaw?: string; hubId?: string } = {}) {
  const dir = tmp()
  const path = join(dir, "devices.json")
  if (o.storeRaw !== undefined) writeFileSync(path, o.storeRaw)
  const store = new DeviceStore(path, o.write)
  store.load()
  const hk = loadOrCreateHubKey(join(dir, "hub-key.pem"))
  if (!hk.ok) throw new Error(hk.reason)
  return new DeviceAuth(o.hubId ?? "11111111-2222-4333-8444-555555555555", hk.key, store, HUB_TOKEN_T)
}
function round(da: DeviceAuth, dev: TestDevice, cred: Parameters<typeof authFrame>[3], o: { path?: "/cc" | "/agora"; now?: number; extra?: Record<string, unknown>; aud?: string } = {}) {
  const conn: Conn = newConn(o.path ?? "/cc", o.aud ?? "hub.example.test:7890")
  const { ctx, frame } = da.newChallenge({ path: conn.path, did: dev.did, cn: conn.cn, aud: conn.aud })
  const ch = JSON.parse(frame) as Challenge
  const out = da.handle(ctx, authFrame(dev, ch, conn, cred, o.extra), { from: "lan", now: o.now ?? 1000 })
  return { conn, ctx, ch, out }
}
const tokenCred = (reauth = false) => ({ kind: "token" as const, secret: tokenSecret(HUB_TOKEN_T), reauth })
const failOf = (out: AuthOutcome) => out.ok ? "ok" : out.reason

test("DeviceAuth：挑战帧能验（hk = hubKeyOf(hub_pub)、sig_hub 绑 did / cn / aud / path），改 path / cn 就验不过", () => {
  const da = makeAuth()
  const dev = makeTestDevice()
  const { ch, conn } = round(da, dev, { kind: "key" })
  expect(ch.type).toBe("auth_challenge")
  expect(ch.v).toBe(2)
  expect(ch.hub_key).toBe(da.key.hk)
  expect(challengeValid(dev, ch, conn)).toBe(true)
  expect(challengeValid(dev, ch, { ...conn, path: "/agora" })).toBe(false)
  expect(challengeValid(dev, ch, { ...conn, cn: randomNonce() })).toBe(false)
  expect(challengeValid(makeTestDevice(), ch, conn)).toBe(false)
})

test("DeviceAuth：key 不认识 → unknown_device；token 登记（hub_proof 对）→ 之后 key 通；吊销 → key / token 都 revoked；reauth 才回来（T7）", () => {
  const da = makeAuth()
  const dev = makeTestDevice()
  expect(failOf(round(da, dev, { kind: "key" }).out)).toBe("unknown_device")
  const t = round(da, dev, tokenCred())
  if (!t.out.ok) throw new Error(failOf(t.out))
  expect(t.out.frame).toEqual({ type: "auth_ok", via: "token", device_id: dev.did, enrolled: true, hub_proof: expectedHubProof(dev, t.ch, t.conn, "token", tokenSecret(HUB_TOKEN_T), true) })
  expect(da.store.get(dev.did)).toMatchObject({ added_via: "token", name: "测试设备", platform: "ios", last_from: "lan" })
  const k = round(da, dev, { kind: "key" }, { now: 5000 })
  expect(k.out.ok && k.out.frame).toEqual({ type: "auth_ok", via: "key", device_id: dev.did, enrolled: true })
  expect(da.store.get(dev.did)?.last_used_at).toBe(5000)
  expect(da.store.revoke(dev.did, 6000)).toBe(true)
  expect(failOf(round(da, dev, { kind: "key" }).out)).toBe("revoked")
  expect(failOf(round(da, dev, tokenCred()).out)).toBe("revoked")
  const re = round(da, dev, tokenCred(true), { now: 7000 })
  expect(re.out.ok).toBe(true)
  expect(da.store.get(dev.did)).toMatchObject({ revoked_at: null, reauthorized_at: 7000 })
  expect(round(da, dev, { kind: "key" }).out.ok).toBe(true)
})

test("DeviceAuth：签名不对 / did 跟 pub 对不上 / 拿别的挑战的签名 / 回显改了 → bad_sig", () => {
  const da = makeAuth()
  const dev = makeTestDevice(), other = makeTestDevice()
  round(da, dev, tokenCred())
  const conn = newConn("/cc", "hub.example.test:7890")
  const { ctx, frame } = da.newChallenge({ path: "/cc", did: dev.did, cn: conn.cn, aud: conn.aud })
  const ch = JSON.parse(frame) as Challenge
  // 帧里换成别人的 pub（did 还是 dev 的）
  expect(failOf(da.handle(ctx, authFrame(other, ch, conn, { kind: "key" }), { from: "lan", now: 1 }))).toBe("bad_sig")
  // 上一条连接的 auth 帧原样重放到新挑战（sn 不同）
  const old = round(da, dev, { kind: "key" })
  const replay = da.newChallenge({ path: "/cc", did: dev.did, cn: old.conn.cn, aud: old.conn.aud })
  expect(failOf(da.handle(replay.ctx, authFrame(dev, old.ch, old.conn, { kind: "key" }), { from: "lan", now: 1 }))).toBe("bad_sig")
  // hub 用自己存的 ctx：设备按别的 path / aud 签的不认
  expect(failOf(da.handle(ctx, authFrame(dev, ch, { ...conn, path: "/agora" }, { kind: "key" }), { from: "lan", now: 1 }))).toBe("bad_sig")
  expect(failOf(da.handle(ctx, authFrame(dev, ch, { ...conn, aud: "evil.example.test:1" }, { kind: "key" }), { from: "lan", now: 1 }))).toBe("bad_sig")
  expect(failOf(da.handle(ctx, authFrame(dev, ch, conn, { kind: "key" }), { from: "lan", now: 1 }))).toBe("ok")
})

test("DeviceAuth：同一 did 登记到两台 hub，A 的签名登不进 B，吊销互不影响（T5 纯逻辑）", () => {
  const A = makeAuth({ hubId: "aaaaaaaa-0000-4000-8000-000000000000" }), B = makeAuth({ hubId: "bbbbbbbb-0000-4000-8000-000000000000" })
  const dev = makeTestDevice()
  round(A, dev, tokenCred()); round(B, dev, tokenCred())
  const a = round(A, dev, { kind: "key" })
  const conn = newConn("/cc", "hub.example.test:7890")
  const b = B.newChallenge({ path: "/cc", did: dev.did, cn: conn.cn, aud: conn.aud })
  // 用 A 的 hub_id / hk 签、套上 B 的 sn
  const forged = authFrame(dev, { ...a.ch, sn: (JSON.parse(b.frame) as Challenge).sn }, conn, { kind: "key" })
  expect(failOf(B.handle(b.ctx, forged, { from: "lan", now: 1 }))).toBe("bad_sig")
  A.store.revoke(dev.did, 2)
  expect(failOf(round(A, dev, { kind: "key" }).out)).toBe("revoked")
  expect(round(B, dev, { kind: "key" }).out.ok).toBe(true)
})

test("DeviceAuth：口令 / 码错 → bad_proof；没有全局闸：别的设备乱试多少次，正确证明同一时刻立即过（K1 返修 r1）", () => {
  const da = makeAuth()
  const attacker = makeTestDevice(), dev = makeTestDevice()
  const wrong = { kind: "token" as const, secret: "nope" }
  for (let i = 0; i < 50; i++) {
    expect(failOf(round(da, attacker, wrong, { now: 0 }).out)).toBe("bad_proof")
    expect(failOf(round(da, attacker, { kind: "code", secret: "x" }, { now: 0 }).out)).toBe("bad_proof")
  }
  expect(failOf(round(da, dev, tokenCred(), { now: 0 }).out)).toBe("ok")
  const c = da.codes.issue({ now: 0 })
  expect(failOf(round(da, makeTestDevice(), { kind: "code", secret: c.pc }, { now: 0 }).out)).toBe("ok")
  // 同一台乱试完也照样能用对的
  expect(failOf(round(da, attacker, tokenCred(), { now: 0 }).out)).toBe("ok")
  // hub 没配口令 → token 永远 bad_proof
  const noTok = new DeviceAuth(da.hubId, da.key, da.store, undefined)
  expect(failOf(round(noTok, dev, { kind: "token", secret: "" }).out)).toBe("bad_proof")
})

test("DeviceAuth：配对码 pc / mc 都能配、hub_proof 用设备实际用的那个、用一次就作废；吊销过的直接重新授权；邀请码记 invited_by", () => {
  const da = makeAuth()
  const dev = makeTestDevice()
  const c1 = da.codes.issue({ now: 0 })
  const viaPc = round(da, dev, { kind: "code", secret: c1.pc }, { now: 10 })
  if (!viaPc.out.ok) throw new Error(failOf(viaPc.out))
  expect(viaPc.out.frame.hub_proof).toBe(expectedHubProof(dev, viaPc.ch, viaPc.conn, "code", c1.pc, true))
  expect(da.store.get(dev.did)?.added_via).toBe("code")
  expect(failOf(round(da, dev, { kind: "code", secret: c1.pc }, { now: 11 }).out)).toBe("bad_proof")
  expect(failOf(round(da, dev, { kind: "code", secret: c1.mc }, { now: 11 }).out)).toBe("bad_proof")
  da.store.revoke(dev.did, 20)
  const c2 = da.codes.issue({ now: 30 })
  const typed = normalizeManualCode(formatManualCode(c2.mc).toLowerCase())
  const viaMc = round(da, dev, { kind: "code", secret: typed }, { now: 40 })
  if (!viaMc.out.ok) throw new Error(failOf(viaMc.out))
  expect(viaMc.out.frame.hub_proof).toBe(expectedHubProof(dev, viaMc.ch, viaMc.conn, "code", c2.mc, true))
  expect(da.store.get(dev.did)).toMatchObject({ revoked_at: null, reauthorized_at: 40 })
  const inviter = makeTestDevice(), newcomer = makeTestDevice()
  const inv = da.codes.issue({ issuer: inviter.did, now: 50 })
  expect(round(da, newcomer, { kind: "code", secret: inv.pc }, { now: 60 }).out.ok).toBe(true)
  expect(da.store.get(newcomer.did)).toMatchObject({ added_via: "invite", invited_by: inviter.did })
})

test("DeviceAuth：配对码登记写盘失败 → unavailable、码不销；修好后同一个码还能用", () => {
  let fail = true
  const da = makeAuth({ write: (p, v) => { if (fail) throw new Error("ENOSPC"); writeFileSync(p, JSON.stringify(v)) } })
  const dev = makeTestDevice()
  const c = da.codes.issue({ now: 0 })
  expect(failOf(round(da, dev, { kind: "code", secret: c.pc }, { now: 1 }).out)).toBe("unavailable")
  expect(da.store.get(dev.did)).toBeUndefined()
  fail = false
  expect(round(da, dev, { kind: "code", secret: c.pc }, { now: 2 }).out.ok).toBe(true)
})

test("DeviceAuth：设备表健康、口令登记写盘失败 → unavailable、内存回滚（新登记 / 撤销吊销都一样，K1 返修 r1）", () => {
  let fail = true
  const da = makeAuth({ write: (p, v) => { if (fail) throw new Error("ENOSPC"); writeFileSync(p, JSON.stringify(v)) } })
  const dev = makeTestDevice()
  expect(failOf(round(da, dev, tokenCred()).out)).toBe("unavailable")
  expect(da.store.get(dev.did)).toBeUndefined()
  fail = false
  expect(round(da, dev, tokenCred()).out.ok).toBe(true)
  da.store.revoke(dev.did, 5)
  fail = true
  expect(failOf(round(da, dev, tokenCred(true)).out)).toBe("unavailable")
  expect(da.store.get(dev.did)?.revoked_at).toBe(5)
})

test("DeviceAuth：只有加载时设备表就坏了，口令才放行 enrolled:false（hub_proof 绑 enrolled=0）", () => {
  const da = makeAuth({ storeRaw: "{broken" })
  const dev = makeTestDevice()
  const r = round(da, dev, tokenCred())
  if (!r.out.ok) throw new Error(failOf(r.out))
  expect(r.out.enrolled).toBe(false)
  expect(r.out.frame.hub_proof).toBe(expectedHubProof(dev, r.ch, r.conn, "token", tokenSecret(HUB_TOKEN_T), false))
})

test("DeviceAuth：设备表坏了 → key / code unavailable（码不销），token 放行 enrolled:false", () => {
  const da = makeAuth({ storeRaw: "{broken" })
  const dev = makeTestDevice()
  expect(failOf(round(da, dev, { kind: "key" }).out)).toBe("unavailable")
  const c = da.codes.issue({ now: 0 })
  expect(failOf(round(da, dev, { kind: "code", secret: c.pc }).out)).toBe("unavailable")
  expect(da.codes.size).toBe(1)
  const t = round(da, dev, tokenCred())
  expect(t.out.ok && t.out.enrolled).toBe(false)
})

test("DeviceAuth：帧坏 → bad_request；alg 不对 → unsupported_alg；auth_fail 帧形状", () => {
  const da = makeAuth()
  const dev = makeTestDevice()
  const ctx: ChallengeCtx = { path: "/cc", did: dev.did, cn: randomNonce(), aud: "a:1", sn: randomNonce() }
  expect(failOf(da.handle(ctx, "{}", { from: "lan", now: 0 }))).toBe("bad_request")
  expect(failOf(da.handle(ctx, JSON.stringify({ type: "hello" }), { from: "lan", now: 0 }))).toBe("bad_request")
  expect(failOf(round(da, dev, { kind: "key" }, { extra: { alg: "ed25519" } }).out)).toBe("unsupported_alg")
  expect(authFailFrame("bad_sig")).toBe(JSON.stringify({ type: "auth_fail", reason: "bad_sig" }))
})

test("validDeviceName：1–40 字、去首尾空白、控制字符拒", () => {
  expect(validDeviceName("  小手机 ")).toBe("小手机")
  expect(validDeviceName("")).toBeNull()
  expect(validDeviceName("   ")).toBeNull()
  expect(validDeviceName("a\u0007b")).toBeNull()
  expect(validDeviceName("🌱".repeat(40))).toBe("🌱".repeat(40))
  expect(validDeviceName("🌱".repeat(41))).toBeNull()
  expect(validDeviceName(5)).toBeNull()
})
