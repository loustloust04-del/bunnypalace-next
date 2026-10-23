import Foundation

struct TodoItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var done: Bool = false
    /// 排在哪天（yyyy-MM-dd，公历民用日期）；nil = 没排日子
    var date: String? = nil
    /// 勾上的时间；取消勾清空（旧数据里已完成的可能是 nil）
    var doneAt: Date? = nil
}

/// 待办列表。全局一份（不分楼层），UserDefaults 持久化。
/// 口径（plan-calendar-photos-todos 裁定 #4）：
/// - 行动清单（小 / 中小组件、今日安排）= 没做完的 今天 → 过期 → 没排日子
/// - 某一天（月历记号、当天列表、每日页）= date == 那天，含已完成；过期的仍记在原日期
/// - 月历打勾 = 那天至少一条且全做完
/// 「今天」由调用方在视图求值时现算传进来（跨午夜、换时区跟着变）。
@MainActor
@Observable
final class TodoManager {
    static let shared = TodoManager()
    private static let key = "todoItems_v1"
    private let defaults: UserDefaults

    private(set) var items: [TodoItem]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let i = try? JSONDecoder().decode([TodoItem].self, from: data) {
            items = i
        } else {
            items = []
        }
    }

    /// 所有没做完的
    var remaining: Int { items.filter { !$0.done }.count }

    // MARK: 口径

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        DailyActivity.dayKey(date, calendar: calendar)
    }

    static func dayKey(after key: String, days: Int = 1, calendar: Calendar = .current) -> String? {
        guard let d = DailyActivity.date(fromKey: key, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: days, to: d) else { return nil }
        return dayKey(next, calendar: calendar)
    }

    /// 某一天的（含已完成）
    func items(on day: String) -> [TodoItem] { items.filter { $0.date == day } }

    /// 没做完的过期待办（日期在今天之前）
    func overdue(today: String) -> [TodoItem] {
        items.filter { !$0.done && ($0.date.map { $0 < today } ?? false) }
    }

    var undated: [TodoItem] { items.filter { $0.date == nil } }

    /// 行动清单：没做完的 今天 → 过期 → 没排日子
    func actionList(today: String) -> [TodoItem] {
        items.filter { !$0.done && $0.date == today } + overdue(today: today) + undated.filter { !$0.done }
    }

    /// 今天一共（含已完成）+ 过期没做的：中 / 大小组件的 today 组
    func todayGroup(today: String) -> [TodoItem] {
        items(on: today) + overdue(today: today)
    }

    /// 明天之后（不含明天）排了日子的，按日期
    func later(today: String) -> [TodoItem] {
        guard let tomorrow = Self.dayKey(after: today) else { return [] }
        return items.filter { ($0.date.map { $0 > tomorrow } ?? false) }.sorted { ($0.date ?? "") < ($1.date ?? "") }
    }

    /// 月历记号：dayKey → 全做完了没（没有待办的日子不在里面）
    static func marks(_ items: [TodoItem]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for t in items { guard let d = t.date else { continue }; out[d] = (out[d] ?? true) && t.done }
        return out
    }

    // MARK: 改

    /// 返回新待办的 id（聊天待办卡要记住它，research-chat-cards §14）；空白不加 → nil
    @discardableResult
    func add(_ text: String, date: String? = nil) -> UUID? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let item = TodoItem(text: t, date: date)
        items.append(item)
        save()
        return item.id
    }

    /// yyyy-MM-dd 且是真日期（同 dayKey 的格式）
    nonisolated static func isValidDayKey(_ s: String) -> Bool {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: s) != nil
    }

    func toggle(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].done.toggle()
        items[idx].doneAt = items[idx].done ? Date() : nil
        save()
    }

    /// nil = 取消日期
    func setDate(_ date: String?, for id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].date = date
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) {
            defaults.set(d, forKey: Self.key)
        }
    }
}
