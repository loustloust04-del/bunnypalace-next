import { expect, test } from "bun:test"
import { TerminalSizeTracker } from "./terminal-size"

test("T51：单设备 = 它自己的尺寸（等于以前的行为）", () => {
  const t = new TerminalSizeTracker<string>()
  t.set("mp-cc-1", "phone", { cols: 52, rows: 30 })
  expect(t.effective("mp-cc-1")).toEqual({ cols: 52, rows: 30 })
  t.set("mp-cc-1", "phone", { cols: 52, rows: 18 })   // 键盘弹起
  expect(t.effective("mp-cc-1")).toEqual({ cols: 52, rows: 18 })
})

test("T51：两台同看取各自最小的列和行；一台离开恢复另一台", () => {
  const t = new TerminalSizeTracker<string>()
  t.set("s", "mac", { cols: 160, rows: 40 })
  t.set("s", "phone", { cols: 52, rows: 60 })
  expect(t.effective("s")).toEqual({ cols: 52, rows: 40 })
  t.remove("s", "phone")
  expect(t.has("s", "phone")).toBe(false)   // detach 之后迟到的 resize 不再认它
  expect(t.has("s", "mac")).toBe(true)
  expect(t.effective("s")).toEqual({ cols: 160, rows: 40 })
  t.remove("s", "mac")
  expect(t.effective("s")).toBeNull()
})

test("T51：退后台的设备不算；全退后台不动窗口（null）；回前台又算", () => {
  const t = new TerminalSizeTracker<string>()
  t.set("s", "mac", { cols: 160, rows: 40 })
  t.set("s", "phone", { cols: 52, rows: 30 })
  expect(t.setActive("phone", false)).toEqual(["s"])
  expect(t.effective("s")).toEqual({ cols: 160, rows: 40 })
  t.setActive("mac", false)
  expect(t.effective("s")).toBeNull()
  t.setActive("phone", true)
  expect(t.effective("s")).toEqual({ cols: 52, rows: 30 })
})

test("T51：连接断开从所有窗口拿掉，返回受影响的窗口", () => {
  const t = new TerminalSizeTracker<string>()
  t.set("a", "phone", { cols: 52, rows: 30 })
  t.set("b", "phone", { cols: 52, rows: 30 })
  t.set("b", "mac", { cols: 120, rows: 40 })
  expect(t.removeClient("phone").sort()).toEqual(["a", "b"])
  expect(t.effective("a")).toBeNull()
  expect(t.effective("b")).toEqual({ cols: 120, rows: 40 })
  expect(t.setActive("phone", true)).toEqual([])
})
