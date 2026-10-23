import Foundation

/// 翻页命令通道的纯逻辑（plan-paging-decouple §3.2）：同页短路、代际、注册前暂存。
/// UIKit 侧（`PagingCommands` / `PagingViewController`）照它的决定执行；拆出来给 mac 单测测。
struct PagingCommandLogic {
    enum Decision: Equatable {
        /// 分页壳还没注册（或还没第一次布局）：存为待执行目标，只留最新一个
        case stored
        /// 目标就是分页壳当前页（手势落定的回写，或在途命令的同一目标）：什么都不做
        case alreadyThere
        /// 真的要翻；带代际号，旧命令的完成回调凭它作废
        case run(generation: Int)
    }

    private(set) var generation = 0
    private(set) var pending: Int?
    /// 已派出、还没开始滚（在等内容就绪）的目标
    private(set) var inFlight: Int?

    /// 每条命令都推进代际：新命令（含回写）一律顶掉在等的旧命令
    mutating func receive(target: Int, currentPage: Int?) -> Decision {
        generation += 1
        guard let currentPage else {
            pending = target
            return .stored
        }
        pending = nil
        if target == currentPage {
            inFlight = nil
            return .alreadyThere
        }
        inFlight = target
        return .run(generation: generation)
    }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// 在途命令开始滚动（或被放弃）
    mutating func started(_ generation: Int) {
        if generation == self.generation { inFlight = nil }
    }

    /// 注册完成、可执行时取出待执行目标
    mutating func takePending() -> Int? {
        defer { pending = nil }
        return pending
    }

    /// 分页壳注销（楼层切换 / dismantle）：旧注册上的在途命令全部作废
    mutating func invalidate() {
        generation += 1
        inFlight = nil
    }
}
