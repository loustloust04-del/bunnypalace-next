import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 整理台的卡（v2 原型 docs/prototypes/audit-desk-20261112）
// 卡 =「说的是谁 · 正文」+ 卡底一排 chip（和详情页同一套，含 Source / Why），别的不放；动作都交回 `MemoryAuditPage`：存盘 + 发通知在那边。
// 两种圆角：卡 / 弹层 16，钮胶囊。三档字：卡正文 sectionHeader（iOS 16）、列表 / 钮 body（14）、出处 / 小字 secondary（13）。

enum MemoryAuditStyle {
    static let corner: CGFloat = 16

    private static func luminance(_ color: Color) -> Double {
        let c = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue)
    }

    /// 页面底（sidebarBg）是不是深色
    static var pageIsDark: Bool { luminance(Theme.sidebarBg) < 0.4 }

    /// 压在页面底 / 玻璃上的字（原型 --onPage）：textPrimary 和 mainBg 里跟页面底差得远的那个——
    /// 她的深蓝主题（页面底深、字深）取 mainBg，默认深色（页面底深、字浅）取 textPrimary
    static var onPage: Color { onPageIsText ? Theme.textPrimary : Theme.mainBg }

    private static var onPageIsText: Bool {
        let page = luminance(Theme.sidebarBg)
        return abs(luminance(Theme.textPrimary) - page) >= abs(luminance(Theme.mainBg) - page)
    }

    /// 实心主钮（强调色底）上的字：textPrimary 和 mainBg 里深的那个（原型主钮是深字）
    static var onAccent: Color {
        luminance(Theme.textPrimary) <= luminance(Theme.mainBg) ? Theme.textPrimary : Theme.mainBg
    }

    static var pageScheme: ColorScheme { pageIsDark ? .dark : .light }
    /// 压在卡上的玻璃（Edit 页托盘）跟卡底走：深蓝主题页面底深、卡是浅的
    static var cardScheme: ColorScheme { luminance(Theme.mainBg) < 0.4 ? .dark : .light }
    /// 页面底上的墨色实心钮（Edit 页 Save，原型 .solid）：底 = `onPage`，字 = textPrimary / mainBg 里剩下那个
    static var offPage: Color { onPageIsText ? Theme.mainBg : Theme.textPrimary }
    /// 行尾「正」钮（Approve / Restore）的底：强调色淡淡一层（原型 --selTint）
    static var positiveTint: Color { Theme.branchIndicator.opacity(0.32) }
}

extension View {
    /// 玻璃层的钮：iOS 26 / macOS 26 系统玻璃（不许 glassEffect + plain，吞点击）；macOS 15 退回 bordered
    @ViewBuilder
    func auditGlassButton(prominent: Bool = false) -> some View {
        #if os(iOS)
        if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        #else
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
        #endif
    }
}

/// 写手给的那几项怎么显示（说的是谁 / 谁说的 / 标签，类别当标签）：详情页、牌堆卡、记忆日志共用
enum MemoryAuditTraits {
    /// 库里 speaker 认得的三个词（Edit 页 From 的选项；显示名走 `from`，写入记录页还用 `origin`）
    static let speakers = ["用户自述", "AI 观察", "AI 承诺"]

    /// 库里的 speaker（`FragmentPool.wholeOrigins` / 老写手的三个词）→ 界面上的英文状态词
    static func origin(_ speaker: String?, assistant: String) -> String? {
        guard let s = speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        switch s {
        case "用户自述": return "Said by you"
        case "AI 观察": return "From \(assistant)"
        case "AI 承诺": return "\(assistant) promised"
        default: return s
        }
    }

    /// Edit 页 From 托盘的选项名（11-13 原型）：You / {助手} noticed / {助手} promised；不认得的原样；空 = nil（界面写 Not set）
    static func from(_ speaker: String?, assistant: String) -> String? {
        guard let s = MemoryAudit.cleaned(speaker) else { return nil }
        switch s {
        case "用户自述": return "You"
        case "AI 观察": return "\(assistant) noticed"
        case "AI 承诺": return "\(assistant) promised"
        default: return s
        }
    }

    /// From 在 chip / 卡上灰小字里的写法：她说的写 From you，其余同 `from`
    static func fromChip(_ speaker: String?, assistant: String) -> String? {
        MemoryAudit.cleaned(speaker) == "用户自述" ? "From you" : from(speaker, assistant: assistant)
    }

    /// 不当标签显示的类别（「事实」= 没特别分类）
    static let plainCategory = "fact"

    /// 旧的五个类别当标签显示（粟粟 11-13「旧的五个类别也是标签一种」，只是显示层，`category` 不动）：「事实」不出，其余出中文名
    static func categoryTag(_ category: String) -> String? {
        guard let c = MemoryAudit.cleaned(category), c != plainCategory else { return nil }
        return MemoryCardView.categoryLabels[c] ?? c
    }

    /// 卡上显示的标签：类别放第一个，后面写手 / 她的标签（去空白去重，和类别同名的不再出一遍）
    static func shownTags(category: String, keywords: [String]) -> [String] {
        let cat = categoryTag(category)
        return (cat.map { [$0] } ?? []) + MemoryAudit.cleanedTags(keywords).filter { $0 != cat }
    }

    /// 标签名是不是另四个类别之一（「事实」不算：它不当标签显示）→ 类别 key
    static func categoryKey(forTag tag: String) -> String? {
        MemoryAuditFilterSheet.categories.first { $0.key != plainCategory && $0.label == tag }?.key
    }
}

/// 归进的 wiki 页没了时那一行 +「重新整理」（只在出事时出现）
struct MemoryAuditPageNotice: View {
    let memory: Memory

    @Environment(\.settingsMetrics) private var m
    @Environment(\.modelContext) private var context
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @State private var pageNotice: String?
    @State private var resetPage: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let pageNotice {
                HStack {
                    Text(pageNotice).font(m.secondary).foregroundColor(Theme.textMuted)
                    if memory.supersededAt == nil {
                        Button("重新整理") { resetPage = memory.organizedPage }
                            .font(m.secondary)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .task(id: memory.organizedPage) { await checkPage() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await checkPage() } }
        .confirmationDialog("重新整理这条碎片？", isPresented: Binding(get: { resetPage != nil }, set: { if !$0 { resetPage = nil } }), titleVisibility: .visible) {
            Button("解除归页标记") { releaseOrganization() }
            Button("Cancel", role: .cancel) { resetPage = nil }
        } message: {
            Text("只解除这条碎片的整理页与整理时间，重新按现有资格筛选；不会自动播种，也不会撤回批准。")
        }
        .alert("重新整理失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func checkPage() async {
        guard let page = memory.organizedPage else { pageNotice = nil; return }
        let pid = memory.profileId
        let notice = await Task.detached(priority: .utility) {
            WikiStore(profileId: pid).unavailablePageMessage(page)
        }.value
        guard profiles?.currentProfile.id == pid, memory.organizedPage == page else { return }
        pageNotice = notice
    }

    private func releaseOrganization() {
        guard let page = resetPage else { return }
        resetPage = nil
        let pid = memory.profileId
        Task {
            do {
                let wiki = await Task.detached(priority: .utility) { WikiStore(profileId: pid) }.value
                try await WikiProposalReview.exclusive(wiki: wiki) {
                    let missing = await Task.detached(priority: .utility) { !wiki.pageExists(page) }.value
                    guard missing else { throw WikiStore.WikiError.conflict(page, "目标页已恢复，不必重新整理") }
                    guard profiles?.currentProfile.id == pid else { return }
                    try CatalogMaterial.releaseOrganization(memory, expectedPage: page, profileId: pid, context: context)
                }
                guard profiles?.currentProfile.id == pid else { return }
                pageNotice = nil
                NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            } catch {
                guard profiles?.currentProfile.id == pid else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - 牌堆（plan 2.3）

/// 正在飞走的那张：往右（留 / 恢复 / 留下里过到下一张）还是往左（删 / 彻底删）
struct MemoryAuditFlight: Equatable {
    let id: UUID
    let toRight: Bool
}

/// 一叠卡：只画最上面三张，后面两张各往下 7pt、缩一点露个边；只有最上面那张能点，飞着的时候都不能点。
/// 不挂任何拖动手势（规格 7¾：左右划跟翻页打架），飞走由页面的 `flight` 驱动
struct MemoryAuditStack<Card: View>: View {
    let deck: [Memory]
    let flight: MemoryAuditFlight?
    @ViewBuilder let card: (Memory) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = Array(deck.prefix(3))
        ZStack(alignment: .top) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, mem in
                let flying = flight?.id == mem.id
                card(mem)
                    // 减弱动态效果：下一张放大到位 / 往上挪不动画，直接到位，只剩淡入淡出（10-17 astra #6）
                    .transaction { t in if reduceMotion { t.animation = nil } } body: {
                        $0.scaleEffect(1 - 0.04 * CGFloat(i), anchor: .bottom)
                            .offset(y: 7 * CGFloat(i))
                            .opacity(i == 0 ? 1 : (i == 1 ? 0.8 : 0.55))
                    }
                    .rotationEffect(.degrees(flying && !reduceMotion ? (flight?.toRight == true ? 12 : -12) : 0))
                    .offset(x: flying && !reduceMotion ? (flight?.toRight == true ? 700 : -700) : 0)
                    .opacity(flying ? 0 : 1)
                    .zIndex(Double(-i))
                    .allowsHitTesting(i == 0 && flight == nil)
                    .accessibilityHidden(i != 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 26)
    }
}

/// 牌堆里的一张（粟粟 11-15 小样「卡上只剩正文 + chip」）：「说的是谁 · 正文」（长的在卡里滚）+ 卡底一排 chip，和详情页同一套；
/// About / From / 置信度 / 标签只显示，Source / Why 点开升托盘看完收回。改东西走底栏 Edit（开详情页），别的钮都在底部玻璃动作条上
struct MemoryAuditDeckCard: View {
    let memory: Memory
    let windowTitle: String?
    let onJump: (() -> Void)?
    /// 「C2 整理」给这张卡的理由（有才出 Why）
    var dreamNote: FragmentDreamNotes.Note? = nil

    private enum Tray: Hashable { case source, why }

    @Environment(\.settingsMetrics) private var m
    @Environment(\.modelContext) private var modelContext
    @AppStorage("assistantName") private var assistantName = "助手"
    @State private var open: Tray?
    @State private var live: String?
    @State private var liveMessages: [MemorySourceMessage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(memory.lineText)
                        .font(m.sectionHeader.weight(.regular))
                        .lineSpacing(5)
                        .foregroundColor(memory.supersededAt == nil ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    MemoryAuditPageNotice(memory: memory)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            if !chips.isEmpty || hasSource || hasWhy {
                Rectangle()
                    .fill(MemoryEntryChip.line)
                    .frame(height: 1)
                FlowLayout(spacing: 4, lineSpacing: 0) {
                    ForEach(chips, id: \.self) { MemoryEntryChip(text: $0, name: $0) }
                    if hasSource {
                        MemoryEntryChip(text: MemoryChipText.source(memory), name: "Source") { toggle(.source) }
                    }
                    if hasWhy {
                        MemoryEntryChip(text: "Why", name: "Why") { toggle(.why) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .opacity(open == nil ? 1 : 0)
                .allowsHitTesting(open == nil)
                .accessibilityHidden(open != nil)
            }
        }
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
        // 影子只给卡底：挂在整张上字也会带一圈虚影
        .background {
            RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous)
                .fill(Theme.mainBg)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
        .overlay(alignment: .bottom) {
            if let open {
                Group {
                    switch open {
                    case .source:
                        MemorySourceTray(memory: memory, windowTitle: windowTitle, live: live, messages: liveMessages, onJump: onJump) { self.open = nil }
                    case .why:
                        if let dreamNote { MemoryWhyTray(note: dreamNote) { self.open = nil } }
                    }
                }
                .memoryTray()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: open)
        .task(id: memory.id) {
            open = nil
            live = MemoryConversationLink.sourceText(of: memory, profileId: memory.profileId, context: modelContext)
            liveMessages = MemoryConversationLink.sourceMessages(of: memory, profileId: memory.profileId, context: modelContext)
        }
    }

    /// 只显示的那几颗：卡上有才出（About / From / 置信度 / 重要度 / 标签）
    private var chips: [String] {
        [MemoryChipText.about(memory.subject),
         MemoryAuditTraits.fromChip(memory.speaker, assistant: assistantName),
         MemoryChipText.sure(memory.confidence),
         MemoryChipText.importance(memory.importance),
         MemoryChipText.tags(MemoryAuditTraits.shownTags(category: memory.category, keywords: memory.keywords))].compactMap { $0 }
    }

    private var hasSource: Bool { MemorySourceTray.has(memory, live: live, canJump: onJump != nil) }
    private var hasWhy: Bool { MemoryWhyTray.shows(dreamNote, for: memory) }

    private func toggle(_ t: Tray) { open = open == t ? nil : t }
}
