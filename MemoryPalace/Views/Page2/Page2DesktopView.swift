#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Page 2 新桌面「针脚点阵」——与经典桌面（DashboardView）并存，设置里切换。
/// 结构：问候区（双头像）/ 撕纸计划卡 / 待办卡+单词卡 / 应用网格；dock 由本文件自己画（老的 ToolBarView 已于 09-15 死码刀删除，只留下拖拽重排的 delegate）。
/// 应用网格有自己的成员+顺序（Page2DesktopManager，与 dock 解耦）；
/// 长按图标或空白进编辑态（学 DashboardView：抖动 + ✕ + 拖拽重排 + 添加区）。
struct Page2DesktopView: View {
    @Binding var selectedToolId: String
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var todo = TodoManager.shared
    @State private var deskMgr = Page2DesktopManager.shared
    @AppStorage("userName") private var userName = "你"
    @State private var vocabStreak = 0
    @State private var vocabReviewedToday = 0
    @State private var vocabDue = 0
    @State private var editing = false
    @State private var wobble = false
    @State private var draggingAppId: String? = nil

    private let springAnim: Animation = .spring(response: 0.45, dampingFraction: 0.75)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                greeting
                    .padding(.horizontal, Page2Metrics.gridMargin)
                planCard
                    .padding(.horizontal, 26)
                    .padding(.top, Page2Metrics.widgetTop)
                widgetRow
                    .padding(.horizontal, 26)
                    .padding(.top, Page2Metrics.widgetGap)
                appGrid
                    .padding(.horizontal, Page2Metrics.gridMargin)
                    .padding(.top, Page2Metrics.gridTop)
                if gridTools.isEmpty && !editing {
                    Text("桌面空了，长按空白处添加")
                        .font(.system(size: 12))
                        .foregroundColor(Page2Palette.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Page2Metrics.gridTop)
                }
                if editing && !addableTools.isEmpty {
                    addSection
                        .padding(.horizontal, Page2Metrics.gridMargin)
                        .padding(.top, 22)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        if !editing {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editing = true }
                        }
                    }
            )
        }
        .overlay(alignment: .topTrailing) {
            if editing { doneButton }
        }
        .background(desktopBackground)
        .task { refreshVocab() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { wobble = true }
        }
    }

    // MARK: - 问候区

    private var greeting: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(enGreeting)
                        .font(Page2Fonts.enLabel(11))
                        .foregroundColor(Page2Palette.inkFaint)
                    TwinkleMark()
                }
                Text("\(cnGreeting)，\(userName)")
                    .font(Page2Fonts.cnTitle(28))
                    .foregroundColor(Page2Palette.ink)
                    .padding(.leading, 5)
                Text(subLine)
                    .font(.system(size: 13))
                    .foregroundColor(Page2Palette.inkSoft)
            }
            Spacer(minLength: 0)
            HStack(spacing: -10) {
                ProfileAvatarView(profile: profileManager?.currentProfile, owner: .user, size: 44)
                    .overlay(Circle().stroke(Page2Palette.canvas, lineWidth: 2))
                ProfileAvatarView(profile: profileManager?.currentProfile, owner: .assistant, size: 44)
                    .overlay(Circle().stroke(Page2Palette.canvas, lineWidth: 2))
            }
            .padding(.top, 4)
        }
    }

    private var hourBand: Int {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 5 { return 3 }
        if h < 11 { return 0 }
        if h < 13 { return 1 }
        if h < 18 { return 2 }
        return 3
    }

    private var enGreeting: String {
        ["good morning, dreamer", "good noon, dreamer", "good afternoon, dreamer", "good evening, dreamer"][hourBand]
    }

    private var cnGreeting: String {
        ["早上好", "中午好", "下午好", "晚上好"][hourBand]
    }

    private var subLine: String {
        let pool = ["柔软的一天也是好的一天。", "慢慢来，比较快。", "今天也和花园一起呼吸。"]
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return pool[day % pool.count]
    }

    // MARK: - 撕纸计划卡

    private var firstTodoText: String? {
        todo.items.first(where: { !$0.done })?.text
    }

    private var planTitle: String {
        var parts: [String] = []
        if let t = firstTodoText { parts.append(String(t.prefix(10))) }
        if vocabDue > 0 { parts.append("复习 \(vocabDue) 词") }
        return parts.isEmpty ? "今天没有安排，自由生长" : parts.joined(separator: " · ")
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("今天的计划")
                .font(.system(size: 13))
                .foregroundColor(Page2Palette.inkSoft)
            Text(planTitle)
                .font(Page2Fonts.cnTitle(19))
                .foregroundColor(Page2Palette.ink)
                .lineLimit(2)
                .padding(.top, 10)
            HStack(spacing: 5) {
                if firstTodoText != nil { planPill("待办") }
                if vocabDue > 0 { planPill("复习") }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            Text(planDetail)
                .font(.system(size: 12))
                .foregroundColor(Page2Palette.ink.opacity(0.58))
        }
        .padding(Page2Metrics.widgetPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Page2Metrics.widgetSmall)
        .background(
            Page2TornShape()
                .fill(Page2Palette.planCard)
        )
    }

    private var planDetail: String {
        var bits: [String] = []
        if todo.remaining > 0 { bits.append("待办 \(todo.remaining) 项") }
        if vocabDue > 0 { bits.append("SM-2 今天到期 \(vocabDue) 词") }
        return bits.isEmpty ? "空白也是一种计划。" : bits.joined(separator: "；")
    }

    private func planPill(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10.5))
            .foregroundColor(Page2Palette.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.88)))
    }

    // MARK: - 待办卡 + 单词卡

    private var widgetRow: some View {
        HStack(spacing: Page2Metrics.widgetGap) {
            todoCardView
            vocabCardView
        }
    }

    private var todoCardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今日待办")
                    .font(.system(size: 13))
                    .foregroundColor(Page2Palette.inkSoft)
                Spacer()
                if !todo.items.isEmpty {
                    Text("\(todo.items.count - todo.remaining) of \(todo.items.count)")
                        .font(Page2Fonts.enLabel(10))
                        .foregroundColor(Page2Palette.inkFaint)
                }
            }
            if todo.items.isEmpty {
                Spacer()
                Text("没有待办，自由生长")
                    .font(.system(size: 12))
                    .foregroundColor(Page2Palette.inkFaint)
                Spacer()
            } else {
                ForEach(todo.items.prefix(3)) { item in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { todo.toggle(item.id) }
                    } label: {
                        HStack(spacing: 9) {
                            StitchCheckbox(done: item.done)
                            Text(item.text)
                                .font(.system(size: 12.5))
                                .strikethrough(item.done, color: Page2Palette.inkFaint)
                                .foregroundColor(item.done ? Page2Palette.inkFaint : Page2Palette.ink.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 11)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Page2Metrics.widgetPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Page2Metrics.widgetSmall)
        .background(
            RoundedRectangle(cornerRadius: Page2Metrics.widgetRadius, style: .continuous)
                .fill(Page2Palette.todoCard)
        )
    }

    private var vocabCardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("单词")
                .font(.system(size: 13))
                .foregroundColor(Page2Palette.cream.opacity(0.8))
            Text("\(vocabStreak)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(Page2Palette.cream)
                .padding(.top, 6)
            Text("天连续 · 今日复习 \(vocabReviewedToday)")
                .font(.system(size: 12.5))
                .foregroundColor(Page2Palette.cream.opacity(0.88))
                .padding(.top, 2)
            Spacer(minLength: 0)
            DotProgressStrip(
                filled: min(7, Int((Double(vocabReviewedToday) / 50.0 * 7).rounded(.up))),
                onColor: Page2Palette.cream.opacity(0.95),
                offColor: Page2Palette.cream.opacity(0.28)
            )
        }
        .padding(Page2Metrics.widgetPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Page2Metrics.widgetSmall)
        .background(
            RoundedRectangle(cornerRadius: Page2Metrics.widgetRadius, style: .continuous)
                .fill(Page2Palette.accentCard)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(springAnim) { selectedToolId = "vocab" }
        }
    }

    // MARK: - 应用网格（成员+顺序独立于 dock，Page2DesktopManager）

    private var gridTools: [RightPanelTool] {
        guard let tm = toolManager else { return [] }
        return deskMgr.desktopTools(tm)
    }

    /// 启用了但不在桌面上的工具（编辑态「添加」区）
    private var addableTools: [RightPanelTool] {
        guard let tm = toolManager else { return [] }
        let onDesk = Set(gridTools.map(\.id))
        return tm.pinnedTools.filter { !onDesk.contains($0.id) }
    }

    private var appGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: Page2Metrics.gridRowGap
        ) {
            ForEach(gridTools) { tool in
                appCell(tool)
            }
        }
    }

    @ViewBuilder
    private func appCell(_ tool: RightPanelTool) -> some View {
        let cell = VStack(spacing: Page2Metrics.labelGap) {
            ZStack {
                RoundedRectangle(cornerRadius: Page2Metrics.iconRadius, style: .continuous)
                    .fill(Page2Palette.surface)
                if tool.id == "topicBox" {
                    PixelIcon(bitmap: PixelGlyph.lightbulb, size: 22, color: Page2Palette.ink)
                } else {
                    AppIconView(name: tool.icon, size: 22, tint: Page2Palette.ink, toolID: tool.id)
                }
            }
            .frame(width: Page2Metrics.iconSize, height: Page2Metrics.iconSize)
            .overlay(alignment: .topLeading) {
                if editing {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if let tm = toolManager { deskMgr.removeFromDesktop(tool.id, tm: tm) }
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Page2Palette.cream)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Page2Palette.ink.opacity(0.75)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -7, y: -7)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            Text(tool.name)
                .font(.system(size: Page2Metrics.labelSize))
                .foregroundColor(Page2Palette.ink.opacity(0.75))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .rotationEffect(.degrees(editing ? (wobble ? 1.3 : -1.3) : 0))
        .opacity(draggingAppId == tool.id ? 0.3 : 1)

        if editing {
            cell
                .onDrag {
                    draggingAppId = tool.id
                    return NSItemProvider(object: tool.id as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ToolReorderDropDelegate(
                    tool: tool,
                    onMove: { fromId, toId in
                        if let tm = toolManager { deskMgr.moveDesktopApp(fromId, before: toId, tm: tm) }
                    },
                    draggingToolId: $draggingAppId
                ))
        } else {
            cell
                .onTapGesture {
                    withAnimation(springAnim) { selectedToolId = tool.id }
                }
                .onLongPressGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editing = true }
                }
        }
    }

    // MARK: - 编辑态：完成按钮 + 添加区

    private var doneButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editing = false }
        } label: {
            Text("完成")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Page2Palette.cream)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Page2Palette.ink))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .padding(.top, 6)
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加到桌面")
                .font(.system(size: 12))
                .foregroundColor(Page2Palette.inkSoft)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(addableTools) { tool in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if let tm = toolManager { deskMgr.addToDesktop(tool.id, tm: tm) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if tool.id == "topicBox" {
                                PixelIcon(bitmap: PixelGlyph.lightbulb, size: 12, color: Page2Palette.ink)
                            } else {
                                AppIconView(name: tool.icon, size: 12, tint: nil, toolID: tool.id)
                            }
                            Text(tool.name)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(Page2Palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Page2Palette.surface))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 背景（page2-flora asset 挂点：粟粟 Illustrator 出图丢进 Assets 即生效）

    private var desktopBackground: some View {
        ZStack(alignment: .bottom) {
            Page2Palette.canvas
            if let ui = UIImage(named: "page2-flora") {
                GeometryReader { geo in
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 单词数据

    private func refreshVocab() {
        let log = VocabCardStore.loadLog()
        let today = ReadingSignals.dayKey(Date())
        vocabReviewedToday = log.filter { ReadingSignals.dayKey($0.ts) == today }.count
        vocabStreak = VocabSignals.streakDays(dayKeys: Set(log.map { ReadingSignals.dayKey($0.ts) }))
        vocabDue = VocabReviewStore().dueCount(within: 1)
    }
}
#endif
