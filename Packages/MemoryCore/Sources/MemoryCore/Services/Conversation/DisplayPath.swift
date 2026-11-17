import Foundation

/// 「选好的那条路径上，哪些节点显示出来」的唯一算法（docs/plan-重构.md §3.7 第 4 步）。
/// 路径本身由 `BranchSelection` 给（每个分叉走哪个孩子）；这里只做两件事：
/// 滤掉不显示的节点；分叉点自己不显示时，记到它前面最近一个显示出来的节点上（分支角标挂在那）。
/// 对话页载入、切分支重排、记忆那边的 `visiblePath` 都走这里。
public enum DisplayPath {
    public struct Result: Equatable {
        public var visibleIds: [String] = []
        /// 显示出来的节点 id → 它后面那个不显示的分叉点 id
        public var bubbledBranches: [String: String] = [:]

        public init(visibleIds: [String] = [], bubbledBranches: [String: String] = [:]) {
            self.visibleIds = visibleIds
            self.bubbledBranches = bubbledBranches
        }
    }

    /// 一个节点显不显示：只有 user / assistant、有可显示的内容、没被软删。
    /// （源隐藏、合成根已经算在「有没有可显示的内容」里，或由调用方另外滤）
    public static func isDisplayable(role: String, hasDisplayableContent: Bool, isTrashed: Bool) -> Bool {
        (role == "user" || role == "assistant") && hasDisplayableContent && !isTrashed
    }

    /// `pathIds`：从根到末端。`childCount`：这个节点有几个有效的孩子（多于一个 = 分叉点）
    public static func project(pathIds: some Sequence<String>, isDisplayable: (String) -> Bool,
                               childCount: (String) -> Int) -> Result {
        var result = Result()
        var lastVisible: String?
        for id in pathIds {
            if isDisplayable(id) {
                result.visibleIds.append(id)
                lastVisible = id
            } else if childCount(id) > 1, let lastVisible {
                result.bubbledBranches[lastVisible] = id
            }
        }
        return result
    }
}
