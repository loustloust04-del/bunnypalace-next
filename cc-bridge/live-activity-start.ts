// push-to-start（M5）：app 完全没开也能让岛冒出来。纯逻辑，可测。
//
// 跟 update 那条链的四点不同（别把两者「统一」）：
//   1. 路由身份是 `install_id`（一台设备一条），不是 `activity_id`（一个岛一条）；
//   2. payload 必须带 `alert` —— Apple 原文 "Include an alert in the JSON payload."，
//      漏了直接启动失败。它会真的弹给粟粟看，所以文案固定、不带任何对话内容（R9）；
//   3. 必须带 `input-push-token: 1`（iOS 18+）：不加的话远程起的岛拿不到 update token，
//      后续所有 update 都发不出去，等于起了一个死岛；
//   4. `attributes-type` 是**结构体类型名字符串**（`"CCActivityAttributes"`），不是全限定名。
import { encodeAttributes, type CCActivityState, type CCPhase } from "./activity-state.ts"
import { type LaAlert, type LaEvent } from "./apns.ts"
import { type LaTokenStore, type LaUpdateRecord } from "./live-activity-tokens.ts"

/// 起岛的 alert 是**会弹到锁屏上的通知**，不是岛上的文字：固定两句，永远不带题面/对话内容。
const START_ALERT_TITLE = "记忆花园"
const START_ALERT_BODY: Record<"waiting" | "other", string> = {
  waiting: "Claude Code 在等你",
  other: "Claude Code 开始干活了",
}

function startAlert(phase: CCPhase): LaAlert {
  return { title: START_ALERT_TITLE, body: START_ALERT_BODY[phase === "waiting" ? "waiting" : "other"] }
}

/// 触发点：`idle/done → working|waiting`，且该 session **当前没有活着的 update 记录**
/// （有岛就该走 update，不能再起第二个 —— 同一 session 同一时刻只允许一个 activity），
/// 且至少有一条 start 记录（没设备报过 push-to-start token 就无从发起）。
export function shouldRemoteStart(
  store: LaTokenStore,
  sessionName: string,
  prevPhase: CCPhase,
  nextPhase: CCPhase,
): boolean {
  if (prevPhase !== "idle" && prevPhase !== "done") return false
  if (nextPhase !== "working" && nextPhase !== "waiting") return false
  if (Object.values(store.update).some((r) => r.session_name === sessionName)) return false
  return Object.keys(store.start).length > 0
}

/// contentState 由调用方按**每条 start 记录**的 preview 组好再传进来（detail 是每设备的隐私决定）。
export function buildStartEvent(sessionName: string, state: CCActivityState): LaEvent {
  return {
    event: "start",
    contentState: state,
    attributesType: "CCActivityAttributes",
    // 走 ④ 那份编码器再 parse 回来：键序/落键规则跟 golden 同一套，不手写字面量。
    attributes: JSON.parse(encodeAttributes({ session_name: sessionName })),
    alert: startAlert(state.phase),
    inputPushToken: true,
  }
}

// ── ⑤ 8 小时上限的滚动换岛（D5 第 4 条）────────────────────────────
// 系统给单个 activity 的硬上限是 8 小时，常驻岛必然撞到。撞上去 = 岛自己消失，
// 而 hub 手里的 update 记录还在（app 被杀掉的话连 unregister 都回不来）。
// 所以到点主动收：先 end 旧的（带 dismissal-date 立刻收走），再走 push-to-start 起新的。

/// 返回 **unix 秒**（记录里存的是毫秒，跟 `updated_at` 同钟）。
/// M5 之前的记录没有 `started_at` → 退回 `updated_at`：宁可早换一次，不漏换。
export function activityStartedAt(record: LaUpdateRecord): number {
  return Math.floor((record.started_at ?? record.updated_at) / 1000)
}

/// 只在 working/waiting 时换：done/idle 的岛留着显示最后状态，
/// 没必要为一个没人在等的岛烧一次起岛预算（还会弹一条 alert）。
export function needsRollover(
  record: LaUpdateRecord,
  phase: CCPhase,
  now: number,
  rolloverSec: number,
): boolean {
  if (phase !== "working" && phase !== "waiting") return false
  return now - activityStartedAt(record) > rolloverSec
}
