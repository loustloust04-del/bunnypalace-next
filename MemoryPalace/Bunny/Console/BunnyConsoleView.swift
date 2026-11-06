import SwiftUI
import SwiftData

// MARK: - [Bunny] Caelum's Console（P1 首页骨架）
//
// 计划书 docs/bunny/PLAN-console-and-tools.md。四段：CARE / LOG / DAILY / WITH YOU。
// 格子读网关（与 Caelum 工具同一份数据，客户端自大肥兔移植，见 Clients/），点进去用上游的
// RightPanelNavigator 打开粟粟的模块（GPT T3）；上游没有的兔兔页面暂显示「搬家中」。
// UI 细节后续慢慢抠。

struct BunnyConsoleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    @State private var vitals: VitalsResponse?
    @State private var meds: MedsClient.Snapshot?
    @State private var period: PeriodClient.Snapshot?
    @State private var screen: ScreenTimeResponse?
    @State private var murmur: MurmurClient.Item?
    @State private var anniversary: (name: String, text: String)?
    @State private var tweet: TweetsClient.Tweet?
    @State private var boardPost: BoardClient.Post?
    @State private var loading = false
    @State private var showSettings = false
    @State private var todo = TodoManager.shared

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !BunnyGateway.isConfigured {
                    card {
                        Button { showSettings = true } label: {
                            Label("先连上网关（和大肥兔同一个地址和口令）", systemImage: "link")
                        }
                    }
                }
                section("CARE") {
                    HStack(alignment: .top, spacing: 0) {
                        stat("饮水", "drop", vitals.map { "\($0.water.count)" }, vitals.map { "/\($0.water.goal)" }, nil)
                        divider
                        stat("进食", "fork.knife", vitals.map { "\($0.food.count)" }, vitals.map { "/\($0.food.goal)" }, nil)
                        divider
                        stat("药物", "pills", meds.map { "\($0.today.count)" }, meds.map { "/\($0.meds.count)" }, nil) {
                            open("health", "meds")
                        }
                    }
                }
                section("LOG") {
                    HStack(alignment: .top, spacing: 0) {
                        stat("步数", "figure.walk", nil, nil, "未记录")
                        divider
                        stat("睡眠", "moon.zzz", nil, nil, "未记录")
                        divider
                        stat("经期", "calendar", period?.prediction.currentCycleDay.map { "\($0)" }, period == nil ? nil : "天",
                             periodHint) { open("health", "cycle") }
                    }
                }
                section("DAILY") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { open("calendar", Self.dayString(Date())) } label: {
                            row("To Do", todayTodoText, "checklist")
                        }.buttonStyle(.plain)
                        Divider()
                        row("今日屏幕", screen.map { "\(Int($0.total_minutes)) 分钟" } ?? "暂无数据", "hourglass")
                    }
                }
                section("WITH YOU") {
                    VStack(alignment: .leading, spacing: 10) {
                        row("MURMUR", murmur?.content ?? "他每天清晨和午后各写一条心里话", "moon.stars")
                        Divider()
                        Button { open("calendar", "anniv:console") } label: {
                            row("ANNIVERSARY", anniversary.map { "\($0.name) · \($0.text)" } ?? "跟 Caelum 说「记一下我们的纪念日」", "heart")
                        }.buttonStyle(.plain)
                        Divider()
                        Button { open("twitter", "") } label: {
                            row("TO WORLD", tweet?.text ?? "还没有同步到推文", "bird")
                        }.buttonStyle(.plain)
                        Divider()
                        row("留言板", boardPost?.text ?? "点开和 Caelum 互相贴小纸条～", "note.text")
                        Divider()
                        row("他做给你的", "花占い、小游戏、小页面——搬家中", "wand.and.stars")
                        Divider()
                        row("游戏室", "他装修的屋子——搬家中", "dice")
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.mainBg.ignoresSafeArea())
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await reload() } }) {
            NavigationStack { BunnyConsoleSettingsView() }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CAELUM'S CONSOLE").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(Theme.accent)
                Text(greeting).font(.title3).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Date().formatted(.dateTime.month().day())).font(.title2.weight(.bold))
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let name = profileManager?.currentProfile.userName ?? ""
        let base = h < 5 ? "夜深了" : h < 11 ? "早安" : h < 14 ? "中午好" : h < 18 ? "下午好" : "晚上好"
        return name.isEmpty ? base : "\(base)，\(name)"
    }

    private var periodHint: String? {
        guard let p = period?.prediction, p.hasData else { return period == nil ? nil : "还没有记录" }
        if p.onPeriod { return "经期中" }
        if let d = p.daysUntil { return d >= 0 ? "距下次预计还有 \(d) 天" : "已推迟 \(-d) 天" }
        return nil
    }

    private var todayTodoText: String {
        let list = todo.items(on: Self.dayString(Date()))
        if list.isEmpty { return "今天还没有待办" }
        let left = list.filter { !$0.done }.count
        return left == 0 ? "今天的 \(list.count) 件都做完啦" : "还剩 \(left) 件 · \(list.first { !$0.done }?.text ?? "")"
    }

    // MARK: 组件

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.bold)).tracking(2).foregroundStyle(Theme.textMuted)
            card(content)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.opacity(0.85)))
    }

    private var divider: some View {
        Rectangle().fill(Theme.textMuted.opacity(0.2)).frame(width: 0.5).padding(.vertical, 4)
    }

    private func stat(_ title: String, _ icon: String, _ value: String?, _ unit: String?, _ hint: String?,
                      action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.subheadline).foregroundStyle(Theme.textMuted)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value ?? "—").font(.system(size: 32, weight: .regular, design: .serif))
                    if let unit { Text(unit).font(.caption).foregroundStyle(Theme.textMuted) }
                }
                if let hint { Text(hint).font(.caption).foregroundStyle(Theme.accent).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func row(_ title: String, _ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(Theme.textMuted)
                Text(text).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: 行为

    private func open(_ tool: String, _ id: String) {
        navigator?.pendingTarget = .init(tool: tool, id: id)
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func reload() async {
        guard BunnyGateway.isConfigured, !loading else { return }
        loading = true
        defer { loading = false }
        async let v = VitalsClient.fetch()
        async let m = MedsClient.fetch()
        async let p = PeriodClient.fetch()
        async let s = ScreenTimeClient.fetch()
        async let mu = MurmurClient.fetch(limit: 1)
        async let an = AnniversaryClient.fetch()
        async let tw = TweetsClient.fetch(limit: 1)
        async let bd = BoardClient.fetch()
        vitals = await v
        meds = await m
        period = await p
        screen = await s
        murmur = await mu.first
        let anns = await an
        anniversary = anns.lazy.compactMap { item in AnniversaryClient.display(for: item).map { (item.name, $0.text) } }.first
        tweet = await tw.first
        boardPost = await bd.first
        _ = await BunnyTwitterSync.runIfDue(profileId: profileId, context: modelContext)
    }
}
