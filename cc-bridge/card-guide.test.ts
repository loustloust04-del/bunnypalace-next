import { describe, expect, test } from "bun:test"
import { CARD_GUIDE, CARD_GUIDE_INDEX, CARD_KINDS, cardGuideFor, cardGuideSection } from "./card-guide"

// 卡片说明用到再查（粟粟 10-03：这么长一坨不要全塞系统提示词）；与 app 的 CardGuideToolTests 同口径
describe("CARD_GUIDE_INDEX", () => {
  test("短，列全种类，说清先查", () => {
    expect(Buffer.byteLength(CARD_GUIDE_INDEX)).toBeLessThan(1000)
    for (const k of ["card-todo", "card-dice", "card-timer", "card-chart", "card-music", "card-word", "card-timeline", "card-ask", "```html"]) {
      expect(CARD_GUIDE_INDEX).toContain(k)
    }
    expect(CARD_GUIDE_INDEX).toContain("card_guide")
    expect(CARD_GUIDE_INDEX).toContain("回复正文")
    expect(CARD_GUIDE_INDEX).toContain("[附带事件]")
    expect(CARD_GUIDE_INDEX).not.toContain("builtin:slowtide")
  })
})

describe("cardGuideFor", () => {
  test("只给要的那种 + 公共规则", () => {
    const out = cardGuideFor(["music"])
    expect(out).toContain("card-music：")
    expect(out).toContain("builtin:slowtide")
    expect(out).not.toContain("card-chart：")
    for (const s of ["新卡片自己起一个短 id", "要修改已有卡片", "语言名要写全", "回复正文"]) expect(out).toContain(s)
  })
  test("提问卡的续行跟着走（CC 不发 secure）", () => {
    const out = cardGuideFor(["card-ask"])
    expect(out).toContain("card-ask：")
    expect(out).toContain("fields")
    expect(out).toContain("不要发 secure 提问卡")
  })
  test("html + 多种", () => {
    const out = cardGuideFor(["html", "todo"])
    expect(out).toContain("mp.todo.add")
    expect(out).toContain("card-todo：")
    expect(out).not.toContain("card-dice：")
  })
  test("不认识 / 空", () => {
    expect(cardGuideFor(["poster"])).toContain("没有这种卡：poster")
    const all = cardGuideFor([])
    for (const s of ["card-todo：", "card-music：", "card-ask：", "mp.todo.add"]) expect(all).toContain(s)
  })
  test("每种都有段", () => {
    for (const k of CARD_KINDS) expect(cardGuideSection(k).length).toBeGreaterThan(0)
  })
  test("全文没变（没有工具时的兜底）", () => {
    expect(CARD_GUIDE).toContain("card-todo：")
  })
})
