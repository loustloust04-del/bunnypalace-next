/// 终端流（#087）：每个被看的会话挂一个只读控制客户端（`tmux -C attach -f ignore-size,read-only`），
/// 增量走它的 `%output`，快照（capture-pane + 光标）也在同一条连接上发。
///
/// 为什么不用 pipe-pane → fifo：那是两条互不相干的通道，快照抓的是「执行 capture 那一刻」的屏幕，
/// 增量是 fifo 里流过来的字节，hub 没法知道哪些字节已经在快照里了 —— 快照之前流出去的会被客户端的
/// reset 抹掉、快照里已有的又被增量重放一遍，Claude Code 这种相对光标重绘一错位就是重复行 / 吞行（复现：
/// docs/research-terminal-render-fix.md §2.1）。控制模式里 tmux 把 %output 和命令回包按产生顺序排进
/// 同一条输出（control.c all_blocks），在 capture 回包之前到的 %output 一定已经画进快照，之后到的一定没有：
/// 快照边界就是回包在流里的位置，`snapshot()` 的回调在这个位置同步调用。
///
/// 子进程用 node:child_process 起，不用 Bun.spawn：Bun 1.3.11 下多一个 Bun.spawn 管道子进程起停之后，
/// 共享控制连接（tmux-control.ts）的 stdout 偶发再也不被读（netstat 看到 Recv-Q 堆着回包、读循环不醒，
/// hub-terminal.test 约 1/4 卡死）；换 node 流 12/12 不再出现。

import { spawn, type ChildProcessByStdio } from "node:child_process"
import type { Readable, Writable } from "node:stream"
import { tmuxSocketArgs } from "./tmux-control"

export interface PaneSnapshotRaw {
  /// capture-pane -p -e -S -200 原样输出
  capture: string
  /// SNAPSHOT_META_FORMAT 去掉开头的 pane_id 之后的部分（hub.ts formatSnapshot 解析）
  meta: string
  /// 备用屏启用时 tmux 保存的主屏，退出备用屏要回到这里
  mainCapture: string
}

export interface PaneStreamHandlers {
  /// 当前 pane 的输出字节（按产生顺序）
  onOutput: (bytes: Buffer) => void
  /// 控制客户端没了（会话结束 / 被关 / 起不来），只调一次
  onExit: (reason: string) => void
}

/// `%output %<pane> <data>`：小于 0x20 的字节和 `\` 写成 `\ooo`，0x80 以上原样（必须按字节解，不能先 TextDecoder）
export function decodeControlOutput(line: Uint8Array, from: number): Buffer {
  const out = Buffer.allocUnsafe(line.length - from)
  let n = 0
  for (let i = from; i < line.length; i++) {
    const b = line[i]
    if (b === 0x5c && i + 3 < line.length) {
      const d0 = line[i + 1] - 0x30, d1 = line[i + 2] - 0x30, d2 = line[i + 3] - 0x30
      if (d0 >= 0 && d0 < 8 && d1 >= 0 && d1 < 8 && d2 >= 0 && d2 < 8) {
        out[n++] = d0 * 64 + d1 * 8 + d2
        i += 3
        continue
      }
    }
    out[n++] = b
  }
  return out.subarray(0, n)
}

interface PendingSnapshot {
  onBoundary: (raw: PaneSnapshotRaw) => void
  resolve: () => void
  reject: (e: Error) => void
  /// 超时 / 关掉之后回包才到：照样按先进先出吃掉，不再回调
  dead: boolean
  replies: { ok: boolean; text: string }[]
}

/// 光标、鼠标上报，以及 capture-pane 不带、但之后的增量要靠它们才画得对的终端状态（光标显隐、滚动区、备用屏）
export const SNAPSHOT_META_FORMAT = "#{pane_id} #{cursor_x} #{cursor_y} #{mouse_any_flag} #{cursor_flag} #{scroll_region_upper} #{scroll_region_lower} #{alternate_on} #{pane_height} #{alternate_saved_x} #{alternate_saved_y}"
const OUTPUT_PREFIX = Buffer.from("%output %")

export class PaneStream {
  /// 控制客户端握手完成（attach 命令的初始块回来了）
  readonly ready: Promise<void>
  private proc: ChildProcessByStdio<Writable, Readable, null> | null = null
  private attached = false
  private exited = false
  private queue: PendingSnapshot[] = []
  /// 只转这个 pane 的输出；第一次快照之前不知道是哪个，那时也还没有观众，丢掉无妨
  private paneId: string | null = null
  private block: { tail: string; flags: string; lines: Buffer[] } | null = null

  constructor(readonly session: string, private readonly handlers: PaneStreamHandlers,
              tmuxArgs: string[] = ["-u", ...tmuxSocketArgs()]) {
    let markReady: () => void = () => {}
    let failReady: (e: Error) => void = () => {}
    this.ready = new Promise<void>((res, rej) => { markReady = res; failReady = rej })
    this.ready.catch(() => {})
    const env: Record<string, string | undefined> = { ...process.env }
    delete env.TMUX
    delete env.TMUX_PANE
    let proc: ChildProcessByStdio<Writable, Readable, null>
    try {
      // read-only：这条连接只看不写，挡掉任何误发的按键；ignore-size：不参与窗口尺寸（尺寸由 hub 的 resize-window 管）
      // 中间垫两只 cat：控制客户端会把自己的 stdin / stdout 交给 tmux server 直接读写，不垫的话 server 拿着的就是
      // hub 这边管道的对端，客户端退出后 server 还会往里补写、迟迟不关（netstat 一串 Recv-Q 29 的孤儿 socket），
      // Bun 对这种「子进程已退出还有人写」的管道处理不好，连带共享控制连接的回包也不再被读（#087 合跑测试卡死）。
      // 垫了 cat，server 拿到的是 cat 之间的管道，hub 的管道只连着 cat，退出时干净 EOF。自成进程组，收尾按组杀
      proc = spawn("sh", ["-c", 'cat | "$@" | cat', "sh",
                          "tmux", ...tmuxArgs, "-C", "attach-session", "-E", "-t", `=${session}`, "-f", "ignore-size,read-only"],
        { stdio: ["pipe", "pipe", "ignore"], env, detached: true })
    } catch (e) {
      this.exited = true
      failReady(new Error(`spawn: ${(e as Error).message}`))
      queueMicrotask(() => handlers.onExit(`spawn: ${(e as Error).message}`))
      return
    }
    this.proc = proc
    // attach 本身的回包：%end = 接上了；%error（会话不存在等）= 失败，tmux 随后自己退出
    this.onInitialBlock = (ok, text) => {
      if (ok) {
        this.attached = true
        this.onInitialPane = (ok, pane) => {
          if (ok && /^%\d+$/.test(pane.trim())) { this.paneId = pane.trim(); markReady() }
          else { failReady(new Error(pane.trim() || "pane lookup failed")); void this.close() }
        }
        proc.stdin.write('display-message -p "#{pane_id}"\n')
      } else { this.attachError = text.trim() || "attach failed" }
    }
    void this.readLoop(proc).then(() => {
      const reason = this.attachError || "eof"
      this.exited = true
      failReady(new Error(reason))
      for (const p of this.queue.splice(0)) if (!p.dead) { p.dead = true; p.reject(new Error(`pane stream closed: ${reason}`)) }
      handlers.onExit(reason)
    })
  }

  private onInitialBlock: ((ok: boolean, text: string) => void) | null = null
  private onInitialPane: ((ok: boolean, text: string) => void) | null = null
  private attachError = ""

  /// 抓一屏快照。`onBoundary` 在流里的快照位置同步调用：之前收到的 onOutput 都已经画进这屏，之后的都没有
  snapshot(onBoundary: (raw: PaneSnapshotRaw) => void, timeoutMs: number): Promise<void> {
    if (this.exited || !this.proc || !this.paneId) return Promise.reject(new Error("pane stream closed"))
    const pane = this.paneId
    // tmux 按 pane 配额发送；其他 pane 的积压会挡住回包，让目标 pane 的新输出越过快照边界。
    // 在 tmux 内一次展开全部窗口/pane，只关闭此客户端对其他 pane 的输出；目标 pane 的队列不丢。
    const onlyPane = `run-shell -C 'refresh-client #{W:#{P:#{?#{==:#{pane_id},${pane}},, -A "#{pane_id}:pause"}}}'`
    const command = `${onlyPane} ; capture-pane -t "${pane}" -p -e -S -200 ; capture-pane -t "${pane}" -p -e -a -q -S -200 ; display-message -t "${pane}" -p "${SNAPSHOT_META_FORMAT}"`
    return new Promise<void>((resolve, reject) => {
      const p: PendingSnapshot = { onBoundary, resolve, reject, dead: false, replies: [] }
      const timer = setTimeout(() => {
        if (p.dead) return
        p.dead = true
        reject(new Error(`snapshot timeout ${timeoutMs}ms`))
      }, timeoutMs)
      p.resolve = () => { clearTimeout(timer); resolve() }
      p.reject = (e) => { clearTimeout(timer); reject(e) }
      this.queue.push(p)
      try {
        this.proc!.stdin.write(command + "\n")
      } catch (e) {
        this.queue.splice(this.queue.indexOf(p), 1)
        p.dead = true
        p.reject(new Error(`write: ${(e as Error).message}`))
      }
    })
  }

  /// 关：关 stdin 让控制客户端自己退。只对已经握手完的补 SIGKILL —— 握手中被杀的控制客户端，
  /// tmux 3.6a 之后给它发通知会空指针崩掉整个 server（tmux-control.ts drop() 同一条）
  /// 返回值在控制客户端进程退出后 resolve
  close(): Promise<void> {
    const proc = this.proc
    if (!proc) return Promise.resolve()
    const gone = this.exited || proc.exitCode !== null || proc.signalCode !== null
      ? Promise.resolve()
      : new Promise<void>(r => proc.once("exit", () => r()))
    try { proc.stdin.end() } catch {}
    if (this.exited) return gone
    if (this.attached) {
      const t = setTimeout(() => { if (!this.exited && proc.pid) { try { process.kill(-proc.pid, "SIGKILL") } catch {} } }, 1_500)
      void gone.then(() => clearTimeout(t))
    }
    return gone
  }

  private readLoop(proc: ChildProcessByStdio<Writable, Readable, null>): Promise<void> {
    let pending: Buffer = Buffer.alloc(0)
    proc.stdout.on("data", (value: Buffer) => {
      const buf = pending.length ? Buffer.concat([pending, value]) : value
      let start = 0
      for (let i = buf.indexOf(0x0a, start); i >= 0; i = buf.indexOf(0x0a, start)) {
        this.onLine(buf.subarray(start, i))
        start = i + 1
      }
      pending = start < buf.length ? Buffer.from(buf.subarray(start)) : Buffer.alloc(0)
    })
    // 管道写端出错（控制客户端已经退了还在写）只当它没了，别让 'error' 事件冒成未捕获异常把 hub 带走
    proc.stdin.on("error", () => {})
    return new Promise<void>(resolve => {
      let done = false
      const finish = () => {
        if (done) return
        done = true
        // stdout 读完（或进程退出 200ms 后）两头都主动关掉：stdout 先 EOF 时前面那只 cat 还在等 stdin，关了它才退
        try { proc.stdout.destroy() } catch {}
        try { proc.stdin.destroy() } catch {}
        resolve()
      }
      proc.stdout.on("close", finish)
      proc.on("exit", () => setTimeout(finish, 200))
      proc.on("error", finish)   // 起不来（ENOENT 等）
    })
  }

  private onLine(line: Buffer): void {
    if (this.block) {
      const s = line.toString("utf8")
      if (s !== "%end" + this.block.tail && s !== "%error" + this.block.tail) { this.block.lines.push(line); return }
      const { flags, lines } = this.block
      this.block = null
      this.onBlock(flags, s.startsWith("%end"), Buffer.concat(lines.flatMap((l, i) => i ? [Buffer.from("\n"), l] : [l])).toString("utf8"))
      return
    }
    if (line.subarray(0, OUTPUT_PREFIX.length).equals(OUTPUT_PREFIX)) {
      const sp = line.indexOf(0x20, OUTPUT_PREFIX.length)
      if (sp < 0) return
      const pane = line.subarray(OUTPUT_PREFIX.length - 1, sp).toString("latin1")
      if (pane !== this.paneId) return
      this.handlers.onOutput(decodeControlOutput(line, sp + 1))
      return
    }
    const s = line.toString("utf8")
    // 控制客户端要退了（会话没了 / attach 失败 / 被关）：关掉我们这头的 stdin，前面那只 cat 才退，整条管道收尾
    if (s === "%exit" || s.startsWith("%exit ")) { try { this.proc?.stdin.end() } catch {}; return }
    if (s.startsWith("%begin ")) {
      const tail = s.slice("%begin".length)
      this.block = { tail, flags: tail.slice(tail.lastIndexOf(" ") + 1), lines: [] }
    }
  }

  /// flags=1 是 stdin 发的命令；0 是 attach 本身（第一个）或 hook 产生的块，丢掉
  private onBlock(flags: string, ok: boolean, text: string): void {
    if (flags !== "1") {
      const init = this.onInitialBlock
      this.onInitialBlock = null
      init?.(ok, text)
      return
    }
    const initialPane = this.onInitialPane
    if (initialPane) { this.onInitialPane = null; initialPane(ok, text); return }
    const p = this.queue[0]
    if (!p) return
    p.replies.push({ ok, text })
    // 一行里的命令表前一条出错，后面的 tmux 不再执行、也不回包：capture 失败就只有这一个块
    // run-shell 与它插入的 refresh-client 各回一块，接着当前屏、保存的主屏、元数据。
    if (p.replies.length < 5 && ok) return
    this.queue.shift()
    if (p.dead) return
    const failed = p.replies.find(r => !r.ok)
    if (failed) { p.dead = true; p.reject(new Error(failed.text || "snapshot failed")); return }
    const [, , cap, main, meta] = p.replies
    const metaParts = meta.text.trim().split(/\s+/)
    if (metaParts[0]?.startsWith("%")) this.paneId = metaParts[0]
    p.dead = true
    // capture 回包按 fork 时 stdout 的样子还原：每行带 \n
    try { p.onBoundary({ capture: cap.text.length ? cap.text + "\n" : "", mainCapture: main.text.length ? main.text + "\n" : "", meta: metaParts.slice(1).join(" ") }) }
    catch (e) { p.reject(e as Error); return }
    p.resolve()
  }
}
