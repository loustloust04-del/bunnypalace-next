import { test, expect } from "bun:test"
import { correctChatId } from "./chat-id-guard.ts"

const REAL = "3E7994B7-B28A-4420-AB85-D4DE37B99F6B"
const TYPO = "3E7194B7-B28A-4420-AB85-D4DE37B99F6B"   // 09-17 小克实抄错的那一位
const OTHER = "A192D201-1111-4222-8333-444455556666"

test("已知 id 原样放行", () => {
  expect(correctChatId(REAL, [REAL, OTHER])).toEqual({ id: REAL, corrected: false })
})

test("错一位、唯一近似 → 纠正", () => {
  expect(correctChatId(TYPO, [REAL, OTHER])).toEqual({ id: REAL, corrected: true })
})

test("session 最近对话优先，即使别的候选也近似", () => {
  const twin = "3E7994B7-B28A-4420-AB85-D4DE37B99F6C"
  expect(correctChatId(TYPO, [twin, REAL], REAL)).toEqual({ id: REAL, corrected: true })
})

test("多个近似且没有 preferred → 不猜，原样", () => {
  const twin = "3E7994B7-B28A-4420-AB85-D4DE37B99F6C"
  expect(correctChatId(TYPO, [twin, REAL])).toEqual({ id: TYPO, corrected: false })
})

test("没有近似（差太多 / 长度不同 / 缓冲为空）→ 原样", () => {
  expect(correctChatId(TYPO, [OTHER])).toEqual({ id: TYPO, corrected: false })
  expect(correctChatId("3E7994B7", [REAL])).toEqual({ id: "3E7994B7", corrected: false })
  expect(correctChatId(TYPO, [])).toEqual({ id: TYPO, corrected: false })
})

test("差两位仍纠正，差三位不纠正", () => {
  const two = "3E7194B7-B28A-4420-AB85-D4DE37B99F6C"
  const three = "3E7194B7-B28A-4420-AB85-D4DE37B99F6D".replace("4420", "4421")
  expect(correctChatId(two, [REAL])).toEqual({ id: REAL, corrected: true })
  expect(correctChatId(three, [REAL])).toEqual({ id: three, corrected: false })
})

test("known 里的空串不参与匹配", () => {
  expect(correctChatId(TYPO, ["", REAL])).toEqual({ id: REAL, corrected: true })
})
