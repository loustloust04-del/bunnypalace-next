import SwiftUI
import SwiftStreamingMarkdown

/// 待办卡（research-chat-cards §4.5）：勾选 / 加一项 → 生成同 id 新版本 → 进输入框，不直接发。
/// §14：点「加入我的待办」后变成真待办（TodoManager）的窗口——勾选直接改真待办并捎带给模型，日历里改了这里跟着变。
struct TodoCardView: View {
    let card: TodoCard
    let nodeId: String?
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @State private var addingItem = false
    @State private var newItem = ""

    private var chatCard: ChatCard { .todo(card) }

    /// 一次渲染的状态快照：索引只查一次（终审 #1）
    private struct Snapshot {
        let status: ChatCardStatus
        let pending: TodoCard?

        var badge: ChatCardBadge {
            if status == .stale { return .stale }
            return pending == nil ? .none : .pending
        }
    }

    private func snapshot() -> Snapshot {
        guard let viewModel else { return Snapshot(status: .readOnly, pending: nil) }
        let status = viewModel.cardStatus(chatCard, nodeId: nodeId)
        guard status == .live, let id = chatCard.id,
              case .todo(let t)? = viewModel.pendingCard(id: id),
              ChatCardIndex.showsPending(baseNodeId: viewModel.cardStagingBase[id], nodeId: nodeId) else {
            return Snapshot(status: status, pending: nil)
        }
        return Snapshot(status: status, pending: t)
    }

    private var conversationId: String? { viewModel?.selectedConversation?.id }
    private var actions: TodoCardActions { TodoCardActions(todos: .shared, links: .shared, outbox: viewModel?.cardEventOutbox ?? .shared) }
    private var today: String { TodoManager.dayKey(Date()) }

    /// 这张卡（只看活的版本）关联到真待办的那些项；空 = 还没加入
    private func linkMap(_ shown: TodoCard, status: ChatCardStatus) -> [String: UUID] {
        guard status == .live, let id = shown.id, !id.isEmpty, let conversationId else { return [:] }
        return ChatTodoLinkStore.shared.links(conversationId: conversationId, cardId: id)
    }

    private func stage(_ updated: TodoCard, status: ChatCardStatus) {
        guard status == .live else { return }
        viewModel?.stageCard(.todo(updated), baseNodeId: nodeId)
    }

    var body: some View {
        let snap = snapshot()
        let shown = snap.pending ?? card
        let links = linkMap(shown, status: snap.status)
        let projected = !links.isEmpty
        ChatCardShell(kindLabel: "待办", badge: snap.badge) {
            VStack(alignment: .leading, spacing: 10) {
                if !shown.title.isEmpty { Text(shown.title).font(.headline) }
                if projected {
                    Label("已同步到我的待办", systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(CodeBlockStyle.label)
                }
                ForEach(Array(shown.items.enumerated()), id: \.offset) { index, item in
                    if projected {
                        projectedRow(item, links: links, shown: shown)
                    } else {
                        TodoItemRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                var updated = shown
                                updated.items[index].done.toggle()
                                stage(updated, status: snap.status)
                            }
                    }
                }
                if snap.status == .live {
                    HStack {
                        Button {
                            newItem = ""
                            addingItem = true
                        } label: {
                            Label("加一项", systemImage: "plus")
                                .font(.subheadline)
                                .foregroundStyle(CodeBlockStyle.label)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if !projected, shown.id?.isEmpty == false, let conversationId {
                            Button {
                                actions.addAll(shown, conversationId: conversationId, today: today)
                                ToastCenter.shared.show("已加进待办")
                            } label: {
                                Label("加入我的待办", systemImage: "tray.and.arrow.down")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.branchIndicator)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 弹框输入，不在正文里放输入框（避开聊天页键盘回底逻辑，research-chat-cards §6）
        .alert("加一项", isPresented: $addingItem) {
            TextField("内容", text: $newItem)
            Button("取消", role: .cancel) {}
            Button("加入") {
                let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let current = snapshot()
                var updated = current.pending ?? card
                updated.items.append(.init(text: text, done: false))
                if !linkMap(updated, status: current.status).isEmpty, let conversationId {   // 已加入：同时写真待办
                    actions.addNewItem(text, card: updated, conversationId: conversationId, today: today)
                }
                stage(updated, status: current.status)
            }
        }
    }

    /// 已加入的卡：每项读真待办
    @ViewBuilder
    private func projectedRow(_ item: TodoCard.Item, links: [String: UUID], shown: TodoCard) -> some View {
        switch TodoCardProjection.state(of: item, links: links, todos: TodoManager.shared.items) {
        case .linked(let real):
            TodoItemRow(item: .init(text: item.text, done: real.done))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let conversationId else { return }
                    actions.toggle(real.id, text: item.text, conversationId: conversationId)
                }
        case .removed:
            TodoItemRow(item: item, note: "已从待办删掉")
                .opacity(0.5)
        case .unlinked:
            HStack {
                TodoItemRow(item: item)
                Spacer(minLength: 8)
                Button {
                    guard let conversationId else { return }
                    actions.addOne(item, card: shown, conversationId: conversationId, today: today)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("把「\(item.text)」加进待办")
            }
        }
    }
}

struct TodoItemRow: View {
    let item: TodoCard.Item
    /// §14：已加入的卡上，真待办被删掉时的小字
    var note: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.done ? Theme.branchIndicator : CodeBlockStyle.label)
            Text(item.text)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? CodeBlockStyle.label : Color.primary)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(CodeBlockStyle.label)
            }
        }
    }
}
