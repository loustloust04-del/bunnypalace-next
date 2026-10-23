// CC 小克的 memory → 花园文件库 memory/cc/（plan-cc-memory-sync）。
// 手机来拉：先要清单（cc_memory_manifest），再按名字分批取（cc_memory_files）；hub 不排任何补投队列。
// 排除在这里做——被排除的文件连清单都不进，内容从不离开 Mac。
// 清单 / 取文件在 WS 处理路径上：读盘全异步（fs/promises），按 mtime 缓存，不卡 hub 主循环（10-11 现场 manifest 一次 2.4s）
import { watch } from "node:fs"
import { readdir, readFile, stat } from "node:fs/promises"
import { timedSyncFs } from "./block-ledger"
const { existsSync } = timedSyncFs("cc-memory ")
import { createHash } from "node:crypto"
import { join } from "node:path"
import { ccWorkdir, ccProjectMemoryDir } from "./cc-workdir.ts"

export const CC_MEMORY_DIR = process.env.CC_MEMORY_SYNC_DIR ?? ccProjectMemoryDir(ccWorkdir())
export const CC_MEMORY_EXCLUDE_FILE = join(import.meta.dir, "cc-memory-sync.exclude")
export const MAX_FETCH_NAMES = 20
export const MAX_FRAME_BYTES = 256 * 1024

export type ManifestEntry = { name: string; sha256: string; size: number }

/** frontmatter 里的 name / description（只认文件开头 --- 包着的块） */
export function frontmatter(text: string): { name?: string; description?: string } {
  const lines = text.split("\n")
  if (lines[0]?.trim() !== "---") return {}
  const out: { name?: string; description?: string } = {}
  for (const line of lines.slice(1)) {
    if (line.trim() === "---") break
    const m = line.match(/^(name|description):\s*(.*)$/)
    if (m) out[m[1] as "name" | "description"] = m[2]
  }
  return out
}

const DIARY = /diary|日记/i

/** 只看文件名就能定的那部分排除：非 .md / private_ 开头 / 名单里的 / 文件名提到日记（这些连读都不用读） */
export function isExcludedByName(name: string, extra: Set<string>): boolean {
  if (!name.endsWith(".md") || name.includes("/") || name.startsWith(".")) return true
  if (name.startsWith("private_")) return true
  if (extra.has(name)) return true
  return DIARY.test(name)
}

/** 排除规则：非 .md / private_ 开头 / 名单里的 / 文件名或 frontmatter 的 name、description 提到日记 */
export function isExcluded(name: string, text: string, extra: Set<string>): boolean {
  if (isExcludedByName(name, extra)) return true
  const fm = frontmatter(text)
  return DIARY.test(fm.name ?? "") || DIARY.test(fm.description ?? "")
}

/** MEMORY.md 索引：去掉指向被排除文件的行（如「小克的日记本」那条） */
export function stripExcludedLinks(index: string, excluded: Set<string>): string {
  if (excluded.size === 0) return index
  return index
    .split("\n")
    .filter(line => ![...excluded].some(f => line.includes(`(${f})`)))
    .join("\n")
}

const isENOENT = (e: unknown) => (e as NodeJS.ErrnoException)?.code === "ENOENT"

/** 不存在 = 空名单；其他读错误照旧抛（清单回 ok:false） */
export async function loadExtraExcludes(path: string = CC_MEMORY_EXCLUDE_FILE): Promise<Set<string>> {
  let text: string
  try { text = await readFile(path, "utf8") } catch (e) { if (isENOENT(e)) return new Set(); throw e }
  return new Set(text.split("\n").map(l => l.trim()).filter(l => l && !l.startsWith("#")))
}

/** 整个进程同时读盘的文件数上限：所有构建共用一个，不是每个请求各 8 个（审查 R1-4） */
export const READ_CONCURRENCY = 8
/** 正在读 / 读过的最高并发（测试看） */
export const readStats = { active: 0, peak: 0 }
const readWaiters: (() => void)[] = []

async function withReadSlot<T>(fn: () => Promise<T>): Promise<T> {
  while (readStats.active >= READ_CONCURRENCY) await new Promise<void>(r => readWaiters.push(r))
  readStats.active++
  readStats.peak = Math.max(readStats.peak, readStats.active)
  try { return await fn() } finally {
    readStats.active--
    readWaiters.shift()?.()
  }
}

type FileStamp = { mtimeMs: number; ctimeMs: number; size: number }
type CachedFile = FileStamp & { text: string }
/** 缓存正文的总字节上限，超了先扔最久没用的（审查 R1-5） */
export const CACHE_MAX_BYTES = 8 * 1024 * 1024

/** 完整路径 → 上次读到的内容；mtime / ctime / 大小都没变就不重读。
 *  只缓存要发出去的：被排除的、超过单帧上限（反正发不出去）的不进；总字节有上限，按最近使用淘汰 */
export class MemoryFileCache {
  private readonly files = new Map<string, CachedFile>()
  bytes = 0
  /** 每开始一次构建 +1；只有最新那次构建能往里写，旧构建晚到的读数（可能是已删除的文件）不再写回（审查 R1-3） */
  epoch = 0
  constructor(readonly maxBytes = CACHE_MAX_BYTES) {}
  get size(): number { return this.files.size }
  has(path: string): boolean { return this.files.has(path) }
  get(path: string): CachedFile | undefined {
    const f = this.files.get(path)
    if (f) { this.files.delete(path); this.files.set(path, f) }   // Map 按插入顺序：挪到最新
    return f
  }
  set(path: string, f: CachedFile): void {
    this.delete(path)
    if (f.size > this.maxBytes) return
    this.files.set(path, f)
    this.bytes += f.size
    for (const [k, v] of this.files) {
      if (this.bytes <= this.maxBytes) break
      this.files.delete(k)
      this.bytes -= v.size
    }
  }
  delete(path: string): void {
    const f = this.files.get(path)
    if (!f) return
    this.files.delete(path)
    this.bytes -= f.size
  }
  /** dir 下不在 keep 里的全清；不给 keep = 整个目录清掉 */
  prune(dir: string, keep?: Set<string>): void {
    const prefix = join(dir, "/")
    for (const k of [...this.files.keys()]) if (k.startsWith(prefix) && !keep?.has(k)) this.delete(k)
  }
}
const defaultCache = new MemoryFileCache()

/** 读一个文件：mtime / ctime / 大小都没变就用缓存。新读的带上 stamp，由调用方过完排除再决定进不进缓存。
 *  文件没了（列目录之后被删）跳过，与原来一样；其他 stat / 读失败：有上次读到的就用它（K3 BindPrefsCache 同款），没有就跳过 */
async function readCached(path: string, cache: MemoryFileCache): Promise<{ text: string; fresh?: FileStamp } | undefined> {
  const prev = cache.get(path)
  try {
    const st = await stat(path)
    if (prev && prev.mtimeMs === st.mtimeMs && prev.ctimeMs === st.ctimeMs && prev.size === st.size) return { text: prev.text }
    const text = await readFile(path, "utf8")
    return { text, fresh: { mtimeMs: st.mtimeMs, ctimeMs: st.ctimeMs, size: st.size } }
  } catch (e) {
    if (isENOENT(e)) { cache.delete(path); return undefined }
    return prev ? { text: prev.text } : undefined
  }
}

/** 读目录 → 过滤后的「文件名 → 要发出去的内容」。目录不存在 = 空 */
export async function buildSnapshot(
  dir: string = CC_MEMORY_DIR,
  extra?: Set<string>,
  cache: MemoryFileCache = defaultCache,
): Promise<Map<string, string>> {
  const epoch = ++cache.epoch
  const excludes = extra ?? await loadExtraExcludes()
  let names: string[]
  try { names = (await readdir(dir)).filter(name => name.endsWith(".md")) }
  catch (e) {
    if (!isENOENT(e)) throw e
    cache.prune(dir)   // 整个目录没了：这个目录的缓存全清
    return new Map()
  }
  cache.prune(dir, new Set(names.map(name => join(dir, name))))   // 删掉的文件不留在缓存里
  // 按名字就能排除的不读（以前也读，只是读完扔掉）；它们照样进 excluded，MEMORY.md 里指向它们的行照删
  const excluded = new Set<string>()
  const toRead = names.filter(name => isExcludedByName(name, excludes) ? (excluded.add(name), false) : true)
  const reads = await Promise.all(toRead.map(name => withReadSlot(() => readCached(join(dir, name), cache))))
  const kept = new Map<string, string>()
  toRead.forEach((name, i) => {
    const r = reads[i]
    if (!r) return
    const path = join(dir, name)
    if (isExcluded(name, r.text, excludes)) { excluded.add(name); cache.delete(path); return }
    kept.set(name, r.text)
    if (!r.fresh) return
    if (epoch !== cache.epoch) return   // 已经有更新的构建开始了：这次的读数不进缓存
    if (r.fresh.size <= MAX_FRAME_BYTES) cache.set(path, { ...r.fresh, text: r.text })
    else cache.delete(path)   // 超过单帧上限：清单里要它的哈希，但正文发不出去，不常驻
  })
  const index = kept.get("MEMORY.md")
  if (index !== undefined) kept.set("MEMORY.md", stripExcludedLinks(index, excluded))
  return kept
}

type Snapshot = Map<string, string>

/** 同一目录的快照构建合并（审查 R1-4）：同一时刻最多一个在读、一个排队，后来的请求挂到排队那个上；
 *  取文件优先复用最近一份（app 收到清单后按 20 个一批连发 fetch，原来每批都重扫整个目录） */
export class MemorySnapshots {
  private running: Promise<Snapshot> | null = null
  private queued: Promise<Snapshot> | null = null
  private last: { snap: Snapshot; at: number } | null = null

  constructor(
    readonly dir: string,
    readonly cache: MemoryFileCache = new MemoryFileCache(),
    private readonly build: (dir: string, extra: Set<string> | undefined, cache: MemoryFileCache) => Promise<Snapshot> = buildSnapshot,
    private readonly reuseMs = 30_000,
  ) {}

  /** 清单用：拿到的快照一定是这次调用之后才开始读的 */
  fresh(): Promise<Snapshot> {
    const running = this.running
    if (!running) return this.start()
    if (!this.queued) {
      const go = () => { this.queued = null; return this.start() }
      this.queued = running.then(go, go)
    }
    return this.queued
  }

  /** 取文件用：有在途 / 排队的就跟它；最近一份不超过 reuseMs 就复用；否则读一份新的 */
  recent(): Promise<Snapshot> {
    if (this.queued) return this.queued
    if (this.running) return this.running
    if (this.last && Date.now() - this.last.at < this.reuseMs) return Promise.resolve(this.last.snap)
    return this.start()
  }

  private start(): Promise<Snapshot> {
    const p = this.build(this.dir, undefined, this.cache).then(snap => { this.last = { snap, at: Date.now() }; return snap })
    this.running = p
    const clear = () => { if (this.running === p) this.running = null }
    p.then(clear, clear)
    return p
  }
}

/** 同一连接的 memory 回包按请求顺序发（审查 R1-3）：读盘是异步的，不串行的话新的（空）清单可能先到、
 *  旧 fetch 后到，手机按清单删掉的文件又被旧内容写回来。配合 MemorySnapshots（同一目录的构建串行、结果只会越来越新），
 *  同一连接上后发的回包用的快照不会比先发的旧 */
export class MemoryReplies {
  private tail: Promise<void> = Promise.resolve()
  constructor(private readonly send: (frame: string) => void) {}

  /** job 自己处理失败（返回要发的帧）；抛了只丢这一次，不断链 */
  push(job: () => Promise<string[]>): Promise<void> {
    const next = this.tail.then(job).then(frames => { for (const f of frames) this.send(f) })
    this.tail = next.catch(() => {})
    return next
  }
}

/** hub 用的那一份（CC_MEMORY_DIR） */
export const ccMemorySnapshots = new MemorySnapshots(CC_MEMORY_DIR, defaultCache)

export function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex")
}

export function manifest(snapshot: Map<string, string>): ManifestEntry[] {
  return [...snapshot.entries()]
    .map(([name, text]) => ({ name, sha256: sha256(text), size: Buffer.byteLength(text, "utf8") }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

/** 按名字取文件，分帧（每帧 ≤ MAX_FRAME_BYTES）。只认快照里有的名字——被排除的、瞎编的一律拿不到 */
export function fetchFrames(snapshot: Map<string, string>, names: unknown): string[] {
  if (!Array.isArray(names)) return []
  const wanted = names.filter((n): n is string => typeof n === "string").slice(0, MAX_FETCH_NAMES)
  const frames: string[] = []
  let batch: { name: string; content: string }[] = []
  let bytes = 0
  const skipped: string[] = []
  const flush = () => {
    if (batch.length) frames.push(JSON.stringify({ type: "cc_memory_files", files: batch }))
    batch = []
    bytes = 0
  }
  for (const name of wanted) {
    const content = snapshot.get(name)
    if (content === undefined) continue
    const size = Buffer.byteLength(content, "utf8")
    if (size > MAX_FRAME_BYTES) { skipped.push(name); continue }
    if (bytes + size > MAX_FRAME_BYTES) flush()
    batch.push({ name, content })
    bytes += size
  }
  flush()
  if (skipped.length) frames.push(JSON.stringify({ type: "cc_memory_files", files: [], skipped }))
  return frames
}

/** 盯目录：有变化就（去抖后）回调一次。目录不存在返回空操作 */
export function watchMemoryDir(dir: string, onChange: () => void, debounceMs = 2000): () => void {
  if (!existsSync(dir)) return () => {}
  let timer: ReturnType<typeof setTimeout> | null = null
  const watcher = watch(dir, () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => { timer = null; onChange() }, debounceMs)
  })
  return () => { if (timer) clearTimeout(timer); watcher.close() }
}
