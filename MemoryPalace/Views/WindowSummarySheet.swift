import SwiftUI

/// 窗口总结 / 上下文摘要的读盘入口：界面只经这里拿「一个窗口按时间排好的段」。
/// 窗口总结读 windows/（v4-1）；还没有（没重新生成、v4-1 以后还没收过尾）就退回把 sessions/ 整份当窗口总结
enum WindowSummaryReader {
    struct Doc: Equatable {
        var conversationId: String
        var title: String
        var segments: [SessionSegment]
    }

    /// 窗口总结，读盘，后台调
    static func load(conversationId: String, profileId: String) -> Doc? {
        guard let s = WindowSummaryStore.load(conversationId: conversationId, profileId: profileId)
                ?? SessionSummaryStore.load(conversationId: conversationId, profileId: profileId) else { return nil }
        return Doc(conversationId: s.conversationId, title: s.title, segments: ordered(s.segments))
    }

    /// 上下文摘要（对话 ⋯ 弹层）：直接读 sessions/，老收尾段不算。读盘，后台调
    static func loadContext(conversationId: String, profileId: String) -> Doc? {
        guard let s = SessionSummaryStore.load(conversationId: conversationId, profileId: profileId) else { return nil }
        return Doc(conversationId: s.conversationId, title: s.title, segments: contextSegments(ordered(s.segments)))
    }

    /// 窗口总结格的列表：windows/ 每个窗口一份，再按对话 id 补上只有 sessions/ 的那些（还没写过窗口总结的窗口）。后台调
    static func listAll(profileId: String) -> [SessionSummary] {
        merge(windows: WindowSummaryStore.all(profileId: profileId), sessions: SessionSummaryStore.all(profileId: profileId))
    }

    /// 纯函数：同一个窗口 windows/ 优先
    static func merge(windows: [SessionSummary], sessions: [SessionSummary]) -> [SessionSummary] {
        let have = Set(windows.map(\.conversationId))
        return windows + sessions.filter { !have.contains($0.conversationId) }
    }

    /// 纯函数：改版前的累计摘要打头（它盖的是最前面那截），其余按开始时间先后；同一时间保持文件里的先后
    static func ordered(_ segments: [SessionSegment]) -> [SessionSegment] {
        let legacy = segments.filter { $0.kind == .legacy }
        let rest = segments.enumerated()
            .filter { $0.element.kind != .legacy }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        return legacy + rest
    }

    /// 纯函数：上下文摘要段 = 压缩段（改版前的累计摘要也是压缩写的，一起算），不含收尾段
    static func contextSegments(_ segments: [SessionSegment]) -> [SessionSegment] {
        segments.filter { $0.kind != .closeout }
    }
}

/// 一个窗口的窗口总结（只读）：所有段按时间从头排到尾，不显示待续（Q2：待续只在时间轴）。
/// 窗口总结格点行、时间轴条目「看窗口总结」、对话 ⋯「窗口总结」共用；只凭对话 id 打开，读盘在后台。
/// 不带 NavigationStack：弹层用 `WindowSummarySheet` 包一层，时间轴条目弹层里直接推进来
struct WindowSummaryPage: View {
    let conversationId: String
    let profileId: String
    /// 文件里没有标题时用（时间轴条目 / 窗口列表已经知道）
    var fallbackTitle: String = ""
    var isGone = false
    /// nil = 底部不放「去这个窗口」（从对话 ⋯ 打开时人已经在这个窗口里）
    var onOpen: (() -> Void)? = nil

    @State private var doc: WindowSummaryReader.Doc? = nil
    @State private var loaded = false

    private var segments: [SessionSegment] { doc?.segments ?? [] }

    private var windowTitle: String {
        if let t = doc?.title, !t.isEmpty { return t }
        return fallbackTitle.isEmpty ? "没有标题的窗口" : fallbackTitle
    }

    var body: some View {
        List {
            if !segments.isEmpty {
                Section {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        WindowSegmentCard(segment: seg)
                            .panelRowBackground()
                    }
                } header: {
                    Text("「\(windowTitle)」· 分 \(segments.count) 段记下")
                        .textCase(nil)
                }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if loaded && segments.isEmpty {
                MemoryEmptyState(title: "这个窗口还没有窗口总结", message: "聊完、安静 30 分钟后会记")
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let onOpen {
                Button(action: onOpen) {
                    Text(isGone ? "这个窗口已经删了" : "去这个窗口")
                }
                .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
                .disabled(isGone)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .toolPageBackground()
        .panelSheetTitle("窗口总结")
        .task(id: conversationId) {
            let cid = conversationId, pid = profileId
            doc = await Task.detached(priority: .userInitiated) {
                WindowSummaryReader.load(conversationId: cid, profileId: pid)
            }.value
            loaded = true
        }
    }
}

/// 一段：时间段 + 标题 / 经过 / 原话（不出待续）；改版前的累计摘要只出正文
struct WindowSegmentCard: View {
    let segment: SessionSegment
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if segment.kind == .legacy {
                Text("改版前的累计摘要")
                    .font(.system(size: m.secondarySize))
                    .foregroundColor(Theme.textMuted)
                paragraph(segment.story)
            } else {
                Text("\(MemoryDateText.short(segment.start)) \(TimelineListLayout.rangeText(start: segment.start, end: segment.end))")
                    .font(.system(size: m.secondarySize, design: .serif))
                    .foregroundColor(Theme.textSecondary)
                if !segment.title.isEmpty {
                    Text(segment.title)
                        .font(.system(size: m.bodySize, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                if !segment.story.isEmpty {
                    label("经过")
                    paragraph(segment.story)
                }
                let quotes = segment.quotes.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !quotes.isEmpty {
                    label("原话")
                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, q in
                        Text(q)
                            .font(.system(size: m.secondarySize))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Theme.branchIndicator.opacity(0.4)).frame(width: 2)
                            }
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: m.secondarySize - 1))
            .foregroundColor(Theme.textMuted)
            .padding(.top, 4)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: m.secondarySize))
            .foregroundColor(Theme.textSecondary)
            .textSelection(.enabled)
    }
}

/// 一个窗口的上下文摘要（只读，plan-memory-app-three-views §5b，从对话 ⋯ 打开）：只放压缩段——
/// 聊长了、前面的消息挤出视野时记下的那几段，不放收尾段。直接读 sessions/（`WindowSummaryReader.loadContext`），读盘在后台
struct ContextSummarySheet: View {
    let conversationId: String
    let profileId: String
    var fallbackTitle: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var doc: WindowSummaryReader.Doc? = nil
    @State private var loaded = false

    private var segments: [SessionSegment] { doc?.segments ?? [] }

    private var windowTitle: String {
        if let t = doc?.title, !t.isEmpty { return t }
        return fallbackTitle.isEmpty ? "没有标题的窗口" : fallbackTitle
    }

    private var assistantName: String {
        let n = profileManager?.profiles.first { $0.id == profileId }?.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    var body: some View {
        NavigationStack {
            List {
                if !segments.isEmpty {
                    Section {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            WindowSegmentCard(segment: seg)
                                .panelRowBackground()
                        }
                    } header: {
                        Text("「\(windowTitle)」· \(segments.count) 段")
                            .textCase(nil)
                    }
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .overlay {
                if loaded && segments.isEmpty {
                    MemoryEmptyState(title: "这个窗口还没有上下文摘要",
                                     message: "聊得长了、前面的消息挤出视野时，\(assistantName)会把那一截记成上下文摘要")
                        .allowsHitTesting(false)
                }
            }
            .toolPageBackground()
            .panelSheetTitle("上下文摘要")
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .task(id: conversationId) {
            let cid = conversationId, pid = profileId
            doc = await Task.detached(priority: .userInitiated) {
                WindowSummaryReader.loadContext(conversationId: cid, profileId: pid)
            }.value
            loaded = true
        }
    }
}

/// 窗口总结弹层：`WindowSummaryPage` + 导航栏「完成」。「去这个窗口」先收弹层再跳
struct WindowSummarySheet: View {
    let conversationId: String
    let profileId: String
    var fallbackTitle: String = ""
    var isGone = false
    var onOpen: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WindowSummaryPage(conversationId: conversationId, profileId: profileId, fallbackTitle: fallbackTitle,
                              isGone: isGone, onOpen: onOpen.map { open in { dismiss(); open() } })
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
        }
    }
}
