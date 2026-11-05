import Foundation
import SwiftData

/// 审计台第四格「整理提案」要显示的字（plan-memory-c3-catalog 第五节）：卡片摘要、按页分组、条目能不能动、「改」的草稿、「它搜了什么」
extension WikiProposal.Origin {
    var label: String {
        switch self {
        case .scheduled: return "定时整理"
        case .manual: return "现在整理"
        case .topic: return "整理主题"
        case .seed: return "种子"
        case .assistant: return "助手"
        }
    }
}

extension WikiProposal.Judgment {
    var label: String {
        switch self {
        case .conflict: return "冲突"
        case .coexist: return "共存"
        }
    }
}

extension WikiProposal.Change {
    /// 「确认已覆盖」没有可改的字
    var isEditable: Bool {
        if case .confirmCovered = self { return false }
        return true
    }

    var kindLabel: String {
        switch self {
        case .newPage: return "新开页"
        case .appendRecords: return "追加记录"
        case .rewriteNow: return "改现在"
        case .link: return "连线"
        case .retag: return "改钩子 / 触发词"
        case .regroup: return "分组调整"
        case .direction(let d): return d.group == true ? "方向 · 整理分组" : d.action == .update ? "方向 · 更新已有页" : "方向 · 开新页"
        case .confirmCovered: return "确认已覆盖"
        }
    }
}

extension WikiProposal.Direction {
    var modeLabel: String {
        switch mode {
        case .daily: return "批了查一次原料、写一次"
        case .agent: return "批了自己查原料再写（最多几轮）"
        case .seed: return "批了由种子任务接着写这一页"
        }
    }
}

enum WikiProposalDisplay {

    /// 批了、还没执行的方向条目。正文 / 改页这些不是方向，不算——
    /// 之前写成 `direction?.ranAt == nil`，非方向条目 nil == nil 也算进去，批正文会空跑一次执行、把「上次」盖成「没有要执行的方向」
    static func unranDirections(_ proposal: WikiProposal) -> Set<String> {
        Set(proposal.items.filter { $0.state == .approved && $0.change.direction.map { $0.ranAt == nil } == true }.map(\.id))
    }

    /// 方向交出的正文，在目录那条上怎么说。读不到（已删 / 解码失败）= 明说读不到，不退回旧的「交了 N 条正文等批」；
    /// 还有待批 = nil（照旧显示方向的 result）；都处理完 = 批 / 驳回 / 失效各几条（astra 审 3294acd33 P2-5）
    static func contentStatus(_ content: WikiProposal?) -> String? {
        guard let content else { return "正文提案读不到了（已删除或文件坏了）" }
        guard content.pendingCount == 0 else { return nil }
        let counts: [(String, WikiProposal.Item.State)] = [("批了", .approved), ("驳回", .rejected), ("失效", .stale)]
        let parts = counts.compactMap { label, state -> String? in
            let n = content.items.filter { $0.state == state }.count
            return n > 0 ? "\(label) \(n) 条" : nil
        }
        return parts.isEmpty ? "正文没有条目" : "正文" + parts.joined(separator: "、")
    }

    /// 来源「助手」显示成楼层的助手名
    static func originLabel(_ origin: WikiProposal.Origin, assistantName: String) -> String {
        origin == .assistant && !assistantName.isEmpty ? assistantName : origin.label
    }

    private static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 「10-18 05:02 定时整理 · 新开 2 页 · 追加 9 行 · 改现在 1 处 · 连线 3 条」；点名主题带上主题名
    static func summary(_ p: WikiProposal, assistantName: String = "", timeZone: TimeZone = .current) -> String {
        var head = timeText(p.createdAt, timeZone: timeZone) + " " + originLabel(p.origin, assistantName: assistantName)
        if let title = p.title, !title.isEmpty { head += "「\(title)」" }
        var directions = 0, newPages = 0, lines = 0, nows = 0, links = 0, retags = 0, regroups = 0, covered = 0
        for item in p.items {
            switch item.change {
            case .direction: directions += 1
            case .newPage: newPages += 1
            case .appendRecords(_, let l): lines += l.count
            case .rewriteNow: nows += 1
            case .link: links += 1
            case .retag: retags += 1
            case .regroup: regroups += 1
            case .confirmCovered: covered += 1
            }
        }
        let parts = [(directions, "方向 \(directions) 个"), (newPages, "新开 \(newPages) 页"), (lines, "追加 \(lines) 行"), (nows, "改现在 \(nows) 处"),
                     (links, "连线 \(links) 条"), (retags, "改钩子 \(retags) 处"), (regroups, "分组调整 \(regroups) 处"),
                     (covered, "确认已覆盖 \(covered) 处")]
            .filter { $0.0 > 0 }.map(\.1)
        let unapplied = p.unapplied?.count ?? 0
        return ([head] + (parts.isEmpty && unapplied == 0 ? ["没有条目"] : parts) + (unapplied > 0 ? ["没收进页 \(unapplied) 处"] : [])).joined(separator: " · ")
    }

    /// 「待批 N」/「待阅 N 处没收进页的内容」/「已处理」
    static func statusText(_ p: WikiProposal) -> String {
        let n = p.pendingCount, unread = p.unreadCount
        let parts = (n > 0 ? ["待批 \(n)"] : []) + (unread > 0 ? ["待阅 \(unread) 处没收进页的内容"] : [])
        return parts.isEmpty ? "已处理" : parts.joined(separator: " · ")
    }

    // MARK: - 出处展示与原文跳转

    struct MessageTarget: Hashable, Sendable {
        let profileId: String
        let conversationId: String
        let nodeId: String
    }

    /// 原文只在所属楼层定位消息；旧 A 线仍打开窗口概览，不猜测节点。
    static func messageTarget(for cite: WikiProposal.Cite, currentProfileId: String) -> MessageTarget? {
        guard cite.layer == "原文", let profileId = cite.profileId, profileId == currentProfileId,
              let conversationId = cite.windowId, !conversationId.isEmpty,
              let nodeId = cite.nodeId, !nodeId.isEmpty else { return nil }
        return MessageTarget(profileId: profileId, conversationId: conversationId, nodeId: nodeId)
    }

    private static func isVisible(_ node: MessageNode, in conversation: Conversation, target: MessageTarget) -> Bool {
        !conversation.isTrashed && conversation.id == target.conversationId && conversation.profileId == target.profileId
            && node.id == target.nodeId && node.conversationId == conversation.id && node.profileId == target.profileId
            && !node.isTrashed && node.hasDisplayableContent && (node.role == "user" || node.role == "assistant")
    }

    /// 在读取 context 内校验，后台加载只把可定位的值目标带回 UI。
    static func liveMessageTargets(for cites: [WikiProposal.Cite], currentProfileId: String,
                                   context: ModelContext) -> Set<MessageTarget> {
        let targets = Set(cites.compactMap { messageTarget(for: $0, currentProfileId: currentProfileId) })
        guard !targets.isEmpty else { return [] }
        let pid = currentProfileId
        let conversationIds = Array(Set(targets.map(\.conversationId)))
        let nodeIds = targets.map(\.nodeId)
        let conversations = (try? context.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == pid && conversationIds.contains($0.id) }
        ))) ?? []
        let nodes = (try? context.fetch(FetchDescriptor<MessageNode>(
            predicate: #Predicate { $0.profileId == pid && nodeIds.contains($0.id) }
        ))) ?? []
        let byConversation = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byNode = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(targets.filter { target in
            guard let conversation = byConversation[target.conversationId], let node = byNode[target.nodeId] else { return false }
            return isVisible(node, in: conversation, target: target)
        })
    }

    /// 点击时重新读取已保存状态；失效出处绝不能进入会误报「已切换到分支」的通用导航。
    @MainActor
    @discardableResult
    static func navigateToMessage(_ target: MessageTarget, currentProfileId: String, container: ModelContainer,
                                  viewModel: ConversationViewModel) -> Bool {
        guard target.profileId == currentProfileId else { return false }
        let context = ModelContext(container)
        let cid = target.conversationId, pid = target.profileId, nid = target.nodeId
        guard let conversation = try? context.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == cid && $0.profileId == pid }
        )).first,
              let node = try? context.fetch(FetchDescriptor<MessageNode>(
                predicate: #Predicate { $0.id == nid && $0.profileId == pid && $0.conversationId == cid }
              )).first,
              isVisible(node, in: conversation, target: target) else { return false }
        viewModel.navigateToSearchResult(nodeId: target.nodeId, conversation: conversation, context: context)
        return true
    }

    static func citeText(_ cite: WikiProposal.Cite, titles: [String: String], originalAvailable: Bool = true) -> String {
        var parts = [cite.layer]
        if cite.layer == "原文", !originalAvailable { parts.append("原消息已删除 / 不可定位") }
        if cite.layer == "原文" {
            switch cite.role {
            case "assistant": parts.append("助手发言 / 非用户事实")
            case "user": parts.append("用户发言")
            default: parts.append("发言者未知")
            }
        }
        if let day = cite.day { parts.append(day) }
        if let id = cite.windowId { parts.append("《\(titles[id] ?? "已删的窗口")》") }
        if let segment = cite.segment { parts.append("第 \(segment) 段") }
        if let from = cite.messageFrom, let to = cite.messageTo { parts.append("消息 \(from)–\(to)") }
        if cite.layer == "原文" {
            if let onMain = cite.onMain { parts.append(onMain ? "主线" : "支线") }
            if let nodeId = cite.nodeId { parts.append("消息 \(nodeId)") }
        }
        if let path = cite.filePath { parts.append(cite.name ?? path) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 详情按页分组

    struct PageGroup: Identifiable, Equatable {
        /// 页路径；分组调整 = nil
        let path: String?
        var items: [WikiProposal.Item]

        var id: String { path ?? "" }
        var title: String { path.map { String($0.split(separator: "/").last ?? "") } ?? "分组调整" }
    }

    /// 按目标页分组，组和组里的条目都按第一次出现的顺序；分组调整单独一组放最后
    static func groups(_ p: WikiProposal) -> [PageGroup] {
        var out: [PageGroup] = []
        var regroup: [WikiProposal.Item] = []
        for item in p.items {
            guard let path = item.change.targetPath else {
                regroup.append(item)
                continue
            }
            if let i = out.firstIndex(where: { $0.path == path }) {
                out[i].items.append(item)
            } else {
                out.append(PageGroup(path: path, items: [item]))
            }
        }
        if !regroup.isEmpty { out.append(PageGroup(path: nil, items: regroup)) }
        return out
    }

    // MARK: - 条目状态

    enum ItemStatus: Equatable {
        case actionable, stale, approved, rejected

        var canAct: Bool { self == .actionable }

        var label: String? {
            switch self {
            case .actionable: return nil
            case .stale: return "页在这之后被改过，重新整理"
            case .approved: return "已批"
            case .rejected: return "已驳回"
            }
        }
    }

    static func status(_ item: WikiProposal.Item) -> ItemStatus {
        switch item.state {
        case .pending: return .actionable
        case .stale: return .stale
        case .approved: return .approved
        case .rejected: return .rejected
        }
    }

    // MARK: - 它搜了什么

    /// 手动 agent 的过程日志：C3 写手、「整理「主题」第 N 轮」，从提案创建起到同主题下一份提案为止，旧→新。定时 / 没主题的没有
    static func searchLog(_ entries: [MemoryWriteLog.Entry], for p: WikiProposal, all: [WikiProposal]) -> [MemoryWriteLog.Entry] {
        guard p.origin == .manual || p.origin == .topic || p.origin == .assistant, let title = p.title, !title.isEmpty else { return [] }
        let until = all.filter { $0.id != p.id && $0.title == title && $0.createdAt > p.createdAt }.map(\.createdAt).min() ?? .distantFuture
        let prefix = "整理「\(title)」第"
        return entries.filter { $0.writer == MemoryWriterID.c3.code && $0.note.hasPrefix(prefix) && $0.time >= p.createdAt && $0.time < until }
            .sorted { $0.time < $1.time }
    }
}

// MARK: - 「改」的草稿：就地改文字（现在、记录行、钩子、触发词、为什么、分组名 / 钩子）

struct WikiProposalDraft {
    var now = ""
    /// 一行一条
    var records = ""
    var hook = ""
    /// 逗号 / 顿号隔开
    var triggers = ""
    var why = ""
    /// 分组：最后一段名字 + 钩子
    var groups: [(name: String, hook: String)] = []
    /// 方向：目标路径、标题；种子目录项另有类、原料清单（一行一份）
    var path = ""
    var title = ""
    var kind: WikiPage.Kind?
    var sources = ""

    init(_ change: WikiProposal.Change) {
        switch change {
        case .direction(let d):
            path = d.path
            title = d.title
            hook = d.hook
            kind = d.kind
            sources = (d.sources ?? []).joined(separator: "\n")
        case .confirmCovered:
            break
        case .newPage(let page):
            now = page.now
            records = page.records.joined(separator: "\n")
            hook = page.hook
            triggers = page.triggers.joined(separator: "、")
        case .appendRecords(_, let lines):
            records = lines.joined(separator: "\n")
        case .rewriteNow(_, _, let new, _):
            now = new
        case .link(_, let link):
            why = link.why
        case .retag(_, _, let newHook, _, let newTriggers):
            hook = newHook
            triggers = newTriggers.joined(separator: "、")
        case .regroup(_, let gs, _):
            groups = gs.map { (String($0.path.split(separator: "/").last ?? ""), $0.hook) }
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 改出来的条目（路径、关系、旧值不动）；分组改名不合法的那组照旧，合法的连同挪去它下面的目标一起改
    func apply(to change: WikiProposal.Change) -> WikiProposal.Change {
        switch change {
        case .direction(var d):
            let newPath = CatalogPrompts.normalizedPath(path)
            if WikiStore.isValidPagePath(newPath) { d.path = newPath }
            d.title = Self.trimmed(title).isEmpty ? String(d.path.split(separator: "/").last ?? "") : Self.trimmed(title)
            d.hook = Self.trimmed(hook)
            if d.mode == .seed {
                d.kind = kind ?? d.kind
                d.sources = WikiStore.normalizedWords(Self.lines(sources).map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 })
            }
            return .direction(d)
        case .confirmCovered:
            return change
        case .newPage(var page):
            page.now = Self.trimmed(now)
            page.validUntil = WikiPage.until(page.validUntil, in: page.now)
            page.records = Self.lines(records)
            page.hook = Self.trimmed(hook)
            page.triggers = WikiPage.list(triggers)
            return .newPage(page: page)
        case .appendRecords(let path, _):
            return .appendRecords(path: path, lines: Self.lines(records))
        case .rewriteNow(let path, let old, _, let until):
            return .rewriteNow(path: path, old: old, new: Self.trimmed(now), until: WikiPage.until(until, in: Self.trimmed(now)))
        case .link(let from, var link):
            link.why = Self.trimmed(why)
            return .link(from: from, link: link)
        case .retag(let path, let oldHook, _, let oldTriggers, _):
            return .retag(path: path, oldHook: oldHook, newHook: Self.trimmed(hook), oldTriggers: oldTriggers, newTriggers: WikiPage.list(triggers))
        case .regroup(let layer, var gs, var moves):
            for i in gs.indices where i < groups.count {
                gs[i].hook = Self.trimmed(groups[i].hook)
                let name = Self.trimmed(groups[i].name)
                let old = gs[i].path
                let parent = old.split(separator: "/").dropLast().joined(separator: "/")
                let new = parent.isEmpty ? name : parent + "/" + name
                guard new != old, !name.contains("/"), WikiStore.isValidFolderPath(new) else { continue }
                gs[i].path = new
                for j in moves.indices where moves[j].to.hasPrefix(old + "/") {
                    moves[j].to = new + moves[j].to.dropFirst(old.count)
                }
            }
            return .regroup(layer: layer, groups: gs, moves: moves)
        }
    }
}
