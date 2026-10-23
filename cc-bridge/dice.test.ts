import { describe, expect, test } from "bun:test"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import { blockText, parseDice, rollDice } from "./dice"
import { CARD_GUIDE, CARD_GUIDE_INDEX } from "./card-guide"

describe("parseDice", () => {
  test("合法", () => {
    expect(parseDice("2d6+1")).toEqual({ count: 2, sides: 6, modifier: 1 })
    expect(parseDice(" D20 ")).toEqual({ count: 1, sides: 20, modifier: 0 })
    expect(parseDice("3d8 - 2")).toEqual({ count: 3, sides: 8, modifier: -2 })
  })
  test("非法", () => {
    for (const bad of ["0d6", "21d6", "1d1", "1d1001", "2d6+", "d", "abc", "1d2+1001"]) expect(parseDice(bad)).toBeNull()
  })
})

describe("blockText", () => {
  test("与 app 同一条固定样例逐字相等（ChatCardTests.testDiceCardBlockMatchesBridgeFixture）", () => {
    const card = { id: "d-0001", title: "攻\"击\"/中文", dice: "2d6+1", result: { rolls: [3, 5], total: 9 } }
    expect(blockText(card)).toBe("```card-dice\n{\"dice\":\"2d6+1\",\"id\":\"d-0001\",\"result\":{\"rolls\":[3,5],\"total\":9},\"title\":\"攻\\\"击\\\"/中文\"}\n```")
  })
  test("内容里有反引号时围栏加长", () => {
    expect(blockText({ id: "d-1", title: "```", options: ["a", "b"] }).startsWith("````card-dice\n")).toBe(true)
  })
})

describe("rollDice", () => {
  const seq = (values: number[]) => { let i = 0; return (n: number) => values[i++ % values.length] % n }
  // 结果 = 卡片块原文 + 空行 + 一行摘要（与 app 同格式；不把卡包进 JSON 字符串，免得模型抄出转义）
  const split = (text: string) => {
    const lines = text.split("\n")
    return { card: JSON.parse(lines[1]), block: lines.slice(0, 3).join("\n"), summary: lines[lines.length - 1], lines }
  }

  test("数字骰：卡片块原文在最前，id 为 d- 加 8 位十六进制", () => {
    const r = rollDice({ dice: "2d6+1", title: "攻击" }, seq([2, 4]))
    expect(r.ok).toBe(true)
    if (!r.ok) return
    const { card, block, summary, lines } = split(r.text)
    expect(lines).toHaveLength(5)
    expect(lines[3]).toBe("")
    expect(block).toBe(blockText(card))
    expect(card.id).toMatch(/^d-[0-9a-f]{8}$/)
    expect(card.title).toBe("攻击")
    expect(card.dice).toBe("2d6+1")
    expect(card.result).toEqual({ rolls: [3, 5], total: 9 })
    expect(summary).toBe("2d6+1 → 3 + 5 + 1 = 9")
  })

  test("抽签：去首尾空白含换行，空项丢掉", () => {
    const r = rollDice({ options: ["火锅", "\n寿司 \n", "  ", "面"], title: "\n午饭\n" }, seq([1]))
    expect(r.ok).toBe(true)
    if (!r.ok) return
    const { card, summary } = split(r.text)
    expect(card.result).toEqual({ pick: 1 })
    expect(card.options).toEqual(["火锅", "寿司", "面"])
    expect(card.title).toBe("午饭")
    expect(summary).toBe("抽中：寿司")
  })

  test("替对方掷已有的卡：给 id 就沿用", () => {
    const r = rollDice({ id: " d-1a2b ", dice: "d20" }, seq([0]))
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(split(r.text).card.id).toBe("d-1a2b")
    for (const bad of [{ id: "t-1a2b", dice: "d6" }, { id: 1, dice: "d6" }, { id: "d-a b", dice: "d6" }, { id: "d-", dice: "d6" }]) {
      expect(rollDice(bad).ok).toBe(false)
    }
  })

  test("空白 dice + 合法 options 算只给了 options", () => {
    expect(rollDice({ dice: "  \n", options: ["a", "b"] }, seq([0])).ok).toBe(true)
  })

  test("非法输入（含类型不符，与 app 同一组反例）", () => {
    const bad: unknown[] = [
      {}, { dice: "3d7000" }, { options: ["只有一个"] }, { dice: "1d6", options: ["a", "b"] },
      { dice: 1 }, { title: 1, dice: "1d6" }, { options: [1, 2] }, { options: ["a", 2] },
      { options: "a,b" }, { dice: "  ", options: [] }, { dice: null },
      null, "not-json", [1],
    ]
    for (const args of bad) expect(rollDice(args as any).ok).toBe(false)
  })
})

describe("CARD_GUIDE", () => {
  test("教用工具、不教自己编结果；卡片块放回复正文；抄解码后的值", () => {
    expect(CARD_GUIDE).toContain("roll_dice")
    expect(CARD_GUIDE).toContain("card-todo")
    expect(CARD_GUIDE).toContain("card-timer")
    expect(CARD_GUIDE).toContain("回复正文")
    expect(CARD_GUIDE).not.toContain("解码")
    expect(CARD_GUIDE).toContain("id 传给 roll_dice")
    expect(CARD_GUIDE).not.toContain("你替对方掷时直接带结果")
    for (const s of ["card-chart", "card-music", "图表 g-", "音乐 m-", "直链", "builtin:slowtide", "不要用内置曲代替", "语言名要写全"]) expect(CARD_GUIDE).toContain(s)
  })
})

describe("mcp-server roll_dice（完整 CallTool 分支）", () => {
  test("合法调用返回卡片；非法调用返回 isError 而不是抛协议错误；instructions 带卡片目录、card_guide 按种类给写法", async () => {
    // hub 指到没人听的随机高位端口：roll_dice 不经 hub，绝不连生产 7890
    const port = 29000 + Math.floor(Math.random() * 1000)
    const transport = new StdioClientTransport({
      command: "bun",
      args: ["run", "mcp-server.ts"],
      cwd: import.meta.dir,
      env: { ...process.env, MP_CC_HUB_URL: `ws://127.0.0.1:${port}/mcp`, MP_CC_HUB_TOKEN: "test-token" } as Record<string, string>,
    })
    const client = new Client({ name: "dice-test", version: "0" })
    await client.connect(transport)
    try {
      // 10-03 起 instructions 只放目录，完整写法走 card_guide 工具
      expect(client.getInstructions()).toBe(CARD_GUIDE_INDEX)
      const tools = await client.listTools()
      expect(tools.tools.some(t => t.name === "roll_dice")).toBe(true)
      expect(tools.tools.some(t => t.name === "card_guide")).toBe(true)
      const guide = await client.callTool({ name: "card_guide", arguments: { kinds: ["music"] } }) as any
      expect(guide.isError).toBeFalsy()
      expect(guide.content[0].text).toContain("builtin:slowtide")
      expect(guide.content[0].text).not.toContain("card-chart：")
      const anyway = await client.callTool({ name: "card_guide", arguments: {} }) as any
      expect(anyway.content[0].text).toContain("card-todo：")

      const ok = await client.callTool({ name: "roll_dice", arguments: { dice: "d20" } }) as any
      expect(ok.isError).toBeFalsy()
      expect(ok.content[0].text.startsWith("```card-dice\n")).toBe(true)
      expect(JSON.parse(ok.content[0].text.split("\n")[1]).result.rolls).toHaveLength(1)

      const bad = await client.callTool({ name: "roll_dice", arguments: { dice: "1d6", options: ["a", "b"] } }) as any
      expect(bad.isError).toBe(true)
      expect(bad.content[0].text).toContain("只能给一个")
    } finally {
      await client.close()
    }
  }, 20_000)
})
