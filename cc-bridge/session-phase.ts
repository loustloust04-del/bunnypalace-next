// 进度卡 B（粟粟 10-03「都按推荐」）：CC 会话的 phase（干活中 / 等你 / 做完了）也推给聊天页。
// 真相源还是 live-activity-phase 的状态机（send / askuser / reply / Stop hook 四个显式事件），这里只管成帧。
// 不扩 APNs 的 contentState（CC_ACTIVITY_STATE_KEYS 冻结），走 WS 帧。
import { type LaPhaseSnapshot } from "./live-activity-phase.ts"
import { type ToolActivity } from "./tool-activity.ts"

/// chatId = 这个会话最近一次是从哪个对话发来的：app 只在那个对话里出状态卡（多个对话共用 mp-cc 时不串）
/// activity：这一轮用了几次「干活」的工具（app 据此决定出不出卡：纯聊天不出）
export function buildSessionPhaseFrame(sessionName: string, snap: LaPhaseSnapshot, canStop: boolean, chatId?: string, activity?: ToolActivity): string {
  return JSON.stringify({
    type: "session_phase",
    session_name: sessionName,
    ...(chatId ? { chat_id: chatId } : {}),
    phase: snap.phase,
    ...(snap.detail !== undefined ? { detail: snap.detail } : {}),
    ...(snap.since_unix !== undefined ? { since_unix: snap.since_unix } : {}),
    updated_unix: snap.updated_unix,
    can_stop: canStop,
    ...(activity && activity.count > 0 ? { tools: activity.count, ...(activity.last ? { tool: activity.last } : {}) } : {}),
  })
}

/// 值得推一帧吗：phase / 这一轮（run_id）/ 题面变了才算。看门狗每 tick 推进 last_progress_at 不算
export function phaseFrameChanged(prev: LaPhaseSnapshot | undefined, next: LaPhaseSnapshot): boolean {
  return !prev || prev.phase !== next.phase || prev.run_id !== next.run_id || prev.detail !== next.detail
}

/// 非 working 帧（K3）：等补数工具完了再按当时的快照发。补数失败照发（工具数沿用上次的）；
/// 等的时候 phase 又跳了不发（跳的那次自己会发）。返回的 Promise 永不 reject（hub 的 unhandledRejection = 退出）
export function sendPhaseAfter(
  refresh: Promise<unknown>,
  snapshot: LaPhaseSnapshot,
  current: () => LaPhaseSnapshot | undefined,
  send: (snap: LaPhaseSnapshot) => void,
): Promise<void> {
  const go = () => {
    const cur = current()
    if (cur && !phaseFrameChanged(snapshot, cur)) send(cur)
  }
  return refresh.then(go, go).catch((e) => console.warn(`[hub] session_phase 帧发送失败: ${e}`))
}

/// app 刚连上：把还在动的会话（非 idle）现状补一份
export function sessionPhaseSnapshotFrames(
  phases: Map<string, LaPhaseSnapshot>,
  canStop: (sessionName: string) => boolean,
  chatIdFor: (sessionName: string) => string | undefined = () => undefined,
  activityFor: (sessionName: string) => ToolActivity | undefined = () => undefined,
): string[] {
  const out: string[] = []
  for (const [name, snap] of phases) {
    if (snap.phase === "idle") continue
    out.push(buildSessionPhaseFrame(name, snap, canStop(name), chatIdFor(name), activityFor(name)))
  }
  return out
}
