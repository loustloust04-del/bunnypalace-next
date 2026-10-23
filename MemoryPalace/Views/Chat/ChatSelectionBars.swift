import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 多选气泡的批量动作（粟粟拍板 3 / 5 / 8）：复制 / 分享 / 收藏（= 批量标星）/ 删除。iOS 操作栏和 mac 选择条共用
@MainActor
struct ChatSelectionActions {
    let viewModel: ConversationViewModel
    let userName: String
    let assistantName: String

    /// 按聊天顺序（只在当前路径里，幽灵 id 自然落掉）
    var nodes: [MessageNode] { viewModel.messageSelection.selectedNodes(in: viewModel.currentPath) }

    func text(of nodes: [MessageNode]) -> String {
        ChatSelectionText.compose(nodes, userName: userName, assistantName: assistantName)
    }

    func copy() {
        let picked = nodes
        guard !picked.isEmpty else { return }
        let joined = text(of: picked)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
        #else
        UIPasteboard.general.string = joined
        #endif
        viewModel.transientNotice = TransientNotice("已复制 \(picked.count) 条")
        viewModel.endMessageSelection()
    }

    func toggleFavorite() {
        let picked = nodes
        guard !picked.isEmpty else { return }
        let on = viewModel.setFavorite(picked)
        viewModel.transientNotice = TransientNotice(on ? "已收藏 \(picked.count) 条" : "已取消收藏 \(picked.count) 条")
        viewModel.endMessageSelection()
    }

    /// 确认后调：看得见的几条散成灰，数据一次性软删（进回收站可恢复）
    func delete() {
        let picked = nodes
        guard !picked.isEmpty else { return }
        MessageDust.vanish(keys: picked.map(\.id)) { [viewModel] in
            viewModel.softDelete(nodes: picked)
        }
        viewModel.endMessageSelection()
    }

    #if os(iOS)
    /// 系统分享面板（UIKit 直接弹：拼接文字在点的这一刻才算）
    func share() {
        let picked = nodes
        guard !picked.isEmpty else { return }
        let vc = UIActivityViewController(activityItems: [text(of: picked)], applicationActivities: nil)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 0, height: 0)
        top.present(vc, animated: true)
    }
    #endif
}

/// 选中的是不是已经全收藏了（决定收藏键是「收藏」还是「取消收藏」）
private func allFavorite(_ nodes: [MessageNode]) -> Bool {
    !nodes.isEmpty && nodes.allSatisfy(\.isFavorite)
}

#if os(iOS)
/// 多选态聊天页顶栏（照对话内查找换装）：左「取消」玻璃胶囊，中「已选 N 条」玻璃胶囊（不可点）
struct ChatSelectTopBar: View {
    let selection: ChatSelectionModel
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Text("已选 \(selection.selected.count) 条")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
                .padding(.horizontal, 18)
                .frame(height: ChatFindMetrics.size)
                .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule)
            HStack {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                // 玻璃按钮只能用 .buttonStyle(.glass)：glassEffect + .plain 会吞点击（同 ChatFindTopBar ✕）
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 48)
    }
}

/// 多选态顶替输入栏的操作栏：玻璃胶囊里四格「图标 + 棕灰英文小字」，和长按浮层顶排同一视觉语言
struct ChatSelectActionBar: View {
    let viewModel: ConversationViewModel
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("userName") private var floorUserName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"
    @State private var confirmDelete = false

    private var actions: ChatSelectionActions {
        ChatSelectionActions(
            viewModel: viewModel,
            userName: viewModel.personaDisplayName(profile: profileManager?.currentProfile) ?? floorUserName,
            assistantName: assistantName)
    }

    var body: some View {
        let picked = viewModel.messageSelection.selectedNodes(in: viewModel.currentPath)
        let starred = allFavorite(picked)
        HStack(spacing: 0) {
            item("doc.on.doc", label: "Copy", title: "复制") { actions.copy() }
            item("square.and.arrow.up", label: "Share", title: "分享") { actions.share() }
            item(starred ? "star.slash" : "star", label: starred ? "Unstar" : "Star", title: starred ? "取消收藏" : "收藏") {
                actions.toggleFavorite()
            }
            item("trash", label: "Delete", title: "删除", destructive: true) { confirmDelete = true }
        }
        .disabled(picked.isEmpty)
        .opacity(picked.isEmpty ? 0.35 : 1)
        .padding(.horizontal, 6)
        .frame(height: 50)
        // 玻璃挂容器上（套 Button 会吞点击）
        .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .alert("删除 \(picked.count) 条消息？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { actions.delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可在回收站恢复")
        }
    }

    private func item(_ symbol: String, label: String, title: String, destructive: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .frame(height: 22)
                    .foregroundStyle(destructive ? Color.red : Theme.textPrimary)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(destructive ? Color.red : Self.labelColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 棕灰：同长按浮层顶排小字（BubbleMenuOverlayView.quickLabelColor，粟粟 10-01 定稿 B）
    private static let labelColor = Color(red: 0.55, green: 0.48, blue: 0.41)
}
#endif

#if os(macOS)
/// mac 多选条：顶替输入条一行「已选 N 条 · 复制 分享 收藏 删除 · ✕」。⌘C 复制、⌫ 删除（弹确认）、Esc 退出
struct MacChatSelectionBar: View {
    let viewModel: ConversationViewModel
    @Environment(\.chatMetrics) private var metrics
    @Environment(\.colorScheme) private var scheme
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("userName") private var floorUserName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"
    @State private var confirmDelete = false

    private var actions: ChatSelectionActions {
        ChatSelectionActions(
            viewModel: viewModel,
            userName: viewModel.personaDisplayName(profile: profileManager?.currentProfile) ?? floorUserName,
            assistantName: assistantName)
    }

    var body: some View {
        let picked = viewModel.messageSelection.selectedNodes(in: viewModel.currentPath)
        let starred = allFavorite(picked)
        HStack(spacing: 16) {
            Text("已选 \(picked.count) 条")
                .fontWeight(.semibold)
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
            Spacer(minLength: 0)
            Group {
                Button { actions.copy() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: .command)
                ShareLink(item: actions.text(of: picked)) { Label("分享", systemImage: "square.and.arrow.up") }
                Button { actions.toggleFavorite() } label: {
                    Label(starred ? "取消收藏" : "收藏", systemImage: starred ? "star.slash" : "star")
                }
                Button { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                    .foregroundColor(.red)
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .disabled(picked.isEmpty)
            Button { viewModel.endMessageSelection() } label: { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
                .help("退出多选（Esc）")
        }
        .font(.system(size: 12.5))
        .foregroundColor(Theme.textSecondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChatSelectionStyle.paper(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.textMuted.opacity(0.2), lineWidth: 0.5))
        .padding(.horizontal, metrics.composerInsetH)
        .padding(.vertical, 10)
        .alert("删除 \(picked.count) 条消息？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { actions.delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可在回收站恢复")
        }
    }
}
#endif
