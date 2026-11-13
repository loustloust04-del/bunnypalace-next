import { describe, expect, test } from "bun:test"
import { stripReactBlocks } from "./react-blocks"

// 规则和 app 端 MemoryPalace/Services/ChatReactionIntent.swift 的 strip 一致（complete + cutClose）
describe("stripReactBlocks", () => {
  test("整块剥掉，块留下的空行压掉", () => {
    expect(stripReactBlocks("晚安\n\n```react\n❤️\n```\n")).toBe("晚安")
    expect(stripReactBlocks("第一段\n```react\n❤️\n```\n第二段")).toBe("第一段\n第二段")
  })

  test("收尾 fence 被截断（0–2 个反引号）也剥", () => {
    expect(stripReactBlocks("晚安\n```react\n❤️\n``")).toBe("晚安")
    expect(stripReactBlocks("晚安\n```react\n👀 3F2A\n`")).toBe("晚安")
    expect(stripReactBlocks("晚安\n```react\n❤️\n")).toBe("晚安")
  })

  test("多行 JSX 的 ```react 不动", () => {
    const code = '```react\nimport React from "react"\nexport default () => <div />\n```'
    expect(stripReactBlocks(`看这个\n${code}\n好`)).toBe(`看这个\n${code}\n好`)
  })

  test("CRLF / 开头 fence 后跟空格都认", () => {
    expect(stripReactBlocks("晚安\r\n```react \r\n❤️\r\n```\r\n")).toBe("晚安")
  })

  test("内容行不是单个 emoji → 不算协议块", () => {
    const s = "```react\nconst a = 1\n```"
    expect(stripReactBlocks(s)).toBe(s)
  })

  test("没块原样返回", () => {
    expect(stripReactBlocks("普通回复\n第二行")).toBe("普通回复\n第二行")
  })
})
