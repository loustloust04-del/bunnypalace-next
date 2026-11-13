#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI
import SwiftData
import UIKit

/// Caelum's Console — 右滑 page 2 控制台（v9：粟粟设计语言 · Widget 网格）
///
/// 布局：问候 → 饮水/进食 → 待办 → 步数/睡眠 → 药物/屏幕 → 经期 → 给世界的 → Caelum 留言
/// 设计语言（对齐 SusuPalace design-dna）：暖奶白 5 阶色阶分层、几乎无阴影、无衬线中文 +
///   Cormorant 数字（lining）、薄荷绿点缀、圆角 16-18、零装饰。
/// 数据来源：DailyContext（SwiftData）/ HealthKitService / VitalsClient / ScreenTimeClient / BunnyTodoManager。
struct ConsoleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var allContexts: [DailyContext] = []   // [Bunny] 原 @Query：改为从网关组装
    // 统一数据源：健康数据全部读本地 SwiftData（跟健康面板同一份）
    @Query private var localMeds: [Medication]

    // 2026-08-28 兔兔报「切右滑页卡顿」：Console 是桌面默认页，每次切进来都重建。
    // 原本这两个 @Query 无过滤全表拉取，再在内存里 filter 出今天——
    //   localMedLogs：每次吃药写一条，用久了成百上千条，只为显示今天那几条
    //   localCycleDays：只取今天一条，却全表读
    // 改为在谓词里就框定范围，把过滤下推给数据库。
    // MedicationLog 只要今天。
    // 2026-08-30 修：原写 #Predicate { $0.takenAt >= Self.todayStart }，
    // CI #186/#187 报 cannot convert ... to closure result type——
    // #Predicate 宏不接受对静态属性的引用（翻译不成 SQL）。
    // 改用局部常量捕获：宏能把捕获的字面值内联进谓词。
    @Query private var localMedLogs: [MedicationLog]
    // CycleDay 保留全量——HealthCycleStore.periods 需要历史算周期，不能截断。
    @Query(sort: \CycleDay.date, order: .reverse) private var localCycleDays: [CycleDay]

    @State private var healthKit = HealthKitService()
    @State private var vitalsData: VitalsResponse? = nil
    @State private var showMemoBoard: Bool = false
    @State private var showGallery: Bool = false     // 他做给你的小页面（09-28）
    @State private var showGameRoom: Bool = false    // 游戏室（09-28）
    @State private var anniversaries: [AnniversaryClient.Item] = []
    @State private var showAnniversaries: Bool = false
    @State private var murmurs: [MurmurClient.Item] = []
    @State private var showMurmurs: Bool = false
    @State private var latestTweets: [TweetsClient.Tweet] = []
    @State private var showTweets: Bool = false
    @State private var showAddTodo: Bool = false
    @State private var newTodoText: String = ""
    @State private var todo = BunnyTodoManager.shared
    @State private var periodPred: PeriodClient.Prediction? = nil
    @State private var showPeriod: Bool = false
    @State private var showSleep: Bool = false
    @State private var showCare: Bool = false
    @State private var showLog: Bool = false
    @State private var screenData: ScreenTimeResponse? = nil
    @State private var latestBoardPost: BoardClient.Post? = nil
    @State private var medsData: MedsClient.Snapshot? = nil
    @State private var showMeds: Bool = false
    @State private var showScreenDetail: Bool = false

    private var todayCtx: DailyContext? {
        let today = Calendar.current.startOfDay(for: Date())
        return allContexts.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                header
                grid
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg.ignoresSafeArea())
        // 兔兔 0906：控制台没有刷新入口——数据只在进页面那一次拉，跨日或服务端
        // 改过都看不到新的。下拉即全量重拉（与首次进入同一套）。
        .refreshable { await refreshAll() }
        .task { await refreshAll() }
        .alert("添加待办", isPresented: $showAddTodo) {
            TextField("要做的事…", text: $newTodoText)
            Button("取消", role: .cancel) { newTodoText = "" }
            Button("添加") { todo.add(newTodoText); newTodoText = "" }
        }
        .sheet(isPresented: $showGallery) { BunnyMovingInView(title: "他做给你的") }   // [Bunny] 搬家中
        .sheet(isPresented: $showGameRoom) { BunnyMovingInView(title: "游戏室") }   // [Bunny] 搬家中
        .sheet(isPresented: $showMemoBoard, onDismiss: {
            Task { latestBoardPost = await BoardClient.fetch().last }
        }) { MemoBoardView() }
        .sheet(isPresented: $showAnniversaries, onDismiss: {
            Task { anniversaries = await AnniversaryClient.fetch() }
        }) { AnniversaryManageSheet() }
        .sheet(isPresented: $showTweets) { TweetsFeedSheet() }
        .sheet(isPresented: $showMurmurs) { MurmurFeedSheet(items: murmurs) }
        .sheet(isPresented: $showPeriod, onDismiss: {
            Task { if let snap = await PeriodClient.fetch() { periodPred = snap.prediction } }
        }) { PeriodSheet() }
        .sheet(isPresented: $showSleep) {
            if let ctx = todayCtx { SleepSheet(context: ctx) }
        }
        .sheet(isPresented: $showCare) {
            CareView(contexts: allContexts, vitals: vitalsData, period: periodPred)
        }
        .sheet(isPresented: $showLog) {
            LogView(contexts: allContexts, todayNotes: vitalsData?.notes ?? [])
        }
        .sheet(isPresented: $showScreenDetail) {
            ScreenTimeDetailView(initial: screenData)
        }
        .sheet(isPresented: $showMeds, onDismiss: {
            Task { medsData = await MedsClient.fetch() }
        }) { MedsSheet() }
    }

    /// 控制台全量刷新：首次进入（.task）与下拉（.refreshable）共用同一套
    @MainActor
    private func refreshAll() async {
            // 健康数据双向同步（本地 SwiftData ↔ Gateway 药品柜 ↔ Caelum）
            if let pid = profileManager?.currentProfile.id {
                await BunnyMedsSync.run(context: modelContext, profileId: pid)   // [Bunny] 原 HealthSyncService
            }
            loadVitals()
            allContexts = await BunnyDailyContexts.load(keeping: allContexts)   // [Bunny] 原 @Query DailyContext + VitalsSyncService：从网关组装
            anniversaries = await AnniversaryClient.fetch()
            murmurs = await MurmurClient.fetch()
            latestTweets = await TweetsClient.fetch(limit: 40)
            latestBoardPost = await BoardClient.fetch().last
            medsData = await MedsClient.fetch()
            ensureTodayContext()
            await todo.refresh()
            await healthKit.requestAuthorization()
            if healthKit.authState == .authorized, let ctx = todayCtx {
                await healthKit.populate(context: ctx)
            }
            // 经期：把 Apple 健康的来潮日同步到网关，再拉预测
            if healthKit.authState == .authorized {
                let starts = await healthKit.fetchMenstrualStarts()
                if !starts.isEmpty { _ = await PeriodClient.sync(dates: starts) }
            }
            if let snap = await PeriodClient.fetch() { periodPred = snap.prediction }
            if let st = await ScreenTimeClient.fetch() {
                screenData = st
                if let ctx = todayCtx {
                    ctx.screenTime = st.total_minutes / 60.0
                    ctx.socialScreenTime = st.social_minutes / 60.0
                    try? modelContext.save()
                }
            }
            // 健康桥：HealthKit/屏幕时间填好后把今日摘要报给网关（30 分钟节流）
            if let ctx = todayCtx { await HealthBridgeClient.report(from: ctx) }
            // Pocket Browser：若已开启，连上让 Caelum 能借手机浏览
            // [Bunny] Pocket（口袋浏览器）随 P5 再接
    }

    private func ensureTodayContext() { BunnyDailyContexts.ensureToday(&allContexts) }   // [Bunny]
    private func loadVitals() {
        Task { let v = await VitalsClient.fetch(); await MainActor.run { vitalsData = v } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CAELUM'S CONSOLE")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(2.5)
                    .foregroundColor(Self.greenDeep)
                Text(greetingString)
                    .font(.system(size: 14.5))
                    .foregroundColor(Self.textSub)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(monthDayStr).font(.system(size: 19, weight: .semibold)).foregroundColor(Self.textPrimary)
                Text("\(weekdayCN(Date())) · \(solarTerm(Date()))")
                    .font(.system(size: 12)).foregroundColor(Self.textMuted)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeaderTappable("CARE") { showCare = true }
            careTrio
            sectionHeaderTappable("LOG") { showLog = true }
            logTrio
            sectionLabel("DAILY")
            todoWidget
            screenWide
            sectionLabel("WITH YOU")
            murmurWidget
            anniversaryWidget
            worldWidget
            caelumWidget
            galleryWidget
            gameRoomWidget
        }
    }

    private var gameRoomWidget: some View {
        wideWidget {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Self.green).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "dice").font(.system(size: 13)).foregroundColor(Self.greenDeep)
                        Text("游戏室").font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(red: 66/255, green: 61/255, blue: 55/255))
                    }
                    Text("他装修的屋子——和他本人对局")
                        .font(.system(size: 11)).foregroundColor(Self.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Self.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showGameRoom = true }
    }

    // MARK: - 他做给你的小页面（09-28）

    private var galleryWidget: some View {
        wideWidget {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Self.green).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.system(size: 13)).foregroundColor(Self.greenDeep)
                        Text("他做给你的").font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(red: 66/255, green: 61/255, blue: 55/255))
                    }
                    Text("花占い、小游戏、小页面——全收在这儿，点开还能玩")
                        .font(.system(size: 11)).foregroundColor(Self.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Self.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showGallery = true }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 11, weight: .semibold)).tracking(1.5)
            .foregroundColor(Self.textSub)
            .padding(.leading, 4)
            .padding(.top, 9)
    }

    /// 可点的分区标题（CARE / LOG 点开二级界面）。
    private func sectionHeaderTappable(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(t)
                    .font(.system(size: 11, weight: .semibold)).tracking(1.5)
                    .foregroundColor(Self.textSub)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Self.textFaint)
                Spacer()
            }
            .padding(.leading, 4)
            .padding(.top, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 三合一紧凑卡（CARE / LOG）

    private var careTrio: some View {
        wideWidget {
            HStack(alignment: .top, spacing: 0) {
                trioCell(icon: "drop", label: "饮水") {
                    // max 创可贴：Caelum 记网关(vitals)、App 记本地互不见，取大者先保证不丢显示；正解=扩展双向同步(DEBT-MAP)
                    let w = vitalsData?.water.count ?? todayCtx?.waterCount ?? 0   // 网关唯一真相
                    bigNum("\(w)", "/6", size: 26)
                    dotsRow(on: w, total: 6).padding(.top, 6)
                }
                trioDivider
                trioCell(icon: "fork.knife", label: "进食") {
                    let count = vitalsData?.food.meals.count ?? todayCtx?.meals.count ?? 0   // 网关唯一真相
                    let goal = vitalsData?.food.goal ?? 3
                    bigNum("\(count)", "/\(goal)", size: 26)
                    Text(vitalsData?.food.meals.last ?? todayCtx?.meals.last?.description ?? "未记录")
                        .font(.system(size: 10.5)).foregroundColor(Self.textMuted)
                        .lineLimit(1).padding(.top, 6)
                }
                trioDivider
                trioCell(icon: "pills", label: "药物", gold: medsUntakenToday) {
                    // 统一数据源：读本地 SwiftData（跟健康面板同一份）
                    let (taken, total) = localMedProgress
                    if total > 0 {
                        bigNum("\(taken)", "/\(total)", size: 26)
                        Text(taken == total ? "已服完" : "待服 \(total - taken)")
                            .font(.system(size: 10.5))
                            .foregroundColor(taken == total ? Self.green : Self.gold)
                            .lineLimit(1).padding(.top, 6)
                    } else {
                        Text("—").font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Self.textFaint).padding(.top, 5)
                        Text("点击加药").font(.system(size: 10.5))
                            .foregroundColor(Self.textMuted).lineLimit(1).padding(.top, 5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showMeds = true }
            }
        }
    }

    private var logTrio: some View {
        wideWidget {
            HStack(alignment: .top, spacing: 0) {
                trioCell(icon: "shoeprints.fill", label: "步数") {
                    bigNum(todayCtx?.steps.map(stepsFormatted) ?? "—", "", size: 26)
                    Text(todayCtx?.steps != nil ? "今日" : "未记录")
                        .font(.system(size: 10.5)).foregroundColor(Self.textMuted).padding(.top, 6)
                }
                trioDivider
                trioCell(icon: "moon.stars", label: "睡眠") {
                    bigNum(sleepHours, sleepUnit, size: 26)
                    Text(sleepSub.isEmpty ? " " : sleepSub)
                        .font(.system(size: 10.5)).foregroundColor(Self.textMuted)
                        .lineLimit(1).padding(.top, 6)
                }
                .contentShape(Rectangle())
                .onTapGesture { ensureTodayContext(); showSleep = true }
                trioDivider
                trioCell(icon: "calendar", label: "经期") {
                    // 统一数据源：本地 SwiftData 优先（跟健康面板同一份）
                    if let local = localCycleStatus {
                        if let dayNum = local.day {
                            bigNum("\(dayNum)", "天", size: 26)
                        } else {
                            Text("—").font(.cormorant(26)).foregroundColor(Self.textPrimary)
                        }
                        Text(local.line)
                            .font(.system(size: 10.5))
                            .foregroundColor(local.onPeriod ? Self.gold : Self.greenDeep)
                            .lineLimit(1).padding(.top, 6)
                    } else if let p = periodPred, p.hasData {
                        if p.onPeriod, let d = p.currentCycleDay {
                            bigNum("\(d)", "天", size: 26)
                            Text("经期中").font(.system(size: 10.5)).foregroundColor(Self.gold).padding(.top, 6)
                        } else if let du = p.daysUntil, du >= 0 {
                            bigNum("\(du)", "天", size: 26)
                            Text(du <= 3 ? "快来了" : p.phase)
                                .font(.system(size: 10.5)).foregroundColor(Self.greenDeep).padding(.top, 6)
                        } else if let du = p.daysUntil {
                            bigNum("\(-du)", "天", size: 26)
                            Text("推迟").font(.system(size: 10.5)).foregroundColor(Self.gold).padding(.top, 6)
                        } else {
                            Text(p.phase).font(.cormorant(26)).foregroundColor(Self.textPrimary)
                            Text("预测").font(.system(size: 10.5)).foregroundColor(Self.textMuted).padding(.top, 6)
                        }
                    } else if let day = todayCtx?.menstrualDay {
                        bigNum("\(day)", "天", size: 26)
                        Text(menstrualPhase(day))
                            .font(.system(size: 10.5)).foregroundColor(Self.greenDeep).padding(.top, 6)
                    } else {
                        Text("—").font(.cormorant(26)).foregroundColor(Self.textFaint)
                        Text("未记录").font(.system(size: 10.5)).foregroundColor(Self.textMuted).padding(.top, 6)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showPeriod = true }
            }
        }
    }

    private var trioDivider: some View {
        Rectangle().fill(Self.line).frame(width: 1)
            .padding(.vertical, 3).padding(.horizontal, 10)
    }

    private func trioCell<C: View>(icon: String, label: String, gold: Bool = false,
                                   @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                    .foregroundColor(gold ? Self.gold : Self.green)
                Text(label).font(.system(size: 11)).foregroundColor(Self.textSub)
            }
            .padding(.bottom, 7)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 今日屏幕 wide（DAILY）

    private var screenWide: some View {
        wideWidget {
            HStack(spacing: 13) {
                Image(systemName: "hourglass").font(.system(size: 17))
                    .foregroundColor(Self.green).frame(width: 26)
                VStack(alignment: .leading, spacing: 7) {
                    if let st = todayCtx?.screenTime {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("今日屏幕").font(.system(size: 13, weight: .medium)).foregroundColor(Self.textSub)
                            Text(String(format: "%.1f", st)).font(.cormorant(20)).foregroundColor(Self.textPrimary)
                            Text("h").font(.system(size: 11)).foregroundColor(Self.textFaint)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Self.sink)
                                Capsule().fill(Self.green)
                                    .frame(width: g.size.width * min(1, st / 8.0))
                            }
                        }
                        .frame(height: 5)
                    } else {
                        Text("今日屏幕 · 暂无数据").font(.system(size: 13)).foregroundColor(Self.textFaint)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Self.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showScreenDetail = true }
    }

    // MARK: - 待办 wide

    private var todoWidget: some View {
        wideWidget {
            VStack(spacing: 0) {
                HStack {
                    Text("To Do").font(.system(size: 11.5, weight: .medium)).tracking(0.5)
                        .foregroundColor(Self.textSub)
                    Spacer()
                }
                .padding(.bottom, 2)
                let items = todo.sorted
                if items.isEmpty {
                    HStack {
                        Text("今天还没有待办").font(.system(size: 14)).foregroundColor(Self.textFaint)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        todoRow(item)
                        if idx < items.count - 1 {
                            Rectangle().fill(Self.line).frame(height: 1)
                        }
                    }
                }
                Button { showAddTodo = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("添加待办").font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(Self.greenDeep).padding(.top, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func todoRow(_ item: BunnyTodoItem) -> some View {
        HStack(spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { todo.toggle(item.id) } } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.done ? Self.green : Color(red: 207/255, green: 200/255, blue: 187/255), lineWidth: 1.5)
                        .background(Circle().fill(item.done ? Self.green : Color.clear))
                        .frame(width: 18, height: 18)
                    if item.done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            Text(item.text)
                .font(.system(size: 14))
                .foregroundColor(item.done ? Self.textFaint : Color(red: 66/255, green: 61/255, blue: 55/255))
                .strikethrough(item.done, color: Self.textFaint)
            Spacer()
            if let src = item.source {
                Text(src).font(.system(size: 10)).foregroundColor(Self.textFaint)
            }
        }
        .padding(.vertical, 9).contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { todo.delete(item.id) } label: { Label("删除", systemImage: "trash") }
            if item.done {
                Button { todo.toggle(item.id) } label: { Label("标为未完成", systemImage: "arrow.uturn.backward") }
            }
        }
    }

    // MARK: - 纪念日 wide

    private var anniversaryWidget: some View {
        wideWidget {
            VStack(alignment: .leading, spacing: 0) {
                widgetHead("ANNIVERSARY", icon: "heart",
                           gold: anniversaries.contains { AnniversaryClient.display(for: $0)?.highlight == true })
                if anniversaries.isEmpty {
                    Text("跟 Caelum 说「记一下我们的纪念日」")
                        .font(.system(size: 13))
                        .foregroundColor(Self.textFaint)
                        .padding(.top, 10)
                } else {
                    VStack(spacing: 8) {
                        ForEach(anniversaries.prefix(3)) { item in
                            anniversaryRow(item)
                        }
                    }
                    .padding(.top, 11)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showAnniversaries = true }
    }

    private func anniversaryRow(_ item: AnniversaryClient.Item) -> some View {
        let disp = AnniversaryClient.display(for: item)
        return HStack(alignment: .firstTextBaseline) {
            Text(item.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Self.textPrimary)
            Spacer()
            Text(disp?.text ?? "已过去")
                .font(.cormorant(16))
                .foregroundColor(disp?.highlight == true ? Self.gold : Self.textSub)
        }
    }

    // MARK: - 他的心里话（murmur）wide

    private var murmurWidget: some View {
        wideWidget {
            HStack(spacing: 13) {
                Image(systemName: "moon.stars").font(.system(size: 20, weight: .regular)).foregroundColor(Self.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MURMUR").font(.system(size: 11.5, weight: .medium)).tracking(1).foregroundColor(Self.textSub)
                    if let m = murmurs.first {
                        Text(m.content).font(.system(size: 14)).foregroundColor(Self.textPrimary).lineLimit(2)
                    } else {
                        Text("他每天清晨和午后各写一条心里话，还没到点")
                            .font(.system(size: 12.5)).foregroundColor(Self.textFaint)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Self.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showMurmurs = true }
    }

    // MARK: - 给世界的（Twitter MCP）wide

    private var worldWidget: some View {
        wideWidget {
            HStack(spacing: 13) {
                Image(systemName: "bird").font(.system(size: 20, weight: .regular)).foregroundColor(Self.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TO WORLD").font(.system(size: 11.5, weight: .medium)).tracking(1).foregroundColor(Self.textSub)
                    if let t = latestTweets.first {
                        Text(t.text).font(.system(size: 14)).foregroundColor(Self.textPrimary).lineLimit(2)
                    } else {
                        Text("还没有同步到推文").font(.system(size: 12.5)).foregroundColor(Self.textFaint)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Self.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showTweets = true }
    }

    // MARK: - Caelum 留言 wide

    private var caelumWidget: some View {
        wideWidget {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Self.green).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    Text(latestBoardPost?.text ?? "点开和 Caelum 互相贴小纸条～")
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 66/255, green: 61/255, blue: 55/255))
                        .lineSpacing(3)
                        .lineLimit(3)
                    HStack {
                        Text(latestBoardPost.map { "\(boardTimeText($0.ts)) · \(boardAuthorText($0.by))" } ?? "留言板")
                            .font(.system(size: 11)).foregroundColor(Self.textMuted)
                        Spacer()
                        Text("查看全部 →").font(.system(size: 11)).foregroundColor(Self.greenDeep)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showMemoBoard = true }
    }

    // MARK: - Widget 容器 & 通用件

    private func wideWidget<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.mainBg))
    }

    private func widgetHead(_ label: String, icon: String, gold: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.system(size: 11.5, weight: .medium)).tracking(0.5).foregroundColor(Self.textSub)
            Spacer()
            Image(systemName: icon).font(.system(size: 14, weight: .regular))
                .foregroundColor(gold ? Self.gold : Self.green)
        }
    }

    private func bigNum(_ main: String, _ unit: String, size: CGFloat = 33) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(main).font(.cormorant(size)).foregroundColor(Self.textPrimary)
            if !unit.isEmpty {
                Text(unit).font(.system(size: size * 0.4)).foregroundColor(Self.textFaint)
            }
        }
    }

    private func dotsRow(on: Int, total: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { i in
                Circle().fill(i < on ? Self.green : Self.sink).frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - 数据文案

    private var greetingString: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<5:   return "夜深了，天奕"
        case 5..<12:  return "早上好，天奕"
        case 12..<18: return "下午好，天奕"
        default:      return "晚上好，天奕"
        }
    }

    private var monthDayStr: String {
        let c = Calendar.current
        return "\(c.component(.month, from: Date())) 月 \(c.component(.day, from: Date())) 日"
    }

    private func weekdayCN(_ date: Date) -> String {
        let w = Calendar.current.component(.weekday, from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[(w - 1) % 7]
    }

    /// 公历近似 24 节气：取当前日期所在（最近已过）的节气名。
    private func solarTerm(_ date: Date) -> String {
        let c = Calendar.current
        let m = c.component(.month, from: date), d = c.component(.day, from: date)
        let terms: [(Int, Int, String)] = [
            (1,5,"小寒"),(1,20,"大寒"),(2,4,"立春"),(2,19,"雨水"),
            (3,5,"惊蛰"),(3,20,"春分"),(4,4,"清明"),(4,20,"谷雨"),
            (5,5,"立夏"),(5,21,"小满"),(6,5,"芒种"),(6,21,"夏至"),
            (7,7,"小暑"),(7,22,"大暑"),(8,7,"立秋"),(8,23,"处暑"),
            (9,7,"白露"),(9,23,"秋分"),(10,8,"寒露"),(10,23,"霜降"),
            (11,7,"立冬"),(11,22,"小雪"),(12,7,"大雪"),(12,21,"冬至")
        ]
        var current = "冬至"
        for (tm, td, name) in terms where m > tm || (m == tm && d >= td) { current = name }
        return current
    }

    private var sleepValue: String {
        guard let dur = todayCtx?.sleepDuration else { return "—" }
        let h = Int(dur), mn = Int((dur - Double(h)) * 60)
        return mn > 0 ? "\(h)h\(mn)" : "\(h)h"
    }
    /// 睡眠拆成「大数字小时 + 小单位」，跟其它 trio 数字统一（不再整串 Cormorant）。
    private var sleepHours: String {
        guard let dur = todayCtx?.sleepDuration else { return "—" }
        return "\(Int(dur))"
    }
    private var sleepUnit: String {
        guard let dur = todayCtx?.sleepDuration else { return "" }
        let m = Int((dur - Double(Int(dur))) * 60)
        return m > 0 ? "h\(m)" : "h"
    }
    private var sleepSub: String {
        if let s = todayCtx?.sleepStart, let e = todayCtx?.sleepEnd {
            return "\(timeString(s)) – \(timeString(e))"
        }
        return todayCtx?.sleepDuration != nil ? "" : "未记录"
    }
    /// 本地经期状态：nil = 无本地数据（回退网关预测）
    private var localCycleStatus: (day: Int?, line: String, onPeriod: Bool)? {
        let periods = HealthCycleStore.periods(days: localCycleDays)
        let today = localCycleDays.first { Calendar.current.isDateInToday($0.date) }
        let flow = today.flatMap { CycleFlow(rawValue: $0.flow) }
        guard !periods.isEmpty || flow != nil else { return nil }
        let line = HealthCycleStore.statusLine(todayFlow: flow, periods: periods, now: Date())
        let day = HealthCycleStore.currentCycleDay(periods: periods, now: Date())
        return (day, line, flow != nil)
    }

    /// 本地药物今日进度：(已服, 总计)
    private var localMedProgress: (Int, Int) {
        let now = Date()
        // 注：@Query 谓词下推那版 CI 编不过（#Predicate 不接受静态属性引用），
        // 暂回内存过滤。卡顿的大头（Console 成为默认首页）已由别处缓解；
        // 真要下推需把「今天零点」做成 @Query(filter:) 的运行时参数，另起一刀。
        let todayLogs = localMedLogs.filter { Calendar.current.isDateInToday($0.takenAt) }
        var total = 0, taken = 0
        for med in localMeds where !med.isArchived {
            for slot in med.timesOfDay {
                total += 1
                if case .taken = HealthLogStore.medState(medication: med, minuteOfDay: slot, todayLogs: todayLogs, now: now) {
                    taken += 1
                }
            }
        }
        return (taken, total)
    }

    private var medsTaken: Bool { todayCtx?.medicationStatus == .taken || vitalsData?.meds.taken == true }
    private var medsUntakenToday: Bool {
        guard let snap = medsData else { return false }
        return !snap.meds.isEmpty && snap.today.isEmpty
    }
    private var medsName: String { vitalsData?.meds.name ?? todayCtx?.medicationName ?? "右佐匹克隆" }

    private func menstrualPhase(_ day: Int) -> String {
        switch day {
        case ...5:    return "经期"
        case 6...13:  return "卵泡期"
        case 14...16: return "排卵期"
        default:      return "黄体期"
        }
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
    private func shortMD(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M.d"; return f.string(from: date)
    }
    private func noteTime(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "刚刚" }
        return timeString(d)
    }
    private func boardAuthorText(_ by: String) -> String { by == "caelum" ? "Caelum" : "你" }
    private func boardTimeText(_ iso: String) -> String {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f1.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return "刚刚" }
        return Calendar.current.isDateInToday(d) ? timeString(d) : shortMD(d)
    }
    private func stepsFormatted(_ n: Int) -> String {
        let fmt = NumberFormatter(); fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}


// MARK: - Design tokens（v9：SusuPalace 暖奶白 + 薄荷绿）

extension ConsoleView {
    static let pageBg      = Color(red: 255/255, green: 251/255, blue: 246/255) // #FFFBF6
    static let card        = Color(red: 243/255, green: 242/255, blue: 235/255) // #F3F2EB
    static let sink        = Color(red: 237/255, green: 231/255, blue: 221/255) // #EDE7DD
    static let textPrimary = Color(red:  61/255, green:  54/255, blue:  51/255) // #3D3633
    static let textSub     = Color(red: 128/255, green: 120/255, blue: 112/255) // #807870
    static let textLabel   = Color(red: 173/255, green: 166/255, blue: 158/255) // #ADA69E
    static let textUnit    = Color(red: 155/255, green: 142/255, blue: 126/255) // #9B8E7E（GatewayConsoleView 引用，勿删）
    static let textMuted   = Color(red: 173/255, green: 166/255, blue: 158/255) // #ADA69E
    static let textFaint   = Color(red: 196/255, green: 188/255, blue: 176/255) // #C4BCB0
    static let line        = Color(red: 228/255, green: 222/255, blue: 211/255) // #E4DED3
    static let green       = Color(red: 142/255, green: 189/255, blue: 159/255) // #8EBD9F
    static let greenDeep   = Color(red:  95/255, green: 146/255, blue: 119/255) // #5F9277
    static let gold        = Color(red: 217/255, green: 169/255, blue:  78/255) // #D9A94E
}

// MARK: - 控制台字体（Cormorant Garamond 数字，强制 lining figures 修掉 oldstyle "11→II"）

private extension Font {
    static func cormorant(_ size: CGFloat) -> Font {
        let name = "CormorantGaramondLight-SemiBold"
        guard let base = UIFont(name: name, size: size) else { return .custom(name, size: size) }
        let desc = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: 21,     // kNumberCaseType
                UIFontDescriptor.FeatureKey.selector: 1   // kUpperCaseNumbersSelector（lining）
            ]]
        ])
        return Font(UIFont(descriptor: desc, size: size))
    }
}

// MARK: - 他的心里话列表

/// murmur 时间线：正文为主，长按一条看他写正文前的思考（同「他当时在想…」的口径——
/// 心里话本身已经是私密的了，思考再收一层）。
struct MurmurFeedSheet: View {
    let items: [MurmurClient.Item]
    @Environment(\.dismiss) private var dismiss
    @State private var thinkingText: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.zzz").font(.system(size: 28)).foregroundColor(ConsoleView.textFaint)
                        Text("还没有心里话——他每天 4:00 和 14:00 各写一条")
                            .font(.system(size: 13)).foregroundColor(ConsoleView.textFaint)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(items) { m in
                                VStack(alignment: .leading, spacing: 5) {
                                    if let d = m.createdDate {
                                        Text(d.formatted(.dateTime.month().day().hour().minute()))
                                            .font(.system(size: 11)).foregroundColor(ConsoleView.textFaint)
                                    }
                                    Text(m.content)
                                        .font(.system(size: 15))
                                        .foregroundColor(ConsoleView.textPrimary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(ConsoleView.card))
                                .contextMenu {
                                    if let t = m.thinking, !t.isEmpty {
                                        Button { thinkingText = t } label: {
                                            Label("他写这句之前在想…", systemImage: "cloud")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(ConsoleView.pageBg.ignoresSafeArea())
            .navigationTitle("他的心里话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: Binding(get: { thinkingText != nil }, set: { if !$0 { thinkingText = nil } })) {
                if let t = thinkingText {
                    ThinkingSheet(text: t)   // [Bunny] 用上游同名页（大肥兔这页本就源自上游）
                }
            }
        }
    }
}
#endif
