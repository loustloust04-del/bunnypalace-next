import Foundation

struct CatalogSearchEvidence: Codable, Equatable, Sendable {
    var original: [String] = []
    var aline: [String] = []
    var fragments: [String] = []
    var assigned: [String] = []
    var vectorStatus: String = "未检索"

    var searchedChars: Int { (original + aline + fragments).reduce(0) { $0 + $1.count } }
    var assignedChars: Int { assigned.reduce(0) { $0 + $1.count } }

    init(original: [String] = [], aline: [String] = [], fragments: [String] = [], assigned: [String] = [], vectorStatus: String = "未检索") {
        self.original = original
        self.aline = aline
        self.fragments = fragments
        self.assigned = assigned
        self.vectorStatus = vectorStatus
    }

    private enum CodingKeys: String, CodingKey { case original, aline, fragments, assigned, vectorStatus }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        original = try c.decodeIfPresent([String].self, forKey: .original) ?? []
        aline = try c.decode([String].self, forKey: .aline)
        fragments = try c.decode([String].self, forKey: .fragments)
        assigned = try c.decode([String].self, forKey: .assigned)
        vectorStatus = try c.decode(String.self, forKey: .vectorStatus)
    }
}

/// 正文区间随拼接记录；出处只登记完整回灌的来源单元（同一条原料 / 段 / 日 A4 的几段正文算一个单元，截掉半截的整个单元不登记）。
struct CatalogSearchReceipt: Sendable {
    enum Kind: Sendable, Equatable { case original, aline, fragment }
    enum Source: Sendable {
        case original(SearchService.CatalogNode)
        case aline(CatalogALineReader.Hit)
        case fragment(String, CatalogFragment)
    }
    struct Body: Sendable {
        var kind: Kind
        var range: Range<Int>
        var source: Source? = nil
        /// 同一个来源单元的几段正文同号
        var unit = 0
        /// 这个单元整个回灌了
        var complete = true
    }
    var text = ""
    var bodies: [Body] = []
    var vectorStatus: String
    /// 已发出的单元号
    var units = 0

    var bodyChars: Int { bodies.reduce(0) { $0 + $1.range.count } }

    mutating func append(_ value: String) { text += value }

    mutating func appendBody(_ value: String, kind: Kind, source: Source? = nil) {
        units += 1
        appendBody(value, kind: kind, source: source, unit: units)
    }

    private mutating func appendBody(_ value: String, kind: Kind, source: Source?, unit: Int) {
        guard !value.isEmpty else { return }
        let start = text.count
        text += value
        bodies.append(Body(kind: kind, range: start..<text.count, source: source, unit: unit))
    }

    mutating func appendParts(_ parts: [CatalogSearchPart], kind: Kind, source: Source? = nil) {
        units += 1
        for part in parts {
            if part.isBody { appendBody(part.text, kind: kind, source: source, unit: units) }
            else { append(part.text) }
        }
    }

    mutating func appendReceipt(_ receipt: CatalogSearchReceipt) {
        let offset = text.count, shift = units
        text += receipt.text
        bodies += receipt.bodies.map {
            Body(kind: $0.kind, range: ($0.range.lowerBound + offset)..<($0.range.upperBound + offset), source: $0.source,
                 unit: $0.unit + shift, complete: $0.complete)
        }
        units += receipt.units
    }

    /// 前 count 个字；被截到的单元（截了半截或后几段没进来）整个标成不完整
    func prefix(_ count: Int) -> CatalogSearchReceipt {
        let limit = min(text.count, max(0, count))
        let cut = Set(bodies.filter { $0.range.upperBound > limit }.map(\.unit))
        var out = CatalogSearchReceipt(text: String(text.prefix(limit)), bodies: bodies.compactMap { body in
            guard body.range.lowerBound < limit else { return nil }
            return Body(kind: body.kind, range: body.range.lowerBound..<min(body.range.upperBound, limit), source: body.source,
                        unit: body.unit, complete: body.complete && !cut.contains(body.unit))
        }, vectorStatus: vectorStatus)
        out.units = units
        return out
    }

    func bodyPrefix(_ count: Int) -> CatalogSearchReceipt {
        var remaining = max(0, count)
        for body in bodies {
            if body.range.count > remaining { return prefix(body.range.lowerBound + remaining) }
            remaining -= body.range.count
            if remaining == 0 { return prefix(body.range.upperBound) }
        }
        return self
    }

    mutating func appendALine(_ hit: CatalogALineReader.Hit) {
        switch hit.layer {
        case .a4 where hit.conversationId == nil:
            append("- \(hit.day) 一天：")
        case .a4:
            append("- \(hit.day) 《\(hit.title)》\(CatalogALineReader.conv(hit.conversationId))\(CatalogALineReader.oldTagText(hit.old))：")
        case .a3:
            append("- \(CatalogALineReader.conv(hit.conversationId))《\(hit.title)》\(CatalogALineReader.spanText(hit.start, hit.end))\(CatalogALineReader.oldTagText(hit.old))：\n")
        case .a2:
            append("〔\(CatalogALineReader.conv(hit.conversationId))《\(hit.title)》第 \(hit.segment ?? 0) 段 · \(CatalogALineReader.spanText(hit.start, hit.end)) · "
                + "\(hit.messages.map(CatalogALineReader.messagesLabel) ?? "")\(CatalogALineReader.oldTagText(hit.old))〕\n")
        }
        appendParts(hit.parts, kind: .aline, source: .aline(hit))
    }

    func register(in sources: inout CatalogSources) {
        for body in bodies where body.complete {
            switch body.source {
            case .original(let node): sources.addOriginal(node)
            case .aline(let hit): sources.add(.init(terms: [], hits: [hit], found: [:]))
            case .fragment(let label, let fragment): sources.fragments[label] = fragment
            case nil: break
            }
        }
    }

    func evidence(visibleChars: Int? = nil) -> CatalogSearchEvidence {
        let limit = min(text.count, max(0, visibleChars ?? text.count))
        var out = CatalogSearchEvidence(vectorStatus: vectorStatus)
        for body in bodies where body.range.lowerBound < limit {
            let lo = text.index(text.startIndex, offsetBy: body.range.lowerBound)
            let hi = text.index(lo, offsetBy: min(limit, body.range.upperBound) - body.range.lowerBound)
            let content = String(text[lo..<hi])
            switch body.kind {
            case .original: out.original.append(content)
            case .aline: out.aline.append(content)
            case .fragment: out.fragments.append(content)
            }
        }
        return out
    }
}
