import { expect, test } from "bun:test"
import { buildTerminalInitPayload, parseMouseAnyFlag } from "./terminal-init"

test("terminal_init 带 mouse_any，只有 tmux flag 1 为 true", () => {
  const frame = JSON.parse(buildTerminalInitPayload("mp-win-abc123", "hello", parseMouseAnyFlag("1\n")))
  expect(frame).toEqual({
    type: "terminal_init",
    session_name: "mp-win-abc123",
    bytes: Buffer.from("hello", "utf8").toString("base64"),
    mouse_any: true,
    paste: true,
  })
  expect(parseMouseAnyFlag("0")).toBe(false)
  expect(parseMouseAnyFlag("")).toBe(false)
})
