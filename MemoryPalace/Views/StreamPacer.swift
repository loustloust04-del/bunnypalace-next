import SwiftUI

/// 流式显示节拍器：到达文本（provider 每 ~0.1-0.6s 一坨）和显示文本解耦。
/// 显示文本按 30Hz 向到达文本追赶，步长 = backlog × dt / horizon（horizon = 最近几坨到达间隔中位数，钳 0.2-1s），
/// 坨大追快坨小追慢，永不停不跳；两坨之间的空档被匀速填满（research-streaming-smoothness：渲染 ≤25ms 不是瓶颈，卡顿=分片）。
@Observable
final class StreamPacer {
    private(set) var shown = ""
    @ObservationIgnored private var target = ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var arrivals: [Date] = []
    @ObservationIgnored private var lastTick = Date()

    private static let hz: Double = 30
    private static let horizonRange: ClosedRange<TimeInterval> = 0.2...1.0

    /// 新的到达快照（完整前缀）。中途改写（快照不再以已显示为前缀）→ 回退到最长公共前缀
    /// 继续放，不整段闪回重打（L5：加工后正文理论上可能被 clean/regex 非追加式修正）。
    func push(_ text: String) {
        if !text.hasPrefix(shown) { shown = shown.commonPrefix(with: text) }
        target = text
        arrivals.append(Date())
        if arrivals.count > 4 { arrivals.removeFirst() }
        if timer == nil {
            lastTick = Date()
            let t = Timer(timeInterval: 1 / Self.hz, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }  // 宿主没调 end 也不空转泄漏
                self.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// 直接铺满到指定快照（不动画、不起 timer）——mid-stream remount（滚出滚回）时
    /// 已有内容瞬时就位，只对后续增量放字（L5）。
    func seed(_ text: String) {
        shown = text
        target = text
    }

    /// 流结束：停节拍。显示侧此时切回 node.content，不需要 flush。
    func end() {
        timer?.invalidate(); timer = nil
        arrivals.removeAll()
    }

    private var horizon: TimeInterval {
        guard arrivals.count >= 2 else { return 0.5 }
        let gaps = zip(arrivals.dropFirst(), arrivals).map { $0.timeIntervalSince($1) }.sorted()
        return min(max(gaps[gaps.count / 2], Self.horizonRange.lowerBound), Self.horizonRange.upperBound)
    }

    private func tick() {
        #if os(iOS)
        // 松手/停稳那一刻落在底半屏内 → 回底跟随（粟粟：滑到底半屏之内就算想看新的）；边沿触发不常驻
        StreamScrollAnchor.AnchorView.pollScrollSettled()
        #endif
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let targetCount = target.count
        let backlog = targetCount - shown.count
        guard backlog > 0 else { return }
        let step = min(backlog, max(1, Int((Double(backlog) * dt / horizon).rounded(.up))))
        // 空白（换行/空格）不单独占 tick：这一步若全是空白，延到下一个可见字一起放（换段 `\n\n` 不留空窗）
        let start = target.index(target.startIndex, offsetBy: shown.count)
        var end = target.index(start, offsetBy: step)
        if target[start..<end].allSatisfy(\.isWhitespace) {
            if let visible = target[end...].firstIndex(where: { !$0.isWhitespace }) {
                end = target.index(after: visible)
            } else {
                end = target.endIndex
            }
        }
        shown = String(target[..<end])
    }
}
