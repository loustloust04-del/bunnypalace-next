import Foundation
import MemoryCore

/// 「想起来了」卡的数据层（plan-recall-card §2.1）：纯值 + 纯函数，不碰 SwiftData、不查现库。
/// 自动块 = 回执 `delivery.items`，翻了块 = `reads`，原因 = `gate`，状态 = `attempts`。
struct RecallCardModel: Equatable {
    enum Shape: Equatable {
        /// 不出（隐藏、CC、常驻项独有、v1 空回执无旧记录）
        case hidden
        /// 只有 `recallHitsData` 的旧消息 → 旧卡
        case legacy
        case card
    }

    struct Row: Equatable {
        let ref: String
        /// 行内短文（`shown`；v1 沿用旧卡的标题取法）
        let title: String
        /// 展开正文（页 / 卡取 `decision.selected` 同 ref 的 text；B4 取 members）
        let text: String?
        let trimmed: Bool
    }

    struct Group: Equatable {
        let kind: String
        let name: String
        let unit: String
        /// 计入 N、触发出卡
        let isHit: Bool
        let tokens: Int
        /// 分项显示数量（聚合项按 `shown` 里的数，其余 = 行数）；折叠行与分项标题共用
        let count: Int
        let rows: [Row]
        /// 被来源窗挡掉的候选数说明（碎片 / 时间轴分项下）
        let note: String?
    }

    struct Read: Equatable {
        let title: String
        let status: String
    }

    /// v1 旧账的 selected 分组（标题取法沿用旧卡，P2 的旧账分块也用它）
    struct LedgerGroup: Equatable {
        let kind: RecallSourceRef.Kind
        let tokens: Int
        let rows: [LedgerRow]
    }

    struct LedgerRow: Equatable {
        let title: String
        let detail: String?
        let text: String
    }

    let shape: Shape
    let groups: [Group]
    /// 旧视图（`RecallCardPresentation`）投影用的 `decision.selected` 分组；v1 / v2 都填，P2 换视图后不用
    let ledgerGroups: [LedgerGroup]
    let reads: [Read]
    /// 「带了 档案页 2 页 · 碎片 3 条 · ≈ 820 token」；没分项时为空串
    let foldedLine: String
    /// 参数快照小字（含 suppression 计数、本机注）
    let tuningLine: String
    /// 没带的顶层原因（总开关 / 本窗 / 插槽）
    let gateNotes: [String]
    /// 老窗 / 本窗划掉 / 档案触发关（参数快照行）
    let gateLine: String?
    /// 「想起来了 N 件事」/「想起来了 · 没翻到」/ 旧记录 / 没发成
    let label: String
    /// N = 想起项 + 翻到了的读（流式中不计读）
    let hitCount: Int
    let notSent: Bool
    /// 中断 / 多次请求
    let notes: [String]
    /// v1 回执：只记了档案触发那部分
    let oldLedger: Bool

    static let oldLedgerNote = "旧账：只记了档案触发那部分"

    // MARK: - 分项表（顺序即折叠行顺序）

    struct KindSpec: Equatable {
        let kind: String
        let name: String
        let unit: String
        let isHit: Bool
    }

    static let specs: [KindSpec] = [
        KindSpec(kind: RecallDeliveryItem.Kind.page, name: "档案页", unit: "页", isHit: true),
        KindSpec(kind: RecallDeliveryItem.Kind.card, name: "要点卡", unit: "张", isHit: true),
        KindSpec(kind: RecallDeliveryItem.Kind.fragment, name: "碎片", unit: "条", isHit: true),
        KindSpec(kind: RecallDeliveryItem.Kind.legacyFragment, name: "碎片", unit: "条", isHit: true),
        KindSpec(kind: RecallDeliveryItem.Kind.pinned, name: "钉住", unit: "条", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.rootIndex, name: "档案目录", unit: "行", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.selfMemory, name: "助手的记忆", unit: "条", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.previousWindow, name: "上个窗口", unit: "条", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.a2, name: "上下文摘要", unit: "段", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.timeline, name: "时间轴", unit: "条", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.pending, name: "待续", unit: "窗", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.anniversary, name: "纪念日", unit: "条", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.journal, name: "今天的日记", unit: "篇", isHit: false),
        KindSpec(kind: RecallDeliveryItem.Kind.expiredReminder, name: "过期提醒", unit: "项", isHit: false),
    ]

    static let otherKind = "other"

    static func isHit(_ kind: String) -> Bool {
        specs.first { $0.kind == kind }?.isHit ?? false
    }

    static func displayName(_ spec: KindSpec, assistantName: String) -> String {
        spec.kind == RecallDeliveryItem.Kind.selfMemory ? "\(assistantName)的记忆" : spec.name
    }

    // MARK: - 出卡 / N / 各情形

    /// - Parameters:
    ///   - legacyHits: `recallHitsData` 的条数（0 = 没有旧卡可回落）
    static func make(receipt: RecallTurnReceipt?, legacyHits: Int, mode: DisclosureMode,
                     streaming: Bool = false, assistantName: String = "助手") -> RecallCardModel {
        func bare(_ shape: Shape, label: String = "", oldLedger: Bool = false) -> RecallCardModel {
            RecallCardModel(shape: shape, groups: [], ledgerGroups: [], reads: [], foldedLine: "",
                            tuningLine: "", gateNotes: [], gateLine: nil, label: label, hitCount: 0,
                            notSent: false, notes: [], oldLedger: oldLedger)
        }
        guard mode != .hidden else { return bare(.hidden) }
        guard let receipt else {
            guard legacyHits > 0 else { return bare(.hidden) }
            return bare(.legacy, label: "想起来了 \(legacyHits) 件事（旧记录）")
        }
        let delivery = receipt.delivery
        guard delivery?.route != "ccBridge" else { return bare(.hidden) }

        let ledger = ledgerGroups(receipt.decision.selected)
        let groups: [Group]
        let hitItems: Int
        if let delivery {
            groups = self.groups(items: delivery.items, selected: receipt.decision.selected,
                                 gate: delivery.gate, assistantName: assistantName)
            hitItems = delivery.items.filter { isHit($0.kind) }.count
        } else {
            groups = oldLedgerGroups(ledger, assistantName: assistantName)
            hitItems = receipt.decision.selected.filter { isHit($0.source.kind.rawValue) }.count
        }
        let sums = tally(hitItems: hitItems, reads: receipt.reads, attempts: receipt.attempts)
        let hasReads = !receipt.reads.isEmpty
        guard hitItems > 0 || hasReads else {
            if delivery == nil, legacyHits > 0 {
                return bare(.legacy, label: "想起来了 \(legacyHits) 件事（旧记录）")
            }
            return bare(.hidden)
        }
        let result = sums.label(streaming: streaming)
        return RecallCardModel(
            shape: .card, groups: groups, ledgerGroups: ledger,
            reads: receipt.reads.map(self.read(_:)),
            foldedLine: foldedLine(groups),
            tuningLine: tuningLine(receipt.decision, route: delivery?.route),
            gateNotes: delivery.map { gateNotes($0.gate, assistantName: assistantName) } ?? [],
            gateLine: delivery.flatMap { d in
                gateLine(d.gate, hasLegacyFragment: d.items.contains { $0.kind == RecallDeliveryItem.Kind.legacyFragment },
                         assistantName: assistantName)
            },
            label: result.label, hitCount: result.n, notSent: sums.notSent,
            notes: attemptNotes(receipt.attempts), oldLedger: delivery == nil)
    }

    struct Tally: Equatable {
        struct Read: Equatable {
            let status: String
            let returnedCount: Int?
        }
        struct Attempt: Equatable {
            let status: String
            let receivedResponse: Bool
        }

        let hitItems: Int
        let reads: [Read]
        let attempts: [Attempt]

        /// 自身 attempts 非空、无 receivedResponse、全部 failed / cancelled（不看 inheritedEffective）
        var notSent: Bool {
            !attempts.isEmpty && attempts.allSatisfy {
                !$0.receivedResponse && ($0.status == "failed" || $0.status == "cancelled")
            }
        }

        /// 分页的成功读（`partial`）也是读到了内容，计入 N（`RecallTool.swift:602-605`）
        var goodReads: Int {
            reads.filter { ($0.status == "success" || $0.status == "partial") && ($0.returnedCount ?? 1) > 0 }.count
        }

        func label(streaming: Bool) -> (n: Int, label: String) {
            let n = hitItems + (streaming ? 0 : goodReads)
            var text: String
            if n > 0 {
                text = "想起来了 \(n) 件事"
            } else if streaming, !reads.isEmpty {
                // 流式中读已经落库，但 N 不计读；别先说「没翻到」，等回复结束再定
                text = "想起来了"
            } else {
                text = "想起来了 · 没翻到"
            }
            if notSent { text += "（没发成）" }
            return (n, text)
        }
    }

    static func tally(hitItems: Int, reads: [RecallReadReceipt], attempts: [RecallAttempt]) -> Tally {
        Tally(hitItems: hitItems,
              reads: reads.map { Tally.Read(status: $0.status, returnedCount: $0.returnedCount) },
              attempts: attempts.map { Tally.Attempt(status: $0.status.rawValue, receivedResponse: $0.receivedResponse) })
    }

    /// 中断 / 多次请求的小字（不看 inheritedEffective）。
    static func attemptNotes(_ attempts: [RecallAttempt]) -> [String] {
        var notes: [String] = []
        if attempts.contains(where: { $0.status == .interrupted }) { notes.append("回复中途停了") }
        if attempts.count > 1 { notes.append("请求了 \(attempts.count) 次（含工具续轮 / 重试）") }
        return notes
    }

    // MARK: - 分项

    static func groups(items: [RecallDeliveryItem], selected: [RecallItem], gate: RecallGateSnapshot,
                       assistantName: String) -> [Group] {
        var rows: [String: [Row]] = [:]
        var tokens: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for item in items {
            let key = specs.contains { $0.kind == item.kind } ? item.kind : otherKind
            let text: String?
            switch item.kind {
            case RecallDeliveryItem.Kind.page, RecallDeliveryItem.Kind.card:
                text = selected.first { MemoryDelivery.key($0.source) == item.ref }?.text
            case RecallDeliveryItem.Kind.selfMemory:
                text = item.members.flatMap { $0.isEmpty ? nil : $0.joined(separator: "\n") }
            default:
                text = nil
            }
            rows[key, default: []].append(Row(ref: item.ref, title: item.shown, text: text, trimmed: item.trimmed == true))
            tokens[key, default: 0] += item.tokens
            counts[key, default: 0] += displayCount(item)
        }
        var groups: [Group] = []
        for spec in specs {
            guard let groupRows = rows[spec.kind], !groupRows.isEmpty else { continue }
            groups.append(Group(kind: spec.kind, name: displayName(spec, assistantName: assistantName),
                                unit: spec.unit, isHit: spec.isHit, tokens: tokens[spec.kind] ?? 0,
                                count: counts[spec.kind] ?? groupRows.count, rows: groupRows, note: nil))
        }
        if let others = rows[otherKind], !others.isEmpty {
            groups.append(Group(kind: otherKind, name: "其他", unit: "项", isHit: false,
                                tokens: tokens[otherKind] ?? 0, count: others.count, rows: others, note: nil))
        }
        let fragments = gate.hiddenFragments > 0
            ? "另有 \(gate.hiddenFragments) 条碎片来自已删 / 不参与的窗，没带" : nil
        let timeline = gate.hiddenTimeline > 0
            ? "时间轴另有 \(gate.hiddenTimeline) 项来自已删 / 不参与的窗，没带" : nil
        guard fragments != nil || timeline != nil else { return groups }
        return groups.map { group in
            let note: String?
            switch group.kind {
            case RecallDeliveryItem.Kind.fragment, RecallDeliveryItem.Kind.legacyFragment: note = fragments
            case RecallDeliveryItem.Kind.timeline: note = timeline
            default: note = nil
            }
            guard let note else { return group }
            return Group(kind: group.kind, name: group.name, unit: group.unit, isHit: group.isHit,
                         tokens: group.tokens, count: group.count, rows: group.rows, note: note)
        }
    }

    /// 聚合项的显示数量取自生产 `shown`（`RecallSelection.swift:32`「全文 x · 目录 y」/ `:46`「根索引 n 行」/
    /// `:79`「已过期 n 项」/ `:90`「上个窗口 n 条」）；其余 kind 一行算一个。解析不出数字按 1。
    static func displayCount(_ item: RecallDeliveryItem) -> Int {
        let numbers = item.shown.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !numbers.isEmpty else { return 1 }
        switch item.kind {
        case RecallDeliveryItem.Kind.selfMemory: return numbers.reduce(0, +)
        case RecallDeliveryItem.Kind.rootIndex, RecallDeliveryItem.Kind.previousWindow,
             RecallDeliveryItem.Kind.expiredReminder: return numbers[0]
        default: return 1
        }
    }

    /// v1：只列 `decision.selected`（页 / 卡 / 碎片），标题取法沿用旧卡。
    static func oldLedgerGroups(_ ledger: [LedgerGroup], assistantName: String) -> [Group] {
        ledger.compactMap { group in
            guard let spec = specs.first(where: { $0.kind == group.kind.rawValue }) else { return nil }
            return Group(kind: spec.kind, name: displayName(spec, assistantName: assistantName), unit: spec.unit,
                         isHit: true, tokens: group.tokens, count: group.rows.count,
                         rows: group.rows.map { Row(ref: "", title: $0.title, text: $0.text, trimmed: false) }, note: nil)
        }
    }

    static func ledgerGroups(_ selected: [RecallItem]) -> [LedgerGroup] {
        var pages: [LedgerRow] = [], cards: [LedgerRow] = [], fragments: [LedgerRow] = []
        var pageTokens = 0, cardTokens = 0, fragmentTokens = 0
        for item in selected {
            let lines = item.text.split(separator: "\n")
            let row: LedgerRow
            switch item.source.kind {
            case .page:
                let title = lines.first(where: { $0.hasPrefix("[[") }).map(String.init) ?? "[[\(item.source.path)]]"
                row = LedgerRow(title: title, detail: nil, text: item.text)
                pages.append(row); pageTokens += item.tokenCost
            case .card:
                let title = lines.first(where: { $0.hasPrefix("条目：") }).map { String($0.dropFirst("条目：".count)) }
                    ?? item.source.path
                row = LedgerRow(title: title, detail: "\(item.source.path)|\(item.source.version)", text: item.text)
                cards.append(row); cardTokens += item.tokenCost
            case .fragment:
                let first = lines.first ?? ""
                let title = String(first.hasPrefix("[") && first.hasSuffix("·本轮相关]")
                                   ? lines.dropFirst().first ?? first : first)
                row = LedgerRow(title: title, detail: nil, text: item.text)
                fragments.append(row); fragmentTokens += item.tokenCost
            }
        }
        var groups: [LedgerGroup] = []
        if !pages.isEmpty { groups.append(LedgerGroup(kind: .page, tokens: pageTokens, rows: pages)) }
        if !cards.isEmpty { groups.append(LedgerGroup(kind: .card, tokens: cardTokens, rows: cards)) }
        if !fragments.isEmpty { groups.append(LedgerGroup(kind: .fragment, tokens: fragmentTokens, rows: fragments)) }
        return groups
    }

    // MARK: - 文案

    static func foldedLine(_ groups: [Group]) -> String {
        let present = groups.filter { !$0.rows.isEmpty }
        guard !present.isEmpty else { return "" }
        let entries = present.map { "\($0.name) \($0.count) \($0.unit)" }
        var line = "带了 " + entries.joined(separator: " · ")
        line += " · ≈ \(present.reduce(0) { $0 + $1.tokens }) token"
        if present.contains(where: { $0.rows.contains { $0.trimmed } }) {
            line += "（本机截断，实际更少）"
        }
        return line
    }

    static func tuningLine(_ decision: RecallTurnDecision, route: String?) -> String {
        let tuning = decision.tuning
        var parts = ["档案触发 \(tuning.archiveTriggerEnabled ? "开" : "关")",
                     "一轮最多 \(tuning.maximumPages) 页"]
        if tuning.cooldownEnabled { parts.append("冷却 \(tuning.cooldownTurns) 句") }
        parts.append("最多翻 \(tuning.maximumRecallCalls) 次")
        func count(_ reason: RecallSuppression.Reason) -> Int {
            decision.suppressions.filter { $0.reason == reason }.count
        }
        for (reason, name) in [(RecallSuppression.Reason.cooldown, "冷却没带"),
                               (.budget, "超预算"), (.pageLimit, "页数上限"), (.unavailable, "不可用")] {
            let n = count(reason)
            if n > 0 { parts.append("\(name) \(n)") }
        }
        if route == "local" { parts.append("本机") }
        return parts.joined(separator: " · ")
    }

    static func gateNotes(_ gate: RecallGateSnapshot, assistantName: String) -> [String] {
        switch gate.off {
        case "master": return ["记忆总开关关着，这轮没带记忆"]
        case "window": return ["这个窗口不参与记忆，这轮没带记忆"]
        case "slot": return ["预设里记忆插槽关着：档案 / 钉住 / \(assistantName)的记忆 / 上窗没带"]
        default: return []
        }
    }

    static func gateLine(_ gate: RecallGateSnapshot, hasLegacyFragment: Bool, assistantName: String) -> String? {
        var parts: [String] = []
        if gate.legacy {
            parts.append("老窗口，按楼层默认带")
        } else {
            let choices = [
                ("timeline", "时间轴"), ("pending", "待续"), ("selfMemory", "\(assistantName)的记忆"),
                ("archive", "档案"), ("previousWindow", "上窗"), ("pinned", "钉住"),
            ]
            let off = choices.filter { gate.choices[$0.0] == false }.map(\.1)
            if !off.isEmpty { parts.append("本窗划掉了：" + off.joined(separator: " · ")) }
        }
        if gate.triggerOff, hasLegacyFragment {
            parts.append("档案触发关着，碎片按旧规则带")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 翻了块

    static func read(_ read: RecallReadReceipt) -> Read {
        Read(title: readTitle(read), status: readStatus(read))
    }

    static func readTitle(_ read: RecallReadReceipt) -> String {
        switch read.layer {
        case "wiki索引": return "档案目录"
        case "L1": return "要点卡"
        case "L2": return "L2 原文"
        default: break
        }
        // 生产写入的一律是 `RecallTool.json(target)`（snake_case），必须用同一个解码器（`RecallTool.swift:195-204`）
        guard let target = try? RecallTool.decoder.decode(RecallTool.Target.self, from: Data(read.target.utf8)) else {
            return knownLayers.contains(read.layer) ? read.layer : "其它"
        }
        switch read.layer {
        case "A4": return "A4 · \(shortDate(target.date))"
        case "A3": return "A3 · 窗口 \(shortId(target.conversationId))"
        case "A2": return "A2 · 第 \(target.segment.map(String.init) ?? "?") 段"
        case "原文":
            if let query = target.query {
                let scope = target.scope.map { "（范围 \($0)）" } ?? ""
                return "搜「\(query)」\(scope)"
            }
            return "原文 · 窗口 \(shortId(target.conversationId))"
        case "wiki页": return "档案页 · \(target.page?.path.split(separator: "/").last.map(String.init) ?? "?")"
        default: return "其它"
        }
    }

    static let knownLayers: Set<String> = ["wiki索引", "L1", "L2", "A4", "A3", "A2", "原文", "wiki页"]

    /// 「2026-11-08」→「11-08」（plan §2.1 的读标题口径）
    static func shortDate(_ date: String?) -> String {
        guard let date, !date.isEmpty else { return "那天" }
        let parts = date.split(separator: "-")
        guard parts.count >= 3 else { return date }
        return "\(parts[parts.count - 2])-\(parts[parts.count - 1])"
    }

    static func readStatus(_ read: RecallReadReceipt) -> String {
        var text: String
        switch read.status {
        case "success", "partial":
            if let count = read.returnedCount {
                text = count > 0 ? "翻到 \(count) 条" : "没找到"
            } else {
                text = "翻了"
            }
        case "invalidTarget": text = "目标不对"
        case "stale": text = "已过期，没读"
        case "unavailable": text = "不可用"
        case "limited": text = "到本轮上限，没翻"
        default: text = "其它"
        }
        if read.next?.hasMore == true { text += "，还有" }
        if read.gate == "master" || read.gate == "window" { text += "（记忆关着，只能翻原文）" }
        return text
    }

    static func shortId(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "?" }
        return String(id.prefix(8))
    }
}

// MARK: - 轻解码（Tutu / 栅格标签只要 N 与出卡）

/// 只解卡要用的字段：`delivery.items[].kind`、`delivery.route`、`reads[].status/returnedCount`、
/// `attempts[].status/receivedResponse`、`decision.selected.count`；不碰 candidates / stateAfterResponse / 正文。
struct RecallCardDigest: Decodable, Equatable {
    struct Item: Decodable, Equatable { let kind: String }
    struct Delivery: Decodable, Equatable { let route: String; let items: [Item] }
    struct Read: Decodable, Equatable { let status: String; let returnedCount: Int? }
    struct Attempt: Decodable, Equatable { let status: String; let receivedResponse: Bool }
    struct Decision: Decodable, Equatable {
        struct Selected: Decodable, Equatable {}
        let selected: [Selected]
    }

    let decision: Decision
    let delivery: Delivery?
    let reads: [Read]
    let attempts: [Attempt]

    var tally: RecallCardModel.Tally {
        RecallCardModel.Tally(
            hitItems: delivery.map { $0.items.filter { RecallCardModel.isHit($0.kind) }.count } ?? decision.selected.count,
            reads: reads.map { .init(status: $0.status, returnedCount: $0.returnedCount) },
            attempts: attempts.map { .init(status: $0.status, receivedResponse: $0.receivedResponse) })
    }
}

struct RecallCardSummary: Equatable {
    let hasRecall: Bool
    let label: String

    static func make(receiptData: Data?, legacyHits: Int, mode: DisclosureMode, streaming: Bool) -> RecallCardSummary {
        let hidden = RecallCardSummary(hasRecall: false, label: "")
        guard mode != .hidden else { return hidden }
        func legacy() -> RecallCardSummary {
            guard legacyHits > 0 else { return hidden }
            return RecallCardSummary(hasRecall: true, label: "想起来了 \(legacyHits) 件事（旧记录）")
        }
        guard let receiptData, let digest = try? JSONDecoder().decode(RecallCardDigest.self, from: receiptData) else {
            return legacy()
        }
        guard digest.delivery?.route != "ccBridge" else { return hidden }
        let tally = digest.tally
        let hasReads = !digest.reads.isEmpty
        guard tally.hitItems > 0 || hasReads else {
            return digest.delivery == nil ? legacy() : hidden
        }
        let result = tally.label(streaming: streaming)
        return RecallCardSummary(hasRecall: true, label: result.label)
    }
}
