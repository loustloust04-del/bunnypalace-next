import SwiftUI

/// 聊天时间分割线（TASK page1-消息-20，粟粟 10-02：学 OA / Anth，隔几个小时才出；样式 A 两侧线改波浪线）。
/// 判断和样子都是独立小块：SwiftUI 列表把它放在那条消息顶上，UIKit 新页也能直接拿去用
enum ChatTimeDivider {
    /// 文章模式：两条消息隔这么久以上才出分割线（保持原行为，测试锁定）
    static let articleGap: TimeInterval = 3 * 3600
    /// 气泡模式：iMessage 口径，隔 1 小时以上出分割线
    static let bubbleGap: TimeInterval = 3600

    /// 按时间顺序的消息 → 哪几条顶上要出分割线（id → 那条的时间）。对话第一条（有时间的）一定出；没时间的跳过、不打断比较
    static func dividers(for nodes: [(id: String, time: Date?)], gap: TimeInterval = articleGap) -> [String: Date] {
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

    /// 气泡模式英文 iMessage 格式。返回（日子 / 时间），调用方日子加粗、时间常规：
    /// 今天「Today 9:23 AM」、昨天「Yesterday 9:05 PM」、6 天内「Wednesday 2:10 PM」、更早「Oct 3 9:00 AM」
    static func bubbleLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> (day: String, time: String) {
        let time = bubbleClock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return ("Today", time) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return ("Yesterday", time) }
        if (2...6).contains(days) {
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            return (names[calendar.component(.weekday, from: date) - 1], time)
        }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let c = calendar.dateComponents([.month, .day], from: date)
        return ("\(months[(c.month ?? 1) - 1]) \(c.day ?? 0)", time)
    }

    /// 12 小时制「9:23 AM」，小时不补零
    static func bubbleClock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let h24 = c.hour ?? 0
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h12):\(String(format: "%02d", c.minute ?? 0)) \(h24 < 12 ? "AM" : "PM")"
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
    private var gap: TimeInterval = ChatTimeDivider.articleGap
    private var result: [String: Date] = [:]
    private(set) var builds = 0

    mutating func dividers(for path: [MessageNode], gap: TimeInterval = ChatTimeDivider.articleGap) -> [String: Date] {
        if self.gap == gap, path.count == nodes.count, zip(path, nodes).allSatisfy({ $0 === $1 }) { return result }
        result = ChatTimeDivider.dividers(for: path.map { ($0.id, $0.createTime) }, gap: gap)
        nodes = path
        self.gap = gap
        builds += 1
        return result
    }

    /// 清空 / 换对话 / 清 SwiftData 引用时调：放掉旧节点，下次必重算
    mutating func reset() {
        nodes = []
        result = [:]
    }
}

/// 与时间分割线同口径：只在路径节点或时间显示开关变化时重算，行内只查表。
struct ChatBubbleRunCache {
    /// 换说话人的间距（10-29 粟粟：iMessage 原值 10 看着挤，拉到 16；同一人连发 4 不动）
    static let speakerChangeSpacing: CGFloat = 16

    struct Layout: Equatable {
        let spacingBefore: CGFloat
        var hasTail: Bool
    }

    private var nodes: [MessageNode] = []
    private var includesTimeDividers = false
    private var gap: TimeInterval = ChatTimeDivider.articleGap
    private var result: [String: Layout] = [:]
    private(set) var builds = 0

    mutating func layouts(for path: [MessageNode], dividers: [String: Date],
                          includesTimeDividers: Bool, gap: TimeInterval = ChatTimeDivider.articleGap) -> [String: Layout] {
        if self.includesTimeDividers == includesTimeDividers, self.gap == gap,
           path.count == nodes.count, zip(path, nodes).allSatisfy({ $0 === $1 }) {
            return result
        }
        result = [:]
        result.reserveCapacity(path.count)
        var previous: (id: String, role: String)?
        for node in path {
            let id = node.id
            let role = node.role
            let hasDivider = includesTimeDividers && dividers[id] != nil
            let continuesRun = previous?.role == role
                && (role == "user" || role == "assistant") && !hasDivider
            if continuesRun, let previous { result[previous.id]?.hasTail = false }
            result[id] = Layout(
                spacingBefore: previous == nil || hasDivider ? 0 : (continuesRun ? 4 : Self.speakerChangeSpacing),
                hasTail: true)
            previous = (id, role)
        }
        nodes = path
        self.includesTimeDividers = includesTimeDividers
        self.gap = gap
        builds += 1
        return result
    }

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
/// 文章模式下方补列表行距；气泡模式用独立时间留白，不叠加连发间距。
struct ChatTimeDividerView: View {
    let date: Date
    let spacing: CGFloat
    var bubbleMode: Bool = false
    var tutuFollowingSpacing: CGFloat = 24

    var body: some View {
        Group {
            #if PERSONAL_APPS && os(iOS)
            if SkinState.shared.active {
                let label = ChatTimeDivider.label(date)
                Text(label)
                    .font(.system(size: TutuChatStyle.isCJK(label) ? 10.5 : 9.5,
                                  weight: TutuChatStyle.isCJK(label) ? .regular : .medium))
                    .tracking(TutuChatStyle.isCJK(label) ? 1.05 : 2.85)
                    .monospacedDigit()
                    .foregroundStyle(Color(red: 107 / 255, green: 103 / 255, blue: 99 / 255))
                    .accessibilityLabel(label)
                    .opacity(TutuChatIntroPresentation.shared.phase.dateOpacity)
            } else {
                ordinaryLabel
            }
            #else
            ordinaryLabel
            #endif
        }
        .foregroundColor(Theme.chat.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.top, tutuSkinActive ? 0 : (bubbleMode ? 16 : 0))
        .padding(.bottom, tutuSkinActive ? tutuFollowingSpacing : (bubbleMode ? 6 : spacing))
    }

    private var tutuSkinActive: Bool {
        #if PERSONAL_APPS && os(iOS)
        return SkinState.shared.active
        #else
        return false
        #endif
    }

    @ViewBuilder private var ordinaryLabel: some View {
            if bubbleMode {
                // iMessage 英文格式：日子加粗、时间常规
                let parts = ChatTimeDivider.bubbleLabel(date)
                (Text(parts.day).fontWeight(.semibold) + Text(" \(parts.time)"))
                    .font(.system(size: 11))
                    .accessibilityLabel("\(parts.day) \(parts.time)")
            } else {
                Text(ChatTimeDivider.label(date))
                    .font(.caption2)
                    .accessibilityLabel(ChatTimeDivider.label(date))
            }
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
