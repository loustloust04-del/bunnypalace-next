import SwiftUI

/// 聊天时间分割线（TASK page1-消息-20，粟粟 10-02：学 OA / Anth，隔几个小时才出；样式 A 两侧线改波浪线）。
/// 判断和样子都是独立小块：SwiftUI 列表把它放在那条消息顶上，UIKit 新页也能直接拿去用
enum ChatTimeDivider {
    /// 两条消息隔这么久以上才出分割线
    static let gap: TimeInterval = 3 * 3600

    /// 按时间顺序的消息 → 哪几条顶上要出分割线（id → 那条的时间）。对话第一条（有时间的）一定出；没时间的跳过、不打断比较
    static func dividers(for nodes: [(id: String, time: Date?)]) -> [String: Date] {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let probeStart = AirPerfProbe.enabled ? AirPerfProbe.beginTimed("timeDividers") : nil
        defer { if let probeStart { AirPerfProbe.endTimed("timeDividers", since: probeStart) } }
        #endif
        var result: [String: Date] = [:]
        var previous: Date?
        for node in nodes {
            guard let time = node.time else { continue }
            if previous.map({ time.timeIntervalSince($0) >= gap }) ?? true { result[node.id] = time }
            previous = time
        }
        return result
    }

    /// 今天「09:12」、昨天「昨天 23:41」、6 天内「周三 14:20」、今年「9月25日 14:20」、更早带年份
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "昨天 \(time)" }
        if (2...6).contains(days) {
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            return "\(names[calendar.component(.weekday, from: date) - 1]) \(time)"
        }
        return "\(day(date, now: now, calendar: calendar)) \(time)"
    }

    /// 「9月25日」，不是今年就「2025年12月31日」
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let md = "\(c.month ?? 0)月\(c.day ?? 0)日"
        return c.year == calendar.component(.year, from: now) ? md : "\(c.year ?? 0)年\(md)"
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// 分割线按路径缓存（#027）：路径里还是同一批节点（逐个比对象，不读 SwiftData 属性）就复用上次结果，
/// 否则才重读每条的 id / createTime。存强引用，免得节点释放后地址复用撞上旧结果
struct ChatTimeDividerCache {
    private var nodes: [MessageNode] = []
    private var result: [String: Date] = [:]
    private(set) var builds = 0

    mutating func dividers(for path: [MessageNode]) -> [String: Date] {
        if path.count == nodes.count, zip(path, nodes).allSatisfy({ $0 === $1 }) { return result }
        result = ChatTimeDivider.dividers(for: path.map { ($0.id, $0.createTime) })
        nodes = path
        builds += 1
        return result
    }

    /// 清空 / 换对话 / 清 SwiftData 引用时调：放掉旧节点，下次必重算
    mutating func reset() {
        nodes = []
        result = [:]
    }
}

/// 长按气泡时菜单底部那行（粟粟 10-02 选 ①）：时间；模型的消息再加输入 / 输出 token 和缓存命中
enum ChatBubbleInfo {
    static func line(time: Date?, isUser: Bool, prompt: Int?, completion: Int?, cacheRead: Int?,
                     now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let time else { return nil }
        let head = "\(ChatTimeDivider.day(time, now: now, calendar: calendar)) \(ChatTimeDivider.clock(time, calendar: calendar))"
        guard !isUser, prompt != nil || completion != nil else { return head }
        var parts: [String] = []
        if let prompt { parts.append("输入 \(tokens(prompt))") }
        if let completion { parts.append("输出 \(tokens(completion))") }
        if let cacheRead, cacheRead > 0 {
            let share = prompt.flatMap { $0 > 0 ? Int((Double(cacheRead) / Double($0) * 100).rounded()) : nil }
            parts.append("缓存命中 \(tokens(cacheRead))" + (share.map { "（\($0)%）" } ?? ""))
        }
        return head + "\n" + parts.joined(separator: " · ")
    }

    static func line(for node: MessageNode, now: Date = Date()) -> String? {
        line(time: node.createTime, isUser: node.role == "user", prompt: node.usagePromptTokens,
             completion: node.usageCompletionTokens, cacheRead: node.usageCacheReadTokens, now: now)
    }

    /// 86 / 1k / 12.4k / 1.3M
    static func tokens(_ n: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if n >= 1_000_000 { return short(Double(n) / 1_000_000, "M") }
        if n >= 1_000 { return short(Double(n) / 1_000, "k") }
        return "\(n)"
    }
}

/// 分割线的样子：居中一个时间（粟粟 10-11 去掉两侧波浪线）。
/// 上方离上一条 = 列表行距；下方补同样的行距，时间正好坐在两条消息中间
struct ChatTimeDividerView: View {
    let date: Date
    let spacing: CGFloat

    var body: some View {
        Text(ChatTimeDivider.label(date))
            .font(.caption2)
            .foregroundColor(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.bottom, spacing)
            .accessibilityLabel(ChatTimeDivider.label(date))
    }
}

private struct BubbleInfoNodeKey: EnvironmentKey {
    static let defaultValue: MessageNode? = nil
}

extension EnvironmentValues {
    /// 长按菜单底部那行要的消息（BubbleView 往下传，菜单 wrapper 读）
    var bubbleInfoNode: MessageNode? {
        get { self[BubbleInfoNodeKey.self] }
        set { self[BubbleInfoNodeKey.self] = newValue }
    }
}
