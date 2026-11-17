import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 一条原子事实露面时共用的零件（详情页 `MemoryAuditEditPage` 和整理台牌堆卡同一套）
// chip：看得见的 32 高胶囊、点按区 44、13 号字；托盘：卡底升起的玻璃，头一行 = 名字 + 钮（Done 浅底胶囊）；
// 出处 / 理由托盘只看不改。浮条：做完一笔浮一行「Deleted 1 · Undo」，留到做下一笔 / 撤了；只是一行字的几秒就收。

/// 卡底一颗 chip。没有 action = 只显示（牌堆卡上的 About / From 这些）
struct MemoryEntryChip: View {
    enum Look { case filled, empty, mine }

    let text: String
    var look: Look = .filled
    /// 改过的那项右上角一个薄荷小点
    var changed = false
    /// 读屏念的名字
    var name: String
    var action: (() -> Void)? = nil

    @Environment(\.settingsMetrics) private var m

    static var fill: Color { Theme.textPrimary.opacity(0.08) }
    static var line: Color { Theme.textPrimary.opacity(0.11) }

    var body: some View {
        if let action {
            Button(action: action) { face.contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .accessibilityLabel(name)
                .accessibilityValue(text)
        } else {
            face
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
        }
    }

    private var face: some View {
        HStack(spacing: 4) {
            if look == .mine {
                Image(systemName: "checkmark").font(m.secondary.weight(.bold))
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(look == .mine ? m.secondary.weight(.semibold) : m.secondary)
        .foregroundColor(look == .mine ? Theme.textPrimary : look == .empty ? Theme.textMuted : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: 260)
        .frame(height: 32)
        .background(look == .filled ? Self.fill : .clear, in: Capsule())
        .overlay {
            if look == .empty { Capsule().strokeBorder(Self.line, lineWidth: 1) }
            if look == .mine { Capsule().strokeBorder(Theme.textPrimary.opacity(0.45), lineWidth: 1) }
        }
        .frame(height: 44)
        .overlay(alignment: .topTrailing) {
            if changed {
                Circle()
                    .fill(Theme.branchIndicator)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Theme.mainBg, lineWidth: 2))
                    .offset(x: 1, y: 5)
            }
        }
    }
}

/// chip 上的字：详情页和牌堆卡同一种写法
enum MemoryChipText {
    static func about(_ subject: String?) -> String? { MemoryAudit.cleaned(subject).map { "About \($0)" } }
    static func sure(_ confidence: Int?) -> String? { confidence.map { "\($0)% sure" } }
    static func importance(_ value: Int?) -> String? { value.map { "Importance \($0)" } }

    /// 最多三个，多的写 +N
    static func tags(_ shown: [String]) -> String? {
        guard !shown.isEmpty else { return nil }
        return shown.prefix(3).map { "#" + $0 }.joined(separator: " ") + (shown.count > 3 ? " +\(shown.count - 3)" : "")
    }

    /// 「Source · 11月14日」
    static func source(_ m: Memory) -> String { "Source · \(MemoryDateText.short(m.createdAt))" }

    /// 托盘头：「Source · 11月14日 · 窗口名」
    static func sourceTitle(_ m: Memory, windowTitle: String?) -> String {
        source(m) + (windowTitle.map { " · \($0)" } ?? "")
    }
}

// MARK: - 托盘

extension View {
    /// 托盘外壳：卡底一块玻璃，跟卡底走深浅
    func memoryTray() -> some View {
        foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shellGlass(in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous), tint: 0.15)
            .environment(\.colorScheme, MemoryAuditStyle.cardScheme)
    }
}

/// 托盘头一行：名字 + 额外的钮 + Done
struct MemoryTrayHead<Extra: View>: View {
    let title: String
    let onDone: () -> Void
    @ViewBuilder var extra: () -> Extra

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(m.secondary.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            extra()
            MemoryTrayButton(title: "Done", action: onDone)
        }
        .frame(height: 44)
    }
}

extension MemoryTrayHead where Extra == EmptyView {
    init(title: String, onDone: @escaping () -> Void) {
        self.init(title: title, onDone: onDone) { EmptyView() }
    }
}

/// 托盘里的钮：默认浅底胶囊（Done / Open in chat）；plain（Adjust / Auto）透明、灰字
struct MemoryTrayButton: View {
    let title: String
    var plain = false
    var height: CGFloat = 44
    let action: () -> Void

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(plain ? m.sectionHeader.weight(.medium) : m.sectionHeader)
                .foregroundColor(plain ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, plain ? 10 : 16)
                .frame(height: height)
                .background(plain ? .clear : Theme.textPrimary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.borderless)
    }
}

/// 出处托盘：头 =「Source · 日期 · 窗口名」+ Open in chat + Done；下面是出处那条消息（现取；消息没了用存下的原话），
/// 能认出是哪一句就标出来并滚到那儿（`MemorySourceSpot`），认不出不标。
/// 挂了几条出处的（`sourceNodeIds`）按顺序一条一条显示（`MemorySourceMessages`），取不到的那几条跳过
struct MemorySourceTray: View {
    let memory: Memory
    let windowTitle: String?
    /// 出处那条消息现在的原文（nil = 取不到）
    let live: String?
    /// 挂的几条出处现在的原文（`MemoryConversationLink.sourceMessages`）；空 = 照旧只显示上面那一条
    var messages: [MemorySourceMessage] = []
    var onJump: (() -> Void)? = nil
    let onDone: () -> Void

    @Environment(\.settingsMetrics) private var m

    struct Shown: Equatable {
        var quote: String?
        /// 出处那条消息已经不在了（删了 / 藏了）
        var gone: Bool
    }

    /// 出处显示什么：消息还在 = 它现在的原文；不在了 = 存下的原话 + 说一声；有锚但两样都没有 = 只说一声；什么都没有 = nil（不出原话）
    static func shown(live: String?, stored: String?, hasAnchor: Bool) -> Shown? {
        let kept = stored.flatMap(MemoryAudit.cleaned)
        if let live { return Shown(quote: live, gone: false) }
        if hasAnchor { return Shown(quote: kept, gone: true) }
        return kept.map { Shown(quote: $0, gone: false) }
    }

    static func has(_ memory: Memory, live: String?, canJump: Bool) -> Bool {
        shown(live: live, stored: memory.sourceQuote, hasAnchor: memory.sourceNodeId != nil) != nil || canJump
    }

    var body: some View {
        let shown = Self.shown(live: live, stored: memory.sourceQuote, hasAnchor: memory.sourceNodeId != nil)
        VStack(alignment: .leading, spacing: 4) {
            MemoryTrayHead(title: MemoryChipText.sourceTitle(memory, windowTitle: windowTitle), onDone: onDone) {
                if let onJump { MemoryTrayButton(title: "Open in chat", action: onJump) }
            }
            if !messages.isEmpty {
                MemorySourceMessages(messages: messages)
                    .padding(.horizontal, 4)
            } else {
                if let quote = shown?.quote {
                    MemorySourceQuote(quote: quote, content: memory.content)
                        .padding(.horizontal, 4)
                }
                if shown?.gone == true {
                    Text("原消息找不到了")
                        .font(m.secondary)
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

/// 挂了几条出处：按存的顺序一条一条，每条一行谁说的 + 时间、下面是原文；高度同单条那份（封顶约十行，再长在里面滚）
struct MemorySourceMessages: View {
    let messages: [MemorySourceMessage]

    @Environment(\.settingsMetrics) private var m
    @AppStorage("assistantName") private var assistantName = "助手"

    var body: some View {
        list
            .frame(maxHeight: MemorySourceQuote.cap, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay {
                ScrollView { list.textSelection(.enabled) }
                    .scrollBounceBehavior(.basedOnSize)
            }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.head(message, assistant: assistantName))
                        .font(m.secondary)
                        .foregroundColor(Theme.textMuted)
                    Text("「\(message.text)」")
                        .font(m.sectionHeader.weight(.regular))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 「You · 11月14日 21:05」；没有时间的只写谁
    static func head(_ message: MemorySourceMessage, assistant: String, now: Date = Date()) -> String {
        let who = message.isUser ? "You" : assistant
        guard let at = message.at else { return who }
        return "\(who) · \(MemoryDateText.short(at, now: now)) \(time.string(from: at))"
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 出处原文：高度跟着实际显示的那份（分段 / 不分段）走，封顶约十行，再长在里面滚；认出的那一句单独成段、薄荷底，打开就滚到它
struct MemorySourceQuote: View {
    let quote: String
    /// 条目正文：拿它找出处是哪一句
    let content: String

    @Environment(\.settingsMetrics) private var m
    @State private var spot: Range<String.Index>?

    /// 约十行 sectionHeader（iOS 16pt / mac 13pt，字号固定不随动态字体）
    #if os(macOS)
    static let cap: CGFloat = 155
    #else
    static let cap: CGFloat = 191
    #endif

    var body: some View {
        shown
            .frame(maxHeight: Self.cap, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay {
                ScrollViewReader { proxy in
                    ScrollView {
                        shown.textSelection(.enabled)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: spot) { _, s in
                        guard s != nil else { return }
                        DispatchQueue.main.async { proxy.scrollTo(Self.spotId, anchor: .center) }
                    }
                }
            }
            .task(id: quote) { spot = MemorySourceSpot.locate(content: content, in: quote) }
    }

    static let spotId = "source-spot"

    @ViewBuilder private var shown: some View {
        if let spot, spot.upperBound <= quote.endIndex {
            marked(spot)
        } else {
            Text("「\(quote)」")
                .font(m.sectionHeader.weight(.regular))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func marked(_ r: Range<String.Index>) -> some View {
        let before = String(quote[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(quote[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let hit = (before.isEmpty ? "「" : "") + String(quote[r]) + (after.isEmpty ? "」" : "")
        return VStack(alignment: .leading, spacing: 4) {
            if !before.isEmpty { Text("「" + before).foregroundColor(Theme.textSecondary) }
            Text(hit)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Theme.branchIndicator.opacity(0.32), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .id(Self.spotId)
                .accessibilityHint("出处这一句")
            if !after.isEmpty { Text(after + "」").foregroundColor(Theme.textSecondary) }
        }
        .font(m.sectionHeader.weight(.regular))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 理由托盘：C2 整理给这条下的结论和理由全文（降成 Unsure 的另带它本来想写的字）
struct MemoryWhyTray: View {
    let note: FragmentDreamNotes.Note
    let onDone: () -> Void

    @Environment(\.settingsMetrics) private var m

    /// 出不出 Why：C2 整理给这条下过结论（有理由）、这条还活着
    static func shows(_ note: FragmentDreamNotes.Note?, for memory: Memory?) -> Bool {
        note != nil && memory != nil && memory?.supersededAt == nil
    }

    static func body(_ note: FragmentDreamNotes.Note) -> String {
        var lines = [[note.problem, note.why].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")].filter { !$0.isEmpty }
        if let text = note.text { lines.append("它想写成：\(text)") }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        let words = Text(Self.body(note))
            .font(m.sectionHeader.weight(.regular))
            .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 4) {
            MemoryTrayHead(title: "Why · \(FragmentDream.actor) · \(note.label)", onDone: onDone)
            words
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .overlay {
                    ScrollView { words.textSelection(.enabled) }
                        .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.horizontal, 4)
        }
    }
}

/// 列表行上的小牌子：这条还是 Draft（不进聊天）
struct MemoryDraftBadge: View {
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        Text("Draft")
            .font(m.caption)
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Theme.textMuted.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - 打开详情页（哪个入口点一条都开这一张）

enum MemoryEntryTarget: Identifiable {
    case existing(Memory)
    /// 新加一条：这一层楼
    case new(profileId: String)

    var id: String {
        switch self {
        case .existing(let m): return m.id.uuidString
        case .new: return "new"
        }
    }
}

/// 详情页做完的一笔：交回给开它的地方浮「Saved 1 · Undo」
struct MemoryEntryEvent {
    enum Kind { case saved, deleted, pinned, added }
    let kind: Kind
    let card: UUID
    let outcome: MemoryEntryActions.Outcome
    var wasDraft = false

    var text: String {
        if kind == .saved { return wasDraft ? "Saved · Approved 1" : "Saved 1" }
        return outcome.entry.map(MemoryEntryActions.toastText) ?? ""
    }
}

private struct MemoryEntryPresenter: ViewModifier {
    @Binding var target: MemoryEntryTarget?
    let onJump: ((Memory) -> (() -> Void)?)?
    let onEvent: (MemoryEntryEvent) -> Void

    @Environment(\.settingsMetrics) private var m

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $target) { page($0) }
        #else
        content.sheet(item: $target) { page($0) }
        #endif
    }

    @ViewBuilder
    private func page(_ t: MemoryEntryTarget) -> some View {
        Group {
            switch t {
            case .existing(let mem):
                MemoryAuditEditPage(memory: mem, profileId: mem.profileId, onJump: onJump?(mem), onEvent: onEvent)
            case .new(let pid):
                MemoryAuditEditPage(memory: nil, profileId: pid, onEvent: onEvent)
            }
        }
        .environment(\.settingsMetrics, m)
    }
}

extension View {
    /// 开唯一的那张条目详情页（iOS 全屏、mac sheet）
    func memoryEntryPage(_ target: Binding<MemoryEntryTarget?>, onJump: ((Memory) -> (() -> Void)?)? = nil,
                         onEvent: @escaping (MemoryEntryEvent) -> Void = { _ in }) -> some View {
        modifier(MemoryEntryPresenter(target: target, onJump: onJump, onEvent: onEvent))
    }

    /// 底部浮条：做完一笔浮「Deleted 1 · Undo」，点 Undo 撤这一笔（走记忆日志，和整理台同一套）
    func memoryUndoToast(_ center: MemoryUndoCenter, profileId: String) -> some View {
        modifier(MemoryUndoToastModifier(center: center, profileId: profileId))
    }
}

// MARK: - 浮条

/// 浮条那一行：能撤的整条是钮（「Deleted 1  Undo」），不能撤的只是一行字
struct MemoryToastView: View {
    let text: String
    var onUndo: (() -> Void)? = nil

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        if let onUndo {
            Button(action: onUndo) {
                HStack(spacing: 10) {
                    Text(text)
                    Text("Undo").fontWeight(.semibold)
                }
                .font(m.body)
                .foregroundStyle(MemoryAuditStyle.onPage)
            }
            .auditGlassButton()
            .environment(\.colorScheme, MemoryAuditStyle.pageScheme)
            .transition(.opacity)
        } else {
            Text(text)
                .font(m.secondary.weight(.medium))
                .foregroundStyle(MemoryAuditStyle.onPage)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .shellGlass(in: Capsule(), tint: 0.15)
                .environment(\.colorScheme, MemoryAuditStyle.pageScheme)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// 记忆页、常驻页、mac 设置用的浮条状态：最近那一笔能撤（整理台牌堆有自己的一套，见 `MemoryAuditPage`）
@MainActor
@Observable
final class MemoryUndoCenter {
    var toast: MemoryAuditToast?
    /// 浮条上 Undo 撤的那一笔
    var entry: MemoryAuditLog.Entry?

    func show(_ text: String, undo entry: MemoryAuditLog.Entry?) {
        guard !text.isEmpty else { return }
        self.entry = entry
        withAnimation(.easeOut(duration: 0.2)) { toast = MemoryAuditToast(text: text, undoable: entry != nil) }
    }

    func show(_ event: MemoryEntryEvent) {
        if let error = event.outcome.error { show(error, undo: nil) } else { show(event.text, undo: event.outcome.undoable) }
    }

    /// 列表里直接做的一笔（左滑删、多选钉）：存不成浮红字那句，存成了浮「Deleted 2 · Undo」
    func show(_ outcome: MemoryEntryActions.Outcome) {
        if let error = outcome.error { show(error, undo: nil); return }
        guard let entry = outcome.entry else { return }
        show(MemoryEntryActions.toastText(entry), undo: outcome.undoable)
    }

    func clear() {
        toast = nil
        entry = nil
    }
}

private struct MemoryUndoToastModifier: ViewModifier {
    let center: MemoryUndoCenter
    let profileId: String

    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.toast {
                    MemoryToastView(text: toast.text, onUndo: toast.undoable && center.entry != nil ? undo : nil)
                        .padding(.bottom, 10)
                }
            }
            .task(id: center.toast?.id) {
                // 能撤的那条不自己收（同整理台的 Undo：留到做下一笔 / 点了 Undo / 换楼层）；只是一行字的几秒就收
                guard let toast = center.toast, !(toast.undoable && center.entry != nil) else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { center.toast = nil } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in center.clear() }
    }

    private func undo() {
        guard let entry = center.entry else { return }
        let r = MemoryEntryActions.undo(entry, profileId: profileId, context: modelContext)
        center.show(r.error ?? r.text, undo: nil)
    }
}
