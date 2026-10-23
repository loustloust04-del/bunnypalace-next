// 测试专用：假 http2 传输 + 现场生成的 P-256 测试密钥。
// 被 apns-alert.test.ts / apns-live-activity.test.ts 共用，不进生产路径。
import { EventEmitter } from "node:events"
import type http2 from "node:http2"
import { __setAPNsTestHooks } from "./apns.ts"

export const TEST_PEM = await (async () => {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", kp.privateKey))
  return `-----BEGIN PRIVATE KEY-----\n${pkcs8.toString("base64").replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`
})()

export class FakeStream extends EventEmitter {
  payloads: string[] = []
  onEnd: (s: FakeStream) => void = () => {}
  write(d: string): boolean { this.payloads.push(d); return true }
  end(): void { queueMicrotask(() => this.onEnd(this)) }
}

export class FakeClient extends EventEmitter {
  headers: Record<string, string> | null = null
  closeCount = 0
  stream = new FakeStream()
  request(h: Record<string, string>): FakeStream { this.headers = h; return this.stream }
  close(): void { this.closeCount++ }
}

export interface Transport {
  clients: FakeClient[]
  connects: Array<{ authority: string; options: { family?: number } }>
  hooks: Parameters<typeof __setAPNsTestHooks>[0]
}

/// drive 在 connect 那一刻拿到 client，用来编排「响应怎么回」。
export function installTransport(drive: (c: FakeClient) => void): Transport {
  const t: Transport = { clients: [], connects: [], hooks: {} }
  t.hooks = {
    enabled: true,
    readKeyPem: () => TEST_PEM,
    connect: ((authority: string, options: { family?: number }) => {
      const c = new FakeClient()
      t.clients.push(c)
      t.connects.push({ authority, options })
      drive(c)
      return c
    }) as unknown as typeof http2.connect,
  }
  __setAPNsTestHooks(t.hooks)
  return t
}

/// 最常用的编排：req.end() 后回一个 status + body。
export const respondWith = (status: number, body = "") => (c: FakeClient) => {
  c.stream.onEnd = (s) => {
    s.emit("response", { ":status": status })
    if (body) s.emit("data", Buffer.from(body))
    s.emit("end")
  }
}
