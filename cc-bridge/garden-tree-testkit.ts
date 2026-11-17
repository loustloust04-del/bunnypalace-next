// 测试用的假花园（garden-tree.test.ts / garden-tree-hub.test.ts 共用）：照 app 那头的规矩收发 garden_tree_* 帧。
// 规矩是 app 的缩小版：花园是准（指纹对不上 = 冲突）、时间轴和 README 只读、新建的记忆条目落下后文件名换成它的编号、
// 「每次询问」那一档先回 waiting 等人点。全虚构。
import { GARDEN_TREE_FRAME_BYTES, GARDEN_TREE_LIST_BATCH, treeHash } from "./garden-tree.ts"

type Frame = Record<string, any>
export type Policy = "allow" | "ask" | "deny"

export class FakeGarden {
  files = new Map<string, string>()
  /// 收到过的每一帧（按到的先后）
  seen: Frame[] = []
  waiting = new Map<string, Frame>()
  policy: (path: string) => Policy = () => "allow"
  private nextCard = 1
  private syncNo = 0
  private claim = false
  private snapshot = new Map<string, string>()
  private waiters: Array<{ match: (f: Frame) => boolean; resolve: (f: Frame) => void }> = []

  constructor(
    private readonly send: (frame: Frame) => void,
    readonly floor = "星砚楼",
    readonly device = "device-a",
    readonly deviceName = "岚舟的手机",
    readonly profileId = "floor-xingyan",
  ) {}

  private head(): Frame {
    return { floor: this.floor, title: this.floor, device: this.device, device_name: this.deviceName, profile_id: this.profileId }
  }

  private manifestOf(files: Map<string, string>): { path: string; hash: string }[] {
    return [...files].map(([path, content]) => ({ path, hash: treeHash(content) }))
  }

  private digest(files: Map<string, string>): string {
    return treeHash(this.manifestOf(files).map((e) => `${e.path}\t${e.hash}`).sort().join("\n"))
  }

  /// 等一帧
  next(match: (f: Frame) => boolean, ms = 3000): Promise<Frame> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("等帧超时")), ms)
      this.waiters.push({ match, resolve: (f) => { clearTimeout(timer); resolve(f) } })
    })
  }

  /// 同步一次，等 hub 回结果
  async sync(claim = false): Promise<Frame> {
    this.snapshot = new Map(this.files)
    this.claim = claim
    const done = this.next((f) => f.type === "garden_tree_result" && f.floor === this.floor)
    this.send({ type: "garden_tree_hello", ...this.head(), digest: this.digest(this.snapshot), ...(claim ? { claim: true } : {}) })
    return done
  }

  remove(): void { this.send({ type: "garden_tree_remove", ...this.head() }) }

  receive(frame: Frame): void {
    this.seen.push(frame)
    if (frame.type === "garden_tree_need" && frame.manifest === true) {
      const sync = `s${++this.syncNo}`
      const list = this.manifestOf(this.snapshot)
      const digest = this.digest(this.snapshot)
      for (let i = 0; i === 0 || i < list.length; i += GARDEN_TREE_LIST_BATCH) {
        this.send({ type: "garden_tree_manifest", ...this.head(), sync, digest, claim: this.claim, files: list.slice(i, i + GARDEN_TREE_LIST_BATCH), last: i + GARDEN_TREE_LIST_BATCH >= list.length })
      }
    } else if (frame.type === "garden_tree_need") {
      let batch: Frame[] = []
      let bytes = 0
      const flush = (last: boolean) => { this.send({ type: "garden_tree_files", floor: this.floor, sync: frame.sync, files: batch, last }); batch = []; bytes = 0 }
      for (const path of frame.paths as string[]) {
        const content = this.snapshot.get(path)
        if (content === undefined) continue
        const size = Buffer.byteLength(content, "utf8")
        if (bytes > 0 && bytes + size > GARDEN_TREE_FRAME_BYTES) flush(false)
        batch.push({ path, content })
        bytes += size
      }
      if (frame.last === true) flush(true)
      else if (batch.length > 0) flush(false)
    } else if (frame.type === "garden_tree_changes") {
      const results: Frame[] = []
      for (const c of frame.changes as Frame[]) {
        for (const [id, w] of this.waiting) if (w.path === c.path) this.waiting.delete(id)
        results.push(this.judge(c, false))
      }
      this.send({ type: "garden_tree_change_result", floor: this.floor, results })
    }
    for (const w of this.waiters.filter((w) => w.match(frame))) {
      this.waiters.splice(this.waiters.indexOf(w), 1)
      w.resolve(frame)
    }
  }

  /// 她点了：允许 / 拒绝一笔等着的
  answer(id: string, allow: boolean): void {
    const c = this.waiting.get(id)
    if (!c) return
    this.waiting.delete(id)
    const r = allow ? this.judge(c, true) : this.result(c, "denied", "她没允许这一笔", c.path)
    this.send({ type: "garden_tree_change_result", floor: this.floor, results: [r] })
  }

  private result(c: Frame, status: string, message: string, path: string): Frame {
    return { id: c.id, from: c.path, status, message, path, content: this.files.get(path) ?? null }
  }

  private judge(c: Frame, approved: boolean): Frame {
    const path: string = c.path
    const current = this.files.get(path)
    if (path === "README.md" || path.startsWith("memory/timeline/")) return this.result(c, "readonly", "这份是花园自己排的，只读", path)
    if (!path.startsWith("memory/") && !path.startsWith(".prompt/")) return this.result(c, "readonly", "这棵树里只有 memory/ 和 .prompt/", path)
    if ((current === undefined ? null : treeHash(current)) !== c.base) return this.result(c, "conflict", "花园里这份已经不是你改的那一版了", path)
    if (!approved) {
      const policy = this.policy(path)
      if (policy === "deny") return this.result(c, "denied", "这一档是不允许", path)
      if (policy === "ask") { this.waiting.set(c.id, c); return { id: c.id, from: path, status: "waiting", message: "等她点", path, content: current ?? null } }
    }
    if (c.op === "delete") {
      this.files.delete(path)
      return this.result(c, "landed", "", path)
    }
    const bad = (c.content as string).split("\n").find((line) => line.includes("格式坏"))
    if (bad !== undefined) return this.result(c, "rejected", `这一行认不出来：${bad}`, path)
    const normalized = (c.content as string).trimEnd() + "\n"
    const card = /^memory\/cards\/([^/]+)\/[^/]+\.md$/.exec(path)
    if (card && current === undefined) {
      const final = `memory/cards/${card[1]}/c${String(this.nextCard++).padStart(7, "0")}.md`
      this.files.set(final, normalized)
      return this.result(c, "landed", "新加了一条记忆条目", final)
    }
    this.files.set(path, normalized)
    return this.result(c, "landed", "", path)
  }
}
