#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI
import SwiftData

/// Log · 记录时间线（控制台 LOG 区点开）。
/// 把散落的记录（喝水/吃饭/吃药/睡眠/经期/留言）汇成一条按天倒序的时间线。
/// 数据：DailyContext 历史 + 今日 vitals 留言 + 网关经期来潮日。只读。
struct LogView: View {
    let contexts: [DailyContext]            // 倒序（最新在前）
    let todayNotes: [VitalsResponse.Note]

    @Environment(\.dismiss) private var dismiss
    @State private var periodStarts: Set<String> = []

    private struct DayEntry: Identifiable {
        let id = UUID()
        let sortTime: Date
        let hasTime: Bool
        let icon: String
        let title: String
        let subtitle: String?
        let color: Color
    }

    private struct DaySection: Identifiable {
        let date: Date
        let entries: [DayEntry]
        var id: Date { date }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    let sections = daySections
                    if sections.isEmpty {
                        Text("还没有记录\n喝水、吃饭、睡眠、经期打卡后都会汇到这里")
                            .font(.system(size: 13.5))
                            .foregroundColor(ConsoleView.textFaint)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 60)
                    } else {
                        ForEach(sections) { section in
                            dayCard(section)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
        .task {
            if let snap = await PeriodClient.fetch() {
                periodStarts = Set(snap.events.map { $0.date })
            }
        }
    }

    private func dayCard(_ section: DaySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayHeader(section.date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ConsoleView.textSub)
            ForEach(section.entries) { e in
                HStack(spacing: 11) {
                    Text(e.hasTime ? timeStr(e.sortTime) : "全天")
                        .font(.system(size: 11)).foregroundColor(ConsoleView.textFaint)
                        .frame(width: 40, alignment: .leading)
                    Image(systemName: e.icon).font(.system(size: 13)).foregroundColor(e.color).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 14)).foregroundColor(ConsoleView.textPrimary)
                        if let sub = e.subtitle {
                            Text(sub).font(.system(size: 11.5)).foregroundColor(ConsoleView.textMuted)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    // MARK: - 数据组装

    private var daySections: [DaySection] {
        contexts.compactMap { ctx in
            let es = entries(for: ctx)
            return es.isEmpty ? nil : DaySection(date: ctx.date, entries: es)
        }
    }

    private func entries(for ctx: DailyContext) -> [DayEntry] {
        var out: [DayEntry] = []
        let dayStart = Calendar.current.startOfDay(for: ctx.date)

        for meal in ctx.meals {
            out.append(DayEntry(sortTime: meal.time, hasTime: true, icon: "fork.knife",
                                title: "进食", subtitle: meal.description, color: ConsoleView.green))
        }
        if let s = ctx.sleepStart {
            out.append(DayEntry(sortTime: s, hasTime: true, icon: "moon.fill",
                                title: "入睡", subtitle: nil, color: ConsoleView.greenDeep))
        }
        if let e = ctx.sleepEnd {
            out.append(DayEntry(sortTime: e, hasTime: true, icon: "sun.max.fill",
                                title: "起床", subtitle: nil, color: ConsoleView.gold))
        }
        if ctx.waterCount > 0 {
            out.append(DayEntry(sortTime: dayStart, hasTime: false, icon: "drop.fill",
                                title: "饮水 \(ctx.waterCount) 杯", subtitle: nil, color: ConsoleView.green))
        }
        if ctx.medicationStatus == .taken {
            out.append(DayEntry(sortTime: dayStart, hasTime: false, icon: "pills.fill",
                                title: "已服药", subtitle: ctx.medicationName, color: ConsoleView.green))
        }
        if periodStarts.contains(ymd(ctx.date)) {
            out.append(DayEntry(sortTime: dayStart, hasTime: false, icon: "drop.fill",
                                title: "经期来潮", subtitle: nil, color: ConsoleView.gold))
        } else if let m = ctx.menstrualDay {
            out.append(DayEntry(sortTime: dayStart, hasTime: false, icon: "calendar",
                                title: "经期 第 \(m) 天", subtitle: nil, color: ConsoleView.gold))
        }
        if Calendar.current.isDateInToday(ctx.date) {
            for n in todayNotes {
                let t = ISO8601DateFormatter().date(from: n.ts)
                out.append(DayEntry(sortTime: t ?? dayStart, hasTime: t != nil, icon: "text.bubble",
                                    title: n.text, subtitle: n.by == "caelum" ? "Caelum" : n.by, color: ConsoleView.greenDeep))
            }
        }
        return out.sorted { $0.sortTime > $1.sortTime }
    }

    // MARK: - helpers

    private func dayHeader(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter(); f.dateFormat = "M月d日 EEEE"; f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
#endif
