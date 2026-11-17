import { expect, test } from "bun:test"
import { MEMORY_PROBE_MS, MEMORY_PROBE_QUIET_MS, routeMemoryCommand, type MemoryCandidate, type ProbeAnswer } from "./memory-route"

type Sock = { name: string }
const sock = (name: string): Sock => ({ name })
const cand = (socket: Sock, platform: string, lastSeen: number): MemoryCandidate<Sock> => ({ socket, platform, lastSeen })

/// 每台设备对探问怎么答；记下问了谁、各等多久
function probing(answers: Map<Sock, ProbeAnswer>, asked: { name: string; ms: number }[] = []) {
  return async (socket: Sock, ms: number): Promise<ProbeAnswer> => {
    asked.push({ name: socket.name, ms })
    return answers.get(socket) ?? "silent"
  }
}

test("两台手机都连着、只有一台有这场对话；hub 刚重启什么都不记得：只发给有的那台", async () => {
  const hers = sock("她的手机"), testPhone = sock("测试机")
  // 测试机更晚有动静：只按「同平台、最近有动静」挑会挑错
  const candidates = [cand(hers, "ios", 100), cand(testPhone, "ios", 900)]
  const route = await routeMemoryCommand({
    chatId: "84", candidates, quiet: new Set<Sock>(),
    probe: probing(new Map<Sock, ProbeAnswer>([[hers, { mine: true }], [testPhone, { mine: false }]])),
  })
  expect("target" in route && route.target).toBe(hers)
})

test("一台连着但不回话（在后台 / 旧版），另一台有这场对话：照样答得上，下一轮不陪不回话的那台等满", async () => {
  const stuck = sock("不回话的"), hers = sock("她的手机")
  const candidates = [cand(stuck, "ios", 900), cand(hers, "ios", 100)]
  const asked: { name: string; ms: number }[] = []
  const answers = new Map<Sock, ProbeAnswer>([[hers, { mine: true }]])
  const first = await routeMemoryCommand({ chatId: "84", candidates, quiet: new Set<Sock>(), probe: probing(answers, asked) })
  expect("target" in first && first.target).toBe(hers)
  expect(first.answers.get(stuck)).toBe("silent")
  expect(asked.every((a) => a.ms === MEMORY_PROBE_MS)).toBe(true)

  asked.length = 0
  await routeMemoryCommand({ chatId: "别的对话", candidates, quiet: new Set([stuck]), probe: probing(answers, asked) })
  expect(asked.find((a) => a.name === "不回话的")?.ms).toBe(MEMORY_PROBE_QUIET_MS)
  expect(asked.find((a) => a.name === "她的手机")?.ms).toBe(MEMORY_PROBE_MS)
})

test("上一次答过「是我的」的那台还连着：直接用，不再问一圈；断了就重新问", async () => {
  const hers = sock("她的手机"), other = sock("测试机")
  const asked: { name: string; ms: number }[] = []
  const probe = probing(new Map<Sock, ProbeAnswer>([[hers, { mine: true }], [other, { mine: false }]]), asked)
  const known = await routeMemoryCommand({ chatId: "84", candidates: [cand(hers, "ios", 1), cand(other, "ios", 2)], knownOwner: hers, quiet: new Set<Sock>(), probe })
  expect("target" in known && known.target).toBe(hers)
  expect(asked).toEqual([])
  const gone = await routeMemoryCommand({ chatId: "84", candidates: [cand(other, "ios", 2)], knownOwner: hers, quiet: new Set<Sock>(), probe })
  expect("error" in gone).toBe(true)
  expect(asked.map((a) => a.name)).toEqual(["测试机"])
})

test("没有哪台有这场对话 / 都不回话 / 一台都没连着：各回一句明白话，不发给任何一台", async () => {
  const a = sock("a"), b = sock("b")
  const candidates = [cand(a, "ios", 1), cand(b, "macos", 2)]
  const none = await routeMemoryCommand({ chatId: "84", candidates, quiet: new Set<Sock>(),
    probe: probing(new Map<Sock, ProbeAnswer>([[a, { mine: false }], [b, { mine: false }]])) })
  expect("error" in none && none.error).toContain("没有哪一台有这场对话（chat_id=84）")
  const mixed = await routeMemoryCommand({ chatId: "84", candidates, quiet: new Set<Sock>(),
    probe: probing(new Map<Sock, ProbeAnswer>([[a, { mine: false }]])) })
  expect("error" in mixed && mixed.error).toContain("其中 1 台没回话")
  const silent = await routeMemoryCommand({ chatId: "84", candidates, quiet: new Set<Sock>(), probe: probing(new Map()) })
  expect("error" in silent && silent.error).toContain("2 台花园都没回话")
  const empty = await routeMemoryCommand({ chatId: "84", candidates: [], quiet: new Set<Sock>(), probe: probing(new Map()) })
  expect("error" in empty && empty.error).toContain("没连着 hub")
})

test("同一场对话两台都有：只挑一台（写不在两台上各做一遍）——最近发话的那种设备；不知道就先手机", async () => {
  const phone = sock("手机"), mac = sock("电脑")
  const candidates = [cand(phone, "ios", 1), cand(mac, "macos", 9)]
  const both = probing(new Map<Sock, ProbeAnswer>([[phone, { mine: true }], [mac, { mine: true }]]))
  const unknown = await routeMemoryCommand({ chatId: "84", candidates, quiet: new Set<Sock>(), probe: both })
  expect("target" in unknown && unknown.target).toBe(phone)
  const fromMac = await routeMemoryCommand({ chatId: "84", candidates, lastPlatform: "macos", quiet: new Set<Sock>(), probe: both })
  expect("target" in fromMac && fromMac.target).toBe(mac)
  // 最近是从手机发的，手机没连着：不改发电脑
  const phoneGone = await routeMemoryCommand({ chatId: "84", candidates: [cand(mac, "macos", 9)], lastPlatform: "ios", quiet: new Set<Sock>(),
    probe: probing(new Map<Sock, ProbeAnswer>([[mac, { mine: true }]])) })
  expect("error" in phoneGone && phoneGone.error).toContain("手机上的花园")
  expect("error" in phoneGone && phoneGone.error).toContain("没有改发别的设备")
})

test("还不认识探问的 app 版本（回了话但没说是不是它的）：没人明说是自己的时发给它一台，它自己会查", async () => {
  const older = sock("旧一点的版本"), other = sock("新版")
  const route = await routeMemoryCommand({ chatId: "84", candidates: [cand(older, "ios", 1), cand(other, "ios", 2)], quiet: new Set<Sock>(),
    probe: probing(new Map<Sock, ProbeAnswer>([[older, "unsupported"], [other, { mine: false }]])) })
  expect("target" in route && route.target).toBe(older)
})
