import SwiftUI
import SwiftData

// MARK: - 审计台卡片（plan-memory-audit-cards）
// 一条档案的卡片内容（列表行 / 牌堆共用）+ 重要度滑条。动作都交回 `MemoryAuditPage`：存盘 + 发通知在那边。

/// 正文（点开全文 + 原话 + 跳到这条 / 改字）、信息行（类别 ▾ · 日期 · 《窗口》 · 你改过 · 图钉）、重要度滑条
struct MemoryAuditCardContent: View {
    let memory: Memory
    let windowTitle: String?
    let expanded: Bool
    /// 列表在「选择」里：滑条不让动（点行是选中）
    var locked = false
    /// 牌堆卡：正文不折叠（卡里有地方，长的在卡里滚）
    var fullText = false
    /// 牌堆卡把滑条放到卡底按钮上面，这里不画
    var showsImportance = true
    let onToggle: () -> Void
    /// nil = 不出「跳到这条」（拿不到聊天 / 没有来源窗口）
    let onJump: (() -> Void)?
    let onEdit: () -> Void
    let onCategory: (String) -> Void
    let onImportance: (Int) -> Void

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        let alive = memory.supersededAt == nil
        VStack(alignment: .leading, spacing: 6) {
            Text(memory.content)
                .font(m.body)
                .foregroundColor(alive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(expanded || fullText ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
            infoLine
            if let note = MemoryAudit.organizeNote(memory) {
                Text(note)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if expanded {
                MemoryAuditSourceView(memory: memory)
                HStack(spacing: 16) {
                    if let onJump {
                        Button("跳到这条 ›", action: onJump)
                    }
                    if alive {
                        Button("改字", action: onEdit)
                    }
                }
                .font(m.caption)
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.borderless)
            }
            if showsImportance {
                MemoryAuditImportance(value: memory.importance, disabled: locked || !alive, onCommit: onImportance)
            }
        }
    }

    /// 信息行：类别 ▾ · 日期 · 《窗口》 · 你改过 · 图钉（钉住的不管什么类别都常驻）；重要度挪到下面的滑条
    private var infoLine: some View {
        var rest: [String] = [MemoryDateText.short(memory.createdAt)]
        if let windowTitle { rest.append("《\(windowTitle)》") }
        if memory.userEditedAt != nil { rest.append("你改过") }
        return HStack(spacing: 4) {
            Menu {
                ForEach(MemoryAuditFilterSheet.categories, id: \.key) { c in
                    Button {
                        onCategory(c.key)
                    } label: {
                        if c.key == memory.category { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                    }
                }
            } label: {
                Text("\(MemoryCardView.categoryLabels[memory.category] ?? memory.category) ▾")
                    .font(m.caption)
                    .foregroundColor(Theme.branchIndicator)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(memory.supersededAt != nil)
            Text("· " + rest.joined(separator: " · "))
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            if memory.isUserExplicit {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.branchIndicator)
                    .accessibilityLabel("钉住的，不管什么类别都常驻")
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

/// 一叠卡：只画最上面三张，后面两张各往下 6pt、缩一点露个边；只有最上面那张能点，飞着的时候都不能点。
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
                            .offset(y: 6 * CGFloat(i))
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
        .padding(.bottom, 24)
    }
}

/// 牌堆里的一张：奶白卡、正文区自己滚；卡底是重要度滑条 + 两颗按钮（左红描边、右薄荷实心白字——实心薄荷只压在奶白卡上）
struct MemoryAuditDeckCard<Content: View>: View {
    let leftTitle: String
    let rightTitle: String
    let importance: Int?
    let importanceDisabled: Bool
    let onImportance: (Int) -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                content()
                    .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            MemoryAuditImportance(value: importance, disabled: importanceDisabled, onCommit: onImportance)
            HStack(spacing: 12) {
                Button(action: onLeft) {
                    Text(leftTitle)
                        .font(m.body.weight(.medium))
                        .foregroundColor(Theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(Capsule().stroke(Theme.danger, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button(rightTitle, action: onRight)
                    .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
            }
        }
        .padding(16)
        .frame(maxWidth: 560, maxHeight: .infinity)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

// MARK: - 重要度滑条（plan 2.4，⧫3 / ⧫5）

/// 连续拖、松手吸到最近的整数 1–5 才交出去（拖动中只改自己的本地值，不碰库）；松手值没变不交。
/// 没定（nil）的停在 3、写「没定」，拖过才算定
struct MemoryAuditImportance: View {
    let value: Int?
    let disabled: Bool
    let onCommit: (Int) -> Void

    @Environment(\.settingsMetrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: Double = 3
    @State private var dragging = false
    @State private var moved = false

    var body: some View {
        HStack(spacing: 8) {
            Text("重要度")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
            Slider(value: $draft, in: 1...5) { editing in
                if editing {
                    dragging = true
                    moved = false
                } else {
                    dragging = false
                    commit()
                }
            }
            .tint(Theme.branchIndicator)
            .disabled(disabled)
            .accessibilityLabel("重要度")
            .accessibilityValue(label)
            Text(label)
                .font(m.caption.monospacedDigit())
                .foregroundColor(showsUnset ? Theme.textMuted : Theme.textPrimary)
                .frame(width: 30, alignment: .trailing)
        }
        .onAppear { draft = Double(Memory.effectiveImportance(value)) }
        .onChange(of: value) { _, v in
            if !dragging { draft = Double(Memory.effectiveImportance(v)) }
        }
        .onChange(of: draft) { _, _ in
            if dragging { moved = true }
        }
    }

    private var showsUnset: Bool { value == nil && !moved }

    private var label: String { showsUnset ? "没定" : "\(Int(draft.rounded()))" }

    private func commit() {
        let v = Int(draft.rounded())
        // 减弱动态效果：吸附不弹，直接到位（10-17 astra #6）
        let snap: Animation? = reduceMotion ? nil : .snappy
        guard moved, v != value else {
            withAnimation(snap) { draft = Double(Memory.effectiveImportance(value)) }
            return
        }
        withAnimation(snap) { draft = Double(v) }
        onCommit(v)
    }
}

// MARK: - 展开后的「原话」

/// 按 `sourceNodeId` 只取那一条消息（fetchLimit 1，前 300 字）；老 AUDN 没节点就用 `sourceQuote`；都没有写「没有出处」
private struct MemoryAuditSourceView: View {
    let memory: Memory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.settingsMetrics) private var m
    @State private var text: String?

    var body: some View {
        Text(text ?? "没有出处")
            .font(m.caption)
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .textSelection(.enabled)
            .task(id: memory.id) { load() }
    }

    private func load() {
        if let nid = memory.sourceNodeId {
            var desc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.id == nid })
            desc.fetchLimit = 1
            if let node = try? modelContext.fetch(desc).first {
                let clean = ContentCleaner.clean(node.content, cacheKey: node.id)
                text = "原话：" + (clean.count > 300 ? String(clean.prefix(300)) + "…" : clean)
                return
            }
        }
        if let quote = memory.sourceQuote, !quote.isEmpty { text = "原话：「\(quote)」" }
    }
}
