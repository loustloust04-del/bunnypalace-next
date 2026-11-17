// 花园记忆 → CC 家目录（docs/plan-cc-read-memory.md 接法 B）：老版本 app 把一个楼层的记忆排成 markdown 发来，
// 这里整份换掉 `<CC 家>/garden-memory/<楼层>/`。只写这个文件夹里面，别处不碰。
// 新版本 app 走 garden-tree.ts（整棵记忆文件夹、增量、CC 能写回）；这个帧只为还没升级的 app 留着。
import { existsSync, lstatSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { ccWorkdir } from "./cc-workdir.ts"

export const GARDEN_MEMORY_DIR = "garden-memory"
export const GARDEN_MEMORY_MAX_FILES = 500
export const GARDEN_MEMORY_MAX_FILE_BYTES = 512 * 1024
export const GARDEN_MEMORY_MAX_TOTAL_BYTES = 4 * 1024 * 1024

export type GardenMemoryResult = { ok: boolean; reason?: string; files?: number }

// 单层名字：不含路径分隔 / 控制字符，不以点开头，不超长
function plainName(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max
    && !value.startsWith(".") && !/[\/\\\u0000-\u001f]/.test(value)
}

function isRealDir(path: string): boolean {
  const s = lstatSync(path, { throwIfNoEntry: false })
  return !!s && s.isDirectory() && !s.isSymbolicLink()
}

/// files 为空 = 这个楼层不再给 CC 看，删掉它的文件夹。任何一项不合格整份不写（宁可留着上一份，也不写一半）
export function writeGardenMemory(
  msg: { floor?: unknown; files?: unknown },
  root: string = join(ccWorkdir(), GARDEN_MEMORY_DIR),
): GardenMemoryResult {
  if (!plainName(msg.floor, 80)) return { ok: false, reason: "invalid_floor" }
  if (!Array.isArray(msg.files) || msg.files.length > GARDEN_MEMORY_MAX_FILES) return { ok: false, reason: "invalid_files" }
  const files: { name: string; content: string }[] = []
  const seen = new Set<string>()
  let total = 0
  for (const f of msg.files) {
    const name = (f as { name?: unknown })?.name
    const content = (f as { content?: unknown })?.content
    if (!plainName(name, 120) || !name.endsWith(".md") || seen.has(name) || typeof content !== "string") {
      return { ok: false, reason: "invalid_file" }
    }
    const bytes = Buffer.byteLength(content, "utf8")
    total += bytes
    if (bytes > GARDEN_MEMORY_MAX_FILE_BYTES || total > GARDEN_MEMORY_MAX_TOTAL_BYTES) return { ok: false, reason: "too_large" }
    seen.add(name)
    files.push({ name, content })
  }
  const dir = join(root, msg.floor)
  const tmp = join(root, `.tmp-${process.pid}-${Date.now()}`)
  try {
    if (existsSync(root) && !isRealDir(root)) return { ok: false, reason: "root_not_dir" }
    if (existsSync(dir) && !isRealDir(dir)) return { ok: false, reason: "floor_not_dir" }
    // 这层楼已经由新的整棵树同步在管（garden-tree.ts）：老版本 app 的整份替换不收，免得把 CC 还没落的修改和同步状态一起抹掉
    if (existsSync(join(dir, "_sync", ".state.json"))) return { ok: false, reason: "tree_sync" }
    if (files.length === 0) {
      rmSync(dir, { recursive: true, force: true })
      return { ok: true, files: 0 }
    }
    mkdirSync(root, { recursive: true })
    // 家目录若是 git 仓库，这个文件夹不跟着走
    const ignore = join(root, ".gitignore")
    if (!existsSync(ignore)) writeFileSync(ignore, "*\n")
    mkdirSync(tmp)
    for (const f of files) writeFileSync(join(tmp, f.name), f.content)
    rmSync(dir, { recursive: true, force: true })
    renameSync(tmp, dir)
    return { ok: true, files: files.length }
  } catch (err) {
    rmSync(tmp, { recursive: true, force: true })
    console.warn(`[hub] set_garden_memory 写入失败: ${err}`)
    return { ok: false, reason: "write_failed" }
  }
}
