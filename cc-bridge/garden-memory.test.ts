import { afterEach, beforeEach, expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { writeGardenMemory } from "./garden-memory.ts"

let home = ""
let root = ""
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "garden-memory-"))
  root = join(home, "garden-memory")
})
afterEach(() => rmSync(home, { recursive: true, force: true }))

const files = [{ name: "README.md", content: "说明" }, { name: "模型船.md", content: "- 只用水性颜料。\n" }]

test("整份写进楼层文件夹，再发一次整份换掉", () => {
  expect(writeGardenMemory({ floor: "星砚楼", files }, root)).toEqual({ ok: true, files: 2 })
  expect(readdirSync(join(root, "星砚楼")).sort()).toEqual(["README.md", "模型船.md"])
  expect(readFileSync(join(root, ".gitignore"), "utf8")).toBe("*\n")
  expect(writeGardenMemory({ floor: "星砚楼", files: [{ name: "底座.md", content: "新的" }] }, root).ok).toBe(true)
  expect(readdirSync(join(root, "星砚楼"))).toEqual(["底座.md"])
  expect(readdirSync(root).sort()).toEqual([".gitignore", "星砚楼"])
})

test("空文件列表 = 删掉这个楼层的，别的楼层不动", () => {
  writeGardenMemory({ floor: "星砚楼", files }, root)
  writeGardenMemory({ floor: "雾岛楼", files }, root)
  expect(writeGardenMemory({ floor: "星砚楼", files: [] }, root)).toEqual({ ok: true, files: 0 })
  expect(existsSync(join(root, "星砚楼"))).toBe(false)
  expect(existsSync(join(root, "雾岛楼", "README.md"))).toBe(true)
  expect(writeGardenMemory({ floor: "没写过的楼", files: [] }, root).ok).toBe(true)
})

test("名字想往外跑 / 不是 md / 重名 / 不是字符串：整份不写，上一份还在", () => {
  writeGardenMemory({ floor: "星砚楼", files }, root)
  const bad = [
    { floor: "../外面", files },
    { floor: ".藏起来", files },
    { floor: "a/b", files },
    { floor: "", files },
    { floor: "星砚楼", files: [{ name: "../x.md", content: "" }] },
    { floor: "星砚楼", files: [{ name: "a/b.md", content: "" }] },
    { floor: "星砚楼", files: [{ name: ".x.md", content: "" }] },
    { floor: "星砚楼", files: [{ name: "x.sh", content: "" }] },
    { floor: "星砚楼", files: [{ name: "x.md", content: 1 }] },
    { floor: "星砚楼", files: [{ name: "x.md", content: "" }, { name: "x.md", content: "" }] },
    { floor: "星砚楼", files: "不是数组" },
    { floor: "星砚楼", files: [{ name: "x.md", content: "长".repeat(200_000) }] },
  ]
  for (const msg of bad) expect(writeGardenMemory(msg, root).ok).toBe(false)
  expect(readdirSync(join(root, "星砚楼")).sort()).toEqual(["README.md", "模型船.md"])
  expect(readdirSync(home)).toEqual(["garden-memory"])
})

test("文件夹是个链接就不写", () => {
  const elsewhere = join(home, "别处")
  mkdirSync(elsewhere)
  writeFileSync(join(elsewhere, "留着.txt"), "别动")
  mkdirSync(root)
  symlinkSync(elsewhere, join(root, "星砚楼"))
  expect(writeGardenMemory({ floor: "星砚楼", files }, root)).toEqual({ ok: false, reason: "floor_not_dir" })
  expect(writeGardenMemory({ floor: "星砚楼", files: [] }, root).ok).toBe(false)
  expect(readdirSync(elsewhere)).toEqual(["留着.txt"])
  const linkedRoot = join(home, "链过去的")
  symlinkSync(elsewhere, linkedRoot)
  expect(writeGardenMemory({ floor: "星砚楼", files }, linkedRoot)).toEqual({ ok: false, reason: "root_not_dir" })
})

test("这层楼已经由整棵树同步在管：老帧的整份替换不收", () => {
  mkdirSync(join(root, "星砚楼", "_sync"), { recursive: true })
  writeFileSync(join(root, "星砚楼", "_sync", ".state.json"), "{}")
  writeFileSync(join(root, "星砚楼", "README.md"), "新格式的说明")
  expect(writeGardenMemory({ floor: "星砚楼", files }, root)).toEqual({ ok: false, reason: "tree_sync" })
  expect(writeGardenMemory({ floor: "星砚楼", files: [] }, root)).toEqual({ ok: false, reason: "tree_sync" })
  expect(readFileSync(join(root, "星砚楼", "README.md"), "utf8")).toBe("新格式的说明")
})
