import SwiftUI

/// 窗口总结 / 上下文摘要的读盘入口：界面只经这里拿「一个窗口」（plan-memory-migrate-3gen §六）。
/// 一个窗口 = A3 一段（windows/ 是一段从头压的才算；v4-1 抄本当「还没压」）+ A2（sessions/，没有就第一代当第 0 段）
enum WindowSummaryReader {
    struct Doc: Equatable {
        var conversationId: String
        var title: String
        var a3: SessionSegment?
        /// A2：第 0 段 + 正式段 + 尾段，按时间
        var a2: [SessionSegment]
        /// 老收尾段（v4，起点以前没搬的）：不注入、不进 A3，灰字放最下面
        var oldCloseouts: [SessionSegment] = []
        /// windows/ 里认不成 A3 的旧窗口总结（v4-1 抄本，还没搬）：灰字一组，不算段数（astra #13）
        var oldWindow: [SessionSegment] = []

        var isEmpty: Bool { a3 == nil && a2.isEmpty && oldCloseouts.isEmpty && oldWindow.isEmpty }
    }

    /// 窗口总结页，读盘，后台调
    static func load(conversationId: String, profileId: String) -> Doc? {
        let w = WindowSummaryStore.load(conversationId: conversationId, profileId: profileId)
        let s = SessionSummaryStore.load(conversationId: conversationId, profileId: profileId)
            ?? SessionSummaryStore.legacySeed(conversationId: conversationId, profileId: profileId)
        guard w != nil || s != nil else { return nil }
        return doc(conversationId: conversationId, window: w, context: s)
    }

    /// 上下文摘要（对话 ⋯ 弹层）：直接读 sessions/，尾段算（标出来），老收尾段不算。读盘，后台调
    static func loadContext(conversationId: String, profileId: String) -> Doc? {
        guard let s = SessionSummaryStore.load(conversationId: conversationId, profileId: profileId) else { return nil }
        return Doc(conversationId: s.conversationId, title: s.title, a3: nil, a2: contextSegments(ordered(s.segments)))
    }

    /// 纯函数：windows/ + sessions/ → 一个窗口
    static func doc(conversationId: String, window w: SessionSummary?, context s: SessionSummary?) -> Doc {
        let segs = ordered(s?.segments ?? [])
        let title = [w?.title, s?.title].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let top = a3(w)
        return Doc(conversationId: conversationId, title: title, a3: top, a2: contextSegments(segs),
                   oldCloseouts: segs.filter { $0.kind == .closeout && !$0.isTail },
                   oldWindow: top == nil ? w?.segments ?? [] : [])
    }

    /// v5 的 A3：windows/ 只有一段、从头压的；v4-1 抄本（多段，或最后那段 from > 0）= 还没压
    static func a3(_ w: SessionSummary?) -> SessionSegment? {
        guard let w, w.segments.count == 1, w.segments[0].from == 0 else { return nil }
        return w.segments[0]
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

    /// 纯函数：A2 的段 = 第 0 段 + 正式段 + 尾段，不含老收尾段
    static func contextSegments(_ segments: [SessionSegment]) -> [SessionSegment] {
        segments.filter { $0.kind != .closeout || $0.isTail }
    }

    /// 纯函数（可测）：时间轴项落在 A2 的哪一段（下标）——这一项当天第一条消息的时间落在段的起止里（秒级），
    /// 几段都对得上时挑标题对得上的；都没有 = nil（切了分支 / 删了）
    static func anchored(_ a2: [SessionSegment], _ anchor: WindowSummaryAnchor) -> Int? {
        let hits = a2.indices.filter { i in
            a2[i].kind != .legacy && a2[i].start.addingTimeInterval(-1) <= anchor.start && anchor.start <= a2[i].end.addingTimeInterval(1)
        }
        return hits.first { !a2[$0].title.isEmpty && anchor.title.hasPrefix(a2[$0].title) } ?? hits.first
    }

    /// 段号现算：有改造前累计摘要它是第 0 段，没有从 1 数（同 `CatalogALineReader.numbered`）
    static func number(_ index: Int, in a2: [SessionSegment]) -> Int {
        index + (a2.first?.kind == .legacy ? 0 : 1)
    }
}

/// 从时间轴一项点进窗口总结页：按这一项当天第一条消息的时间 + 标题定位到那一段 A2
struct WindowSummaryAnchor: Equatable {
    var start: Date
    var title: String
}

/// 一个窗口的窗口总结（只读）：上面 A3 一段（还没有 =「还没压成窗口总结」），下面 A2 一段一段从早到晚，
/// 最下面灰字一组老收尾段；不显示待续（Q2：待续只在时间轴）。
/// 窗口总结格点行、时间轴条目「看窗口总结」、对话 ⋯「窗口总结」共用；只凭对话 id 打开，读盘在后台。
/// 不带 NavigationStack：弹层用 `WindowSummarySheet` 包一层，时间轴条目弹层里直接推进来
struct WindowSummaryPage: View {
    let conversationId: String
    let profileId: String
    /// 文件里没有标题时用（时间轴条目 / 窗口列表已经知道）
    var fallbackTitle: String = ""
    var isGone = false
    /// 从时间轴一项点进来：定位到那一段（找不到明确说）
    var anchor: WindowSummaryAnchor? = nil
    /// nil = 底部不放「去这个窗口」（从对话 ⋯ 打开时人已经在这个窗口里）
    var onOpen: (() -> Void)? = nil

    @Environment(\.settingsMetrics) private var m
    @State private var doc: WindowSummaryReader.Doc? = nil
    @State private var loaded = false

    private var anchoredIndex: Int? {
        guard let anchor, let doc else { return nil }
        return WindowSummaryReader.anchored(doc.a2, anchor)
    }

    private var windowTitle: String {
        if let t = doc?.title, !t.isEmpty { return t }
        return fallbackTitle.isEmpty ? "没有标题的窗口" : fallbackTitle
    }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: loaded) { _, done in
                    if done, let i = anchoredIndex { proxy.scrollTo("a2-\(i)", anchor: .top) }
                }
        }
    }

    private var content: some View {
        List {
            if anchor != nil, loaded, anchoredIndex == nil {
                Text("时间轴里那一段在这个窗口里找不到了（可能切了分支或删了）")
                    .font(.system(size: m.secondarySize))
                    .foregroundColor(Theme.textMuted)
                    .panelRowBackground()
            }
            if let doc, !doc.isEmpty {
                Section {
                    if let a3 = doc.a3 {
                        WindowSegmentCard(segment: a3, isA3: true)
                            .panelRowBackground()
                    } else {
                        Text("还没压成窗口总结")
                            .font(.system(size: m.secondarySize))
                            .foregroundColor(Theme.textMuted)
                            .panelRowBackground()
                    }
                } header: {
                    Text("「\(windowTitle)」· A3 \(doc.a3 == nil ? "还没有" : "一段") · A2 \(doc.a2.count) 段")
                        .textCase(nil)
                }
                if !doc.a2.isEmpty {
                    Section {
                        ForEach(Array(doc.a2.enumerated()), id: \.offset) { i, seg in
                            VStack(alignment: .leading, spacing: 0) {
                                if i == anchoredIndex {
                                    Text("第 \(WindowSummaryReader.number(i, in: doc.a2)) 段 · 时间轴点进来的这一段")
                                        .font(.system(size: m.secondarySize))
                                        .foregroundColor(Theme.branchIndicator)
                                }
                                WindowSegmentCard(segment: seg)
                            }
                            .id("a2-\(i)")
                            .panelRowBackground()
                        }
                    } header: {
                        Text("A2 上下文摘要")
                            .textCase(nil)
                    }
                }
                if !doc.oldCloseouts.isEmpty {
                    Section {
                        ForEach(Array(doc.oldCloseouts.enumerated()), id: \.offset) { _, seg in
                            WindowSegmentCard(segment: seg, muted: true)
                                .panelRowBackground()
                        }
                    } header: {
                        Text("老收尾段（v4，起点以前没搬）")
                            .textCase(nil)
                    }
                }
                if !doc.oldWindow.isEmpty {
                    Section {
                        ForEach(Array(doc.oldWindow.enumerated()), id: \.offset) { _, seg in
                            WindowSegmentCard(segment: seg, muted: true)
                                .panelRowBackground()
                        }
                    } header: {
                        Text("旧窗口总结（v4，还没搬）")
                            .textCase(nil)
                    }
                }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if loaded && (doc?.isEmpty ?? true) {
                MemoryEmptyState(title: "这个窗口还没有窗口总结", message: "聊完、安静 12 小时后会记")
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

/// 一段：时间段 + 标题 / 经过 / 原话（不出待续）；改版前的累计摘要只出正文；
/// A3 头上写「写到哪天」，尾段标「尾段」，muted = 老收尾段整段灰字
struct WindowSegmentCard: View {
    let segment: SessionSegment
    var isA3 = false
    var muted = false
    @Environment(\.settingsMetrics) private var m

    private var primary: Color { muted ? Theme.textMuted : Theme.textPrimary }
    private var secondary: Color { muted ? Theme.textMuted : Theme.textSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if segment.kind == .legacy {
                Text("改版前的累计摘要")
                    .font(.system(size: m.secondarySize))
                    .foregroundColor(Theme.textMuted)
                paragraph(segment.story)
            } else {
                if isA3 {
                    Text("写到 \(MemoryDateText.short(segment.end))")
                        .font(.system(size: m.secondarySize, design: .serif))
                        .foregroundColor(secondary)
                } else {
                    if segment.isTail {
                        Text("尾段 · 还在聊，会整段重写")
                            .font(.system(size: m.secondarySize))
                            .foregroundColor(Theme.textMuted)
                    }
                    Text("\(MemoryDateText.short(segment.start)) \(TimelineListLayout.rangeText(start: segment.start, end: segment.end))")
                        .font(.system(size: m.secondarySize, design: .serif))
                        .foregroundColor(secondary)
                }
                if !segment.title.isEmpty {
                    Text(segment.title)
                        .font(.system(size: m.bodySize, weight: .semibold))
                        .foregroundColor(primary)
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
                            .foregroundColor(primary)
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
            .foregroundColor(secondary)
            .textSelection(.enabled)
    }
}

/// 一个窗口的上下文摘要（只读，plan-memory-app-three-views §5b，从对话 ⋯ 打开）：压缩段——聊长了、前面的消息挤出视野时
/// 记下的那几段 + 尾段（标出来，三代搬迁 W4），不放老收尾段。直接读 sessions/（`WindowSummaryReader.loadContext`），读盘在后台
struct ContextSummarySheet: View {
    let conversationId: String
    let profileId: String
    var fallbackTitle: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var doc: WindowSummaryReader.Doc? = nil
    @State private var loaded = false

    private var segments: [SessionSegment] { doc?.a2 ?? [] }

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
