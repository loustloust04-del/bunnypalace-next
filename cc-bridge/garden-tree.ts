// 花园记忆文件夹 ↔ CC 家目录（docs/记忆系统/README.md §0「记忆对外就是 文件库 › 记忆 那个文件夹」）。
//
// 电脑上 `<CC 家>/garden-memory/<楼层>/` 是花园里 memory/ 和 .prompt/ 那棵树的一份：CC 直接读写本地文件。
// - 花园 → 电脑：app 先报清单（路径 + 内容指纹），这里只要变了的那几份，没变的不重写（mtime 留着），花园里没了的删掉。
// - 电脑 → 花园：这里拿盘上的文件和「花园上次给的那一版」比，不一样的就是待落的修改，送给这层楼所在的那台 app；
//   app 落 / 拒 / 判冲突后回结果，这里照结果把文件摆成花园现在的样子，并把每一笔记进 `_sync/收件回执.md`。
// 盘上的文件就是队列：app 不在线、hub 重启，改动都还在盘上，下次比出来照样送。花园是准：对不上的一律以花园为准，CC 写的另存不丢。
// 这个文件不碰 socket（发帧走构造时给的 send），hub.ts 只管转帧和定时 tick。
import { createHash } from "node:crypto"
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, rmdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { GARDEN_MEMORY_DIR } from "./garden-memory.ts"
import { ccWorkdir } from "./cc-workdir.ts"

/// 上限都在这里。一份文件 512KB、一帧 256KB：同原来的 set_garden_memory / cc_memory_fetch（app 收帧上限 1MB，留一半以上余量）
export const GARDEN_TREE_MAX_FILE_BYTES = 512 * 1024
export const GARDEN_TREE_FRAME_BYTES = 256 * 1024
/// 清单 / 要哪些 一帧最多多少条（一条 ≈ 路径 + 32 位指纹，500 条远小于一帧的字节上限）
export const GARDEN_TREE_LIST_BATCH = 500
/// 一层楼最多多少份（挡坏帧用的硬顶，正常的树到不了）
export const GARDEN_TREE_MAX_FILES = 20000
/// CC 改完一份文件，等这么久没再动才送（它常连着改同一份好几下，别一下一笔）
export const GARDEN_TREE_SETTLE_MS = 3000
/// 回执留最近多少笔（连同它们另存的那份；更早的一起清掉）
export const GARDEN_TREE_RECEIPTS_KEEP = 200
/// 一次同步的帧断了多久算作废（app 走了）
export const GARDEN_TREE_SYNC_STALE_MS = 60_000

export const SYNC_DIR = "_sync"
export const RECEIPTS_FILE = "收件回执.md"
export const SAVED_DIR = "没落下的"
const STATE_FILE = ".state.json"

export type ChangeStatus = "landed" | "waiting" | "denied" | "conflict" | "readonly" | "rejected"
const STATUS_LABEL: Record<Exclude<ChangeStatus, "waiting">, string> = {
  landed: "落下了", denied: "被拒，没落", conflict: "冲突，没落", readonly: "只读，没落", rejected: "没落下",
}

interface BaseEntry { hash: string; size: number; mtimeMs: number }
interface Owner { device: string; deviceName: string; profileId: string; title: string }
interface Receipt { at: number; status: Exclude<ChangeStatus, "waiting">; path: string; final?: string; message: string; saved?: string }
interface State { v: 1; owner: Owner; digest: string; syncedAt: number; base: Record<string, BaseEntry>; receipts: Receipt[] }

interface Pending { op: "write" | "delete"; hash: string | null; mtimeMs: number; tooBig?: boolean; content?: string }
interface Incoming<S> { sync: string; from: S; owner: Owner; digest: string; manifest: Map<string, string>; need: Set<string>; fresh: boolean
  touched: number; written: number; complete: boolean; gotManifest: boolean }
interface Floor<S> { name: string; dir: string; state: State | null; socket: S | null; incoming: Incoming<S> | null
  /// 送出去还没结果的：路径 → 那一笔的编号和现在到哪一步
  inflight: Map<string, { id: string; waiting: boolean; message: string }>
  /// 花园已经给过最终结果的那一笔（路径 → 编号）：盘上还是那一版就不再送（没能恢复成花园的样子时才会留在这）
  done: Map<string, string>
  pending: Map<string, Pending>; receiptsText: string }

export function treeHash(content: string): string {
  return createHash("sha256").update(content, "utf8").digest("hex").slice(0, 32)
}

export function changeId(path: string, op: string, base: string | null, hash: string | null): string {
  return treeHash([path, op, base ?? "", hash ?? ""].join("\n")).slice(0, 16)
}

// 单层名字：不含路径分隔 / 控制字符，不以点开头，不超长（同 garden-memory.ts 的楼层名）
function plainName(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max
    && !value.startsWith(".") && !/[\/\\\u0000-\u001f]/.test(value)
}

/// 树里的相对路径：一段一段都是正经名字，不往外跑，不进 _sync
export function validTreePath(path: unknown): path is string {
  if (typeof path !== "string" || path.length === 0 || path.length > 1024) return false
  const parts = path.split("/")
  if (parts[0] === SYNC_DIR) return false
  return parts.every((p) => p.length > 0 && p !== "." && p !== ".." && Buffer.byteLength(p, "utf8") <= 255 && !/[\\\u0000-\u001f]/.test(p))
}

function isRealDir(path: string): boolean {
  const s = lstatSync(path, { throwIfNoEntry: false })
  return !!s && s.isDirectory() && !s.isSymbolicLink()
}

/// 楼层文件夹里的一份文件的真路径；路上有链接（CC 家里谁放了个链接想让这里写到外面去）就不给
function safeTarget(dir: string, rel: string): string | null {
  let cur = dir
  const parts = rel.split("/")
  for (let i = 0; i < parts.length; i++) {
    cur = join(cur, parts[i])
    const s = lstatSync(cur, { throwIfNoEntry: false })
    if (!s) continue
    if (s.isSymbolicLink()) return null
    if (i < parts.length - 1 ? !s.isDirectory() : !s.isFile()) return null
  }
  return cur
}

function stamp(ms: number): string {
  const d = new Date(ms)
  const p = (n: number) => String(n).padStart(2, "0")
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

export class GardenTreeSync<S> {
  private floors = new Map<string, Floor<S>>()
  private dirty = true
  private lastScan = Number.NEGATIVE_INFINITY

  private readonly root: string
  private readonly now: () => number
  private readonly fallbackMs: number
  private readonly settleMs: number

  /// fallbackMs = 没有文件动静时多久也扫一遍（watch 漏事件的兜底）
  constructor(
    private readonly send: (to: S, frame: Record<string, unknown>) => void,
    options: { root?: string; now?: () => number; fallbackMs?: number; settleMs?: number } = {},
  ) {
    this.root = options.root ?? join(ccWorkdir(), GARDEN_MEMORY_DIR)
    this.now = options.now ?? Date.now
    this.fallbackMs = options.fallbackMs ?? 30_000
    this.settleMs = options.settleMs ?? GARDEN_TREE_SETTLE_MS
  }

  /// 盘上有动静（hub.ts 的 fs.watch）
  markDirty(): void { this.dirty = true }

  // MARK: - 帧

  /// 认得的帧返回 true
  onFrame(from: S, msg: any): boolean {
    switch (msg?.type) {
      case "garden_tree_hello": this.hello(from, msg); return true
      case "garden_tree_manifest": this.manifest(from, msg); return true
      case "garden_tree_files": this.files(from, msg); return true
      case "garden_tree_remove": this.remove(from, msg); return true
      case "garden_tree_change_result": this.results(from, msg); return true
      default: return false
    }
  }

  onClose(from: S): void {
    for (const f of this.floors.values()) {
      if (f.incoming?.from === from) f.incoming = null
      if (f.socket !== from) continue
      f.socket = null
      f.inflight.clear()
      this.writeReceipts(f)
    }
  }

  /// 定时调：有动静（或到了兜底周期）才扫盘；扫出待落的修改就送给连着的那台。没到扫的时候只把放稳了的送出去
  tick(): void {
    const t = this.now()
    const due = this.dirty || t - this.lastScan >= this.fallbackMs
    if (due) { this.dirty = false; this.lastScan = t }
    for (const name of due ? this.floorNames() : [...this.floors.keys()]) {
      const f = due ? this.floor(name) : this.floors.get(name)
      if (!f || !f.state) continue
      if (f.incoming) {
        if (t - f.incoming.touched < GARDEN_TREE_SYNC_STALE_MS) continue
        f.incoming = null
      }
      if (due) this.scan(f)
      else if (f.pending.size === f.inflight.size) continue
      this.flush(f)
      this.writeReceipts(f)
    }
  }

  private floorNames(): string[] {
    if (!isRealDir(this.root)) return []
    return readdirSync(this.root, { withFileTypes: true }).filter((e) => e.isDirectory() && plainName(e.name, 80)).map((e) => e.name)
  }

  private floor(name: string): Floor<S> | null {
    if (!plainName(name, 80)) return null
    let f = this.floors.get(name)
    const dir = join(this.root, name)
    if (!f) {
      f = { name, dir, state: null, socket: null, incoming: null, inflight: new Map(), done: new Map(), pending: new Map(), receiptsText: "" }
      this.floors.set(name, f)
      f.state = this.loadState(dir)
    } else if (f.state && !existsSync(join(dir, SYNC_DIR, STATE_FILE))) {
      // 文件夹被整个删了 / 换了：记着的那份作废
      f.state = null
      f.pending.clear()
      f.inflight.clear()
    } else if (!f.state) {
      f.state = this.loadState(dir)
    }
    return f
  }

  private loadState(dir: string): State | null {
    try {
      const raw = JSON.parse(readFileSync(join(dir, SYNC_DIR, STATE_FILE), "utf8"))
      if (raw?.v !== 1 || typeof raw.owner?.device !== "string" || typeof raw.owner?.profileId !== "string"
        || typeof raw.base !== "object" || raw.base === null || !Array.isArray(raw.receipts)) return null
      return { v: 1, owner: { device: raw.owner.device, deviceName: String(raw.owner.deviceName ?? ""), profileId: raw.owner.profileId, title: String(raw.owner.title ?? "") },
               digest: typeof raw.digest === "string" ? raw.digest : "", syncedAt: Number(raw.syncedAt) || 0, base: raw.base, receipts: raw.receipts }
    } catch { return null }
  }

  private saveState(f: Floor<S>): void {
    if (!f.state) return
    mkdirSync(join(f.dir, SYNC_DIR), { recursive: true })
    const path = join(f.dir, SYNC_DIR, STATE_FILE)
    writeFileSync(path + ".tmp", JSON.stringify(f.state))
    renameSync(path + ".tmp", path)
  }

  private reply(to: S, frame: Record<string, unknown>): void {
    try { this.send(to, frame) } catch {}
  }

  private ownerOf(msg: any): Owner | null {
    if (typeof msg.device !== "string" || msg.device.length === 0 || msg.device.length > 100) return null
    if (typeof msg.profile_id !== "string" || msg.profile_id.length === 0 || msg.profile_id.length > 200) return null
    return { device: msg.device, deviceName: String(msg.device_name ?? "").slice(0, 100), profileId: msg.profile_id, title: String(msg.title ?? msg.floor ?? "").slice(0, 100) }
  }

  /// 这层楼的文件夹现在跟的是不是这台设备的这层楼。不是、又没说要接手 → 拒（两台设备不能互相盖）
  private refusal(f: Floor<S>, owner: Owner, claim: boolean): Record<string, unknown> | null {
    const cur = f.state?.owner
    if (!cur || claim || (cur.device === owner.device && cur.profileId === owner.profileId)) return null
    return { ok: false, reason: "other_device", owner_name: cur.deviceName }
  }

  // MARK: - 花园 → 电脑

  private hello(from: S, msg: any): void {
    const f = this.floor(msg.floor)
    const owner = this.ownerOf(msg)
    if (!f || !owner) { this.reply(from, { type: "garden_tree_result", floor: msg.floor, ok: false, reason: "invalid" }); return }
    const no = this.refusal(f, owner, msg.claim === true)
    if (no) { this.reply(from, { type: "garden_tree_result", floor: f.name, ...no }); return }
    if (f.state && f.state.digest !== "" && f.state.digest === msg.digest && f.state.owner.device === owner.device && f.state.owner.profileId === owner.profileId) {
      this.attach(f, from)
      this.scan(f)
      this.reply(from, { type: "garden_tree_result", floor: f.name, ok: true, unchanged: true, files: Object.keys(f.state.base).length, written: 0, removed: 0, pending: f.pending.size })
      this.flush(f)
      this.writeReceipts(f)
      return
    }
    this.reply(from, { type: "garden_tree_need", floor: f.name, manifest: true })
  }

  private manifest(from: S, msg: any): void {
    const fail = (reason: string, extra: Record<string, unknown> = {}) =>
      this.reply(from, { type: "garden_tree_result", floor: msg.floor, sync: msg.sync, ok: false, reason, ...extra })
    const owner = this.ownerOf(msg)
    if (!owner || typeof msg.sync !== "string" || !Array.isArray(msg.files)) { fail("invalid"); return }
    this.adoptRenamed(msg.floor, owner)
    const f = this.floor(msg.floor)
    if (!f) { fail("invalid_floor"); return }
    const no = this.refusal(f, owner, msg.claim === true)
    if (no) { fail(String(no.reason), no); return }
    if (!f.incoming || f.incoming.sync !== msg.sync || f.incoming.from !== from) {
      f.incoming = { sync: msg.sync, from, owner, digest: typeof msg.digest === "string" ? msg.digest : "", manifest: new Map(), need: new Set(),
                     fresh: false, touched: this.now(), written: 0, complete: true, gotManifest: false }
    }
    const inc = f.incoming
    inc.touched = this.now()
    for (const e of msg.files) {
      if (!validTreePath(e?.path) || typeof e.hash !== "string" || inc.manifest.size >= GARDEN_TREE_MAX_FILES) { f.incoming = null; fail("invalid_file"); return }
      inc.manifest.set(e.path, e.hash)
    }
    if (msg.last !== true) return
    inc.gotManifest = true

    try {
      if (existsSync(this.root) && !isRealDir(this.root)) { f.incoming = null; fail("root_not_dir"); return }
      if (existsSync(f.dir) && !isRealDir(f.dir)) { f.incoming = null; fail("floor_not_dir"); return }
      mkdirSync(join(f.dir, SYNC_DIR), { recursive: true })
      // 家目录若是 git 仓库，这个文件夹不跟着走
      const ignore = join(this.root, ".gitignore")
      if (!existsSync(ignore)) writeFileSync(ignore, "*\n")
    } catch (err) { f.incoming = null; fail("write_failed"); console.warn(`[hub] garden_tree 建目录失败: ${err}`); return }

    const sameOwner = f.state?.owner.device === owner.device && f.state?.owner.profileId === owner.profileId
    // 没有可信的「上一版」（老格式的文件夹 / 状态丢了）：这一次照花园的整份摆，盘上多出来的不当成 CC 新写的
    inc.fresh = f.state === null
    if (!f.state) f.state = { v: 1, owner, digest: "", syncedAt: 0, base: {}, receipts: [] }
    if (!sameOwner) f.inflight.clear()
    f.state.owner = owner
    f.state.digest = ""
    this.saveState(f)
    this.scan(f)
    for (const [path, hash] of inc.manifest) {
      if (f.state.base[path]?.hash !== hash) inc.need.add(path)
    }
    const need = [...inc.need]
    if (need.length === 0) { this.commit(f); return }
    for (let i = 0; i < need.length; i += GARDEN_TREE_LIST_BATCH) {
      this.reply(from, { type: "garden_tree_need", floor: f.name, sync: inc.sync, paths: need.slice(i, i + GARDEN_TREE_LIST_BATCH), last: i + GARDEN_TREE_LIST_BATCH >= need.length })
    }
  }

  private files(from: S, msg: any): void {
    const f = this.floor(msg.floor)
    const inc = f?.incoming
    if (!f || !f.state || !inc || !inc.gotManifest || inc.from !== from || inc.sync !== msg.sync || !Array.isArray(msg.files)) return
    inc.touched = this.now()
    for (const file of msg.files) {
      const path = file?.path, content = file?.content
      if (typeof path !== "string" || typeof content !== "string" || !inc.need.has(path)) continue
      if (Buffer.byteLength(content, "utf8") > GARDEN_TREE_MAX_FILE_BYTES || treeHash(content) !== inc.manifest.get(path)) continue
      if (this.takeFromGarden(f, path, content, inc.fresh)) { inc.need.delete(path); inc.written += 1 }
    }
    if (msg.last === true) this.commit(f)
  }

  /// 花园的一份落到盘上。盘上那份 CC 改过还没落 = 冲突：CC 写的另存，文件换成花园的
  private takeFromGarden(f: Floor<S>, path: string, content: string, fresh: boolean): boolean {
    const hash = treeHash(content)
    const local = f.pending.get(path)
    if (local && !fresh && local.hash !== hash) {
      const mine = local.op === "write" ? this.readLocal(f, path) : null
      const saved = mine === null ? undefined : this.saveAside(f, path, mine)
      this.receipt(f, { status: "conflict", path, saved,
        message: local.op === "delete" ? "你删了这份，可花园里它在这之后改过；已经照花园的放回来了" : "花园里这份在你改的时候已经变了；文件已恢复成花园现在的样子" })
    }
    if (!this.writeLocal(f, path, content)) return false
    f.pending.delete(path)
    f.inflight.delete(path)
    return true
  }

  private commit(f: Floor<S>): void {
    const inc = f.incoming
    if (!inc || !f.state) return
    f.incoming = null
    let removed = 0
    for (const path of Object.keys(f.state.base)) {
      if (inc.manifest.has(path)) continue
      const local = f.pending.get(path)
      if (local?.op === "write" && !inc.fresh) {
        const mine = this.readLocal(f, path)
        this.receipt(f, { status: "conflict", path, saved: mine === null ? undefined : this.saveAside(f, path, mine), message: "花园里这份已经没有了；你改的没落下" })
      }
      this.removeLocal(f, path)
      delete f.state.base[path]
      f.pending.delete(path)
      f.inflight.delete(path)
      removed += 1
    }
    if (inc.fresh) {
      for (const path of this.walk(f.dir)) {
        if (!inc.manifest.has(path)) { this.removeLocal(f, path); f.pending.delete(path) }
      }
    }
    const complete = inc.need.size === 0
    f.state.digest = complete ? inc.digest : ""
    f.state.syncedAt = this.now()
    this.saveState(f)
    this.attach(f, inc.from)
    this.scan(f)
    this.reply(inc.from, { type: "garden_tree_result", floor: f.name, sync: inc.sync, ok: complete, ...(complete ? {} : { reason: "incomplete" }),
                           files: inc.manifest.size, written: inc.written, removed, pending: f.pending.size })
    console.log(`[hub] garden_tree ${f.name} ← ${inc.manifest.size} 份（写 ${inc.written} 删 ${removed}${complete ? "" : `，缺 ${inc.need.size}`}），待落 ${f.pending.size}`)
    this.flush(f)
    this.writeReceipts(f)
  }

  /// 同一台设备的同一层楼换了名字：把原来那个文件夹改过来（待落的修改跟着走）
  private adoptRenamed(name: unknown, owner: Owner): void {
    if (!plainName(name, 80) || existsSync(join(this.root, name))) return
    for (const other of this.floorNames()) {
      const g = this.floor(other)
      if (!g?.state || g.incoming || g.state.owner.device !== owner.device || g.state.owner.profileId !== owner.profileId) continue
      try { renameSync(g.dir, join(this.root, name)) } catch { return }
      this.floors.delete(other)
      return
    }
  }

  private remove(from: S, msg: any): void {
    const f = this.floor(msg.floor)
    const owner = this.ownerOf(msg)
    if (!f || !owner) return
    const cur = f.state?.owner
    if (cur && (cur.device !== owner.device || cur.profileId !== owner.profileId)) {
      this.reply(from, { type: "garden_tree_result", floor: f.name, ok: false, reason: "other_device", owner_name: cur.deviceName })
      return
    }
    const kept = this.keepUnlanded(f)
    try {
      if (kept === 0) { if (!existsSync(f.dir) || isRealDir(f.dir)) rmSync(f.dir, { recursive: true, force: true }) }
      else if (isRealDir(f.dir)) {
        // 只留 _sync（回执 + 另存的那几份）；树拿掉。状态里「花园给过哪些」清空（keepUnlanded 已清）：
        // 不清的话下一拍会把「文件都没了」当成 CC 删的，等花园再连上时送回去
        for (const e of readdirSync(f.dir)) if (e !== SYNC_DIR) rmSync(join(f.dir, e), { recursive: true, force: true })
      }
    } catch {}
    this.floors.delete(f.name)
    this.reply(from, { type: "garden_tree_result", floor: f.name, ok: true, removed_floor: true, files: 0, kept })
    if (kept > 0) console.log(`[hub] garden_tree ${f.name} 关了同步：${kept} 处没落进花园的修改留在 ${SYNC_DIR}/`)
  }

  /// 关同步之前：CC 在这里改了、还没落进花园的（没送 / 等她点 / 花园没连着）不跟着文件夹一起删——
  /// 写过的另存到 `_sync/没落下的/`，每一处记进回执。返回留下了几处
  private keepUnlanded(f: Floor<S>): number {
    if (!f.state || !isRealDir(f.dir)) return 0
    this.scan(f)
    if (f.pending.size === 0) return 0
    for (const [path, p] of f.pending) {
      const mine = p.op === "write" ? (p.content ?? this.readLocal(f, path)) : null
      this.receipt(f, { status: "rejected", path, saved: mine === null ? undefined : this.saveAside(f, path, mine),
        message: p.op === "delete" ? "花园那边关了同步，你删这份的事没送到花园；重新打开同步以后再删一次" : "花园那边关了同步，你写的没落进花园；重新打开同步以后照花园的样子再改一遍" })
    }
    const count = f.pending.size
    f.pending.clear()
    f.inflight.clear()
    f.socket = null
    f.state.base = {}
    f.state.digest = ""
    this.saveState(f)
    this.writeReceipts(f)
    return count
  }

  private attach(f: Floor<S>, socket: S): void {
    if (f.socket === socket) return
    f.socket = socket
    f.inflight.clear()
  }

  // MARK: - 盘上的文件

  /// 楼层文件夹里所有文件的相对路径（不进 _sync、不看点开头的——`.prompt` 除外、不跟链接）
  private walk(dir: string): string[] {
    const out: string[] = []
    const visit = (abs: string, rel: string) => {
      let entries: import("node:fs").Dirent[]
      try { entries = readdirSync(abs, { withFileTypes: true }) } catch { return }
      for (const e of entries) {
        if (rel === "" && e.name === SYNC_DIR) continue
        if (e.name.startsWith(".") && !(rel === "" && e.name === ".prompt")) continue
        const child = rel === "" ? e.name : rel + "/" + e.name
        if (e.isDirectory()) visit(join(abs, e.name), child)
        else if (e.isFile()) out.push(child)
      }
    }
    visit(dir, "")
    return out
  }

  private readLocal(f: Floor<S>, path: string): string | null {
    const target = safeTarget(f.dir, path)
    if (!target) return null
    try { return readFileSync(target, "utf8") } catch { return null }
  }

  private writeLocal(f: Floor<S>, path: string, content: string): boolean {
    if (!f.state || !validTreePath(path)) return false
    const target = safeTarget(f.dir, path)
    if (!target) { console.warn(`[hub] garden_tree 不写 ${f.name}/${path}：路上有链接或同名的文件夹`); return false }
    try {
      mkdirSync(dirname(target), { recursive: true })
      const tmp = join(dirname(target), `.tmp-${process.pid}-${this.now()}`)
      writeFileSync(tmp, content)
      renameSync(tmp, target)
      const s = lstatSync(target)
      f.state.base[path] = { hash: treeHash(content), size: s.size, mtimeMs: s.mtimeMs }
      return true
    } catch (err) {
      console.warn(`[hub] garden_tree 写 ${f.name}/${path} 失败: ${err}`)
      return false
    }
  }

  private removeLocal(f: Floor<S>, path: string): void {
    const target = safeTarget(f.dir, path)
    if (!target) return
    try { rmSync(target, { force: true }) } catch {}
    // 空了的文件夹一路收掉
    let dir = dirname(target)
    while (dir.startsWith(f.dir + "/")) {
      try { rmdirSync(dir) } catch { break }
      dir = dirname(dir)
    }
  }

  /// 盘上和「花园上次给的那一版」比：不一样的记进 f.pending
  private scan(f: Floor<S>): void {
    if (!f.state) return
    const base = f.state.base
    const found = new Map<string, Pending>()
    const seen = new Set<string>()
    for (const path of this.walk(f.dir)) {
      seen.add(path)
      // walk 不进链接、只列真文件：这里一份只 stat 一次（几千份的树每次有动静都要过一遍）
      const s = lstatSync(join(f.dir, path), { throwIfNoEntry: false })
      if (!s || !s.isFile()) continue
      const b = base[path]
      if (b && b.size === s.size && b.mtimeMs === s.mtimeMs) continue
      if (s.size > GARDEN_TREE_MAX_FILE_BYTES) { found.set(path, { op: "write", hash: null, mtimeMs: s.mtimeMs, tooBig: true }); continue }
      const was = f.pending.get(path)
      const content = was && was.mtimeMs === s.mtimeMs && was.content !== undefined ? was.content : this.readLocal(f, path)
      if (content === null) continue
      const hash = treeHash(content)
      if (b && b.hash === hash) { b.size = s.size; b.mtimeMs = s.mtimeMs; continue }
      found.set(path, { op: "write", hash, mtimeMs: s.mtimeMs, content })
    }
    for (const path of Object.keys(base)) {
      if (!seen.has(path)) found.set(path, { op: "delete", hash: null, mtimeMs: f.pending.get(path)?.mtimeMs ?? this.now() })
    }
    f.pending = found
    const idNow = (path: string) => { const p = found.get(path); return p ? changeId(path, p.op, base[path]?.hash ?? null, p.hash) : null }
    for (const path of [...f.inflight.keys()]) if (idNow(path) !== f.inflight.get(path)!.id) f.inflight.delete(path)
    for (const path of [...f.done.keys()]) if (idNow(path) !== f.done.get(path)) f.done.delete(path)
  }

  // MARK: - 电脑 → 花园

  /// 待落的修改送给连着的那台（放稳了的、还没送过的）
  private flush(f: Floor<S>): void {
    if (!f.state || !f.socket || f.incoming) return
    const t = this.now()
    let batch: Record<string, unknown>[] = []
    let bytes = 0
    const sendBatch = () => {
      if (batch.length === 0) return
      this.reply(f.socket!, { type: "garden_tree_changes", floor: f.name, profile_id: f.state!.owner.profileId, changes: batch })
      batch = []
      bytes = 0
    }
    for (const [path, p] of f.pending) {
      if (p.tooBig || t - p.mtimeMs < this.settleMs) continue
      const base = f.state.base[path]?.hash ?? null
      const id = changeId(path, p.op, base, p.hash)
      if (f.inflight.get(path)?.id === id || f.done.get(path) === id) continue
      const size = Buffer.byteLength(p.content ?? "", "utf8") + path.length + 200
      if (bytes + size > GARDEN_TREE_FRAME_BYTES) sendBatch()
      batch.push({ id, path, op: p.op, base, ...(p.op === "write" ? { content: p.content ?? "" } : {}) })
      bytes += size
      f.inflight.set(path, { id, waiting: false, message: "" })
    }
    sendBatch()
  }

  private results(from: S, msg: any): void {
    const f = this.floor(msg.floor)
    if (!f || !f.state || f.socket !== from || !Array.isArray(msg.results)) return
    this.scan(f)
    for (const r of msg.results) {
      const origin = r?.from
      if (typeof r?.id !== "string" || !validTreePath(origin) || typeof r.status !== "string") continue
      const message = typeof r.message === "string" ? r.message : ""
      if (r.status === "waiting") {
        const flight = f.inflight.get(origin)
        if (flight?.id === r.id) { flight.waiting = true; flight.message = message }
        continue
      }
      if (!(r.status in STATUS_LABEL)) continue
      const status = r.status as Exclude<ChangeStatus, "waiting">
      const final = validTreePath(r.path) ? r.path : origin
      const content: string | null = typeof r.content === "string" ? r.content : null
      const p = f.pending.get(origin)
      // 盘上还是送过去的那一版吗（这中间 CC 又改了就不是了）
      const untouched = p ? changeId(origin, p.op, f.state.base[origin]?.hash ?? null, p.hash) === r.id : false
      let saved: string | undefined
      if (untouched) {
        if (status !== "landed" && p!.op === "write" && p!.content !== undefined) saved = this.saveAside(f, origin, p!.content)
        if (final !== origin || content === null) { this.removeLocal(f, origin); delete f.state.base[origin] }
        if (content !== null) this.writeLocal(f, final, content)
        f.pending.delete(origin)
      } else if (content !== null) {
        // 这中间 CC 又动过：文件不碰，只记下花园现在是哪一版，它后来改的那份会当成新的一笔再送
        const at = final === origin ? origin : final
        if (final !== origin) this.writeLocal(f, final, content)
        else f.state.base[at] = { hash: treeHash(content), size: -1, mtimeMs: -1 }
      } else {
        delete f.state.base[origin]
      }
      f.inflight.delete(origin)
      f.done.set(origin, r.id)
      f.state.digest = ""
      this.receipt(f, { status, path: origin, ...(final !== origin ? { final } : {}), message, saved })
    }
    this.saveState(f)
    this.scan(f)
    this.flush(f)
    this.writeReceipts(f)
  }

  /// CC 写的那一版另存到回执旁边
  private saveAside(f: Floor<S>, path: string, content: string): string | undefined {
    const d = new Date(this.now())
    const p = (n: number) => String(n).padStart(2, "0")
    const name = `${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}-${path.replaceAll("/", "__")}`.slice(0, 200)
    try {
      mkdirSync(join(f.dir, SYNC_DIR, SAVED_DIR), { recursive: true })
      let file = name
      for (let i = 2; existsSync(join(f.dir, SYNC_DIR, SAVED_DIR, file)); i++) file = `${i}-${name}`
      writeFileSync(join(f.dir, SYNC_DIR, SAVED_DIR, file), content)
      return `${SYNC_DIR}/${SAVED_DIR}/${file}`
    } catch { return undefined }
  }

  private receipt(f: Floor<S>, r: Omit<Receipt, "at">): void {
    if (!f.state) return
    f.state.receipts.unshift({ at: this.now(), ...r })
    for (const old of f.state.receipts.splice(GARDEN_TREE_RECEIPTS_KEEP)) {
      if (old.saved) { try { rmSync(join(f.dir, old.saved), { force: true }) } catch {} }
    }
  }

  /// `_sync/收件回执.md`：还没落的 + 每一笔的结果。内容没变不重写
  private writeReceipts(f: Floor<S>): void {
    if (!f.state || !isRealDir(f.dir)) return
    const s = f.state
    const lines = [`# 收件回执 · ${s.owner.title || f.name}`, "",
      "你在这个文件夹里改、新建、删掉的文件会送回花园去落。这里是每一笔的结果，新的在前。",
      `花园：${s.owner.deviceName || "（没报名字）"} · ${f.socket ? "连着" : "没连着（连上以后按顺序送）"}${s.syncedAt ? ` · 上次同步 ${stamp(s.syncedAt)}` : ""}`, "",
      `## 还没落进花园（${f.pending.size}）`, ""]
    if (f.pending.size === 0) lines.push("没有等着的修改。")
    for (const [path, p] of f.pending) {
      const what = p.op === "delete" ? "删除" : s.base[path] ? "修改" : "新建"
      const flight = f.inflight.get(path)
      const where = p.tooBig ? `超过 ${GARDEN_TREE_MAX_FILE_BYTES / 1024}KB，没送`
        : f.done.has(path) ? "花园已经回过结果（见下面），但这份没能摆回花园的样子，要手动处理"
        : !f.socket ? "花园没连着，连上就送"
        : flight?.waiting ? `已送到花园，等她点允许${flight.message ? `（${flight.message}）` : ""}`
        : flight ? "已送到花园，等结果" : "马上送"
      lines.push(`- ${path} · ${what} · ${where}`)
    }
    lines.push("", "## 结果", "")
    if (s.receipts.length === 0) lines.push("还没有。")
    for (const r of s.receipts) {
      const moved = r.final ? ` → ${r.final}` : ""
      const saved = r.saved ? `；你写的那份在 ${r.saved}` : ""
      lines.push(`- ${stamp(r.at)} · ${STATUS_LABEL[r.status]} · ${r.path}${moved}${r.message ? `：${r.message}` : ""}${saved}`)
    }
    const text = lines.join("\n") + "\n"
    if (text === f.receiptsText) return
    try {
      mkdirSync(join(f.dir, SYNC_DIR), { recursive: true })
      writeFileSync(join(f.dir, SYNC_DIR, RECEIPTS_FILE), text)
      f.receiptsText = text
    } catch {}
  }
}
