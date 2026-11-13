import MemoryCore
import Foundation

extension CatalogALineReader.Result {
    func receipt() -> CatalogSearchReceipt {
        var receipt = CatalogSearchReceipt(vectorStatus: "未检索")
        let quoted = terms.map { "「\($0)」" }.joined()
        guard !hits.isEmpty else {
            receipt.append("A 线搜\(quoted)：A4 时间轴、A3 窗口总结、A2 上下文摘要都没命中。")
            return receipt
        }
        func count(_ l: CatalogALineReader.Layer, _ unit: String) -> String {
            let f = found[l] ?? 0, g = given(l)
            return f == g ? "\(l.rawValue) \(g) \(unit)" : "\(l.rawValue) \(f) \(unit)（给了 \(g)）"
        }
        var head = "A 线搜\(quoted)，按检索顺序：" + [count(.a4, "条"), count(.a3, "个窗口"), count(.a2, "段")].joined(separator: "、")
        if truncated { head += "，已按备料上限截断" }
        head += "。往下翻：read_aline(窗口) = 这个窗口的 A3 + A2 段目录；read_aline(窗口, 段号) = 那一段全文。"
        receipt.append(head)
        var previous: CatalogALineReader.Layer?
        for hit in hits {
            if previous != hit.layer {
                switch hit.layer {
                case .a4: receipt.append("\n\n【A4 时间轴】")
                case .a3: receipt.append("\n\n【A3 窗口总结】")
                case .a2: receipt.append("\n\n【A2 上下文摘要】")
                }
            }
            receipt.append(hit.layer == .a2 ? "\n\n" : "\n")
            receipt.appendALine(hit)
            previous = hit.layer
        }
        return receipt
    }

    func render() -> String { receipt().text }
}

extension CatalogALineReader.Window {
    func receipt() -> CatalogSearchReceipt {
        var receipt = CatalogSearchReceipt(vectorStatus: "未检索")
        var head = "A3 + A2 目录 · \(CatalogALineReader.conv(conversationId))《\(title)》：A2 共 \(segments.count) 段"
        if a3 == nil { head += "，还没压成窗口总结" }
        head += segments.isEmpty ? "。" : "。往下翻：read_aline(窗口, 段号) = 那一段全文（经过 + 原话）。"
        receipt.append(head)
        if let a3 {
            receipt.append("\n\n【A3 窗口总结】\(SessionSummaryStore.timeRange(a3)) · \(a3.title)\n")
            let hit = CatalogALineReader.Hit(layer: .a3, conversationId: conversationId, title: title, start: a3.start, end: a3.end,
                                            day: MemoryDay.key(a3.start), parts: [], old: nil)
            receipt.appendParts(CatalogALineReader.segmentParts(a3, includeTitle: false), kind: .aline, source: .aline(hit))
        } else if !oldA3.isEmpty {
            receipt.append("\n\n【A3 窗口总结】（旧·v4-1 窗口总结抄本，只列 A2 里没有的）\n")
            for (index, segment) in oldA3.enumerated() {
                if index > 0 { receipt.append("\n\n") }
                receipt.append("〔\(SessionSummaryStore.timeRange(segment)) · \(segment.title)〕\n")
                let hit = CatalogALineReader.Hit(layer: .a3, conversationId: conversationId, title: title, start: segment.start, end: segment.end,
                                                day: MemoryDay.key(segment.start), parts: [], old: "v4-1")
                receipt.appendParts(CatalogALineReader.segmentParts(segment, includeTitle: false), kind: .aline, source: .aline(hit))
            }
        }
        if !segments.isEmpty {
            receipt.append("\n\n【A2 段目录】\n")
            for (index, segment) in segments.enumerated() {
                if index > 0 { receipt.append("\n") }
                receipt.append("- 第 \(segment.number) 段 · \(SessionSummaryStore.timeRange(segment.segment)) · \(segment.segment.title) · ")
                let hit = CatalogALineReader.Hit(layer: .a2, conversationId: conversationId, title: title,
                                                start: segment.segment.start, end: segment.segment.end, day: MemoryDay.key(segment.segment.start),
                                                segment: segment.number, messages: segment.messages, parts: [], old: segment.old)
                receipt.appendParts(CatalogALineReader.gistParts(segment.segment), kind: .aline, source: .aline(hit))
                receipt.append(" · \(CatalogALineReader.messagesLabel(segment.messages))\(CatalogALineReader.oldTagText(segment.old))")
            }
        }
        return receipt
    }

    func render() -> String { receipt().text }
}

extension CatalogALineReader.SegmentRead {
    func receipt() -> CatalogSearchReceipt {
        var receipt = CatalogSearchReceipt(vectorStatus: "未检索")
        receipt.append("A2 第 \(segment.number) 段（共 \(count) 段）· \(CatalogALineReader.conv(conversationId))《\(title)》· \(SessionSummaryStore.timeRange(segment.segment))"
            + " · \(CatalogALineReader.messagesLabel(segment.messages))\(CatalogALineReader.oldTagText(segment.old))。再往下只有原文。\n\n")
        let hit = CatalogALineReader.Hit(layer: .a2, conversationId: conversationId, title: title,
                                        start: segment.segment.start, end: segment.segment.end, day: MemoryDay.key(segment.segment.start),
                                        segment: segment.number, messages: segment.messages, parts: [], old: segment.old)
        receipt.appendParts(segment.parts, kind: .aline, source: .aline(hit))
        return receipt
    }

    func render() -> String { receipt().text }
}
