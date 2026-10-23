import { test, expect } from "bun:test"
import { mkdtempSync, mkdirSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { ccWorkdir, codexWorkdir, ccProjectMemoryDir } from "./cc-workdir.ts"

test("ccWorkdir：env 优先 → 已有的 ~/Desktop/cc-rp → Application Support", () => {
  const home = mkdtempSync(join(tmpdir(), "cc-home-"))
  expect(ccWorkdir({ MP_CC_WORKDIR: "/x/y" }, home)).toBe("/x/y")
  expect(ccWorkdir({}, home)).toBe(join(home, "Library", "Application Support", "MemoryPalace", "cc-bridge", "cc-rp"))
  mkdirSync(join(home, "Desktop", "cc-rp"), { recursive: true })
  expect(ccWorkdir({}, home)).toBe(join(home, "Desktop", "cc-rp"))
})

test("codexWorkdir：env 优先 → 已有的 ~/Desktop/gpt-rp → Application Support（#046 补兜底）", () => {
  const home = mkdtempSync(join(tmpdir(), "codex-home-"))
  expect(codexWorkdir({ MP_CODEX_WORKDIR: "/x/g" }, home)).toBe("/x/g")
  expect(codexWorkdir({}, home)).toBe(join(home, "Library", "Application Support", "MemoryPalace", "cc-bridge", "gpt-rp"))
  mkdirSync(join(home, "Desktop", "gpt-rp"), { recursive: true })
  expect(codexWorkdir({}, home)).toBe(join(home, "Desktop", "gpt-rp"))
})

test("ccProjectMemoryDir 跟 Claude Code 的 project 目录命名一致（非字母数字 → -）", () => {
  expect(ccProjectMemoryDir("/Users/tester/Desktop/cc-rp", "/Users/tester"))
    .toBe("/Users/tester/.claude/projects/-Users-tester-Desktop-cc-rp/memory")
  expect(ccProjectMemoryDir("/Users/tester/Library/Application Support/记忆", "/h"))
    .toBe("/h/.claude/projects/-Users-tester-Library-Application-Support---/memory")
})
