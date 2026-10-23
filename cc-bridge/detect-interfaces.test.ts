import { test, expect } from "bun:test"
import { detectInterfaces } from "./hub.ts"

// 构造假 networkInterfaces() 返回，只填 detectInterfaces 用到的字段。
function iface(address: string, family = "IPv4", internal = false): any {
  return { address, family, internal, netmask: "", mac: "", cidr: null }
}

test("Tailscale + LAN 同时存在，正确分类", () => {
  const d = detectInterfaces({
    lo0: [iface("127.0.0.1"), iface("::1", "IPv6")],
    en0: [iface("192.168.31.20")],
    utun3: [iface("100.110.76.9")],
  })
  expect(d.loopback).toBe("127.0.0.1")
  expect(d.lan).toBe("192.168.31.20")
  expect(d.tailscale).toBe("100.110.76.9")
})

test("只有 LAN（Tailscale 没跑）→ tailscale undefined ← 这正是时序 bug 现场", () => {
  // hub 启动时 Tailscale 还没连上，detected.tailscale 就是 undefined。
  // 旧代码这个值被冻结成常量，Tailscale 后启动也永远绑不上。新代码靠定期重检自愈。
  const d = detectInterfaces({ en0: [iface("192.168.31.20")] })
  expect(d.lan).toBe("192.168.31.20")
  expect(d.tailscale).toBeUndefined()
})

test("只有 Tailscale（出国公共 WiFi，无可用私网段）", () => {
  const d = detectInterfaces({ utun3: [iface("100.116.36.98")] })
  expect(d.tailscale).toBe("100.116.36.98")
  expect(d.lan).toBeUndefined()
})

test("跳过 IPv6 和 internal 接口", () => {
  const d = detectInterfaces({
    lo0: [iface("127.0.0.1", "IPv4", true)],            // internal，不当 LAN
    en0: [iface("fe80::1", "IPv6"), iface("192.168.1.5")],
  })
  expect(d.lan).toBe("192.168.1.5")
})

test("100.x 在 CGNAT 段外（公网）不当 Tailscale", () => {
  // 只有 100.64-127 是 Tailscale CGNAT；100.200.x 是公网
  expect(detectInterfaces({ en0: [iface("100.200.5.5")] }).tailscale).toBeUndefined()
  expect(detectInterfaces({ en0: [iface("100.63.0.1")] }).tailscale).toBeUndefined()
  expect(detectInterfaces({ en0: [iface("100.128.0.1")] }).tailscale).toBeUndefined()
})

test("10.x / 172.16-31 也算 LAN，172.15 / 172.32 不算", () => {
  expect(detectInterfaces({ en0: [iface("10.0.0.5")] }).lan).toBe("10.0.0.5")
  expect(detectInterfaces({ en0: [iface("172.20.1.1")] }).lan).toBe("172.20.1.1")
  expect(detectInterfaces({ en0: [iface("172.15.0.1")] }).lan).toBeUndefined()
  expect(detectInterfaces({ en0: [iface("172.32.0.1")] }).lan).toBeUndefined()
})

test("多个同类接口取第一个（??= 语义）", () => {
  const d = detectInterfaces({
    en0: [iface("192.168.1.5")],
    en1: [iface("192.168.2.7")],
  })
  expect(d.lan).toBe("192.168.1.5")
})
