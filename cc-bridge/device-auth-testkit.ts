// 测试用「设备端」：按 §0.2 / §0.3 现生成测试钥、验挑战、拼 auth、核 hub_proof。只给 *.test.ts 用，hub 不 import
import { generateKeyPairSync, type KeyObject } from "node:crypto"
import { b64u, buildTranscript, deviceIdOf, hmacB64u, hubKeyOf, importP256Spki, randomNonce, signP256, verifyP256, type AuthKind, type AuthPath, type TranscriptFields } from "./device-auth.ts"

export interface TestDevice { priv: KeyObject; pub: string; did: string }
export interface Challenge { type: "auth_challenge"; v: number; hub_id: string; hub_key: string; hub_pub: string; sn: string; sig_hub: string }
export interface Conn { path: AuthPath; cn: string; aud: string }
export type Cred = { kind: "key" } | { kind: "token"; secret: string; reauth?: boolean } | { kind: "code"; secret: string }

export function makeTestDevice(): TestDevice {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  const spki = publicKey.export({ format: "der", type: "spki" })
  return { priv: privateKey, pub: b64u(spki), did: deviceIdOf(spki) }
}

export function newConn(path: AuthPath, aud: string): Conn {
  return { path, cn: randomNonce(), aud }
}

export function v2QueryString(dev: TestDevice, c: Conn, bundle: string): string {
  return `v=2&did=${dev.did}&cn=${c.cn}&aud=${encodeURIComponent(c.aud)}&bundle=${encodeURIComponent(bundle)}`
}

function fields(dev: TestDevice, ch: Challenge, c: Conn, role: TranscriptFields["role"], kind: AuthKind | "-", pub: string, result: "ok" | "-" = "-", enrolled: "1" | "0" | "-" = "-"): TranscriptFields {
  return { role, path: c.path, kind, hubId: ch.hub_id, hubKey: ch.hub_key, deviceId: dev.did, pub, cn: c.cn, sn: ch.sn, aud: c.aud, result, enrolled }
}

/// 设备侧核挑战：hk == hubKeyOf(hub_pub)、sig_hub 验得过（用自己这边的 did / cn / aud / path）
export function challengeValid(dev: TestDevice, ch: Challenge, c: Conn): boolean {
  const key = importP256Spki(ch.hub_pub)
  if (!key || hubKeyOf(Buffer.from(ch.hub_pub, "base64url")) !== ch.hub_key) return false
  return verifyP256(key, buildTranscript(fields(dev, ch, c, "hub-challenge", "-", "-")), ch.sig_hub)
}

export function authFrame(dev: TestDevice, ch: Challenge, c: Conn, cred: Cred, extra: Record<string, unknown> = {}): string {
  const sig = signP256(dev.priv, buildTranscript(fields(dev, ch, c, "dev", cred.kind, dev.pub)))
  const frame: Record<string, unknown> = { type: "auth", v: 2, kind: cred.kind, alg: "p256", pub: dev.pub, sig_dev: sig }
  if (cred.kind !== "key") {
    frame.proof = hmacB64u(cred.secret, buildTranscript(fields(dev, ch, c, "secret-dev", cred.kind, dev.pub)))
    frame.name = "测试设备"
    frame.platform = "ios"
  }
  if (cred.kind === "token" && cred.reauth) frame.reauth = true
  return JSON.stringify({ ...frame, ...extra })
}

export function expectedHubProof(dev: TestDevice, ch: Challenge, c: Conn, kind: "token" | "code", secret: string, enrolled: boolean): string {
  return hmacB64u(secret, buildTranscript(fields(dev, ch, c, "secret-hub", kind, dev.pub, "ok", enrolled ? "1" : "0")))
}
