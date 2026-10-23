import Foundation

// MARK: - 小芽窗口 · 跟不跟底（09-26 粟粟：输出乱抖、收键盘时舞台缩放诡异）
// 舞台收放后来改成只看键盘（AssistantPanelView.stageCollapsed），这里只管列表贴不贴底。
// 根因：原来拿「离底距离 > 80」当「在看旧消息」。可离底距离变大有三种来源——用户往上翻、
// 流式一块长出好几行、键盘把可视区压矮——后两种被误判，列表就在输出 / 弹键盘时停跟。
// 现在只有「用户亲手滚动」时才改判断；其余几何变化一律按住底部。

struct XiaoyaScrollFollow: Equatable {
    enum Action: Equatable { case none, pinToBottom }

    /// 在看旧消息：不跟底
    private(set) var readingHistory = false
    private var scrolling = false

    static let leaveThreshold: Double = 80
    static let returnThreshold: Double = 24

    mutating func userScrolling(_ active: Bool) {
        scrolling = active
    }

    mutating func geometryChanged(distance: Double) -> Action {
        if scrolling {
            // 滞回：拖到 80 以外才算走开，回到 24 以内才算回来
            if !readingHistory, distance > Self.leaveThreshold { readingHistory = true }
            else if readingHistory, distance < Self.returnThreshold { readingHistory = false }
            return .none
        }
        if readingHistory { return .none }
        return distance > 1 ? .pinToBottom : .none
    }

    mutating func userSent() {
        readingHistory = false
    }
}
