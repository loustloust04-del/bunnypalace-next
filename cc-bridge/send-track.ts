/// K1 第 4b 步 · 审查 R1（docs/plan-hub-perf.md，perf/hub-实验日志.md「K1 第 4b 步 · 审查 R1」）：发一条消息，结果不明时核对送达。
///
/// 原则：「这次查不到」不等于「没进去」。只有**确定没执行**的写才自动重发一次（tmux 明确答错；粘贴的临时缓冲区落定后还在 = paste-buffer 没跑过）。
/// - 已执行（回执晚到 / 缓冲区被 -d 用掉了 / 输入框里认出了这次的记号）：字节已交给终端，等消费 → 补回车 → 确认，绝不重注入；
/// - 不确定：有界窗口里轮询 transcript（从发送前的位置往后）和当前输入框，看到了就接着走；窗口完了判 failed（retryable），不重发。
/// 失败 ≠ 会话能接着注入：失败后会话继续堵着，直到某次读屏确认输入框里没有这条（最多 2 分钟，到点放行并记日志、补一句原因）。
/// 这一切都在 hub 的 chainSessionSend 里跑：后面的消息在它之后才注入，不粘连、不乱序
import { TmuxCommandError, TmuxUncertainError, type WriteFate } from "./tmux-control"
import {
  channelIds, hasMarker, PASTE_PLACEHOLDER_RE, TranscriptScanner, withMarker,
  type ActiveOp, type EditArea, type Outcome, type SendMarker, type SendStatusBook, type TranscriptCursor,
} from "./send-verify"

/// 一次完整发送（注入 + 回车 + 原有核对）的结果。注入失败照旧抛：TmuxCommandError = 确定没执行，TmuxUncertainError = 不明
export interface InjectResult {
  /// 回车之后有没有确认提交上（原有的占位 / 指纹检查；读屏失败也算 false，不当空屏）
  committed: boolean
  /// 走的粘贴路径（长文本 / 多行）
  paste: boolean
}

export interface TrackDeps {
  inject(text: string, session: string): Promise<InjectResult>
  /// 输入框里已经有字了，补回车（原有提交路径）；true = 提交上了
  submit(text: string, session: string, paste: boolean): Promise<boolean>
  settle(err: TmuxUncertainError, deadlineAt: number): Promise<WriteFate>
  /// 粘贴的临时缓冲区还在不在（undefined = 查不了）
  bufferExists(name: string): Promise<boolean | undefined>
  deleteBuffer(name: string): Promise<void>
  /// 发送前记 transcript 位置（有界，等不到 = undefined）
  cursor(session: string): Promise<TranscriptCursor | undefined>
  editArea(session: string): Promise<EditArea>
  /// 会话代次（每次重新拉起 +1）：核对途中变了 = 换了个会话，旧核对不许再往里写
  generation(session: string): number | undefined
  /// 会话已经不在了：清就绪态，下一条消息走重新拉起
  sessionGone(session: string): void
  /// 重发途中会话没了：交回原有发送路径（重新拉起 + 排队），身份留在账上
  requeue(session: string, text: string): void
  legacyError(session: string, messageId: string | undefined, reason: string): void
  sleep(ms: number): Promise<void>
  now(): number
}

export interface TrackTimings {
  /// 每次等原写入落定最多多久
  settleMs: number
  /// 不确定 / 已执行时轮询确认的窗口
  confirmMs: number
  /// 已执行但认不出输入框时，等多久就当终端已经消费了
  consumeMs: number
  /// 失败后会话最多再堵多久
  holdMs: number
  pollMs: number
  /// 接受的重发最多挂多久没结果就判 failed
  retryMaxMs: number
}

export const DEFAULT_TIMINGS: TrackTimings = { settleMs: 60_000, confirmMs: 20_000, consumeMs: 1_000, holdMs: 120_000, pollMs: 500, retryMaxMs: 300_000 }

const MAYBE_IN = "可能已经进去了，看一眼终端再决定要不要重发"

interface Ctx {
  session: string
  text: string
  marker: SendMarker
  messageId?: string
  /// 第几次发送（channel 标签的 ts）
  attempt?: string
  op?: ActiveOp
  cursor?: TranscriptCursor
  scanner: TranscriptScanner
  gen: number | undefined
  paste: boolean
  /// 当前这条结果不明的写（落定之前会话不能放行）
  pending?: TmuxUncertainError
  settled: boolean
  resent: boolean
}

type Step = { done: Outcome; hold: boolean } | { next: "executed" | "uncertain" | "not-executed" }

export class SendTracker {
  private readonly verifying = new Map<string, number>()

  constructor(readonly book: SendStatusBook, private readonly deps: TrackDeps, private readonly t: TrackTimings = DEFAULT_TIMINGS) {}

  /// 核对中 / 有进行中的重发：会话不能被回收
  busy(session: string): boolean { return (this.verifying.get(session) ?? 0) > 0 || this.book.busy(session) }

  /// app 的 retry 被接受后：挂看门狗，到点还没结果 → failed（每条出口都有终态，审查 R1-8）
  armRetry(op: ActiveOp): void {
    setTimeout(() => {
      if (this.book.finish(op, { status: "failed", retryable: true, reason: `重发 ${Math.round(this.t.retryMaxMs / 60_000)} 分钟没发出去（会话没拉起来？）` })) {
        console.warn(`[hub] 重发看门狗 ${op.messageId} → failed`)
      }
    }, this.t.retryMaxMs).unref?.()
  }

  /// 接受了的重发在注入前就失败（附件落盘、组帧…）
  abortRetry(messageId: string, reason: string): void {
    const op = this.book.active.get(messageId)
    if (op?.retry) this.book.finish(op, { status: "failed", retryable: true, reason })
  }

  /// 发一条（在 chainSessionSend 里）。正常发送：只多记一次 transcript 位置，注入 / 回车与原来逐字相同，不发 send_status
  async send(raw: string, session: string): Promise<void> {
    const { text, marker } = withMarker(raw)
    const { chatId = "", messageId, ts } = channelIds(text)
    const gen = this.deps.generation(session)
    const live = messageId !== undefined ? this.book.active.get(messageId) : undefined
    const retryOp = live?.retry && !live.started ? live : undefined
    if (retryOp) retryOp.started = true
    const cursor = await this.deps.cursor(session)
    const ctx: Ctx = {
      session, text, marker, messageId, attempt: ts, op: retryOp, cursor, scanner: new TranscriptScanner(retryOp?.cursor ?? cursor, marker),
      gen, paste: false, settled: true, resent: false,
    }
    this.verifying.set(session, (this.verifying.get(session) ?? 0) + 1)
    try {
      if (retryOp) {
        const pre = await this.retryPrecheck(ctx)
        if (pre === "requeued") return
        if (pre) return await this.conclude(ctx, pre.done, pre.hold)
      }
      let res: InjectResult
      try { res = await this.deps.inject(text, session) } catch (e) {
        if (e instanceof TmuxUncertainError) return await this.recover(ctx, e, chatId)
        if (retryOp && e instanceof TmuxCommandError) retryOp.started = false   // 交回原有路径（清态重拉起后再发），身份留在账上
        throw e
      }
      ctx.paste = res.paste
      if (res.committed) {
        if (retryOp) await this.conclude(ctx, { status: "delivered", reason: "重发了", retryable: false }, false)
        return
      }
      // 注入成功、回车后没确认提交（原来：记一行就放下一条）→ 已执行的确认流程
      console.warn(`[hub] send 回车后没确认提交 ${session}${messageId ? ` message_id=${messageId}` : ""} → 核对`)
      await this.track(ctx, chatId, async () => this.confirmExecuted(ctx, false))
    } finally {
      const n = (this.verifying.get(session) ?? 1) - 1
      if (n > 0) this.verifying.set(session, n); else this.verifying.delete(session)
    }
  }

  private async recover(ctx: Ctx, err: TmuxUncertainError, chatId: string): Promise<void> {
    console.warn(`[hub] send 结果不明 ${ctx.session}${ctx.messageId ? ` message_id=${ctx.messageId}` : ""} → 等落定后核对: ${err.message.split("\n")[0]}`)
    ctx.paste = err.buffer !== undefined
    await this.track(ctx, chatId, async () => this.fromUncertain(ctx, err))
  }

  /// 进账（有 message_id 才进）→ 跑核对 → 终态 → 必要时堵着会话
  private async track(ctx: Ctx, chatId: string, run: () => Promise<{ done: Outcome; hold: boolean }>): Promise<void> {
    if (ctx.messageId !== undefined && !ctx.op) ctx.op = this.book.begin(ctx.messageId, chatId, ctx.session, ctx.cursor, ctx.attempt)
    const r = await run()
    await this.conclude(ctx, r.done, r.hold)
  }

  private async conclude(ctx: Ctx, o: Outcome, hold: boolean): Promise<void> {
    console.log(`[hub] send 核对 ${ctx.session}${ctx.messageId ? ` message_id=${ctx.messageId}` : ""}：${o.status}（${o.reason}）`)
    // 同一个 message_id 有更新的一次发送开始了（重新生成）：这次的结果不发给 app（finish 返回 false）
    const current = ctx.op ? this.book.finish(ctx.op, o, ctx.cursor) : ctx.messageId === undefined
    if (o.status === "failed" && current) this.deps.legacyError(ctx.session, ctx.messageId, o.reason)
    if (hold) await this.hold(ctx)
  }

  private async fromUncertain(ctx: Ctx, err: TmuxUncertainError): Promise<{ done: Outcome; hold: boolean }> {
    let e = err
    for (;;) {
      ctx.pending = e
      ctx.settled = false
      const fate = await this.deps.settle(e, this.deps.now() + this.t.settleMs)
      let next: "executed" | "uncertain" | "not-executed"
      if (fate.kind === "timeout") {
        if (e.buffer) void this.deps.deleteBuffer(e.buffer).catch(() => {})   // 尽力：赶在卡着的 paste-buffer 之前删掉，它就贴不进去了
        return { done: { status: "failed", retryable: true, reason: `tmux 卡了 ${Math.round(this.t.settleMs / 1000)}s 还没恢复，${MAYBE_IN}` }, hold: true }
      }
      ctx.settled = true
      ctx.pending = undefined
      if (fate.kind === "executed") next = "executed"
      else if (fate.kind === "not-executed") next = "not-executed"
      else if (e.buffer) {
        // 粘贴：-d 贴完即删。落定后缓冲区还在 = paste-buffer 没执行过、也不会再执行（旧客户端已经没了）
        const exists = await this.deps.bufferExists(e.buffer)
        next = exists === true ? "not-executed" : exists === false ? "executed" : "uncertain"
      } else next = "uncertain"
      if (e.buffer && next !== "executed") await this.deps.deleteBuffer(e.buffer).catch(() => {})
      if (next === "executed") return this.confirmExecuted(ctx, true)
      if (next === "uncertain") return this.confirmUncertain(ctx)
      // 确定没执行：自动重发一次
      if (ctx.resent) return { done: { status: "failed", retryable: true, reason: "重发了一次还是没进" }, hold: false }
      if (this.genChanged(ctx)) return { done: { status: "failed", retryable: true, reason: "会话重新拉起过，这条没送进去，可以重发" }, hold: false }
      ctx.resent = true
      try {
        const res = await this.deps.inject(ctx.text, ctx.session)
        ctx.paste = res.paste
        if (res.committed) return { done: { status: "delivered", retryable: false, reason: "没进，自动重发了一次" }, hold: false }
        return this.confirmExecuted(ctx, false)
      } catch (x) {
        if (x instanceof TmuxUncertainError) { e = x; ctx.paste = x.buffer !== undefined; continue }
        return this.goneOr(ctx, x, `重发失败：${(x as Error).message.split("\n")[0]}`)
      }
    }
  }

  /// 不确定：窗口内看到了（transcript 有 / 输入框里认出这次的记号）就接着走，否则 failed，不重发
  private async confirmUncertain(ctx: Ctx): Promise<{ done: Outcome; hold: boolean }> {
    const deadline = this.deps.now() + this.t.confirmMs
    for (;;) {
      if ((await ctx.scanner.poll()) === "seen") return { done: { status: "delivered", retryable: false, reason: "已经提交了" }, hold: false }
      const ea = await this.deps.editArea(ctx.session)
      if (ea.kind === "gone") return this.whenGone(ctx, ea.detail)
      if (ea.kind === "found" && hasMarker(ea.text, ctx.marker)) return this.confirmExecuted(ctx, true, true)
      if (this.deps.now() >= deadline) return { done: { status: "failed", retryable: true, reason: MAYBE_IN }, hold: true }
      await this.deps.sleep(this.t.pollMs)
    }
  }

  /// 字节已经交给终端：等它进输入框 → 补回车 → 确认（transcript 有，或输入框里这条没了）。不重注入。
  /// inBox：调用方刚在输入框里认出了这条
  private async confirmExecuted(ctx: Ctx, needEnter: boolean, inBox = false): Promise<{ done: Outcome; hold: boolean }> {
    const start = this.deps.now()
    let entered = !needEnter || inBox
    let submitted = false
    while (!entered) {
      if ((await ctx.scanner.poll()) === "seen") return { done: { status: "delivered", retryable: false, reason: "已经提交了" }, hold: false }
      const ea = await this.deps.editArea(ctx.session)
      if (ea.kind === "gone") return this.whenGone(ctx, ea.detail)
      if (ea.kind === "found" && this.ours(ea.text, ctx)) entered = true
      else if (ea.kind === "unlocated" && this.deps.now() - start >= this.t.consumeMs) entered = true   // 认不出输入框：和正常路径一样，等一会儿就当消费了
      else if (this.deps.now() - start >= this.t.confirmMs) return { done: { status: "failed", retryable: true, reason: `字已经交给终端了，但一直没在输入框里看到，${MAYBE_IN}` }, hold: true }
      else await this.deps.sleep(this.t.pollMs)
    }
    if (needEnter) {
      if (this.genChanged(ctx)) return { done: { status: "failed", retryable: true, reason: "会话重新拉起过，这条没法确认" }, hold: false }
      submitted = await this.deps.submit(ctx.text, ctx.session, ctx.paste)
    }
    const deadline = this.deps.now() + this.t.confirmMs
    for (;;) {
      if ((await ctx.scanner.poll()) === "seen") return { done: { status: "delivered", retryable: false, reason: needEnter ? "停在输入框里，补了回车" : "已经提交了" }, hold: false }
      const ea = await this.deps.editArea(ctx.session)
      if (ea.kind === "gone") return this.whenGone(ctx, ea.detail)
      // 输入框里这条没了 = 终端收下了（提交或排队），和正常路径同等把握
      if (ea.kind === "found" && !this.ours(ea.text, ctx)) return { done: { status: "delivered", retryable: false, reason: needEnter ? "补了回车，输入框已清空" : "回车后输入框已清空" }, hold: false }
      if (ea.kind === "unlocated" && submitted) return { done: { status: "delivered", retryable: false, reason: "补了回车" }, hold: false }
      if (this.deps.now() >= deadline) return { done: { status: "failed", retryable: true, reason: `回车后还停在输入框里 / 确认不了，${MAYBE_IN}` }, hold: true }
      await this.deps.sleep(this.t.pollMs)
    }
  }

  /// 重发之前看现场：原来那次其实提交过（transcript 从原发送位置往后有）→ 不再发；停在输入框里 → 补回车；会话没了 → 交回原有路径
  private async retryPrecheck(ctx: Ctx): Promise<{ done: Outcome; hold: boolean } | "requeued" | undefined> {
    if ((await ctx.scanner.poll()) === "seen") return { done: { status: "delivered", retryable: false, reason: "原来那条其实已经提交了，没有重发" }, hold: false }
    const ea = await this.deps.editArea(ctx.session)
    if (ea.kind === "found" && hasMarker(ea.text, ctx.marker)) return this.confirmExecuted(ctx, true, true)
    if (ea.kind === "gone") {
      // 会话不在了（审查 R1-9）：清就绪态、交回原有路径重新拉起，身份留在账上，重新排队的那次接着写终态；只交一次
      this.deps.sessionGone(ctx.session)
      if (ctx.op?.requeued) return { done: { status: "failed", retryable: true, reason: `会话拉不起来（${ea.detail.split("\n")[0]}），这条没重发出去` }, hold: false }
      ctx.op!.requeued = true
      ctx.op!.started = false
      console.warn(`[hub] 重发 ${ctx.messageId}：会话不在了 → 交回原有路径重新拉起（${ea.detail.split("\n")[0]}）`)
      this.deps.requeue(ctx.session, ctx.text)
      return "requeued"
    }
    // 之后照常注入；transcript 改从这次发送前的位置看
    ctx.scanner = new TranscriptScanner(ctx.cursor, ctx.marker)
    return undefined
  }

  private async whenGone(ctx: Ctx, detail: string): Promise<{ done: Outcome; hold: boolean }> {
    this.deps.sessionGone(ctx.session)
    if ((await ctx.scanner.poll()) === "seen") return { done: { status: "delivered", retryable: false, reason: "已经提交了（之后会话没了）" }, hold: false }
    // 终端都没了：没提交的字跟着没了，重发不会两遍
    return { done: { status: "failed", retryable: true, reason: `会话没了（${detail.split("\n")[0]}），这条没提交上，可以重发` }, hold: false }
  }

  private async goneOr(ctx: Ctx, e: unknown, reason: string): Promise<{ done: Outcome; hold: boolean }> {
    const msg = (e as Error)?.message ?? String(e)
    if (/can't find (?:session|pane|window)|no server running/.test(msg)) return this.whenGone(ctx, msg)
    return { done: { status: "failed", retryable: true, reason }, hold: false }
  }

  /// 输入框里是不是这条：认出记号；已执行的粘贴另外认占位（字节确定是这次交过去的）
  private ours(area: string, ctx: Ctx): boolean {
    return hasMarker(area, ctx.marker) || (ctx.paste && PASTE_PLACEHOLDER_RE.test(area))
  }

  private genChanged(ctx: Ctx): boolean { return this.deps.generation(ctx.session) !== ctx.gen }

  /// 失败后堵着会话：旧写落定、且读屏确认输入框里没有这条（也没有粘贴占位）才放行；最多 holdMs，到点放行、记日志、补原因。
  /// 「清空」不要求输入框是空串：空的输入框会显示灰字占位（codex `› Ask Codex to do anything` + 下面一行状态栏，claude 的提示语），文案会变，
  /// 只看里面还有没有这次的记号 / 粘贴占位
  private async hold(ctx: Ctx): Promise<void> {
    const until = this.deps.now() + this.t.holdMs
    while (this.deps.now() < until) {
      if (ctx.pending && !ctx.settled) {
        const f = await this.deps.settle(ctx.pending, Math.min(until, this.deps.now() + 3_000))
        if (f.kind !== "timeout") ctx.settled = true
      }
      if (ctx.settled || !ctx.pending) {
        const ea = await this.deps.editArea(ctx.session)
        if (ea.kind === "gone") { this.deps.sessionGone(ctx.session); return }
        if (ea.kind === "found" && !hasMarker(ea.text, ctx.marker) && !PASTE_PLACEHOLDER_RE.test(ea.text)) return
      }
      await this.deps.sleep(Math.min(1_000, Math.max(0, until - this.deps.now())))
    }
    console.warn(`[hub] ${ctx.session} 输入框 ${Math.round(this.t.holdMs / 1000)}s 没确认清空 → 放行后面的消息${ctx.messageId ? `（message_id=${ctx.messageId}）` : ""}`)
    if (ctx.messageId !== undefined) {
      const r = this.book.record(ctx.messageId)
      if (r?.status === "failed") this.book.amend(ctx.messageId, `${r.reason ?? ""}（会话等了 ${Math.round(this.t.holdMs / 60_000)} 分钟输入框还没确认清空，后面的消息已经放行，可能会接在它后面）`)
    }
  }
}
