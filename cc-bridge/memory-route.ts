// CC 动花园的记忆（/memory/cmd）发给哪一台 app。
//
// 记忆存在各台设备自己的花园里，请求必须到**有这场对话（chat_id）的那一台**，而且只到一台（写不能在两台上各做一遍）。
// 只按平台挑不行：两台手机都连着（她的手机 + 测试机）时会随手挑到没有这场对话、或者在后台不回话的那台，对方白等到超时（11-14 真连第一次就撞上）。
//
// 做法：先问一圈「这场对话是不是你的」（`memory_cmd` 帧带 `probe: true`，不带工具，app 立刻回 `mine: true / false`，不执行任何东西），
// 再把真正的命令只发给答「是我的」那一台。hub 重启后什么都不记得也照样认得出来；不回话的（在后台 / 版本太旧）只等一小会儿，不拖住别的设备。
// 这个文件不碰 socket，只定规矩；hub.ts 负责发帧。

export type ProbeAnswer =
  | { mine: boolean }
  /// 回了话但没说是不是它的：还不认识探问的 app 版本（它自己会查对话在不在，找不到立刻回错）
  | "unsupported"
  /// 时限内没回话：在后台、挂起了，或者版本旧到不认识 memory_cmd
  | "silent"

export interface MemoryCandidate<S> {
  socket: S
  /// client_info 报的平台（"ios" / "macos"）
  platform: string
  lastSeen: number
}

const PLATFORM_LABEL: Record<string, string> = { ios: "手机", macos: "电脑" }

/// 探问等多久（毫秒）。上一轮没回话的只等短的那个：它多半还在后台，别每次都陪它等满
export const MEMORY_PROBE_MS = 3000
export const MEMORY_PROBE_QUIET_MS = 400

export interface MemoryRouteInput<S> {
  chatId: string | undefined
  /// 还连着、报过平台的 app
  candidates: MemoryCandidate<S>[]
  /// 这场对话最近一次是从哪种设备发来的（hub 重启后没有）
  lastPlatform?: string
  /// 上一次答「是我的」的那台（还连着就直接用，不再问一圈）
  knownOwner?: S
  /// 上一轮探问没回话的
  quiet: Set<S>
  probe: (socket: S, timeoutMs: number) => Promise<ProbeAnswer>
}

export type MemoryRoute<S> = { target: S; answers: Map<S, ProbeAnswer> } | { error: string; answers: Map<S, ProbeAnswer> }

export async function routeMemoryCommand<S>(input: MemoryRouteInput<S>): Promise<MemoryRoute<S>> {
  const { candidates, lastPlatform, knownOwner, quiet } = input
  const answers = new Map<S, ProbeAnswer>()
  if (candidates.length === 0) {
    return { error: "花园 app 没连着 hub（app 没开着或在后台），这次没做成；等对方把 app 开到前台再试", answers }
  }
  const known = knownOwner === undefined ? undefined : candidates.find((c) => c.socket === knownOwner)
  if (known && (!lastPlatform || known.platform === lastPlatform)) return { target: known.socket, answers }

  await Promise.all(candidates.map(async (c) => {
    answers.set(c.socket, await input.probe(c.socket, quiet.has(c.socket) ? MEMORY_PROBE_QUIET_MS : MEMORY_PROBE_MS))
  }))
  const answered = (c: MemoryCandidate<S>) => answers.get(c.socket)
  const newest = (list: MemoryCandidate<S>[]) =>
    list.reduce<MemoryCandidate<S> | null>((best, c) => !best || c.lastSeen > best.lastSeen ? c : best, null)
  /// 同一场对话两台都有时只挑一台：最近发话的那种设备；不知道就先手机；再取最近有动静的
  const pickOne = (list: MemoryCandidate<S>[]): MemoryCandidate<S> | null => {
    if (lastPlatform) return newest(list.filter((c) => c.platform === lastPlatform))
    return newest(list.filter((c) => c.platform === "ios")) ?? newest(list)
  }

  const owners = candidates.filter((c) => { const a = answered(c); return typeof a === "object" && a.mine })
  const owner = pickOne(owners)
  if (owner) return { target: owner.socket, answers }
  // 没人明说是它的：还不认识探问的那几台里挑一台（它自己会查，找不到立刻回错）
  const older = pickOne(candidates.filter((c) => answered(c) === "unsupported"))
  if (older) return { target: older.socket, answers }

  const silent = candidates.filter((c) => answered(c) === "silent").length
  const chat = input.chatId ? `（chat_id=${input.chatId}）` : ""
  if (lastPlatform && !candidates.some((c) => c.platform === lastPlatform)) {
    const where = PLATFORM_LABEL[lastPlatform] ?? lastPlatform
    return { error: `这场对话是从${where}上的花园发来的，它现在没连着 hub（app 没开着或在后台）。没有改发别的设备，这次没做成；等对方把 app 开到前台再试`, answers }
  }
  if (silent === candidates.length) {
    return { error: `连着 hub 的 ${silent} 台花园都没回话（app 在后台，或版本还不认识这个功能）。这次没做成；等对方把 app 开到前台再试`, answers }
  }
  const parts = [`连着 hub 的 ${candidates.length} 台花园里没有哪一台有这场对话${chat}`]
  if (silent > 0) parts.push(`其中 ${silent} 台没回话（app 在后台，或版本还不认识这个功能）`)
  if (owners.length > 0 && lastPlatform) parts.push(`有这场对话的那台不是它最近发话的${PLATFORM_LABEL[lastPlatform] ?? lastPlatform}，没有改发`)
  return { error: parts.join("；") + "。这次没做成；核对 chat_id，或等对方把那台设备上的 app 开到前台再试", answers }
}
