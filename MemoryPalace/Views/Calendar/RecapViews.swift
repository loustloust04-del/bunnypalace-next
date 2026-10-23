import SwiftUI
import SwiftData

// MARK: - 月度回顾 + 一年的心情（plan-calendar §九 P7）
// 回顾按需现算（不存盘）：哪天打开都能看任何一个有数据的月，缺月自然补上。
// 像一枚绣出来的纪念品（p8）：souvenir · 月份 + 一排刺绣小花 + 总条数 + 三个数 + 那个月日记里的一句。

struct MonthlyRecap: Equatable, Identifiable {
    var id: String { "\(year)-\(month)" }
    let year: Int
    let month: Int
    let messages: Int
    /// 比上个月多 / 少百分之几；上个月没有数据时 nil
    let changePercent: Int?
    let activeDays: Int
    let latest: String?
    let newMemories: Int
    let quote: String?
    let quoteKey: String?

    static func build(year: Int, month: Int, summary s: DailyActivity.Summary, calendar: Calendar,
                      newMemories: Int, journalBodies: [String: String], aiDiaries: [String: String]) -> MonthlyRecap? {
        let prefix = String(format: "%04d-%02d-", year, month)
        let keys = s.days.keys.filter { $0.hasPrefix(prefix) }
        let messages = keys.reduce(0) { $0 + (s.days[$1]?.messages ?? 0) }
        guard messages > 0 else { return nil }
        let (py, pm) = month == 1 ? (year - 1, 12) : (year, month - 1)
        let prevPrefix = String(format: "%04d-%02d-", py, pm)
        var prev = 0
        for (k, d) in s.days where k.hasPrefix(prevPrefix) { prev += d.messages }
        let change: Int? = prev > 0 ? Int((Double(messages - prev) / Double(prev) * 100).rounded()) : nil
        let active = keys.filter { (s.days[$0]?.messages ?? 0) > 0 }.count
        let late = keys.compactMap { k in s.days[k]?.lateMinute }.max().map { m -> String in
            let mm = m % 1440
            return String(format: "%02d:%02d", mm / 60, mm % 60)
        }
        // 摘句：那个月最长一篇她的日记的第一句；没有就取 AI 日记
        func firstSentence(_ text: String) -> String? {
            let body = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("- [") }
            guard let body else { return nil }
            let end = body.firstIndex { "。！？!?".contains($0) }.map { body.index(after: $0) } ?? body.endIndex
            let s = String(body[..<end])
            return s.count > 60 ? String(s.prefix(60)) + "……" : s
        }
        let mine = journalBodies.filter { $0.key.hasPrefix(prefix) }.max { $0.value.count < $1.value.count }
        let theirs = aiDiaries.filter { $0.key.hasPrefix(prefix) }.max { $0.value.count < $1.value.count }
        let pick = mine.flatMap { m in firstSentence(m.value).map { ($0, m.key) } } ?? theirs.flatMap { t in firstSentence(t.value).map { ($0, t.key) } }
        return MonthlyRecap(year: year, month: month, messages: messages, changePercent: change, activeDays: active,
                            latest: late, newMemories: newMemories, quote: pick?.0, quoteKey: pick?.1)
    }
}

struct RecapCard: View {
    let recap: MonthlyRecap

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("souvenir · \(Self.months[recap.month - 1]) \(String(recap.year))")
                .font(.custom("Georgia", size: 12.5)).tracking(2).foregroundColor(Theme.textMuted)
            Canvas { ctx, _ in
                var rng = CalendarInk.Rand(seed: CalendarInk.seed("recap", String(recap.year), String(recap.month)))
                let S = CalendarInk.Stitch.self
                let row: [(String, Color, Color?, Color?)] = [("sprig", S.orange, S.leaf, S.rust), ("apple", S.rust, S.leaf, nil),
                                                             ("tulip", S.lilac, S.olive, nil), ("star8", S.navy, nil, S.pink), ("quatre", S.olive, nil, S.orange)]
                for (i, item) in row.enumerated() {
                    guard let p = CalendarInk.patterns[item.0] else { continue }
                    CalendarInk.draw(p, mode: .stitch, in: &ctx, origin: CGPoint(x: 6 + CGFloat(i) * 50, y: 6), cell: 3.4,
                                     head: item.1, stem: item.2, core: item.3, rng: &rng)
                }
            }
            .frame(height: 46)
            Text(recap.messages.formatted()).font(.custom("Georgia", size: 44)).foregroundColor(Theme.textPrimary)
            Text(changeLine).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            HStack(spacing: 22) {
                stat("\(recap.activeDays)", "天有聊")
                stat(recap.latest ?? "–", "最晚一次")
                stat("\(recap.newMemories)", "新记住的事")
            }
            if let quote = recap.quote {
                HStack(alignment: .top, spacing: 8) {
                    SparkleMark().frame(width: 11, height: 11).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quote).font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                        if let k = recap.quoteKey { Text("\(CalendarPanelView.shortDate(k)) 的日记").font(.system(size: 11)).foregroundColor(Theme.textMuted) }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(red: 0.992, green: 0.988, blue: 0.976)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.textMuted.opacity(0.18), lineWidth: 1))
    }

    private var changeLine: String {
        guard let c = recap.changePercent else { return "条" }
        return c == 0 ? "条 · 和上个月一样" : "条 · 比上个月\(c > 0 ? "多" : "少") \(abs(c))%"
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.custom("Georgia", size: 20)).foregroundColor(Theme.textPrimary)
            Text(k).font(.system(size: 11)).foregroundColor(Theme.textMuted)
        }
    }
}

struct RecapSheet: View {
    let recap: MonthlyRecap
    @Environment(\.dismiss) private var dismiss

    @MainActor private var image: Image? {
        let r = ImageRenderer(content: RecapCard(recap: recap).frame(width: 340).padding(10).background(Theme.sidebarBg))
        r.scale = 3
        #if os(iOS)
        return r.uiImage.map { Image(uiImage: $0) }
        #else
        return r.nsImage.map { Image(nsImage: $0) }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    RecapCard(recap: recap).frame(maxWidth: 360)
                    if let image {
                        ShareLink(item: image, preview: SharePreview("\(recap.year) 年 \(recap.month) 月", image: image)) {
                            Label("存成图 / 分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .padding(24)
            }
            .background(Theme.sidebarBg)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}

/// 一年的心情：一天一针，颜色 = 心情（p8）；没点的日子留一个浅针眼
struct MoodYearView: View {
    let year: Int
    let moods: [String: JournalMood]

    private let calendar = Calendar.current

    var body: some View {
        Canvas { ctx, size in
            guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let days = calendar.range(of: .day, in: .year, for: first)?.count else { return }
            let pad = calendar.component(.weekday, from: first) - 1
            let c = size.width / 53
            var rng = CalendarInk.Rand(seed: CalendarInk.seed("mood", String(year)))
            let today = calendar.startOfDay(for: Date())
            for i in 0..<days {
                guard let d = calendar.date(byAdding: .day, value: i, to: first), d <= today else { continue }
                let idx = pad + i
                let p = CGPoint(x: (CGFloat(idx / 7) + 0.5) * c, y: (CGFloat(idx % 7) + 0.5) * c)
                if let mood = moods[DailyActivity.dayKey(d, calendar: calendar)] {
                    let stitch = Path(ellipseIn: CGRect(x: -c * 0.36, y: -c * 0.3, width: c * 0.72, height: c * 0.6))
                        .applying(CGAffineTransform(rotationAngle: rng.jitter(0.9)).concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
                    ctx.fill(stitch, with: .color(JournalMoodLook.color(mood)))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - c * 0.12, y: p.y - c * 0.12, width: c * 0.24, height: c * 0.24)),
                             with: .color(Theme.textMuted.opacity(0.35)))
                }
            }
        }
        .aspectRatio(53.0 / 7.0, contentMode: .fit)
        .accessibilityLabel("\(year) 年的心情，点过 \(moods.filter { $0.key.hasPrefix(String(year)) }.count) 天")
    }
}
