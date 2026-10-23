import SwiftUI
import SwiftData

// MARK: - 日历 · iOS 风（plan-calendar-v5 §1）
// 只是呈现：数据、刷新、sheet 都在 CalendarPanelView 外层，两种样子共用。
// 薄荷底上一张票根纸，底部浮动页签（月 / 年 / 纪念日 / 设置）。

extension CalendarPanelView {
    var iosTabSelection: Binding<CalendarIOSTab> {
        Binding(
            get: {
                if iosSettings { return .settings }
                switch tab {
                case .month: return .month
                case .year: return .year
                case .anniversaries: return .anniversaries
                }
            },
            set: { t in
                switch t {
                case .settings: iosSettings = true
                case .month: iosSettings = false; tab = .month
                case .year: iosSettings = false; tab = .year
                case .anniversaries: iosSettings = false; tab = .anniversaries
                }
            }
        )
    }

    /// iOS：系统原生页签（iOS 26 液态玻璃底栏，往下滚收起）；mac 没有底栏，用自画的浮动胶囊
    @ViewBuilder
    var iosBody: some View {
        #if os(iOS)
        TabView(selection: iosTabSelection) {
            Tab(CalendarIOSTab.month.title, systemImage: CalendarIOSTab.month.icon, value: CalendarIOSTab.month) {
                iosScrollPage { iosMonthContent }
            }
            Tab(CalendarIOSTab.year.title, systemImage: CalendarIOSTab.year.icon, value: CalendarIOSTab.year) {
                iosScrollPage { iosYearContent }
            }
            Tab(CalendarIOSTab.anniversaries.title, systemImage: CalendarIOSTab.anniversaries.icon, value: CalendarIOSTab.anniversaries) {
                iosScrollPage { iosAnniversaries }
            }
            Tab(CalendarIOSTab.settings.title, systemImage: CalendarIOSTab.settings.icon, value: CalendarIOSTab.settings) {
                iosSettingsList.background(Theme.sidebarBg.ignoresSafeArea().allowsHitTesting(false))
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.branchIndicator)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        #else
        Group {
            if iosSettings {
                iosSettingsList
            } else {
                iosScrollPage {
                    switch tab {
                    case .month: iosMonthContent
                    case .year: iosYearContent
                    case .anniversaries: iosAnniversaries
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CalendarIOSTabBar(selection: iosTabSelection)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .background(Theme.sidebarBg.ignoresSafeArea().allowsHitTesting(false))
        #endif
    }

    private func iosScrollPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .background(Theme.sidebarBg.ignoresSafeArea().allowsHitTesting(false))
        #if os(iOS)
        .toolbarVisibility(keyboardUp ? .hidden : .automatic, for: .tabBar)
        #endif
    }

    @ViewBuilder
    private var iosSettingsList: some View {
        #if os(iOS)
        List { CalendarSettingsSections(profileId: profileId) }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        #else
        MacSettingsForm { CalendarSettingsSections(profileId: profileId) }
            .scrollContentBackground(.hidden)
        #endif
    }

    /// 纪念日墙一笔不改；外面铺一张纸，深色主题下也看得清（astra #5）
    private var iosAnniversaries: some View {
        AnniversaryWall(profileId: profileId, anniversaries: anniversaries, width: max(0, pageWidth - 16), onChange: reloadFiles)
            .padding(.vertical, 10)
            .background(CalInk.paper, in: RoundedRectangle(cornerRadius: IOSCal.radius, style: .continuous))
            .padding(.horizontal, 8)
    }

    // MARK: 月

    private var iosMonthContent: some View {
        let marks = monthMarks
        let lay = monthLayout
        var chat = Set<Int>()
        for d in 1...lay.daysInMonth {
            if let date = calendar.date(byAdding: .day, value: d - 1, to: lay.firstOfMonth),
               (activity.summary.days[DailyActivity.dayKey(date, calendar: calendar)]?.messages ?? 0) > 0 { chat.insert(d) }
        }
        return CalendarTicket {
            iosNavHeader(title: "\(calendar.component(.year, from: displayedMonth))年\(calendar.component(.month, from: displayedMonth))月",
                         prevLabel: "上个月", nextLabel: "下个月", prev: { shiftMonth(-1) }, next: { shiftMonth(1) }) {
                Button("今天") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        displayedMonth = Date()
                        selectedDate = Date()
                    }
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
            }
            if let p = activity.progress {
                Text("正在数聊天…… \(p.done) / \(p.total)")
                    .font(.system(size: 12)).foregroundColor(Theme.textMuted)
                    .padding(.horizontal, IOSCal.pad)
            }
            IOSMonthGrid(
                month: displayedMonth, days: marks, chatDays: chat, selected: selectedDate,
                accessibilityDetail: { d in
                    guard let date = calendar.date(byAdding: .day, value: d - 1, to: lay.firstOfMonth) else { return "" }
                    let n = activity.summary.days[DailyActivity.dayKey(date, calendar: calendar)]?.messages ?? 0
                    return n > 0 ? "，聊了 \(n) 条" : ""
                },
                onSelect: { d in
                    if calendar.isDate(d, inSameDayAs: selectedDate) { dayPage = CalendarDayItem(date: d) } else { selectedDate = d }
                }
            )
            if !anniversaries.isEmpty { iosAnniversaryLine }
            TicketNotch()
            iosDayHeader
            CalendarTodoList(dayKey: selectedKey, look: .ios)
            IOSSubLabel(text: "对话")
            iosDayRows
            Color.clear.frame(height: 12)
        }
    }

    private func iosNavHeader<Extra: View>(title: String, prevLabel: String, nextLabel: String,
                                          prev: @escaping () -> Void, next: @escaping () -> Void,
                                          @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 0) {
            iosChevron("chevron.left", label: prevLabel, action: prev)
            Spacer()
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            extra()
            iosChevron("chevron.right", label: nextLabel, action: next)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private func iosChevron(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 月历下一行：最近两个纪念日还有几天，点了去纪念日页签
    private var iosAnniversaryLine: some View {
        let next = AnniversaryOrdering.upcoming(anniversaries).prefix(2)
        return Button { withAnimation(.easeInOut(duration: 0.15)) { tab = .anniversaries } } label: {
            HStack(spacing: 6) {
                ForEach(Array(next.enumerated()), id: \.element.id) { i, a in
                    let (_, number) = AnniversaryText.count(a)
                    if i > 0 { Text("·").foregroundColor(Theme.textMuted.opacity(0.6)) }
                    Text(a.title).foregroundColor(Theme.textSecondary).lineLimit(1)
                    Text(number == "今天" ? "今天" : "\(number) 天").fontWeight(.semibold).foregroundColor(Theme.textPrimary).fixedSize()
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textMuted.opacity(0.6))
            }
            .font(.system(size: 13))
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("去纪念日")
    }

    private var iosDayHeader: some View {
        Button { dayPage = CalendarDayItem(date: selectedDate) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.chineseDayTitle(selectedDate)).font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(dayFacts.joined(separator: " · ")).font(.system(size: 13)).foregroundColor(Theme.textMuted).lineLimit(2)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textMuted.opacity(0.6))
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开这一天")
    }

    @ViewBuilder
    private var iosDayRows: some View {
        let conversations = conversationsForSelectedDate
        let counts = activity.summary.conversationsByDay[selectedKey] ?? [:]
        let past = CalendarDayPage.onThisDay(selectedDate, summary: activity.summary, conversations: allConversations, calendar: calendar)
        if let note = selectedDiary {
            IOSCalendarRow(icon: "book.closed", title: "\(assistantName)的日记", meta: "\(note.text.count) 字") {
                dayPage = CalendarDayItem(date: selectedDate)
            }
        }
        if conversations.isEmpty {
            Text("这天没有对话")
                .font(.system(size: 13)).foregroundColor(Theme.textMuted)
                .padding(.horizontal, IOSCal.pad)
                .padding(.vertical, 12)
        } else {
            ForEach(conversations, id: \.id) { c in
                IOSCalendarRow(icon: CalendarRow.icon(for: c), title: c.title, tag: CalendarRow.tag(for: c),
                               meta: counts[c.id].map { "\($0) 条" }) {
                    viewModel.loadConversation(c, context: modelContext)
                }
            }
        }
        ForEach(past, id: \.conv.id) { item in
            IOSCalendarRow(icon: "sparkle", title: "\(CalendarText.yearsAgo(item.years))：\(item.conv.title)") {
                viewModel.loadConversation(item.conv, context: modelContext)
            }
        }
    }

    // MARK: 年（不画小格子：一月一行横条 + 几点聊 + 心情色带）

    private var iosYearContent: some View {
        let s = activity.summary
        let y = displayedYear
        let today = Date()
        let isThisYear = y == calendar.component(.year, from: today)
        var activeByMonth: [Int: Int] = [:]
        for key in ActivityStats.keys(ofYear: y, in: s) where (s.days[key]?.messages ?? 0) > 0 {
            if let m = Int(key.dropFirst(5).prefix(2)) { activeByMonth[m, default: 0] += 1 }
        }
        let (rows, futureFrom) = CalendarIOSMath.monthRows(activeByMonth: activeByMonth, year: y, today: today, calendar: calendar)
        let longest = ActivityStats.longestStreak(s, year: y, calendar: calendar)
        let busiest = ActivityStats.busiestDay(s, year: y)
        let latest = ActivityStats.latest(s, year: y)
        var stats: [(String, String)] = [("\(ActivityStats.activeDays(s, year: y))", "有聊的日子")]
        if isThisYear { stats.append(("\(ActivityStats.currentStreak(s, today: today, calendar: calendar))", "现在连续")) }
        stats.append((longest.map { "\($0.length)" } ?? "–", "最长连续"))
        if !isThisYear { stats.append((busiest.map { "\($0.messages)" } ?? "–", "最多一天")) }
        var note: [String] = []
        if let busiest { note.append("最多一天 \(Self.chineseShortDate(busiest.key)) \(busiest.messages) 条") }
        if let latest { note.append("最晚 \(Self.chineseShortDate(latest.key)) \(latest.time)") }
        let hours = CalendarIOSMath.hourTotals(ActivityStats.punchCard(s, year: y, calendar: calendar))
        let weeks = CalendarIOSMath.weeklyMoods(year: y, moods: yearMoods, today: today, calendar: calendar)

        return CalendarTicket {
            iosNavHeader(title: String(y), prevLabel: "上一年", nextLabel: "下一年",
                         prev: { displayedYear -= 1 }, next: { displayedYear += 1 }) { EmptyView() }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, st in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(st.0).font(.system(size: 24, weight: .semibold)).foregroundColor(Theme.textPrimary)
                        Text(st.1).font(.system(size: 12)).foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, IOSCal.pad)
            if !note.isEmpty {
                Text(note.joined(separator: " · ")).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, IOSCal.pad)
                    .padding(.top, 8)
            }
            TicketNotch().padding(.top, 6)

            IOSSubLabel(text: "每个月")
            ForEach(rows, id: \.month) { r in iosMonthRow(r, year: y) }
            if let f = futureFrom {
                Text(f == 12 ? "12月　还没到" : "\(f)–12月　还没到")
                    .font(.system(size: 15)).foregroundColor(Theme.textMuted.opacity(0.7))
                    .padding(.horizontal, IOSCal.pad)
                    .frame(minHeight: 44)
            }

            TicketNotch()
            IOSSubLabel(text: "一天里什么时候聊")
            iosHourBars(hours)
            if weeks.contains(where: { $0 != nil }) {
                IOSSubLabel(text: "心情")
                iosMoodRibbon(weeks)
            }
            Color.clear.frame(height: 16)
        }
    }

    /// `9-14` → `9月14日`
    static func chineseShortDate(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[1])月\(p[2])日" : key
    }

    private func iosMonthRow(_ r: CalendarIOSMath.MonthRow, year: Int) -> some View {
        let tappable = r.kind == .current || r.activeDays > 0
        return Button {
            if r.kind == .current {
                if let d = calendar.date(from: DateComponents(year: year, month: r.month, day: 1)) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        displayedMonth = d
                        selectedDate = Date()
                        tab = .month
                    }
                }
            } else {
                openRecap(month: r.month)
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("\(r.month)月").font(.system(size: 15)).foregroundColor(Theme.textPrimary).frame(width: 40, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.accent)
                            Capsule().fill(Theme.branchIndicator).frame(width: g.size.width * r.fraction)
                        }
                    }
                    .frame(height: 6)
                    Text("\(r.activeDays) 天").font(.system(size: 13)).foregroundColor(Theme.textMuted).frame(width: 44, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(tappable ? 0.6 : 0))
                }
                .padding(.horizontal, IOSCal.pad)
                .frame(minHeight: 44)
                IOSHairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.month)月，有聊 \(r.activeDays) 天")
        .accessibilityHint(r.kind == .current ? "去这个月" : (tappable ? "看月度回顾" : ""))
        .accessibilityAddTraits(tappable ? .isButton : [])
    }

    private func iosHourBars(_ hours: [Int]) -> some View {
        let mx = max(1, hours.max() ?? 1)
        let peak = hours.firstIndex(of: mx) ?? 0
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { h in
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(Theme.branchIndicator)
                        .frame(height: max(2, CGFloat(hours[h]) / CGFloat(mx) * 44))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 46, alignment: .bottom)
            HStack {
                ForEach(["0点", "6", "12", "18", "24"], id: \.self) { t in
                    Text(t).font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    if t != "24" { Spacer() }
                }
            }
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hours.allSatisfy { $0 == 0 } ? "这一年还没聊" : "\(peak) 点聊得最多")
    }

    private func iosMoodRibbon(_ weeks: [JournalMood?]) -> some View {
        var count: [JournalMood: Int] = [:]
        for case let m? in weeks { count[m, default: 0] += 1 }
        let top = count.values.max() ?? 0
        let most = JournalMood.allCases.first { count[$0] == top && top > 0 }
        return HStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, m in
                Rectangle().fill(m.map(JournalMoodLook.color) ?? Theme.accent)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(most.map { "心情，最多的是\($0.label)" } ?? "心情")
    }
}
