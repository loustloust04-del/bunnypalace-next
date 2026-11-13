/// hub 设备密钥对鉴权（docs/plan-hub-keypair-auth.md §0 / K1-B）：纯函数 + 小状态，hub.ts 只接线。
///
/// 字节格式（transcript / b64u / HMAC / 签名）是跟 app（K2 Swift）共用的契约，金样在 fixtures/hub-auth-v2.json，
/// 改这里任何一个字节都要两端一起改。日志里永远不打签名 / proof / 码 / 口令 / cn / sn。
import { createHash, createHmac, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign, timingSafeEqual, verify, type KeyObject } from "node:crypto"
import { timedSyncFs } from "./block-ledger"
import { saveJsonPrivate, writeFilePrivate } from "./hub-config"
const { readFileSync } = timedSyncFs("device-auth ")

// ── 编码与格式校验（§0.1）──

export function b64u(buf: Uint8Array): string {
  return Buffer.from(buf).toString("base64url")
}

const B64U_RE = /^[A-Za-z0-9_-]+$/
/// 固定长度 + 字符集 + 规范编码（解码再编码一致，挡尾部多余比特的变体）
export function isB64u(s: unknown, len: number): s is string {
  return typeof s === "string" && s.length === len && B64U_RE.test(s) && b64u(Buffer.from(s, "base64url")) === s
}

/// did 是 sha256 的 b64u 截前 22 个字符，不是某段字节的完整编码，只核长度 + 字符集
export function isDid(s: unknown): s is string {
  return typeof s === "string" && s.length === LEN.did && B64U_RE.test(s)
}

export const LEN = { did: 22, hk: 43, nonce: 43, sig: 86, mac: 43, pub: 122 } as const
const UUID_LOWER_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
/// aud：`host:port`，host 可以是 [IPv6]；≤ 300 字符。hub 不改写，只核形状
const AUD_RE = /^(\[[0-9A-Za-z:.%]+\]|[^\s:[\]/@?#]+):([0-9]{1,5})$/

export function isAud(s: unknown): s is string {
  if (typeof s !== "string" || s.length > 300) return false
  const m = AUD_RE.exec(s)
  if (!m) return false
  const port = Number(m[2])
  return port >= 1 && port <= 65535
}

/// 连接 URL → aud（设备侧算法，hub 测试客户端和金样用）：host 小写（IPv6 带方括号）+ `:` + 端口，没写端口按 ws 80 / wss 443
export function normalizeAud(url: string): string {
  const u = new URL(url)
  const port = u.port || (u.protocol === "wss:" ? "443" : "80")
  return `${u.hostname.toLowerCase()}:${port}`
}

/// 这些 query 重复出现即 bad_request（防两端各取一个）
export const AUTH_QUERY_KEYS = ["v", "did", "cn", "aud", "bundle", "since", "token"] as const
export function duplicateAuthQuery(params: URLSearchParams): string | null {
  for (const k of AUTH_QUERY_KEYS) if (params.getAll(k).length > 1) return k
  return null
}

export interface V2Query { did: string; cn: string; aud: string }
/// `v=2` 连接的 query：did / cn / aud 合法才返回（bundle / since 由调用方照旧处理）
export function parseV2Query(params: URLSearchParams): V2Query | null {
  if (params.get("v") !== "2") return null
  const did = params.get("did"), cn = params.get("cn"), aud = params.get("aud")
  if (!isDid(did) || !isB64u(cn, LEN.nonce) || !isAud(aud)) return null
  return { did, cn, aud }
}

// ── transcript（§0.2）──

export type AuthRole = "hub-challenge" | "dev" | "secret-dev" | "secret-hub"
export type AuthPath = "/cc" | "/agora"
export type AuthKind = "key" | "token" | "code"

export interface TranscriptFields {
  role: AuthRole
  path: AuthPath
  kind: AuthKind | "-"
  hubId: string
  hubKey: string
  deviceId: string
  pub: string
  cn: string
  sn: string
  aud: string
  result: "ok" | "-"
  enrolled: "1" | "0" | "-"
}

/// UTF-8、LF、每行结尾都有 \n、行序固定；没值的字段由调用方写 `-`。值里有 \n / \r 或是空串直接抛（调用方之前都已核过格式，抛 = 程序错）
export function buildTranscript(f: TranscriptFields): Buffer {
  const lines: [string, string][] = [
    ["role", f.role], ["path", f.path], ["kind", f.kind], ["hub_id", f.hubId], ["hub_key", f.hubKey],
    ["device_id", f.deviceId], ["pub", f.pub], ["cn", f.cn], ["sn", f.sn], ["aud", f.aud],
    ["result", f.result], ["enrolled", f.enrolled],
  ]
  let out = "mp-hub-auth/2\n"
  for (const [k, v] of lines) {
    if (v === "" || /[\r\n]/.test(v)) throw new Error(`transcript ${k} 空或含换行`)
    out += `${k}=${v}\n`
  }
  return Buffer.from(out, "utf8")
}

// ── auth 帧（§0.3，设备→hub）──

export type AuthFrame =
  | { kind: "key"; pub: string; sigDev: string }
  | { kind: "token"; pub: string; sigDev: string; proof: string; name: string; platform: string; reauth: boolean }
  | { kind: "code"; pub: string; sigDev: string; proof: string; name: string; platform: string }
export type AuthFrameResult = { ok: true; frame: AuthFrame } | { ok: false; reason: "bad_request" | "unsupported_alg" }

export const DEFAULT_DEVICE_NAME = "未命名设备"
/// 控制字符去掉、去首尾空白、截 40 字；空了用默认名
export function sanitizeDeviceName(s: string): string {
  return [...s.replace(/[\u0000-\u001f\u007f-\u009f]/g, "").trim()].slice(0, 40).join("") || DEFAULT_DEVICE_NAME
}
/// 改名（管理接口）：去首尾空白后 1–40 字、不含控制字符，否则 null（调用方回 bad_name）
export function validDeviceName(s: unknown): string | null {
  if (typeof s !== "string") return null
  const t = s.trim()
  const n = [...t].length
  return n >= 1 && n <= 40 && !/[\u0000-\u001f\u007f-\u009f]/.test(t) ? t : null
}
function sanitizePlatform(s: string): string {
  return s.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 20) || "unknown"
}

/// 字段类型逐个核（未知字段忽略）；不是 P-256 / SPKI 导不进 → unsupported_alg，其余不对 → bad_request
export function parseAuthFrame(raw: string): AuthFrameResult {
  const bad = { ok: false, reason: "bad_request" } as const
  let o: unknown
  try { o = JSON.parse(raw) } catch { return bad }
  if (!o || typeof o !== "object" || Array.isArray(o)) return bad
  const r = o as Record<string, unknown>
  if (r.type !== "auth" || r.v !== 2) return bad
  if (r.kind !== "key" && r.kind !== "token" && r.kind !== "code") return bad
  if (typeof r.alg !== "string") return bad
  if (r.alg !== "p256") return { ok: false, reason: "unsupported_alg" }
  if (!isB64u(r.pub, LEN.pub) || !isB64u(r.sig_dev, LEN.sig)) return bad
  if (!importP256Spki(r.pub)) return { ok: false, reason: "unsupported_alg" }
  if (r.kind === "key") return { ok: true, frame: { kind: "key", pub: r.pub, sigDev: r.sig_dev } }
  if (!isB64u(r.proof, LEN.mac)) return bad
  if (r.name !== undefined && typeof r.name !== "string") return bad
  if (r.platform !== undefined && typeof r.platform !== "string") return bad
  const name = sanitizeDeviceName(r.name ?? ""), platform = sanitizePlatform(r.platform ?? "")
  if (r.kind === "code") return { ok: true, frame: { kind: "code", pub: r.pub, sigDev: r.sig_dev, proof: r.proof, name, platform } }
  if (r.reauth !== undefined && typeof r.reauth !== "boolean") return bad
  return { ok: true, frame: { kind: "token", pub: r.pub, sigDev: r.sig_dev, proof: r.proof, name, platform, reauth: r.reauth === true } }
}

// ── 钥与签名（§0.1）──

export function sha256(buf: Uint8Array): Buffer {
  return createHash("sha256").update(buf).digest()
}
export function deviceIdOf(spkiDer: Uint8Array): string {
  return b64u(sha256(spkiDer)).slice(0, LEN.did)
}
export function hubKeyOf(spkiDer: Uint8Array): string {
  return b64u(sha256(spkiDer))
}

/// SPKI DER（b64u）→ 公钥；不是 EC P-256 一律 null（调用方回 unsupported_alg）
export function importP256Spki(pubB64u: string): KeyObject | null {
  try {
    const key = createPublicKey({ key: Buffer.from(pubB64u, "base64url"), format: "der", type: "spki" })
    if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") return null
    return key
  } catch { return null }
}

/// 签名 raw r‖s 64 字节（CryptoKit rawRepresentation）
export function verifyP256(key: KeyObject, msg: Uint8Array, sigB64u: string): boolean {
  if (!isB64u(sigB64u, LEN.sig)) return false
  try { return verify("sha256", msg, { key, dsaEncoding: "ieee-p1363" }, Buffer.from(sigB64u, "base64url")) } catch { return false }
}

export function signP256(priv: KeyObject, msg: Uint8Array): string {
  return b64u(sign("sha256", msg, { key: priv, dsaEncoding: "ieee-p1363" }))
}

export function hmacB64u(secret: string, msg: Uint8Array): string {
  return b64u(createHmac("sha256", Buffer.from(secret, "utf8")).update(msg).digest())
}

/// 两个 b64u 串常量时间比（长度不同直接 false，长度本身不是秘密）
export function timingSafeEqualB64u(a: string, b: string): boolean {
  const x = Buffer.from(a, "utf8"), y = Buffer.from(b, "utf8")
  return x.length === y.length && timingSafeEqual(x, y)
}

export function randomNonce(): string {
  return b64u(randomBytes(32))
}

// ── 秘密（§0.2 secret）──

/// kind=token：口令去首尾空白
export function tokenSecret(token: string): string {
  return token.trim()
}

/// Crockford base32（去掉 I L O U）
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
/// 手填码规范化（只作用于 mc；pc 原样）：去 `-` / 空白、转大写、I/L→1、O→0
export function normalizeManualCode(mc: string): string {
  return mc.replace(/[-\s]/g, "").toUpperCase().replace(/[IL]/g, "1").replace(/O/g, "0")
}
export function formatManualCode(mc: string): string {
  return `${mc.slice(0, 5)}-${mc.slice(5)}`
}

// ── hub 身份钥（§0.8 secrets/hub-key.pem）──

export interface HubKey { priv: KeyObject; pub: string; hk: string }
export type HubKeyResult = { ok: true; key: HubKey; created: boolean } | { ok: false; reason: string }

/// 没有 → 生成并写盘（写不进去 = 这次不开新协议，不用临时钥）；有但读不出 / 不是 P-256 → 不重建，不开新协议
export function loadOrCreateHubKey(path: string, write: (path: string, text: string) => void = writeFilePrivate): HubKeyResult {
  let pem: string | undefined
  try { pem = readFileSync(path, "utf-8") } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") return { ok: false, reason: `hub-key.pem 读不了（${(e as NodeJS.ErrnoException).code ?? "?"}）` }
  }
  if (pem === undefined) {
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
    try { write(path, privateKey.export({ format: "pem", type: "pkcs8" }).toString()) } catch (e) {
      return { ok: false, reason: `hub-key.pem 写不进去（${(e as Error).message}）` }
    }
    return { ok: true, key: hubKeyFrom(privateKey), created: true }
  }
  let priv: KeyObject
  try { priv = createPrivateKey({ key: pem, format: "pem" }) } catch {
    return { ok: false, reason: "hub-key.pem 坏了（解析不了）" }
  }
  if (priv.asymmetricKeyType !== "ec" || priv.asymmetricKeyDetails?.namedCurve !== "prime256v1") return { ok: false, reason: "hub-key.pem 不是 P-256" }
  return { ok: true, key: hubKeyFrom(priv), created: false }
}

function hubKeyFrom(priv: KeyObject): HubKey {
  const spki = createPublicKey(priv).export({ format: "der", type: "spki" })
  return { priv, pub: b64u(spki), hk: hubKeyOf(spki) }
}

// ── 设备表（§0.8 secrets/devices.json）──

export type AddedVia = "token" | "code" | "invite"
export interface DeviceRecord {
  id: string
  name: string
  platform: string
  alg: "p256"
  pub: string
  added_at: number
  added_via: AddedVia
  invited_by?: string
  last_used_at: number | null
  last_from: string | null
  revoked_at: number | null
  reauthorized_at: number | null
}

type JsonWriter = (path: string, value: unknown) => void
const TOUCH_PERSIST_MS = 60 * 60 * 1000

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v)
const numOrNull = (v: unknown): v is number | null => v === null || isNum(v)
const strOrNull = (v: unknown): v is string | null => v === null || typeof v === "string"

function parseDeviceRecord(v: unknown): DeviceRecord | null {
  if (!v || typeof v !== "object") return null
  const r = v as Record<string, unknown>
  if (!isDid(r.id) || !isB64u(r.pub, LEN.pub) || r.alg !== "p256") return null
  if (typeof r.name !== "string" || typeof r.platform !== "string") return null
  if (r.added_via !== "token" && r.added_via !== "code" && r.added_via !== "invite") return null
  if (r.invited_by !== undefined && typeof r.invited_by !== "string") return null
  if (!isNum(r.added_at) || !numOrNull(r.last_used_at) || !strOrNull(r.last_from) || !numOrNull(r.revoked_at) || !numOrNull(r.reauthorized_at)) return null
  const rec: DeviceRecord = {
    id: r.id, name: r.name, platform: r.platform, alg: "p256", pub: r.pub, added_at: r.added_at, added_via: r.added_via,
    last_used_at: r.last_used_at, last_from: r.last_from, revoked_at: r.revoked_at, reauthorized_at: r.reauthorized_at,
  }
  if (typeof r.invited_by === "string") rec.invited_by = r.invited_by
  return rec
}

/// 读出来是坏的 → 不当空表（`available=false`，原文件不动）。新增 / 吊销 / 撤销吊销 / 改名同步写盘，
/// 写失败抛错且内存回滚；只有 touch（last_used_at / last_from）节流，1 小时最多落一次盘。运行时只有 hub 写这个文件
export class DeviceStore {
  private devices = new Map<string, DeviceRecord>()
  private touchPersistedAt = new Map<string, number>()
  available = false
  unavailableReason: string | null = null

  constructor(readonly path: string, private readonly write: JsonWriter = saveJsonPrivate) {}

  load(): void {
    this.devices.clear()
    let raw: string
    try { raw = readFileSync(this.path, "utf-8") } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") { this.available = true; this.unavailableReason = null; return }
      return this.markBad(`devices.json 读不了（${(e as NodeJS.ErrnoException).code ?? "?"}）`)
    }
    let parsed: unknown
    try { parsed = JSON.parse(raw) } catch { return this.markBad("devices.json 坏了（不是 JSON）") }
    if (!parsed || typeof parsed !== "object" || (parsed as { v?: unknown }).v !== 1) return this.markBad("devices.json 版本 / 形状不对")
    const list = (parsed as { devices?: unknown }).devices
    if (!Array.isArray(list)) return this.markBad("devices.json 没有 devices 数组")
    for (const item of list) {
      const rec = parseDeviceRecord(item)
      if (!rec || this.devices.has(rec.id)) { this.devices.clear(); return this.markBad("devices.json 里有坏条目") }
      this.devices.set(rec.id, rec)
    }
    this.available = true
    this.unavailableReason = null
  }

  private markBad(reason: string): void {
    this.available = false
    this.unavailableReason = reason
  }

  get(did: string): DeviceRecord | undefined {
    return this.devices.get(did)
  }

  /// 没吊销的
  list(): DeviceRecord[] {
    return [...this.devices.values()].filter((d) => d.revoked_at === null)
  }

  /// 登记 / 更新：新设备建条；吊销过的（调用方已判过可以重新授权）撤销吊销、记 reauthorized_at；已有的不改名
  upsertEnroll(o: { id: string; pub: string; name: string; platform: string; via: AddedVia; invitedBy?: string; from: string; now: number }): { created: boolean; reauthorized: boolean } {
    this.requireAvailable()
    const prev = this.devices.get(o.id)
    if (prev) {
      const reauthorized = prev.revoked_at !== null
      const next: DeviceRecord = { ...prev, last_used_at: o.now, last_from: o.from }
      if (reauthorized) { next.revoked_at = null; next.reauthorized_at = o.now }
      this.commit(o.id, prev, next)
      this.touchPersistedAt.set(o.id, o.now)
      return { created: false, reauthorized }
    }
    const rec: DeviceRecord = {
      id: o.id, name: o.name, platform: o.platform, alg: "p256", pub: o.pub, added_at: o.now, added_via: o.via,
      last_used_at: o.now, last_from: o.from, revoked_at: null, reauthorized_at: null,
    }
    if (o.invitedBy) rec.invited_by = o.invitedBy
    this.commit(o.id, undefined, rec)
    this.touchPersistedAt.set(o.id, o.now)
    return { created: true, reauthorized: false }
  }

  /// 没这台 / 已经吊销 → false（不写盘）
  revoke(did: string, now: number): boolean {
    this.requireAvailable()
    const prev = this.devices.get(did)
    if (!prev || prev.revoked_at !== null) return false
    this.commit(did, prev, { ...prev, revoked_at: now })
    return true
  }

  rename(did: string, name: string): boolean {
    this.requireAvailable()
    const prev = this.devices.get(did)
    if (!prev || prev.revoked_at !== null) return false
    this.commit(did, prev, { ...prev, name })
    return true
  }

  /// 每次 kind=key 成功都调；内存总是最新，落盘 1 小时一次（写失败只吞掉，下次再试）
  touch(did: string, from: string, now: number): void {
    if (!this.available) return
    const prev = this.devices.get(did)
    if (!prev) return
    this.devices.set(did, { ...prev, last_used_at: now, last_from: from })
    const last = this.touchPersistedAt.get(did)
    if (last !== undefined && now - last < TOUCH_PERSIST_MS) return
    try {
      this.persist()
      this.touchPersistedAt.set(did, now)
    } catch (e) { console.warn(`[hub] devices.json touch 写失败（${(e as Error).message}），下次再试`) }
  }

  private requireAvailable(): void {
    if (!this.available) throw new Error(this.unavailableReason ?? "devices.json 不可用")
  }

  /// 先改内存再同步写盘；写失败回滚这一条并抛
  private commit(did: string, prev: DeviceRecord | undefined, next: DeviceRecord): void {
    this.devices.set(did, next)
    try { this.persist() } catch (e) {
      if (prev) this.devices.set(did, prev)
      else this.devices.delete(did)
      throw e
    }
  }

  private persist(): void {
    this.write(this.path, { v: 1, devices: [...this.devices.values()] })
  }
}

// ── 配对码（§0.6，只在内存）──

export interface PairCode {
  pc: string
  /// 规范形（10 位、无横线）
  mc: string
  expiresAt: number
  issuedBy: string | null
}

export const PAIR_CODE_TTL_MS = 10 * 60 * 1000
export const PAIR_CODE_MAX = 5

/// 同一条记录 pc / mc 任一个用掉整条作废；10 分钟过期；最多 5 条（多了挤掉最老的）；hub 重启作废
export class PairCodes {
  private codes: PairCode[] = []

  issue(o: { issuer?: string; now: number }): PairCode {
    this.prune(o.now)
    const bytes = randomBytes(10)
    let mc = ""
    for (const b of bytes) mc += CROCKFORD[b & 31]
    const rec: PairCode = { pc: randomNonce(), mc, expiresAt: o.now + PAIR_CODE_TTL_MS, issuedBy: o.issuer ?? null }
    this.codes.push(rec)
    while (this.codes.length > PAIR_CODE_MAX) this.codes.shift()
    return rec
  }

  /// 在没过期的码里逐条算 HMAC（pc 原样、mc 规范形）找命中；不销。secret = 设备实际用的那个（hub_proof 要用同一个）
  match(transcript: Uint8Array, proof: string, now: number): { rec: PairCode; secret: string } | null {
    this.prune(now)
    let hit: { rec: PairCode; secret: string } | null = null
    for (const rec of this.codes) {
      // 不短路：每条都算完，耗时不随命中位置变
      const a = timingSafeEqualB64u(hmacB64u(rec.pc, transcript), proof)
      const b = timingSafeEqualB64u(hmacB64u(rec.mc, transcript), proof)
      if ((a || b) && !hit) hit = { rec, secret: a ? rec.pc : rec.mc }
    }
    return hit
  }

  /// 落盘成功之后才调
  consume(rec: PairCode): void {
    this.codes = this.codes.filter((c) => c !== rec)
  }

  /// 吊销设备时撤它发的未用邀请
  revokeIssuedBy(did: string): number {
    const before = this.codes.length
    this.codes = this.codes.filter((c) => c.issuedBy !== did)
    return before - this.codes.length
  }

  get size(): number { return this.codes.length }

  private prune(now: number): void {
    this.codes = this.codes.filter((c) => c.expiresAt > now)
  }
}

/// /pair 和邀请码里的那三个字段（exp 是 unix 秒）
export function pairCodeFields(rec: PairCode): { pc: string; mc: string; exp: number } {
  return { pc: rec.pc, mc: formatManualCode(rec.mc), exp: Math.floor(rec.expiresAt / 1000) }
}

// ── 失败拖慢（§0.4，K1 返修 r1）──

/// 口令 / 配对码证明不对时，这条连接等这么久才回 auth_fail 并关。不设全局闸：全局计数会被匿名设备拿来锁死所有人的配对
/// （astra K1 审 B1）；10 位码 50 bit、口令 128 bit，在线猜每秒千次也要上万年，只需拖慢单条连接。正确证明永远立即验、立即过
export const BAD_PROOF_DELAY_MS = 1500

// ── 最后一次口令原文登录（§0.8 secrets/legacy-seen.json）──

export interface LegacySeenValue { at: number; from: string }

/// 内存总是最新，落盘 1 小时最多一次；写失败只打日志
export class LegacySeen {
  private value: LegacySeenValue | null = null
  private persistedAt: number | null = null

  constructor(readonly path: string, private readonly write: JsonWriter = saveJsonPrivate) {
    try {
      const o: unknown = JSON.parse(readFileSync(path, "utf-8"))
      if (o && typeof o === "object") {
        const r = o as { last_at?: unknown; last_from?: unknown }
        if (isNum(r.last_at) && typeof r.last_from === "string") this.value = { at: r.last_at, from: r.last_from }
      }
    } catch { /* 没有 / 坏了 = 没记录 */ }
  }

  get(): LegacySeenValue | null { return this.value }

  touch(from: string, now: number): void {
    this.value = { at: now, from }
    if (this.persistedAt !== null && now - this.persistedAt < TOUCH_PERSIST_MS) return
    try {
      this.write(this.path, { last_at: now, last_from: from })
      this.persistedAt = now
    } catch (e) { console.warn(`[hub] legacy-seen 写失败（${(e as Error).message}）`) }
  }
}

// ── hub 处理挑战 / auth（§0.3 / §0.4）──

/// `rate_limited`（§0.4 表里那行）K1 返修 r1 起 hub 不再发，app 侧枚举可以留着
export type AuthFailReason = "unknown_device" | "revoked" | "bad_sig" | "bad_proof" | "unavailable" | "expired" | "bad_request" | "unsupported_alg"
/// 一条连接的挑战上下文：全部是 hub 自己存的（验签只用这些，不用对方帧里回显的）
export interface ChallengeCtx { path: AuthPath; did: string; cn: string; aud: string; sn: string }
export interface AuthOkFrame { type: "auth_ok"; via: AuthKind; device_id: string; enrolled: boolean; hub_proof?: string }
export type AuthOutcome =
  | { ok: true; via: AuthKind; deviceId: string; enrolled: boolean; frame: AuthOkFrame }
  | { ok: false; reason: AuthFailReason }

export function authFailFrame(reason: AuthFailReason): string {
  return JSON.stringify({ type: "auth_fail", reason })
}

/// hub 身份钥可用时才建。设备表坏了照样建：key / code 回 unavailable，token 放行但 enrolled:false
export class DeviceAuth {
  readonly codes = new PairCodes()

  constructor(readonly hubId: string, readonly key: HubKey, readonly store: DeviceStore, private readonly hubToken: string | undefined) {}

  /// 生成 sn、签 sig_hub；返回要记在这条 socket 上的上下文和要发的帧
  newChallenge(q: { path: AuthPath; did: string; cn: string; aud: string }): { ctx: ChallengeCtx; frame: string } {
    const ctx: ChallengeCtx = { ...q, sn: randomNonce() }
    const sig = signP256(this.key.priv, this.transcript(ctx, "hub-challenge", "-", "-"))
    return { ctx, frame: JSON.stringify({ type: "auth_challenge", v: 2, hub_id: this.hubId, hub_key: this.key.hk, hub_pub: this.key.pub, sn: ctx.sn, sig_hub: sig }) }
  }

  /// §0.4 顺序：格式 → did == deviceIdOf(pub) → sig_dev → 按 kind。所有写盘都是同步的，返回时已落盘
  handle(ctx: ChallengeCtx, raw: string, o: { from: string; now: number }): AuthOutcome {
    const fail = (reason: AuthFailReason): AuthOutcome => ({ ok: false, reason })
    const parsed = parseAuthFrame(raw)
    if (!parsed.ok) return fail(parsed.reason)
    const f = parsed.frame
    // did 跟 pub 对不上 = 这台的配对坏了（按 bad_sig 让 app 进待配对，不是无限退避重连）
    if (deviceIdOf(Buffer.from(f.pub, "base64url")) !== ctx.did) return fail("bad_sig")
    const devKey = importP256Spki(f.pub)
    if (!devKey || !verifyP256(devKey, this.transcript(ctx, "dev", f.kind, f.pub), f.sigDev)) return fail("bad_sig")

    if (f.kind === "key") {
      if (!this.store.available) return fail("unavailable")
      const rec = this.store.get(ctx.did)
      if (!rec) return fail("unknown_device")
      if (rec.pub !== f.pub) return fail("bad_sig")
      if (rec.revoked_at !== null) return fail("revoked")
      this.store.touch(ctx.did, o.from, o.now)
      return { ok: true, via: "key", deviceId: ctx.did, enrolled: true, frame: { type: "auth_ok", via: "key", device_id: ctx.did, enrolled: true } }
    }

    const proofT = this.transcript(ctx, "secret-dev", f.kind, f.pub)
    const enroll = (via: AddedVia, invitedBy?: string) =>
      this.store.upsertEnroll({ id: ctx.did, pub: f.pub, name: f.name, platform: f.platform, via, invitedBy, from: o.from, now: o.now })

    if (f.kind === "token") {
      const secret = this.hubToken ? tokenSecret(this.hubToken) : ""
      if (!secret || !timingSafeEqualB64u(hmacB64u(secret, proofT), f.proof)) return fail("bad_proof")
      // 只有「加载时设备表就坏了」才不登记、放行 enrolled:false（§0.4）；表健康但这次写盘失败 = 安全变更失败（§0.8），回 unavailable（内存已回滚）
      let enrolled = false
      if (this.store.available) {
        const rec = this.store.get(ctx.did)
        // 被移除的设备不会被口令自动放回：只有用户这次手动填了口令（reauth）才撤销吊销
        if (rec && rec.revoked_at !== null && !f.reauth) return fail("revoked")
        try { enroll("token"); enrolled = true } catch (e) {
          console.warn(`[hub] auth token 登记写盘失败（${(e as Error).message}），回 unavailable`)
          return fail("unavailable")
        }
      }
      const hubProof = hmacB64u(secret, this.transcript(ctx, "secret-hub", "token", f.pub, "ok", enrolled ? "1" : "0"))
      return { ok: true, via: "token", deviceId: ctx.did, enrolled, frame: { type: "auth_ok", via: "token", device_id: ctx.did, enrolled, hub_proof: hubProof } }
    }

    const hit = this.codes.match(proofT, f.proof, o.now)
    if (!hit) return fail("bad_proof")
    if (!this.store.available) return fail("unavailable")
    // 吊销过的直接重新授权（新码 = 用户这次主动配）
    try { enroll(hit.rec.issuedBy ? "invite" : "code", hit.rec.issuedBy ?? undefined) } catch (e) {
      console.warn(`[hub] auth code 登记写盘失败（${(e as Error).message}），码不销`)
      return fail("unavailable")
    }
    this.codes.consume(hit.rec)
    const hubProof = hmacB64u(hit.secret, this.transcript(ctx, "secret-hub", "code", f.pub, "ok", "1"))
    return { ok: true, via: "code", deviceId: ctx.did, enrolled: true, frame: { type: "auth_ok", via: "code", device_id: ctx.did, enrolled: true, hub_proof: hubProof } }
  }

  private transcript(ctx: ChallengeCtx, role: AuthRole, kind: AuthKind | "-", pub: string, result: "ok" | "-" = "-", enrolled: "1" | "0" | "-" = "-"): Buffer {
    return buildTranscript({ role, path: ctx.path, kind, hubId: this.hubId, hubKey: this.key.hk, deviceId: ctx.did, pub, cn: ctx.cn, sn: ctx.sn, aud: ctx.aud, result, enrolled })
  }
}
