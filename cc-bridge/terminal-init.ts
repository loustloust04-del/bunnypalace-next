export function parseMouseAnyFlag(value: string): boolean {
  return value.trim() === "1"
}

export function buildTerminalInitPayload(
  sessionName: string,
  snapshot: string,
  mouseAny: boolean,
  timing?: { ms: number; steps: string },
): string {
  return JSON.stringify({
    type: "terminal_init",
    session_name: sessionName,
    bytes: Buffer.from(snapshot, "utf8").toString("base64"),
    mouse_any: mouseAny,
    // 能力位：这个 hub 认 terminal_paste（#053）。老 hub 没这字段 → 客户端走老路兜底
    paste: true,
    // 终端出字账本：hub 处理这次 attach 花的时间 + 分步（重发快照时没有）
    ...(timing ? { hub_ms: timing.ms, hub_steps: timing.steps } : {}),
  })
}
