import { describe, expect, test } from "bun:test"
import { effortArg, effortChange, normalizeEffort } from "./effort"
import { buildStreamArgs } from "./stream-runner"

describe("effort（思考强度跟着模型走）", () => {
  test("只认引擎自己的档位，「默认」和怪值不动会话", () => {
    expect(normalizeEffort("claude", "XHigh")).toBe("xhigh")
    expect(normalizeEffort("claude", "max")).toBe("max")
    expect(normalizeEffort("codex", "max")).toBeUndefined()
    expect(normalizeEffort("claude", "auto")).toBeUndefined()
    expect(normalizeEffort("claude", "high; rm -rf /")).toBeUndefined()
    expect(normalizeEffort("shell", "high")).toBeUndefined()
    expect(normalizeEffort("claude", 3)).toBeUndefined()
  })

  test("启动参数", () => {
    expect(effortArg("claude", "high")).toBe(" --effort high")
    expect(effortArg("codex", "xhigh")).toBe(` -c model_reasoning_effort="xhigh"`)
    expect(effortArg("claude", undefined)).toBe("")
    expect(effortArg("codex", "max")).toBe("")
  })

  test("跑着的会话：claude 发 /effort，codex 重启，一样就不动", () => {
    expect(effortChange("claude", "high", "max")).toEqual({ command: "/effort max", respawn: false })
    expect(effortChange("claude", undefined, "low")).toEqual({ command: "/effort low", respawn: false })
    expect(effortChange("claude", "max", "max")).toEqual({ respawn: false })
    expect(effortChange("codex", "medium", "high")).toEqual({ respawn: true })
    expect(effortChange("codex", "high", "high")).toEqual({ respawn: false })
    expect(effortChange("claude", "high", "auto")).toEqual({ respawn: false })
  })

  test("stream 会话启动带 --effort", () => {
    const base = { cwd: "/tmp", model: "m", mcpConfig: "c", sessionId: "s" }
    expect(buildStreamArgs({ ...base, effort: "high" }).slice(-2)).toEqual(["--effort", "high"])
    expect(buildStreamArgs(base)).not.toContain("--effort")
  })
})
