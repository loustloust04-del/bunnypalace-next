// CC 小克的 memory → 花园文件库 memory/cc/（plan-cc-memory-sync）。
// 手机来拉：先要清单（cc_memory_manifest），再按名字分批取（cc_memory_files）；hub 不排任何补投队列。
// 排除在这里做——被排除的文件连清单都不进，内容从不离开 Mac。
// 清单 / 取文件在 WS 处理路径上：读盘全异步（fs/promises），按 mtime 缓存，不卡 hub 主循环（10-11 现场 manifest 一次 2.4s）
import { watch } from "node:fs"
import { constants } from "node:fs"
import { open, readdir, readFile } from "node:fs/promises"
import { timedSyncFs } from "./block-ledger"
const { existsSync } = timedSyncFs("cc-memory ")
import { createHash } from "node:crypto"
import { basename, join } from "node:path"
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

/** 私人文件：去掉路径后的文件名以 private_ 开头（不分大小写）。与 app（CCMemorySync.isExcluded）、种子（CatalogSeed）同一条；
 *  只是中间带 private_ 的（如 project_private_repo.md）是普通文件 */
export function isPrivateName(name: string): boolean {
  return basename(name).toLowerCase().startsWith("private_")
}

/** 只看文件名就能定的排除：非 .md / 带斜杠 / 点开头 / 私人文件 / 名单里的（这些连读都不用读） */
export function isExcludedByName(name: string, extra: Set<string>): boolean {
  if (!name.endsWith(".md") || name.includes("/") || name.startsWith(".")) return true
  if (isPrivateName(name)) return true
  return extra.has(name)
}

/** 排除规则：同 isExcludedByName，不按内容里的字样整份扔（要挡哪份写进名单） */
export function isExcluded(name: string, _text: string, extra: Set<string>): boolean {
  return isExcludedByName(name, extra)
}

/** 一行归一：去掉 ASCII 标点前的反斜杠转义、空白并成一个空格、转小写（%XX 不在这里解：链接目标单独解）。全程线性 */
function normalizeLine(line: string): string {
  let out = ""
  for (let i = 0; i < line.length; i++) {
    if (line[i] === "\\" && i + 1 < line.length && /[!-/:-@[-`{-~]/.test(line[i + 1])) continue
    out += line[i]
  }
  return out.replace(/\s+/g, " ").toLowerCase()
}

const NAME_CHAR = /[a-z0-9_.-]/
/** 正文里文件名的分隔：空白、ASCII 标点（文件名常用的 % - . _ 除外）、中文全角标点。前面是这些（或行首）才算一个文件名的开头 */
const NAME_DELIM = /[\s!-$&-,/:-@\[-^`{-~（）【】〔〕「」『』《》〈〉，。：；、！？“”‘’…—·　]/

/** 正文里裸写了以 private_ 开头的文件名：private_ 前面是行首或分隔符就算，后面跟什么都不否决（private_!gone.md 也算） */
function mentionsPrivateFile(text: string): boolean {
  for (let i = text.indexOf("private_"); i >= 0; i = text.indexOf("private_", i + 1)) {
    if (i === 0 || NAME_DELIM.test(text[i - 1])) return true
  }
  return false
}

/** text 里出现了 name 这个文件名（前后不是文件名字符，免得 b.md 命中 project_b.md） */
function mentionsName(text: string, name: string): boolean {
  for (let i = text.indexOf(name); i >= 0; i = text.indexOf(name, i + 1)) {
    const before = text[i - 1], after = text[i + name.length]
    if ((before === undefined || !NAME_CHAR.test(before)) && (after === undefined || !NAME_CHAR.test(after))) return true
  }
  return false
}

/** 链接目标按完整路径取 basename：去 #锚点、?参数，解 %XX；解码后不再按空格切 */
function targetBasename(raw: string): string {
  let t = raw.split("#")[0].split("?")[0]
  try { t = decodeURIComponent(t) } catch { t = t.replace(/%([0-9a-fA-F]{2})/g, (_, h: string) => String.fromCharCode(parseInt(h, 16))) }
  return basename(t).toLowerCase()
}

/** 从 j 读一个链接目标（先跳空格）：<…> 读到 >（没闭合就到行尾），否则读到空格或 ) 为止 */
function readTarget(norm: string, j: number): { target: string; end: number } {
  while (norm[j] === " ") j++
  if (norm[j] === "<") {
    const close = norm.indexOf(">", j + 1)
    return close < 0 ? { target: norm.slice(j + 1), end: norm.length } : { target: norm.slice(j + 1, close), end: close + 1 }
  }
  let k = j
  while (k < norm.length && norm[k] !== " " && norm[k] !== ")") k++
  return { target: norm.slice(j, k), end: k }
}

/** 引用定义行 `[标签]: 目标` 的标签（已归一）；不是定义行 = undefined */
function refDefLabel(norm: string): string | undefined {
  const t = norm.trimStart()
  if (!t.startsWith("[")) return undefined
  const end = t.indexOf("]")
  if (end < 2 || t[end + 1] !== ":") return undefined
  return t.slice(1, end).trim()
}

/** 一行拆成链接目标（行内 ](…) 的、引用定义的）和目标以外的正文。往前推进不回头，线性 */
function splitLine(norm: string): { targets: string[]; bare: string } {
  const targets: string[] = []
  let bare = ""
  let from = 0
  const take = (j: number) => { const r = readTarget(norm, j); targets.push(r.target); from = r.end }
  if (refDefLabel(norm) !== undefined) {
    const colon = norm.indexOf("]:")
    bare += norm.slice(0, colon + 2)
    take(colon + 2)
  }
  for (let i = norm.indexOf("](", from); i >= 0; i = norm.indexOf("](", from)) {
    bare += norm.slice(from, i + 2)
    take(i + 2)
  }
  return { targets, bare: bare + norm.slice(from) }
}

/** 一行里所有 [..] 方括号的内容（已归一），线性扫描 */
function bracketLabels(norm: string): string[] {
  const out: string[] = []
  for (let i = norm.indexOf("["); i >= 0; ) {
    const end = norm.indexOf("]", i + 1)
    if (end < 0) break
    out.push(norm.slice(norm.lastIndexOf("[", end) + 1, end).trim())
    i = norm.indexOf("[", end + 1)
  }
  return out
}

/** MEMORY.md 索引：按行线性处理（去转义、空白归一后）。整行剥掉的情况：
 *  - 链接目标（行内 ](…) / <…> / 引用定义）按完整路径解码取 basename，与 isPrivateName 同一判定是私人文件，或是被排除 / 名单里的文件；
 *  - 目标以外的正文里裸写了以 private_ 开头的文件名（前面是行首或分隔符，含中文标点），或被排除 / 名单里的文件名。
 *  文件已经不在了的悬空链接也一样。引用式：定义行指向私人文件就剥定义行；用到这个标签的行，只有自己没有行内链接（真是靠标签引用）才剥。
 *  已知限制：跨行的链接不处理——MEMORY.md 是 CC 自己生成的索引，一条一行 */
export function stripExcludedLinks(index: string, excluded: Set<string>, extra: Set<string> = new Set()): string {
  const names = [...excluded, ...extra].map(n => n.toLowerCase())
  const nameSet = new Set(names)
  const lines = index.split("\n")
  const norms = lines.map(normalizeLine)
  const hits = norms.map(norm => {
    const { targets, bare } = splitLine(norm)
    return targets.some(t => { const b = targetBasename(t); return isPrivateName(b) || nameSet.has(b) })
      || mentionsPrivateFile(bare) || names.some(name => mentionsName(bare, name))
  })
  const badLabels = new Set<string>()
  norms.forEach((norm, i) => {
    const label = refDefLabel(norm)
    if (label !== undefined && hits[i]) badLabels.add(label)
  })
  return lines
    .filter((_, i) => {
      const norm = norms[i]
      if (hits[i]) return false
      if (refDefLabel(norm) !== undefined || norm.includes("](")) return true
      return !bracketLabels(norm).some(label => badLabels.has(label))
    })
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

/** 测试用：每次真正打开文件前回调一次（证明私人文件 / 链接从没被打开；返回 Promise 可卡住这次读） */
export const readHooks: { onOpen?: (path: string) => void | Promise<void> } = {}

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

const NOT_PLAIN = Symbol("not a plain file")
const OPEN_FLAGS = constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK

/** 读一个文件：不跟符号链接打开，打开后核验是普通文件，才看缓存（mtime / ctime / 大小都没变就用缓存）。
 *  新读的带上 stamp，由调用方过完排除再决定进不进缓存。是链接 / 不是普通文件 = NOT_PLAIN（缓存清掉）；
 *  文件没了（列目录之后被删）跳过，与原来一样；其他打开 / 读失败：有上次读到的就用它（K3 BindPrefsCache 同款），没有就跳过 */
async function readCached(path: string, cache: MemoryFileCache): Promise<{ text: string; fresh?: FileStamp } | typeof NOT_PLAIN | undefined> {
  await readHooks.onOpen?.(path)
  let fh
  try { fh = await open(path, OPEN_FLAGS) } catch (e) {
    const code = (e as NodeJS.ErrnoException)?.code
    if (code === "ELOOP" || code === "EMLINK") { cache.delete(path); return NOT_PLAIN }
    if (isENOENT(e)) { cache.delete(path); return undefined }
    const prev = cache.get(path)
    return prev ? { text: prev.text } : undefined
  }
  try {
    const st = await fh.stat()
    if (!st.isFile()) { cache.delete(path); return NOT_PLAIN }
    const prev = cache.get(path)
    if (prev && prev.mtimeMs === st.mtimeMs && prev.ctimeMs === st.ctimeMs && prev.size === st.size) return { text: prev.text }
    try {
      const text = await fh.readFile({ encoding: "utf8" })
      return { text, fresh: { mtimeMs: st.mtimeMs, ctimeMs: st.ctimeMs, size: st.size } }
    } catch { return prev ? { text: prev.text } : undefined }
  } finally { await fh.close() }
}

/** 读目录 → 过滤后的「文件名 → 要发出去的内容」。目录不存在 = 空 */
export async function buildSnapshot(
  dir: string = CC_MEMORY_DIR,
  extra?: Set<string>,
  cache: MemoryFileCache = defaultCache,
): Promise<Map<string, string>> {
  const epoch = ++cache.epoch
  const excludes = extra ?? await loadExtraExcludes()
  let entries: { name: string; plain: boolean }[]
  try {
    entries = (await readdir(dir, { withFileTypes: true }))
      .filter(d => d.name.endsWith(".md"))
      .map(d => ({ name: d.name, plain: d.isFile() && !d.isSymbolicLink() }))
  } catch (e) {
    if (!isENOENT(e)) throw e
    cache.prune(dir)   // 整个目录没了：这个目录的缓存全清
    return new Map()
  }
  cache.prune(dir, new Set(entries.map(e => join(dir, e.name))))   // 删掉的文件不留在缓存里
  // 按名字就能排除的、符号链接 / 不是普通文件的不打开；它们进 excluded（缓存清掉），MEMORY.md 里指向它们的行照删
  const excluded = new Set<string>()
  const toRead: string[] = []
  for (const { name, plain } of entries) {
    if (plain && !isExcludedByName(name, excludes)) { toRead.push(name); continue }
    excluded.add(name)
    cache.delete(join(dir, name))
  }
  const reads = await Promise.all(toRead.map(name => withReadSlot(() => readCached(join(dir, name), cache))))
  const kept = new Map<string, string>()
  toRead.forEach((name, i) => {
    const r = reads[i]
    if (!r) return
    const path = join(dir, name)
    if (r === NOT_PLAIN || isExcluded(name, r.text, excludes)) { excluded.add(name); cache.delete(path); return }
    kept.set(name, r.text)
    if (!r.fresh) return
    if (epoch !== cache.epoch) return   // 已经有更新的构建开始了：这次的读数不进缓存
    if (r.fresh.size <= MAX_FRAME_BYTES) cache.set(path, { ...r.fresh, text: r.text })
    else cache.delete(path)   // 超过单帧上限：清单里要它的哈希，但正文发不出去，不常驻
  })
  const index = kept.get("MEMORY.md")
  if (index !== undefined) kept.set("MEMORY.md", stripExcludedLinks(index, excluded, excludes))
  return kept
}

type Snapshot = Map<string, string>

/** 发出去前按当前规则再核一遍：名字被排除的拿掉，MEMORY.md 按当前名单再剥一遍链接 */
export function screenSnapshot(snap: Snapshot, extra: Set<string>): Snapshot {
  const out = new Map<string, string>()
  const removed = new Set<string>()
  for (const [name, text] of snap) {
    if (isExcludedByName(name, extra)) removed.add(name)
    else out.set(name, text)
  }
  const index = out.get("MEMORY.md")
  if (index !== undefined) out.set("MEMORY.md", stripExcludedLinks(index, removed, extra))
  return out
}

const excludesKey = (extra: Set<string>) => [...extra].sort().join("\n")

/** 同一目录的快照构建合并（审查 R1-4）：同一时刻最多一个在读、一个排队，后来的请求挂到排队那个上；
 *  取文件优先复用最近一份（app 收到清单后按 20 个一批连发 fetch，原来每批都重扫整个目录） */
export class MemorySnapshots {
  private running: Promise<Snapshot> | null = null
  private queued: Promise<Snapshot> | null = null
  private last: { snap: Snapshot; at: number; excludes: string } | null = null

  constructor(
    readonly dir: string,
    readonly cache: MemoryFileCache = new MemoryFileCache(),
    private readonly build: (dir: string, extra: Set<string> | undefined, cache: MemoryFileCache) => Promise<Snapshot> = buildSnapshot,
    private readonly reuseMs = 30_000,
    private readonly loadExcludes: () => Promise<Set<string>> = () => loadExtraExcludes(),
  ) {}

  /** 清单用：拿到的快照一定是这次调用之后才开始读的；拿到后按当前名单再核一遍 */
  fresh(): Promise<Snapshot> {
    return this.freshBuild().then(snap => this.screen(snap))
  }

  private freshBuild(): Promise<Snapshot> {
    const running = this.running
    if (!running) return this.start()
    if (!this.queued) {
      const go = () => { this.queued = null; return this.start() }
      this.queued = running.then(go, go)
    }
    return this.queued
  }

  /** 取文件用：有在途 / 排队的就跟它；最近一份不超过 reuseMs、名单也没变就复用；否则读一份新的。等到快照后按当前名单再核一遍 */
  async recent(): Promise<Snapshot> {
    const extra = await this.loadExcludes()
    const last = this.last
    const reusable = last && Date.now() - last.at < this.reuseMs && last.excludes === excludesKey(extra) ? last.snap : undefined
    return this.screen(await (this.queued ?? this.running ?? reusable ?? this.start()))
  }

  /** 快照到手（可能是名单变之前开始读的）之后，按此刻的名单核一遍：被排除的拿掉，正文缓存同步清掉 */
  private async screen(snap: Snapshot): Promise<Snapshot> {
    const extra = await this.loadExcludes()
    for (const name of snap.keys()) if (isExcludedByName(name, extra)) this.cache.delete(join(this.dir, name))
    return screenSnapshot(snap, extra)
  }

  private start(): Promise<Snapshot> {
    const p = this.loadExcludes().then(extra => this.build(this.dir, extra, this.cache).then(snap => {
      this.last = { snap, at: Date.now(), excludes: excludesKey(extra) }
      return snap
    }))
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
