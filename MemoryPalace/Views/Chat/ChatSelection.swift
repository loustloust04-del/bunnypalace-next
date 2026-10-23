import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 多选气泡（Telegram 式，docs/research-multi-select-bubbles.md）的选中状态。
/// 性能红线（research §7.1）：选中集合 `selected` 只给勾选圆 / 选中底这种叶子视图读；
/// 列表行、BubbleView 只读 `isActive`（进 / 出各一次），点一下不牵动整屏气泡重算。
/// 选中单位 = 整条消息（MessageNode.id），只在当前显示路径里选（不跨分支）。
@Observable
final class ChatSelectionModel {
    private(set) var isActive = false
    private(set) var selected: Set<String> = []
    /// mac ⇧ 连选的起点：上次点的那条
    @ObservationIgnored private var anchorId: String?
    /// 多选期间锁横向翻页用的 owner（PagingViewController.setPage2DragLocked）
    let pagingLockOwner = UUID()

    func begin(selecting id: String?) {
        selected = id.map { Set([$0]) } ?? []
        anchorId = id
        isActive = true
    }

    func end() {
        guard isActive || !selected.isEmpty else { return }
        isActive = false
        selected = []
        anchorId = nil
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchorId = id
    }

    /// ⇧ 点：从上次点的那条到这条整段选中（只在当前路径里，跳过不可选的）。没有起点就当普通点
    func extend(to id: String, in path: [MessageNode], selectable: (MessageNode) -> Bool) {
        guard let anchorId,
              let a = path.firstIndex(where: { $0.id == anchorId }),
              let b = path.firstIndex(where: { $0.id == id }) else {
            toggle(id)
            return
        }
        selected.formUnion(path[min(a, b)...max(a, b)].filter(selectable).map(\.id))
        self.anchorId = id
    }

    /// 显示路径变了（删除 / 别处切支 / 新消息）：选中集合按当前路径过滤，不留幽灵 id
    func prune(toIds ids: [String]) {
        guard !selected.isEmpty else { return }
        let kept = selected.intersection(ids)
        if kept.count != selected.count { selected = kept }
        if let anchorId, !kept.contains(anchorId) { self.anchorId = nil }
    }

    /// 按聊天顺序取出选中的消息
    func selectedNodes(in path: [MessageNode]) -> [MessageNode] {
        guard !selected.isEmpty else { return [] }
        return path.filter { selected.contains($0.id) }
    }
}

extension ConversationViewModel {
    /// 进多选（长按菜单「多选」/ mac ⌘ 点）。输入栏要被操作栏顶替：先定稿拼音、收键盘（同查找入口）；查找开着就收掉
    @MainActor
    func beginMessageSelection(with nodeId: String?) {
        #if os(iOS)
        ChatInputHandle.shared.finalizeCompositionAndCommit()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        if inConvSearchActive { endInConvSearch() }
        withAnimation(.easeInOut(duration: 0.25)) { messageSelection.begin(selecting: nodeId) }
    }

    @MainActor
    func endMessageSelection() {
        guard messageSelection.isActive else { return }
        withAnimation(.easeInOut(duration: 0.25)) { messageSelection.end() }
    }
}

/// 多选「复制 / 分享」的拼接格式（粟粟拍板 5）：按聊天顺序，每条前一行「名字：」，条间空一行；
/// 选中的全是同一个人说的就不加名字。不带思考、不带时间；附件写成 [图片] / [文件 名]
enum ChatSelectionText {
    static func compose(_ nodes: [MessageNode], userName: String, assistantName: String) -> String {
        let oneSpeaker = Set(nodes.map(\.role)).count <= 1
        return nodes.map { node -> String in
            let text = body(of: node)
            guard !oneSpeaker else { return text }
            return "\(node.role == "user" ? userName : assistantName)：\n\(text)"
        }
        .joined(separator: "\n\n")
    }

    /// 单条正文：分段消息取文字段（不含思考 / 工具段），否则取清洗后的正文并剥掉 [thinking]；附件占位接在正文后
    static func body(of node: MessageNode) -> String {
        body(content: node.content, segments: ChatDisplaySnapshot.segments(of: node) ?? [], isUser: node.role == "user", cacheKey: node.id)
    }

    /// 她带语音的消息：打的字 + 转写按段顺序（同单条复制，sol P2-7），语音不再写成 [语音] 占位；没转出文字才留占位
    static func body(content: String, segments segs: [MessageSegment], isUser: Bool, cacheKey: String) -> String {
        if isUser, let voice = segs.userVoiceCopyText {
            let text = voice.trimmingCharacters(in: .whitespacesAndNewlines)
            let others = segs.compactMap { seg -> String? in
                if case .audioRef = seg { return nil }
                return placeholder(seg)
            }.joined(separator: " ")
            return (text.isEmpty ? "[语音]" : text) + others
        }
        let segText = segs.compactMap { seg -> String? in
            if case .text(let s) = seg { return s }
            return nil
        }.joined(separator: "\n\n")
        let raw = segText.isEmpty ? ContentCleaner.clean(content, cacheKey: cacheKey) : segText
        let text = ContentCleaner.extractThinking(from: raw).content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = segs.compactMap(placeholder).joined(separator: " ")
        return text + attachments
    }

    private static func placeholder(_ seg: MessageSegment) -> String? {
        switch seg {
        case .image, .imageRef: return "[图片]"
        case .attachment(let name, _, _), .file(let name, _), .fileData(let name, _, _), .fileDataRef(let name, _, _):
            return "[文件 \(name)]"
        case .audioRef: return "[语音]"
        default: return nil
        }
    }
}
