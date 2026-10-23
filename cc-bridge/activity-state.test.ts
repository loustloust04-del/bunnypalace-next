// golden 对拍（TS 半边）：encode* 的输出必须跟 fixtures 逐字节相同。fixture 只读。
import { expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { encodeAttributes, encodeContentState, validateContentState } from "./activity-state.ts"

const FIXTURES = join(import.meta.dir, "..", "fixtures", "live-activity")
const golden = (name: string) => readFileSync(join(FIXTURES, name), "utf8").trim()

test("golden · 满字段 ContentState 逐字节一致", () => {
  expect(encodeContentState({
    phase: "waiting",
    model: "Opus 5",
    ctx: 47,
    five_hour: 20,
    seven_day: 88,
    detail: "要不要把 M4 拆成两步？",
    since_unix: 1756472400,
    updated_unix: 1756472460,
    run_id: "r-1756472400-3",
  })).toBe(golden("content-state.golden.json"))
})

test("golden · 最小 ContentState 逐字节一致（undefined 不落键）", () => {
  expect(encodeContentState({ phase: "idle" })).toBe(golden("content-state-minimal.golden.json"))
})

test("golden · Attributes 逐字节一致", () => {
  expect(encodeAttributes({ session_name: "mp-cc" })).toBe(golden("attributes.golden.json"))
})

test("键按字母序输出，且不含任何空白", () => {
  const out = encodeContentState({ phase: "done", run_id: "r1", ctx: 1 })
  expect(out).toBe('{"ctx":1,"phase":"done","run_id":"r1"}')
  expect(out).not.toMatch(/\s/)
})

test("显式传 undefined 与不传等价", () => {
  expect(encodeContentState({ phase: "idle", model: undefined, detail: undefined }))
    .toBe(encodeContentState({ phase: "idle" }))
})

test("validateContentState · 合法 state 放行", () => {
  expect(validateContentState({ phase: "working", ctx: 47, detail: "x" })).toBeNull()
})

test("validateContentState · phase 不在枚举里 → bad_phase", () => {
  expect(validateContentState({ phase: "busy" })).toBe("bad_phase")
  expect(validateContentState({})).toBe("bad_phase")
  expect(validateContentState({ phase: 1 })).toBe("bad_phase")
})

test("validateContentState · 合同外的键 → unknown_keys（拼错一个字母不能静默放行）", () => {
  expect(validateContentState({ phase: "idle", fivehour: 20 })).toBe("unknown_keys:fivehour")
  expect(validateContentState({ phase: "idle", Detail: "x", zzz: 1 })).toBe("unknown_keys:Detail,zzz")
})
