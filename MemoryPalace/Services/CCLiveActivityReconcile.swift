import Foundation

/// hub 对一个 activity 的回话（`la_query_result` 的 `alive[id]` 非 null 时）。
struct CCLiveActivityAlive: Equatable {
    let phase: String
    let runId: String?
    let sessionName: String
}

/// 冷启动对账的动作。`reattach` 是显式的「什么都不做」——留一条 log 才看得出走了哪支。
enum CCLiveActivityReconcileAction: Equatable {
    case reattach(activityId: String)
    case end(activityId: String)
}

/// M4b2 ③：冷启动发现的岛该 reattach 还是 end。
///
/// iPhone 上 app 被杀是**正常工作模式**（数据源在 Mac 的 hub），所以「本地看到一个岛」
/// 不等于「这一轮还在跑」，更不等于「这一轮已经死了」——必须问 hub：
///   - hub 认识（回了非 null 快照）→ reattach，什么都不做（M2 的 token 重报已覆盖）
///   - hub 明确说不认识（回了 null）→ end
///   - hub 压根没回这个 id（WS 没连上 / 超时 / 帧里少了这一格）→ **不动，不猜**
/// 第三支是靠 `answered` 跟 `alive` 分开表达的：JSON 的 null 会丢信息，
/// 「回了 null」和「根本没回」在 app 侧是两种完全相反的决定。
///
/// 纯函数不碰 ActivityKit —— macOS 测试 target 里直接测。
func reconcileLiveActivities(
    liveIds: [String],
    alive: [String: CCLiveActivityAlive],
    answered: Set<String>
) -> [CCLiveActivityReconcileAction] {
    liveIds.compactMap { id in
        if alive[id] != nil { return .reattach(activityId: id) }
        return answered.contains(id) ? .end(activityId: id) : nil
    }
}

/// T13：这一轮 `la_query` 该问 hub 哪些岛 —— 只问**本地注册表里已有 update token 记录的**。
///
/// hub 判活的唯一证据就是它自己的 update token 记录（`hub.ts` 的 `la_query` 分支：
/// `laTokens.update[id]` 不存在就回 null）。远程 push-to-start 拉起的岛，app 是回前台才
/// 第一次看见它的，那一刻 token 还在 ActivityKit 手里没报上去 —— 问了必得 null →
/// `reconcileLiveActivities` 判 `.end` → `endStale` 顺手 cancel 掉正在等 token 的
/// `pushTokenUpdates` 监听 → 这个岛的 token 永远上不了岸（08-30 真机实撞）。
///
/// 所以陌生岛这一轮只挂监听、不问、不 end；token 注册完，下一次 recheck 它就是「已知的」，
/// 自然纳入对账。代价是陌生的死岛多活一轮 recheck，比误杀活岛便宜。
func liveActivityIdsToQuery(liveIds: [String], registeredIds: Set<String>) -> [String] {
    liveIds.filter(registeredIds.contains)
}
