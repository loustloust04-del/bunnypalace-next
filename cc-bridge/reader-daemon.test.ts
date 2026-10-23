import { test, expect } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { readerGate, loadReaderMaterial, loadReaderPersona, parseReaderOutput, buildBookNotePayload, appendReaderHistory, readerHistoryBlock } from "./reader-daemon.ts"

function makeDir(ctx?: Record<string, unknown>, status?: Record<string, unknown>): string {
  const dir = mkdtempSync(join(tmpdir(), "cc-reader-"))
  if (ctx) writeFileSync(join(dir, "reading-context.json"), JSON.stringify(ctx))
  if (status) writeFileSync(join(dir, "reading-status.json"), JSON.stringify(status))
  return dir
}

const CTX = {
  floorId: "f1", safeName: "b", bookName: "测试书", chapter: 3, totalChapters: 10,
  chapterTitle: "第三章", text: "这一章的正文内容。读到这里。", userName: "禾禾",
  userNotes: [{ id: "n1", anchorText: "读到这里", content: "这句好戳" }],
}

// MARK: gate

test("readerGate: no material → skip", () => {
  const dir = makeDir()
  expect(readerGate(dir)).toEqual({ ok: false, reason: "skipped-no-material" })
})

test("readerGate: she is reading → yield", () => {
  const dir = makeDir(CTX, { updatedAt: new Date().toISOString() })
  expect(readerGate(dir)).toEqual({ ok: false, reason: "skipped-reading" })
})

test("readerGate: stale status + material → go", () => {
  const dir = makeDir(CTX, { updatedAt: new Date(Date.now() - 3 * 3600_000).toISOString() })
  expect(readerGate(dir)).toEqual({ ok: true })
})

// MARK: material

test("loadReaderMaterial injects book, text and her notes", () => {
  const dir = makeDir(CTX)
  const m = loadReaderMaterial(dir)!
  expect(m).toContain("《测试书》第 3 章")
  expect(m).toContain("这一章的正文内容")
  expect(m).toContain("这句好戳")
  expect(m).toContain("禾禾正在读的书")
  expect(m).not.toContain("她正在读")
})

test("loadReaderMaterial falls back to 用户 when userName absent", () => {
  const { userName, ...rest } = CTX as any
  const dir = makeDir(rest)
  expect(loadReaderMaterial(dir)!).toContain("用户正在读的书")
})

// MARK: parse

test("parseReaderOutput accepts fenced JSON and caps notes", () => {
  const raw = '好的，这是我的批注：\n```json\n' + JSON.stringify({
    annotations: [
      { anchorText: "她读到这里的一句原文", comment: "第一条" },
      { anchorText: "另一句足够长的原文引用", comment: "第二条", replyToAnchor: "她读到这里" },
      { anchorText: "第三句足够长的原文引用", comment: "第三条" },
      { anchorText: "第四句足够长的原文引用", comment: "超额丢弃" },
    ],
    message: "我读到第三章了",
  }) + "\n```"
  const out = parseReaderOutput(raw)!
  expect(out.notes.length).toBe(3)
  expect(out.notes[1].replyToAnchor).toBe("她读到这里")
  expect(out.message).toBe("我读到第三章了")
})

test("parseReaderOutput drops bad anchors and rejects garbage", () => {
  const out = parseReaderOutput(JSON.stringify({
    annotations: [
      { anchorText: "短", comment: "锚太短丢" },
      { anchorText: "这是一句足够长的原文", comment: "" },
    ],
    message: "",
  }))
  expect(out).toBeNull()   // 全废 → null
  expect(parseReaderOutput("完全不是 JSON 的回答")).toBeNull()
})

// MARK: payload

test("buildBookNotePayload carries context identity", () => {
  const dir = makeDir(CTX)
  const p = buildBookNotePayload({ notes: [{ anchorText: "读到这里的原文", comment: "c" }], message: "m" }, dir)!
  expect(p.safeName).toBe("b")
  expect(p.floorId).toBe("f1")
  expect(p.chapter).toBe(3)
  expect(typeof p.uuid).toBe("string")
})

// R1 人格注入
test("loadReaderPersona returns persona with coreading suffix", () => {
  const dir = makeDir({ ...CTX, persona: "你是小岚。你在陪禾禾读书。温柔，爱书。" })
  const p = loadReaderPersona(dir)!
  expect(p).toContain("你是小岚")
  expect(p).toContain("共读")
  expect(p).toContain("现在禾禾不在")
})

test("loadReaderPersona null when absent", () => {
  expect(loadReaderPersona(makeDir(CTX))).toBeNull()
  expect(loadReaderPersona(makeDir())).toBeNull()
})

// R3 共读足迹
test("readerHistoryBlock renders recent entries and rolls at 20", () => {
  const dir = makeDir(CTX)
  expect(readerHistoryBlock(dir)).toBe("")
  for (let i = 1; i <= 22; i++) {
    appendReaderHistory({ ts: `2026-07-0${(i % 9) + 1}T12:00:00Z`, bookName: "测试书", safeName: "b",
      chapter: i, comments: [`第${i}轮批注`], message: `第${i}轮消息` }, dir)
  }
  const all = JSON.parse(require("node:fs").readFileSync(require("node:path").join(dir, "reader-history.json"), "utf8"))
  expect(all.length).toBe(20)
  const block = readerHistoryBlock(dir)
  expect(block).toContain("共读足迹")
  expect(block).toContain("第 22 章")
  expect(block).toContain("第22轮批注")
  expect(block).not.toContain("第 18 章")   // latest=4 只带最近 4 条
})

test("loadReaderMaterial appends history block", () => {
  const dir = makeDir(CTX)
  appendReaderHistory({ ts: "2026-07-06T12:00:00Z", bookName: "测试书", safeName: "b",
    chapter: 2, comments: ["上次的批注"], message: "" }, dir)
  expect(loadReaderMaterial(dir)!).toContain("上次的批注")
})
