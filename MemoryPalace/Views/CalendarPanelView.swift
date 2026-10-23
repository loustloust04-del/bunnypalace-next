import SwiftUI
import SwiftData

// MARK: - 日历（plan-calendar §六 P1）
// 顶部分段「月 / 年 / 纪念日」+ 整页滚动（不给任何块设最低高度，B-5）。
// 月：铅笔月历（聊得多少 = 铅笔涂多深）+ 当天卡。「这天聊了」从按天统计缓存反查，不再按对话创建日。

enum CalendarTab: String, CaseIterable, Identifiable {
    case month, year, anniversaries
    var id: String { rawValue }
    var label: String {
        switch self {
        case .month: "月"
        case .year: "年"
        case .anniversaries: "纪念日"
        }
    }
}

struct CalendarPanelView: View {
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage("assistantName") var assistantName = "助手"
    #if os(iOS)
    @Environment(\.page2AppActive) private var appActive
    #else
    /// page2 外壳只在 iOS；mac 面板一直算可见
    private let appActive = true
    #endif
    var viewModel: ConversationViewModel
    let profileId: String
    @Query var allConversations: [Conversation]

    init(viewModel: ConversationViewModel, profileId: String) {
        self.viewModel = viewModel
        self.profileId = profileId
        _allConversations = Query(
            filter: #Predicate<Conversation> { $0.profileId == profileId && !$0.isTrashed },
            sort: \Conversation.createTime,
            order: .forward
        )
    }

    @State var activity = CalendarActivityModel.shared
    @State var tab: CalendarTab = .month
    @State var displayedMonth = Date()
    @State var selectedDate = Date()
    /// 容器宽：页头、纪念日墙按它断行（mac 面板可以窄到 280）
    @State var pageWidth: CGFloat = 390
    @State private var journalDates: Set<String> = []
    @State private var moods: [String: JournalMood] = [:]
    @State var anniversaries: [Anniversary] = []
    @State var dayPage: CalendarDayItem?
    @State var displayedYear = Calendar.current.component(.year, from: Date())
    @State var yearMoods: [String: JournalMood] = [:]
    @State private var yearJournal: [String: String] = [:]
    @State private var recap: MonthlyRecap?

    @AppStorage(CalendarLook.storageKey) var lookRaw = CalendarLook.paper.rawValue
    var look: CalendarLook { CalendarLook(rawValue: lookRaw) ?? .paper }
    /// iOS 底部页签停在「设置」（`tab` 不动，年页的刷新钩子照旧跟 `tab` 走）
    @State var iosSettings = false
    /// 键盘起来时藏系统底栏（不藏的话底栏骑在键盘上，正好盖住新待办那行）
    @State var keyboardUp = false
    @State private var showSettings = false
    @AppStorage("calendar_lightDots") private var lightDots = true
    @AppStorage("calendar_monthStyle") private var monthStyle = "pencil"
    @AppStorage("calendar_cardColor") private var cardColorRaw = StarCardColor.white.rawValue
    /// 星孔卡片翻开了没有（按楼层记住）
    @State private var cardOpen = false
    @AppStorage("calendar_metric") private var metricRaw = ActivityMetric.messages.rawValue

    let calendar = Calendar.current

    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "calendar" else { return }
        desktopNavigator?.pendingTarget = nil
        iosSettings = false
        if target.id.hasPrefix("anniv:") {
            tab = .anniversaries
            return
        }
        guard let date = DailyActivity.date(fromKey: target.id, calendar: calendar) else { return }
        tab = .month
        selectedDate = date
        displayedMonth = date
        dayPage = CalendarDayItem(date: date)
    }

    var selectedDiary: DailyNote? {
        DailyFileStore.load(date: DailyActivity.dayKey(selectedDate, calendar: calendar), profileId: profileId)
    }

    var body: some View {
        Group {
            if look == .ios { iosBody } else { paperBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        // 纸没有「设置」页签：切回纸时收掉
        .onChange(of: lookRaw) { _, _ in iosSettings = false }
        // 年 → 设置 → 年：tab 没变，靠这里刷年数据
        .onChange(of: iosSettings) { _, on in if !on, tab == .year { reloadYearFiles() } }
        .sheet(isPresented: $showSettings) { CalendarSettingsSheet(profileId: profileId) }
        .task(id: profileId) { reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        .onChange(of: appActive) { _, active in if active { reload() } }
        .onChange(of: displayedMonth) { _, _ in reloadFiles() }
        .onChange(of: displayedYear) { _, _ in reloadYearFiles() }
        .onChange(of: tab) { _, t in if t == .year { reloadYearFiles() } }
        .sheet(item: $recap) { r in RecapSheet(recap: r) }
        .onAppear { consumeDesktopTarget() }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .sheet(item: $dayPage) { item in
            NavigationStack {
                CalendarDayPage(date: item.date, profileId: profileId, viewModel: viewModel)
                    .navigationTitle(look == .ios ? Self.chineseDayTitle(item.date) : "")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { dayPage = nil }.foregroundColor(look == .ios ? Theme.branchIndicator : CalInk.ink2)
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 560)
            #else
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    private var paperBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GardenGateTabs(selection: $tab)
                switch tab {
                case .month: monthContent
                case .year: yearContent
                case .anniversaries: AnniversaryWall(profileId: profileId, anniversaries: anniversaries, width: pageWidth, onChange: reloadFiles)
                }
                CalendarSignature { showSettings = true }
            }
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        // 整页是一张纸（plan-calendar-page §2.1）；mac 也不用玻璃
        .background(CalendarPaperBackground().ignoresSafeArea())
    }

    // MARK: 刷新（可见时 / 回到前台 / 切楼层，不只 onAppear——astra #16）

    private func reload() {
        activity.refresh(profileId: profileId)
        reloadFiles()
        if tab == .year { reloadYearFiles() }
        cardOpen = UserDefaults.standard.bool(forKey: cardOpenKey)
    }

    private var cardOpenKey: String { "calendar.cardOpen.\(profileId)" }
    private var usesCard: Bool { monthStyle == "card" }

    /// 她的日记 / 心情 / 纪念日：都是文件，量很小，直接读
    func reloadFiles() {
        let journal = JournalStore.forProfile(profileId)
        let dates = journal.existingDates()
        journalDates = dates
        let monthPrefix = String(DailyActivity.dayKey(displayedMonth, calendar: calendar).prefix(8))
        var m: [String: JournalMood] = [:]
        for d in dates where d.hasPrefix(monthPrefix) {
            if let mood = journal.load(date: d)?.mood { m[d] = mood }
        }
        moods = m
        anniversaries = AnniversaryStore.forProfile(profileId).loadAll()
        CalendarSnapshotWriter.refresh(profileId: profileId)
    }

    /// 年视图：这一年她的日记正文和心情（只读有文件的日子）
    private func reloadYearFiles() {
        let store = JournalStore.forProfile(profileId)
        let prefix = String(format: "%04d-", displayedYear)
        var moodsOut: [String: JournalMood] = [:], bodies: [String: String] = [:]
        for d in store.existingDates() where d.hasPrefix(prefix) {
            guard let doc = store.load(date: d) else { continue }
            if let m = doc.mood { moodsOut[d] = m }
            bodies[d] = doc.body
        }
        yearMoods = moodsOut
        yearJournal = bodies
    }

    func openRecap(month m: Int) {
        let y = displayedYear
        guard let start = calendar.date(from: DateComponents(year: y, month: m, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return }
        let pid = profileId
        let memCount = (try? modelContext.fetchCount(FetchDescriptor<Memory>(
            predicate: #Predicate { $0.profileId == pid && $0.createdAt >= start && $0.createdAt < end }))) ?? 0
        let prefix = String(format: "%04d-%02d-", y, m)
        var ai: [String: String] = [:]
        for d in DailyFileStore.existingDates(profileId: profileId) where d.hasPrefix(prefix) {
            if let note = DailyFileStore.load(date: d, profileId: profileId) { ai[d] = note.text }
        }
        recap = MonthlyRecap.build(year: y, month: m, summary: activity.summary, calendar: calendar,
                                   newMemories: memCount, journalBodies: yearJournal, aiDiaries: ai)
    }

    // MARK: 页头（D 标题 + M 副标 + 导航；窄于 340 拆两行）

    private func pageHeader<Extra: View>(title: String, sub: String?, prevLabel: String, nextLabel: String,
                                         prev: @escaping () -> Void, next: @escaping () -> Void,
                                         @ViewBuilder extra: () -> Extra) -> some View {
        let titleView = HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title).font(CalType.hand(CalType.d)).foregroundColor(CalInk.ink)
            if let sub { Text(sub).font(CalType.type(CalType.m)).tracking(2).foregroundColor(CalInk.ink3) }
        }
        .accessibilityElement(children: .combine)
        let controls = HStack(spacing: 4) {
            extra()
            arrow("←", label: prevLabel, action: prev)
            arrow("→", label: nextLabel, action: next)
        }
        return Group {
            if pageWidth < 340 {
                VStack(alignment: .leading, spacing: 2) {
                    titleView
                    HStack { Spacer(); controls }
                }
            } else {
                HStack(alignment: .center) { titleView; Spacer(minLength: 8); controls }
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.top, 6)
    }

    private func arrow(_ glyph: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(CalType.type(17)).foregroundColor(CalInk.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: 年（plan-calendar-page §2.3）

    private var yearThresholds: [Int] {
        DailyActivity.thresholds(
            recentValues: CalendarMarks.recentValues(activity.summary, metric: metric, who: .all, today: Date(), calendar: calendar),
            metric: metric
        )
    }

    private var yearContent: some View {
        let s = activity.summary
        let y = displayedYear
        let t = yearThresholds
        var levels: [String: Int] = [:]
        var activeByMonth: [Int: Int] = [:]
        for key in ActivityStats.keys(ofYear: y, in: s) {
            let v = DailyActivity.value(s.days[key], metric: metric, who: .all)
            levels[key] = DailyActivity.level(v, thresholds: t)
            if (s.days[key]?.messages ?? 0) > 0, let m = Int(key.dropFirst(5).prefix(2)) { activeByMonth[m, default: 0] += 1 }
        }
        let chinese = AnniversaryMath.chineseCalendar(timeZone: calendar.timeZone)
        var annKeys = Set<String>()
        for m in 1...12 {
            guard let first = calendar.date(from: DateComponents(year: y, month: m, day: 1)) else { continue }
            for a in anniversaries { annKeys.formUnion(AnniversaryMath.occurrenceKeys(of: a, inMonth: first, gregorian: calendar, chinese: chinese)) }
        }
        let longest = ActivityStats.longestStreak(s, year: y, calendar: calendar)
        let busiest = ActivityStats.busiestDay(s, year: y)
        let latest = ActivityStats.latest(s, year: y)
        let isThisYear = y == calendar.component(.year, from: Date())
        // 月度回顾：有数据的月份（今年只到上个月）
        let lastMonth = isThisYear ? calendar.component(.month, from: Date()) - 1 : 12
        let recapMonths = lastMonth < 1 ? [] : (1...lastMonth).filter { m in
            ActivityStats.keys(ofYear: y, in: s).contains { $0.hasPrefix(String(format: "%04d-%02d-", y, m)) && (s.days[$0]?.messages ?? 0) > 0 }
        }
        var stats: [(String, String)] = [("\(ActivityStats.activeDays(s, year: y))", "有聊的日子")]
        if isThisYear { stats.append(("\(ActivityStats.currentStreak(s, today: Date(), calendar: calendar))", "现在连续")) }
        stats.append((longest.map { "\($0.length)" } ?? "–", "最长连续"))
        stats.append((busiest.map { "\($0.messages)" } ?? "–", busiest.map { "最多一天 \(Self.shortDate($0.key))" } ?? "最多一天"))
        stats.append((latest?.time ?? "–", latest.map { "最晚 \(Self.shortDate($0.key))" } ?? "最晚一次"))

        return VStack(alignment: .leading, spacing: 0) {
            pageHeader(title: String(y), sub: nil, prevLabel: "上一年", nextLabel: "下一年",
                       prev: { displayedYear -= 1 }, next: { displayedYear += 1 }) { EmptyView() }

            // 统计不能点：裸数字 + 标注，不带框
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 12) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, st in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(st.0).font(CalType.hand(CalType.n)).foregroundColor(CalInk.ink)
                        Text(st.1).font(.system(size: CalType.s)).foregroundColor(CalInk.ink3)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)

            PencilRule(seed: "year-grid").padding(.vertical, 10)
            PencilYearView(year: y, levels: levels, anniversaryKeys: annKeys, seedKey: profileId,
                           activeDaysByMonth: activeByMonth) { m in
                if let d = calendar.date(from: DateComponents(year: y, month: m, day: 1)) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        displayedMonth = d
                        selectedDate = d
                        tab = .month
                    }
                }
            }
            .padding(.horizontal, 12)

            PencilRule(seed: "year-punch").padding(.vertical, 10)
            CalendarSectionLabel(text: "几点最爱聊")
            PencilPunchCard(grid: ActivityStats.punchCard(s, year: y, calendar: calendar))
                .padding(.horizontal, 22)
                .padding(.top, 8)

            if !yearMoods.isEmpty {
                PencilRule(seed: "year-mood").padding(.vertical, 10)
                CalendarSectionLabel(text: "一年的心情")
                MoodYearView(year: y, moods: yearMoods)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
            }

            PencilRule(seed: "year-legend").padding(.vertical, 10)
            CalendarSectionLabel(text: "月历上的记号")
            CalendarLegend().padding(.top, 8)

            if !recapMonths.isEmpty {
                PencilRule(seed: "year-recap").padding(.vertical, 10)
                CalendarSectionLabel(text: "月度回顾")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recapMonths.reversed(), id: \.self) { m in
                            PencilBoxButton(seed: "recap-\(y)-\(m)", action: { openRecap(month: m) }) {
                                // 手写体没有中文字形：英文月名缩写
                                Text(StarCardCover.monthAbbrev(m)).font(CalType.hand(CalType.n)).foregroundColor(CalInk.ink)
                                    .frame(minWidth: 40, minHeight: 32)
                            }
                            .accessibilityLabel("\(m)月回顾")
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    static func shortDate(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[1])/\(p[2])" : key
    }

    // MARK: 月（plan-calendar-page §2.2）

    var metric: ActivityMetric { ActivityMetric(rawValue: metricRaw) ?? .messages }

    var monthLayout: PencilMonthView.Layout { PencilMonthView.Layout(month: displayedMonth, calendar: calendar) }

    var monthMarks: [Int: PencilMonthDay] {
        let lay = monthLayout
        let chinese = AnniversaryMath.chineseCalendar(timeZone: calendar.timeZone)
        var annDays: [String: Bool] = [:]
        for a in anniversaries {
            for key in AnniversaryMath.occurrenceKeys(of: a, inMonth: lay.firstOfMonth, gregorian: calendar, chinese: chinese) {
                annDays[key] = (annDays[key] ?? false) || a.isBirthday
            }
        }
        let inputs = CalendarMarks.Inputs(
            summary: activity.summary, metric: metric, who: .all,
            journalDates: journalDates, moods: moods, anniversaryDays: annDays,
            periodDays: Set(monthCycleMarks.map { DailyActivity.dayKey($0, calendar: calendar) }),
            todoMarks: TodoManager.marks(TodoManager.shared.items)
        )
        let thresholds = DailyActivity.thresholds(
            recentValues: CalendarMarks.recentValues(activity.summary, metric: metric, who: .all, today: Date(), calendar: calendar),
            metric: metric
        )
        return CalendarMarks.month(lay.firstOfMonth, daysInMonth: lay.daysInMonth, inputs: inputs, thresholds: thresholds, calendar: calendar)
    }

    private var monthContent: some View {
        let marks = monthMarks
        let cardColor = StarCardColor(rawValue: cardColorRaw) ?? .white
        return VStack(alignment: .leading, spacing: 0) {
            monthHeader
            if let p = activity.progress {
                Text("正在数聊天…… \(p.done) / \(p.total)")
                    .font(.system(size: CalType.s))
                    .foregroundColor(CalInk.ink3)
                    .padding(.horizontal, 22)
            }
            if !anniversaries.isEmpty {
                AnniversaryStrip(anniversaries: anniversaries) { _ in
                    withAnimation(.easeInOut(duration: 0.15)) { tab = .anniversaries }
                }
                .padding(.top, 10)
            }
            ZStack {
                PencilMonthView(
                    month: displayedMonth,
                    days: marks,
                    selected: selectedDate,
                    seedKey: profileId,
                    showLightDots: lightDots,
                    accessibilityDetail: { d in
                        guard let date = calendar.date(byAdding: .day, value: d - 1, to: monthLayout.firstOfMonth) else { return "" }
                        let n = activity.summary.days[DailyActivity.dayKey(date, calendar: calendar)]?.messages ?? 0
                        return n > 0 ? "，聊了 \(n) 条" : ""
                    },
                    onSelect: { d in
                        if calendar.isDate(d, inSameDayAs: selectedDate) { dayPage = CalendarDayItem(date: d) } else { selectedDate = d }
                    }
                )
                if usesCard {
                    // 星孔外卡：卡面输入不变不重画（equatable），选中圈 / 今天在上面单独一层；卡不吃点击，点格子照样选日
                    ZStack {
                        StarCardCover(month: displayedMonth, levels: marks.mapValues(\.level), color: cardColor, seedKey: profileId)
                            .equatable()
                            // 卡外沿的投影在 Canvas 外面，得在视图上加（Canvas 会裁掉出界的部分）
                            .shadow(color: .black.opacity(0.16), radius: 2.5, x: 1, y: 2)
                        StarCardMarks(month: displayedMonth, selected: selectedDate, color: cardColor, todos: marks.compactMapValues(\.todo))
                    }
                    .rotation3DEffect(.degrees(cardOpen && !reduceMotion ? -172 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.45)
                    .opacity(cardOpen ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            daySection
        }
    }

    var isCurrentMonth: Bool { calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month) }

    private var monthHeader: some View {
        pageHeader(title: StarCardCover.monthName(displayedMonth),
                   sub: String(calendar.component(.year, from: displayedMonth)),
                   prevLabel: "上个月", nextLabel: "下个月",
                   prev: { shiftMonth(-1) }, next: { shiftMonth(1) }) {
            if usesCard {
                PencilBoxButton(seed: "flip", action: {
                    if reduceMotion { cardOpen.toggle() } else { withAnimation(.easeInOut(duration: 0.9)) { cardOpen.toggle() } }
                    UserDefaults.standard.set(cardOpen, forKey: cardOpenKey)
                }) {
                    Text(cardOpen ? "合上" : "翻开").font(.system(size: 15)).foregroundColor(CalInk.ink)
                }
            }
            if !isCurrentMonth {
                PencilBoxButton(seed: "today", action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        displayedMonth = Date()
                        selectedDate = Date()
                    }
                }) {
                    Text("今天").font(.system(size: 15)).foregroundColor(CalInk.ink)
                }
            }
        }
    }

    // MARK: 当天（标题行整行可点 → 每日页；下面是行，行尾 › = 进入）

    var selectedKey: String { DailyActivity.dayKey(selectedDate, calendar: calendar) }

    /// 那天有贡献的对话（按那天条数从多到少）；首次统计还没出来时退回按创建日
    var conversationsForSelectedDate: [Conversation] {
        if let byConv = activity.summary.conversationsByDay[selectedKey] {
            let byId = Dictionary(allConversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return byConv.sorted { $0.value > $1.value }.compactMap { byId[$0.key] }
        }
        guard activity.summary.days.isEmpty else { return [] }
        let dayStart = calendar.startOfDay(for: selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return allConversations.filter { $0.createTime >= dayStart && $0.createTime < dayEnd }
    }

    /// `星期日 · 聊了 93 条 · 体重 72.2 公斤`
    var dayLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return ([f.string(from: selectedDate)] + dayFacts).joined(separator: " · ")
    }

    /// `9月27日 星期日`（iOS 每日页标题、当天行）
    static func chineseDayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: date)
    }

    /// 这天的几句事实：聊了几条 / 几项待办 / 健康（不含星期）
    var dayFacts: [String] {
        var parts: [String] = []
        let n = activity.summary.days[selectedKey]?.messages ?? 0
        if n > 0 { parts.append("聊了 \(n) 条") }
        let today = TodoManager.dayKey(Date())
        let open = selectedKey == today
            ? TodoManager.shared.actionList(today: today).count
            : TodoManager.shared.items(on: selectedKey).filter { !$0.done }.count
        if open > 0 { parts.append("\(open) 项待办") }
        if let health = CalendarDayHealth.summary(context: modelContext, profileId: profileId, date: selectedDate) { parts.append(health) }
        return parts
    }

    /// 纸：三块（那一天 / 待办 / 对话），手绘波浪框；外边 16 · 块间 10 · 块内 14×10（plan-calendar-v5 §0.1）
    private var daySection: some View {
        let inset = CalendarBlockStyle.inset
        return VStack(alignment: .leading, spacing: 10) {
            CalendarBlock(seed: "day-head") {
                Button { dayPage = CalendarDayItem(date: selectedDate) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(calendar.component(.day, from: selectedDate))").font(CalType.hand(CalType.n)).foregroundColor(CalInk.ink)
                        Text(dayLine).font(.system(size: CalType.s)).foregroundColor(CalInk.ink2).lineLimit(2)
                        Spacer(minLength: 8)
                        Text("›").font(CalType.type(17)).foregroundColor(CalInk.ink).accessibilityHidden(true)
                    }
                    .padding(.horizontal, inset)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PencilPressStyle())
                .accessibilityElement(children: .combine)
                .accessibilityHint("打开这一天")
            }
            CalendarBlock(seed: "day-todo") {
                CalendarTodoList(dayKey: selectedKey, inset: inset)
            }
            CalendarBlock(seed: "day-chat") {
                CalendarBlockHeader(title: "对话")
                dayRows(inset: inset)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// 这天的对话那几行（纸 / iOS 共用数据，行的样子各自的）
    @ViewBuilder
    private func dayRows(inset: CGFloat) -> some View {
        let conversations = conversationsForSelectedDate
        let counts = activity.summary.conversationsByDay[selectedKey] ?? [:]
        let past = CalendarDayPage.onThisDay(selectedDate, summary: activity.summary, conversations: allConversations, calendar: calendar)
        if let note = selectedDiary {
            CalendarRow(icon: "book.closed", title: "\(assistantName)的日记", meta: "\(note.text.count) 字", inset: inset) {
                dayPage = CalendarDayItem(date: selectedDate)
            }
        }
        if conversations.isEmpty {
            Text("这天没有对话")
                .font(.system(size: CalType.s))
                .foregroundColor(CalInk.ink3)
                .padding(.horizontal, inset)
                .padding(.vertical, 12)
        } else {
            ForEach(conversations) { c in
                CalendarRow(icon: CalendarRow.icon(for: c), title: c.title, tag: CalendarRow.tag(for: c),
                            meta: counts[c.id].map { "\($0) 条" }, inset: inset) {
                    viewModel.loadConversation(c, context: modelContext)
                }
            }
        }
        ForEach(past, id: \.conv.id) { item in
            CalendarRow(icon: "sparkle", title: "\(CalendarText.yearsAgo(item.years))：\(item.conv.title)", inset: inset) {
                viewModel.loadConversation(item.conv, context: modelContext)
            }
        }
    }

    // MARK: - 经期（plan-health-cycle §3：只画实际经期日；预测不进铅笔月历）

    private var monthCycleMarks: Set<Date> {
        let allDays = HealthCycleStore.fetchDays(context: modelContext, profileId: profileId)
        return Set(allDays.map { calendar.startOfDay(for: $0.date) })
    }

    // 亲密记录不进日历（格子标记/详情行都不露，隐私拍板 plan-health-intimacy）——别在 dayLine 里加 IntimacyEntry

    // MARK: - Helpers

    func shiftMonth(_ offset: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if let newDate = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
                displayedMonth = newDate
                selectedDate = alignedSelectionDate(for: newDate)
            }
        }
    }

    private func alignedSelectionDate(for month: Date) -> Date {
        let selectedDay = calendar.component(.day, from: selectedDate)
        let targetDay = min(selectedDay, calendar.range(of: .day, in: .month, for: month)?.count ?? selectedDay)
        var comps = calendar.dateComponents([.year, .month], from: month)
        comps.day = targetDay
        return calendar.date(from: comps) ?? month
    }
}

struct DiaryListSheet: View {
    let profileId: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var dates: [String] {
        DailyFileStore.existingDates(profileId: profileId).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            Group {
                if dates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                        Text("还没有日记\n开「时间轴摘要」开关，每天自动写一篇")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PanelSectionList { Section { ForEach(dates, id: \.self) { date in
                        Button {
                            onSelect(date)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(date)
                                        .font(.system(size: Theme.F.body, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                    if let note = DailyFileStore.load(date: date, profileId: profileId) {
                                        Text(note.text.prefix(60))
                                            .font(.system(size: Theme.F.caption))
                                            .foregroundColor(Theme.textMuted)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textMuted.opacity(0.5))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.mainBg)
                    } } }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .toolPageBackground()
            .panelSheetTitle("楼层日记")
            #if os(macOS)
            // mac sheet 不给尺寸会塌成 0（List / ScrollView 都一样）
            .frame(minWidth: 420, minHeight: 480)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
    }
}
