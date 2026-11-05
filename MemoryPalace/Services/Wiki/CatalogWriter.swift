import Foundation

// MARK: - 楼层提示词：她亲手写的那几段（规格 4：写过的不重复写）

/// 取楼层上她自己写的字：系统提示、她的身份、角色描述、角色性格、场景（不是拼装好的整份 prompt，不带预设 / 记忆 / 世界书）。
/// `{{user}}` / `{{char}}` 换成名字；太长截掉尾巴
enum CatalogFloorPrompt {
    static let maxChars = 3000

    static func text(profile: Profile, defaults: UserDefaults = .standard) -> String {
        let names = EffectiveCharacterContext(profile: profile, defaults: defaults)
        return text(sections: [
            ("系统提示", profile.systemPrompt),
            ("\(names.userName)的身份", profile.userPersona),
            ("角色描述", profile.characterDescription),
            ("角色性格", profile.characterPersonality),
            ("场景", profile.scenario),
        ], names: names)
    }

    static func text(sections: [(String, String)], names: EffectiveCharacterContext) -> String {
        let out = sections.compactMap { label, raw -> String? in
            let t = names.expand(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : "〔\(label)〕\n\(t)"
        }.joined(separator: "\n\n")
        return out.count > maxChars ? String(out.prefix(maxChars)) + "…" : out
    }
}

// MARK: - 出处：模型能引用的碎片、原文节点和 A 线窗口 / 段（引用不到的不算出处）

struct CatalogSources: Sendable {
    struct Window: Sendable, Equatable {
        var id: String
        var title: String
        var day: String
    }
    /// 窗口前 8 位 → 本次实际提供过的 A 线层
    var windowLayers: [String: Set<String>] = [:]
    /// 本次实际提供过的 A4 一天一条（日期；不属于哪个窗口，按日期引用）
    var days: Set<String> = []

    struct Segment: Sendable, Equatable {
        var messages: Range<Int>?
        var day: String
    }

    /// 编号（f1…）→ 碎片
    var fragments: [String: CatalogFragment] = [:]
    /// conv 前 8 位 → 窗口
    var windows: [String: Window] = [:]
    /// 「前 8 位#段号」→ 那一段
    var segments: [String: Segment] = [:]
    /// 消息节点 id → 本次实际提供的可见原文值快照
    var originals: [String: SearchService.CatalogNode] = [:]
    /// 页路径 → 动笔前 / 读页时看到的版本（提案的基线；没记上的页不能改）
    var versions: [String: String] = [:]

    /// 实际给过模型的整份原料（种子的 Prompt 槽 / 字段、CC 文件、wiki 页 / 索引；问卷答案也从 addFile 登记）：路径 → 出处
    struct File: Sendable, Equatable {
        var cite: WikiProposal.Cite
        var label: String
    }
    var files: [String: File] = [:]

    /// 登记一份实际给过模型的原料；记录行「（出处：…）」里的字只从 label 出，改稿时按同一个口径核
    mutating func addFile(_ path: String, cite: WikiProposal.Cite) {
        files[path] = File(cite: cite, label: Self.label(cite))
    }

    static func label(_ cite: WikiProposal.Cite) -> String {
        let path = cite.filePath ?? ""
        switch cite.layer {
        case "Prompt": return "Prompt \(cite.name ?? path)"
        case "wiki":
            if let page = CatalogSeedMaterials.pagePath(path) { return "wiki " + page }
            if let folder = CatalogSeedMaterials.indexFolder(path) { return folder.isEmpty ? "wiki 根索引" : "wiki \(folder) 索引" }
            return "wiki " + path
        case CatalogSurvey.layer: return CatalogSurvey.label(cite)
        default: return "\(cite.layer) \(path)"
        }
    }

    static func label(_ fragment: UUID) -> String { "碎片 \(fragment.uuidString.prefix(8).lowercased())" }

    /// 她自己补的、改过字的记录行的出处
    static let userEdit = "用户编辑"

    /// 一行记录拆成正文和「（出处：…）」里的几项；没有出处 = nil
    static func split(_ line: String) -> (body: String, labels: [String]?) {
        guard line.hasSuffix("）"), let open = line.range(of: "（出处：", options: .backwards) else { return (line, nil) }
        return (String(line[..<open.lowerBound]), line[open.upperBound..<line.index(before: line.endIndex)].components(separatedBy: "；"))
    }

    /// 审计台 / 文件库改过的记录（种子、普通提案同一套）：行末留着原有出处（或「用户编辑」）的照留，改了字也不动出处；
    /// 没写出处的新行标「用户编辑」；删掉旧行的出处、或写了不认识的出处，拒存
    static func checkEdited(_ lines: [String], original: [String], allowed: Set<String>) throws -> [String] {
        let bodies = Set(original.map { split($0).body })
        let known = allowed.union(original.flatMap { split($0).labels ?? [] }).union([userEdit])
        return try lines.enumerated().map { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let (body, labels) = split(line)
            guard let labels else {
                if bodies.contains(body) { throw CatalogSeedDrafts.EditError.invalid("第 \(index + 1) 条记录删掉了出处，不能存") }
                return "\(line)（出处：\(userEdit)）"
            }
            guard labels.allSatisfy(known.contains) else {
                throw CatalogSeedDrafts.EditError.invalid("第 \(index + 1) 条记录的出处不是这一条原来的出处，不能存")
            }
            return line
        }
    }

    /// 改过记录之后还挂着的碎片：原来哪行写着它、改完一行都不写它了的，不再挂（批了也不标已整理，回池子）
    static func keptFragments(_ ids: [UUID], original: [String], edited: [String]) -> [UUID] {
        let before = Set(original.flatMap { split($0).labels ?? [] }), after = Set(edited.flatMap { split($0).labels ?? [] })
        return ids.filter { !before.contains(label($0)) || after.contains(label($0)) }
    }
    /// 还没入库、但这次可以连过去的页（种子：同一任务里获批的目录项）；是否真的在，正文审批时再处理
    var linkTargets: Set<String> = []

    static func windowKey(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("conv") { t = t.dropFirst(4).trimmingCharacters(in: .whitespaces) }
        return String(t.prefix(8))
    }

    static func segmentKey(_ window: String, _ n: Int) -> String { "\(windowKey(window))#\(n)" }

    mutating func addFragments(_ list: [CatalogFragment], labels: (Int) -> String = CatalogSorter.label) {
        var seen = Set(fragments.values.map(\.id))
        for (i, f) in list.enumerated() where seen.insert(f.id).inserted { fragments[labels(i)] = f }
    }

    mutating func addOriginal(_ node: SearchService.CatalogNode) {
        guard node.role == "user" || node.role == "assistant" else { return }
        originals[node.nodeId] = node
    }

    private mutating func addWindow(_ id: String, title: String, day: String, layer: String) {
        let key = Self.windowKey(id)
        if windows[key] == nil || windows[key]?.title.isEmpty == true { windows[key] = Window(id: id, title: title, day: day) }
        windowLayers[key, default: []].insert(layer)
    }

    mutating func add(_ r: CatalogALineReader.Result) {
        for h in r.hits {
            guard let id = h.conversationId else {
                days.insert(h.day)
                continue
            }
            addWindow(id, title: h.title, day: h.day, layer: h.layer.rawValue)
            if let n = h.segment { segments[Self.segmentKey(id, n)] = Segment(messages: h.messages, day: h.day) }
        }
    }

    mutating func add(_ w: CatalogALineReader.Window) {
        if w.a3 != nil || !w.oldA3.isEmpty {
            addWindow(w.conversationId, title: w.title, day: w.a3.map { MemoryDay.key($0.start) } ?? w.oldA3.first.map { MemoryDay.key($0.start) } ?? "", layer: "A3")
        }
        for s in w.segments {
            addWindow(w.conversationId, title: w.title, day: MemoryDay.key(s.segment.start), layer: "A2")
            segments[Self.segmentKey(w.conversationId, s.number)] = Segment(messages: s.messages, day: MemoryDay.key(s.segment.start))
        }
    }

    mutating func add(_ s: CatalogALineReader.SegmentRead) {
        addWindow(s.conversationId, title: s.title, day: MemoryDay.key(s.segment.segment.start), layer: "A2")
        segments[Self.segmentKey(s.conversationId, s.segment.number)] = Segment(messages: s.segment.messages, day: MemoryDay.key(s.segment.segment.start))
    }
}

// MARK: - 条目：模型交的 JSON → 提案条目（两步的第二步、手动 agent 的 submit_proposal 共用一套校验）

enum CatalogItems {
    struct Parsed: Equatable {
        var items: [WikiProposal.Item]
        /// 扔掉的（条目不合格 + 没出处的记录行）
        var dropped: Int
        /// 写手判「已被现有页写过、不用再写」的碎片（`attachCovered` 之后 = 没条目可挂的）
        var covered: [UUID] = []
        /// 写手判「单条就够」的碎片：不进页、不用批，留在碎片池照样能找到
        var single: [UUID] = []
        /// covered 对应哪一页（agent 读过的页里点名）
        var coveredPage: String? = nil
        var dropReasons: [String] = []
        var reason: String? = nil
        /// 代码硬查没过的（定位：哪项）；同样的话挂在对应条目的 checks 上
        var checks: [String] = []
        /// 收不进页的内容（关系不在四种之内的连线、不认识的条目类型、条目带了不收的字段）：不执行，原样留在提案上给她看
        var unapplied: [WikiProposal.Unapplied] = []
        /// 修订实际走到哪一步
        var revision: String? = nil
        /// 写手同一次自报的两样诊断（只记日志）；nil = 这次没交
        var coverage: [CatalogDiagnostics.Coverage]? = nil
        var preservation: [CatalogDiagnostics.Preservation]? = nil

        /// 要给模型那一次修订的理由
        var revisionNotes: [String] { checks + unapplied.map { "\($0.at)：\($0.reason)" } }
        /// 交得出去：有条目、有没收进页的内容，或合法的 covered / single
        var deliverable: Bool { !items.isEmpty || !unapplied.isEmpty || !covered.isEmpty || !single.isEmpty }
    }

    struct RawCite: Decodable {
        let layer: String
        let day: String?
        let window: String?
        let nodeId: String?
        let profileId: String?
        let segment: Int?
    }

    struct RawRecord: Decodable {
        let text: String
        let fragments: [CatalogJSON.Label]?
        let aline: [CatalogJSON.Lossy<RawCite>]?
        let sources: [String]?
    }

    struct RawLink: Decodable {
        let to: String
        let relation: String
        let why: String?
    }

    struct RawItem: Decodable {
        let type: String
        let path: String
        let kind: String?
        let title: String?
        let triggers: [String]?
        let hook: String?
        let now: String?
        let records: [CatalogJSON.Lossy<RawRecord>]?
        let links: [CatalogJSON.Lossy<RawLink>]?
        let to: String?
        let relation: String?
        let why: String?
        let judgment: String?
        let fragments: [CatalogJSON.Label]?
        let aline: [CatalogJSON.Lossy<RawCite>]?
        let validUntil: String?

        private enum CodingKeys: String, CodingKey {
            case type, path, kind, title, triggers, hook, now, records, links, to, relation, why, judgment, fragments, aline
            case validUntil = "valid_until"
        }
    }

    private struct Envelope: Decodable {
        let items: [CatalogJSON.Lossy<RawItem>]
        let covered: [CatalogJSON.Label]?
        let single: [CatalogJSON.Label]?
        let coveredPage: String?
        let reason: String?

        private enum CodingKeys: String, CodingKey {
            case items, covered, single, reason
            case coveredPage = "covered_page"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decode(CatalogJSON.Container<[CatalogJSON.Lossy<RawItem>]>.self, forKey: .items).value
            covered = try container.decodeIfPresent(CatalogJSON.Container<[CatalogJSON.Label]>.self, forKey: .covered)?.value
            single = try? container.decodeIfPresent(CatalogJSON.Container<[CatalogJSON.Label]>.self, forKey: .single)?.value
            coveredPage = try? container.decode(String.self, forKey: .coveredPage)
            reason = try? container.decode(String.self, forKey: .reason)
        }
    }

    static func judgment(_ raw: String?) -> WikiProposal.Judgment? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "conflict", "冲突": return .conflict
        case "coexist", "共存": return .coexist
        default: return nil
        }
    }

    /// 一行出处：碎片编号要认得、A 线窗口要在搜 / 读过的结果里；认不出的不算
    private struct Resolved {
        var fragments: [CatalogFragment] = []
        var cites: [(WikiProposal.Cite, String)] = []
        var isEmpty: Bool { fragments.isEmpty && cites.isEmpty }
    }

    private static func resolve(_ labels: [CatalogJSON.Label]?, _ cites: [CatalogJSON.Lossy<RawCite>]?, files: [String]? = nil,
                                sources: CatalogSources) -> Resolved {
        var out = Resolved()
        for l in labels ?? [] {
            guard let f = sources.fragments[l.value] else { continue }
            if !out.fragments.contains(f) { out.fragments.append(f) }
        }
        for path in files ?? [] {
            guard let file = sources.files[path.trimmingCharacters(in: .whitespacesAndNewlines)] else { continue }
            if !out.cites.contains(where: { $0.0 == file.cite }) { out.cites.append((file.cite, file.label)) }
        }
        for c in (cites ?? []).compactMap(\.value) {
            let layer = c.layer.trimmingCharacters(in: .whitespaces).uppercased()
            if layer == "原文" {
                guard let nodeId = c.nodeId, let node = sources.originals[nodeId], c.segment == nil,
                      c.profileId == nil || c.profileId == node.profileId else { continue }
                if let window = c.window {
                    let raw = window.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = raw.lowercased().hasPrefix("conv ") ? String(raw.dropFirst(5)).trimmingCharacters(in: .whitespaces) : raw
                    guard id == node.conversationId || id == String(node.conversationId.prefix(8)) else { continue }
                }
                let cite = WikiProposal.Cite(layer: "原文", day: node.created.map { MemoryDay.key($0) }, windowId: node.conversationId,
                                             profileId: node.profileId, nodeId: node.nodeId, role: node.role,
                                             created: node.created, onMain: node.onMain)
                let label = WikiProposalDisplay.citeText(cite, titles: [node.conversationId: node.title])
                if !out.cites.contains(where: { $0.0 == cite }) { out.cites.append((cite, label)) }
                continue
            }
            if layer == "A4", c.window == nil, c.nodeId == nil, c.segment == nil,
               let day = c.day?.trimmingCharacters(in: .whitespaces), sources.days.contains(day) {
                let cite = WikiProposal.Cite(layer: "A4", day: day)
                if !out.cites.contains(where: { $0.0 == cite }) { out.cites.append((cite, "A4 \(day)")) }
                continue
            }
            guard c.nodeId == nil, ["A2", "A3", "A4"].contains(layer), let window = c.window,
                  let w = sources.windows[CatalogSources.windowKey(window)] else { continue }
            if layer != "A2" {
                guard c.segment == nil, sources.windowLayers[CatalogSources.windowKey(window)]?.contains(layer) == true else { continue }
            }
            var cite = WikiProposal.Cite(layer: layer, day: w.day.isEmpty ? nil : w.day, windowId: w.id)
            var label = "\(layer)《\(w.title.isEmpty ? CatalogALineReader.conv(w.id) : w.title)》"
            if layer == "A2" {
                guard let n = c.segment, let seg = sources.segments[CatalogSources.segmentKey(w.id, n)] else { continue }
                cite.segment = n
                cite.day = seg.day
                cite.messageFrom = seg.messages?.lowerBound
                cite.messageTo = seg.messages?.upperBound
                label += "第 \(n) 段"
            } else if layer == "A4", let day = cite.day {
                label = "A4 \(day)《\(w.title.isEmpty ? CatalogALineReader.conv(w.id) : w.title)》"
            }
            if !out.cites.contains(where: { $0.0 == cite }) { out.cites.append((cite, label)) }
        }
        return out
    }

    /// 「2026-10-12 约了复诊（到 2026-10-22）（出处：碎片 1a2b3c4d；A2《看病》第 3 段）」
    static func recordLine(_ text: String, fragments: [CatalogFragment], cites: [String]) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for bullet in ["- ", "* "] where t.hasPrefix(bullet) { t = String(t.dropFirst(2)) }
        let src = fragments.map { CatalogSources.label($0.id) } + cites
        return "\(t)（出处：\(src.joined(separator: "；"))）"
    }

    /// nil = 不是 {"items":[…]}。校验：路径在工程 / 楼层下；新开页必须还没有、别的种必须已有且看过版本（基线 = sources.versions）；
    /// 记录行没出处的扔；「记录」只能追加（没有改 / 删旧记录的种）。硬查没过的写进 checks（条目上和汇总各一份）；
    /// 关系不在四种之内、不认识的条目类型、带了不收的字段 → unapplied（原样留下，不执行）。读 wiki，后台调。
    /// 正文和 coverage / preservation 诊断分开解析（`CatalogDiagnostics.split`）：诊断缺、坏、被截断只记未评估，不连累正文；
    /// truncated = 输出被截断：只收诊断键之前那段完整的正文
    static func parse(_ json: String, sources: CatalogSources, wiki: WikiStore, truncated: Bool = false,
                      onError: ((String) -> Void)? = nil) -> Parsed? {
        let split = CatalogDiagnostics.split(json, truncated: truncated)
        var firstError: String?
        var picked: (env: Envelope, text: String)?
        for body in split.bodies {
            if let env = CatalogJSON.decode(Envelope.self, body, onError: { firstError = firstError ?? $0 }) {
                picked = (env, body)
                break
            }
        }
        guard let (env, body) = picked else {
            onError?(firstError ?? "输出被截断，正文不完整")
            return nil
        }
        let diagnostics = CatalogDiagnostics.decode(split.diagnostics)
        var items: [WikiProposal.Item] = []
        var dropReasons: [String] = []
        /// 按条目顺序排：带了不收的字段的在前面那一遍就挑出来了
        var unapplied: [(index: Int, item: WikiProposal.Unapplied)] = []
        var newPaths = Set<String>()
        let rawList = ((try? JSONSerialization.jsonObject(with: Data((FragmentPool.strictObjectText(body) ?? body).utf8))) as? [String: Any])?["items"] as? [Any]
        /// 这一条（或它的第 link 条连线）在写手输出里的原文
        func original(_ index: Int, link: Int? = nil, fallback: String) -> String {
            var object = rawList.flatMap { index < $0.count ? $0[index] : nil }
            if let link { object = ((object as? [String: Any])?["links"] as? [Any]).flatMap { link < $0.count ? $0[link] : nil } }
            guard let object, JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return fallback }
            return String(decoding: data, as: UTF8.self)
        }
        func drop(_ location: String, _ reason: String) {
            dropReasons.append("\(location)：\(reason)")
        }
        func unconsumedField(_ raw: RawItem) -> (name: String, replacement: String)? {
            let consumed: Set<String>
            switch raw.type {
            case "new_page": consumed = ["kind", "title", "triggers", "hook", "now", "records", "links", "valid_until"]
            case "append": consumed = ["records", "judgment"]
            case "rewrite_now": consumed = ["now", "judgment", "valid_until"]
            case "link": consumed = ["to", "relation", "why", "judgment"]
            case "retag": consumed = ["hook", "triggers"]
            default: return nil
            }
            let fields = [
                ("kind", raw.kind != nil, "new_page"),
                ("title", raw.title != nil, "new_page"),
                ("triggers", raw.triggers != nil, "retag"),
                ("hook", raw.hook != nil, "retag"),
                ("now", raw.now != nil, "rewrite_now"),
                ("records", raw.records != nil, "append"),
                ("links", raw.links != nil, "link"),
                ("to", raw.to != nil, "link"),
                ("relation", raw.relation != nil, "link"),
                ("why", raw.why != nil, "link"),
                ("judgment", raw.judgment != nil, "append / rewrite_now / link"),
                ("valid_until", raw.validUntil != nil, "new_page / rewrite_now"),
            ]
            return fields.first { $0.1 && !consumed.contains($0.0) }.map { ($0.0, $0.2) }
        }
        let raws = env.items.enumerated().compactMap { index, entry -> (index: Int, raw: RawItem)? in
            guard let raw = entry.value else {
                drop("items[\(index)]", "条目格式不合格（字段缺失或类型错误）")
                return nil
            }
            if let extra = unconsumedField(raw) {
                let path = CatalogPrompts.normalizedPath(raw.path)
                unapplied.append((index, .init(page: WikiStore.isValidPagePath(path) ? path : nil, raw: original(index, fallback: "type=\(raw.type) path=\(raw.path)"),
                                       reason: "type=\(raw.type) 不收 \(extra.name) 字段，改用 \(extra.replacement)", at: "items[\(index)] \(path)")))
                return nil
            }
            return (index, raw)
        }
        for (_, raw) in raws where raw.type == "new_page" {
            let path = CatalogPrompts.normalizedPath(raw.path)
            if WikiStore.isValidPagePath(path), !wiki.pageExists(path) { newPaths.insert(path) }
        }

        func records(_ list: [CatalogJSON.Lossy<RawRecord>]?, at location: String)
            -> (lines: [String], fragments: [UUID], cites: [WikiProposal.Cite], checks: [CatalogChecks.Finding]) {
            var lines: [String] = [], frags: [UUID] = [], cites: [WikiProposal.Cite] = [], checks: [CatalogChecks.Finding] = []
            for (index, entry) in (list ?? []).enumerated() {
                let at = "\(location).records[\(index)]"
                guard let r = entry.value else { drop(at, "记录格式不合格（字段缺失或类型错误）"); continue }
                guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { drop(at, "记录正文为空"); continue }
                let src = resolve(r.fragments, r.aline, files: r.sources, sources: sources)
                guard !src.isEmpty else { drop(at, "记录没有可用出处（碎片、原文节点、A 线层 / 段或读过的原料都不在本次原料中）"); continue }
                let line = recordLine(r.text, fragments: src.fragments, cites: src.cites.map(\.1))
                lines.append(line)
                checks += CatalogChecks.record(line, at: at)
                for f in src.fragments where !frags.contains(f.id) { frags.append(f.id) }
                for c in src.cites.map(\.0) where !cites.contains(c) { cites.append(c) }
            }
            return (lines, frags, cites, checks)
        }

        func link(_ to: String, _ relation: String, _ why: String?) -> WikiPage.Link? {
            let target = CatalogPrompts.normalizedPath(to)
            guard WikiStore.isValidPagePath(target), wiki.pageExists(target) || newPaths.contains(target) || sources.linkTargets.contains(target),
                  let rel = WikiPage.Relation(rawValue: relation.trimmingCharacters(in: .whitespaces)) else { return nil }
            return WikiPage.Link(target: target, relation: rel, why: why?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }

        var created = Set<String>()
        var findings: [CatalogChecks.Finding] = []
        /// 关系不在四种之内：整条连线原样留下，不进页
        func hold(_ index: Int, from: String, to: String, relation: String, raw: String, at location: String) -> Bool {
            guard let reason = CatalogChecks.relation(relation, to: to) else { return false }
            unapplied.append((index, .init(page: from, raw: raw, reason: reason, at: location)))
            return true
        }
        /// 期限从「现在」里写明的「到 日子」推；写手给的 valid_until 是其中一天就用它，对不上的原样留给她看（条目照交）
        func until(_ index: Int, _ value: String?, now: String, path: String, at location: String) -> String? {
            let day = WikiPage.until(value, in: now)
            if let value, FragmentPool.validDay(value) != day {
                unapplied.append((index, .init(page: path, raw: "valid_until=\(value)",
                                               reason: "valid_until「\(value)」不是「现在」里写的到期日（到 YYYY-MM-DD），按正文定为\(day ?? "没有期限")", at: location)))
            }
            return day
        }
        for (index, raw) in raws {
            let path = CatalogPrompts.normalizedPath(raw.path)
            let at = "items[\(index)] \(path)"
            guard WikiStore.isValidPagePath(path) else { drop(at, "路径不在工程 / 楼层下或路径不合法"); continue }
            let extra = resolve(raw.fragments, raw.aline, sources: sources)
            var item: WikiProposal.Item?
            var rejection: String? = "条目格式不合格"
            var checks: [CatalogChecks.Finding] = []
            switch raw.type {
            case "new_page":
                guard newPaths.contains(path) else { rejection = "新开页已存在"; break }
                guard created.insert(path).inserted else { rejection = "同批重复新开页"; break }
                let r = records(raw.records, at: at)
                checks += r.checks
                var links: [WikiPage.Link] = []
                for (linkIndex, entry) in (raw.links ?? []).enumerated() {
                    let linkAt = "\(at).links[\(linkIndex)]"
                    guard let l = entry.value else { drop(linkAt, "连线格式不合格（字段缺失或类型错误）"); continue }
                    if let ok = link(l.to, l.relation, l.why), ok.target != path {
                        links.append(ok)
                    } else if !hold(index, from: path, to: l.to, relation: l.relation,
                                    raw: original(index, link: linkIndex, fallback: "to=\(l.to) relation=\(l.relation)"), at: linkAt) {
                        drop(linkAt, "连线不合法（目标 \(l.to)，关系 \(l.relation)：目标路径 / 页面不存在、关系不支持或连到自己）")
                    }
                }
                let title = raw.title?.trimmingCharacters(in: .whitespaces).nonEmpty ?? String(path.split(separator: "/").last ?? "")
                let page = WikiPage(path: path, kind: raw.kind.flatMap { WikiPage.Kind(rawValue: $0.trimmingCharacters(in: .whitespaces)) },
                                    triggers: WikiStore.normalizedWords(raw.triggers?.isEmpty == false ? raw.triggers! : [title]),
                                    hook: raw.hook?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", title: title,
                                    now: raw.now?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", records: r.lines, links: links)
                var withUntil = page
                withUntil.validUntil = until(index, raw.validUntil, now: page.now, path: path, at: at)
                checks += CatalogChecks.now(page.now, at: at)
                item = WikiProposal.Item(change: .newPage(page: withUntil), fragmentIds: r.fragments, cites: r.cites, baseVersion: nil)
            case "append":
                guard let base = sources.versions[path] else { rejection = "已有页未读版本或页面不存在"; break }
                guard wiki.pageExists(path) else { rejection = "已有页不存在"; break }
                let r = records(raw.records, at: at)
                guard !r.lines.isEmpty else { rejection = "没有可追加的有效记录"; break }
                checks += r.checks
                item = WikiProposal.Item(change: .appendRecords(path: path, lines: r.lines), judgment: judgment(raw.judgment),
                                         fragmentIds: r.fragments, cites: r.cites, baseVersion: base)
            case "rewrite_now":
                guard let base = sources.versions[path] else { rejection = "已有页未读版本或页面不存在"; break }
                guard let page = wiki.read(path) else { rejection = "已有页不存在或无法读取"; break }
                guard let now = raw.now?.trimmingCharacters(in: .whitespacesAndNewlines), !now.isEmpty else { rejection = "现在正文缺失或为空"; break }
                let newUntil = until(index, raw.validUntil, now: now, path: path, at: at)
                guard now != page.now || newUntil != page.validUntil else { rejection = "无变化（现在和期限都与已有页相同）"; break }
                checks += CatalogChecks.now(now, at: at)
                item = WikiProposal.Item(change: .rewriteNow(path: path, old: page.now, new: now, until: newUntil),
                                         judgment: judgment(raw.judgment), baseVersion: base)
            case "link":
                guard let base = sources.versions[path] else { rejection = "已有页未读版本或页面不存在"; break }
                guard let page = wiki.read(path) else { rejection = "已有页不存在或无法读取"; break }
                guard let to = raw.to, let relation = raw.relation else { rejection = "连线格式不合格（缺少目标或关系）"; break }
                if hold(index, from: path, to: to, relation: relation, raw: original(index, fallback: "type=link to=\(to) relation=\(relation)"), at: at) {
                    rejection = nil
                    break
                }
                guard let l = link(to, relation, raw.why), l.target != path else {
                    rejection = "连线不合法（目标 \(to)，关系 \(relation)：目标路径 / 页面不存在或连到自己）"
                    break
                }
                guard !page.links.contains(l) else { rejection = "无变化（连线已存在）"; break }
                item = WikiProposal.Item(change: .link(from: path, link: l), judgment: judgment(raw.judgment), baseVersion: base)
            case "retag":
                guard let base = sources.versions[path] else { rejection = "已有页未读版本或页面不存在"; break }
                guard let page = wiki.read(path) else { rejection = "已有页不存在或无法读取"; break }
                let hook = raw.hook?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? page.hook
                let triggers = raw.triggers.map(WikiStore.normalizedWords).flatMap { $0.isEmpty ? nil : $0 } ?? page.triggers
                guard hook != page.hook || triggers != page.triggers else { rejection = "无变化（钩子和触发词与已有页相同）"; break }
                item = WikiProposal.Item(change: .retag(path: path, oldHook: page.hook, newHook: hook, oldTriggers: page.triggers, newTriggers: triggers),
                                         baseVersion: base)
            default:
                unapplied.append((index, .init(page: path, raw: original(index, fallback: "type=\(raw.type) path=\(path)"),
                                       reason: "不支持的条目类型：\(raw.type)（只有 new_page / append / rewrite_now / link / retag；记录只追加，已有记录行不能改）",
                                       at: at)))
                rejection = nil
            }
            findings += checks
            guard var ok = item else {
                if let rejection { drop(at, rejection) }
                continue
            }
            if !checks.isEmpty { ok.checks = checks.map(\.message) }
            for f in extra.fragments where !ok.fragmentIds.contains(f.id) { ok.fragmentIds.append(f.id) }
            for c in extra.cites.map(\.0) where !ok.cites.contains(c) { ok.cites.append(c) }
            items.append(ok)
        }
        let used = Set(items.flatMap(\.fragmentIds))
        var covered: [UUID] = []
        for l in env.covered ?? [] {
            if let f = sources.fragments[l.value], !used.contains(f.id), !covered.contains(f.id) { covered.append(f.id) }
        }
        var single: [UUID] = []
        for l in env.single ?? [] {
            if let f = sources.fragments[l.value], !used.contains(f.id), !covered.contains(f.id), !single.contains(f.id) {
                single.append(f.id)
            }
        }
        return Parsed(items: items, dropped: dropReasons.count, covered: covered, single: single,
                      coveredPage: env.coveredPage.map(CatalogPrompts.normalizedPath).flatMap { $0.isEmpty ? nil : $0 }, dropReasons: dropReasons,
                      reason: env.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty, checks: findings.map(\.text),
                      unapplied: unapplied.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element.item),
                      coverage: diagnostics.coverage, preservation: diagnostics.preservation)
    }

    /// 分组方向：写手在分组里新开的每一页，记录或 covered 认领的本组不同碎片不到 threshold 条就不收（碎片留在池里），
    /// 连到这些页的线一起不收；原文 / A 线出处照常算出处，只是不算认领。返回说明
    static func dropThinNewPages(_ items: inout [WikiProposal.Item], among group: Set<UUID>, threshold: Int) -> [String] {
        let thin = items.compactMap { item -> (path: String, count: Int)? in
            guard case .newPage(let page) = item.change else { return nil }
            let claimed = Set(item.fragmentIds + (item.covered ?? [])).intersection(group).count
            return claimed < threshold ? (page.path, claimed) : nil
        }
        guard !thin.isEmpty else { return [] }
        let paths = Set(thin.map(\.path))
        items.removeAll { item in
            if let target = item.change.targetPath, paths.contains(target) { return true }
            if case .link(_, let l) = item.change { return paths.contains(l.target) }
            return false
        }
        for i in items.indices {
            guard case .newPage(var page) = items[i].change else { continue }
            page.links.removeAll { paths.contains($0.target) }
            items[i].change = .newPage(page: page)
        }
        return thin.map { "新开页「\($0.path)」只认领了本组 \($0.count) 条碎片，不到 \(threshold) 条，没交，碎片留在池里" }
    }

    /// covered 的碎片挂在写这一页的第一条上（批了一起标「已整理进」，驳回不连带）；这页这次一条都没写、页在且看过版本，
    /// 就单出一条「确认已覆盖」等她批（不改页）。返回哪都挂不上的（页不在），不打标
    static func attachCovered(_ items: inout [WikiProposal.Item], covered: [UUID], path: String, version: String?) -> [UUID] {
        guard !covered.isEmpty else { return [] }
        if let i = items.firstIndex(where: { $0.change.targetPath == path }) {
            items[i].covered = (items[i].covered ?? []) + covered.filter { !(items[i].covered ?? []).contains($0) }
            return []
        }
        guard let version, WikiStore.isValidPagePath(path) else { return covered }
        items.append(WikiProposal.Item(change: .confirmCovered(path: path), baseVersion: version, covered: covered))
        return []
    }

    /// 方向里定好的钩子是硬输入：这页新开就用它；已有页钩子不一样，就改到它（模型交了改钩子就覆盖成它，没交就补一条，照样等批）
    static func applyHook(_ items: inout [WikiProposal.Item], hook: String, path: String, page: WikiPage?, version: String?) {
        let hook = hook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hook.isEmpty else { return }
        for i in items.indices where items[i].change.targetPath == path {
            switch items[i].change {
            case .newPage(var p):
                p.hook = hook
                items[i].change = .newPage(page: p)
                return
            case .retag(_, let oldHook, _, let oldTriggers, let newTriggers):
                items[i].change = .retag(path: path, oldHook: oldHook, newHook: hook, oldTriggers: oldTriggers, newTriggers: newTriggers)
                return
            default:
                continue
            }
        }
        guard let page, let version, page.hook != hook else { return }
        items.append(WikiProposal.Item(change: .retag(path: path, oldHook: page.hook, newHook: hook, oldTriggers: page.triggers,
                                                      newTriggers: page.triggers), baseVersion: version))
    }
}

// MARK: - 写作者的代码检查：硬查判得准的三项（「现在」列表行、记录超 30 字、关系不在四种）；改旧记录由条目类型本身挡住。
// 不过和格式诊断共用一次修订，还不过照样交批并标出；判不准的三样只记日志

enum CatalogChecks {
    static let recordLimit = 30
    /// 列表标记：标记后面跟空格才算（「-5 度」这种负号不算）
    private static let listMark = "^[-·●▪][ \\t\u{3000}]"
    /// 严格的日子：YYYY-MM-DD / YYYY-MM，后面不能再接数字或连字符
    private static let date = "\\d{4}-\\d{2}(?:-\\d{2})?(?![0-9-])"

    struct Finding: Equatable {
        var location: String
        var message: String
        var text: String { "\(location)：\(message)" }
    }

    /// 「现在」里的列表行（- · ● ▪ 后面跟空格）
    static func listLines(_ now: String) -> [String] {
        now.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: listMark, options: .regularExpression) != nil }
    }

    /// 记录行去掉代码接的「（出处：…）」和开头的日期（或「日期未注明」）
    static func recordText(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("）"), let r = t.range(of: "（出处：", options: .backwards) { t = String(t[..<r.lowerBound]) }
        return t.replacingOccurrences(of: "^(?:\(date)|日期未注明)\\s*", with: "", options: .regularExpression)
    }

    /// 记录正文算字数的部分：再去掉确定是时间锚的括号（「（到 日子）」「（自 日子 起）」「（日子）」）和碎片编号括号；
    /// 别的带数字的括号（工号、次数）算正文。不算空白
    static func recordBody(_ line: String) -> String {
        recordText(line)
            .replacingOccurrences(of: "[（(]\\s*(?:到\\s*\(date)|自\\s*\(date)\\s*起|\(date))\\s*[）)]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[（(]\\s*f\\d+(?:\\s*[、,，]\\s*f\\d+)*\\s*[）)]", with: "", options: .regularExpression)
            .filter { !$0.isWhitespace }
    }

    static func now(_ text: String, at location: String) -> [Finding] {
        listLines(text).map { Finding(location: location, message: "「现在」里有列表行「\($0)」：「现在」要写连贯段落，不用 - · ● ▪ 开头的列表") }
    }

    static func record(_ line: String, at location: String) -> [Finding] {
        let count = recordBody(line).count
        guard count > recordLimit else { return [] }
        return [Finding(location: location, message: "记录「\(recordText(line))」正文 \(count) 字，超过 \(recordLimit) 字（不算日期和出处）：压成一件事的动词短语")]
    }

    /// 关系不在四种之内：说明；在四种之内 = nil
    static func relation(_ relation: String, to: String) -> String? {
        guard WikiPage.Relation(rawValue: relation.trimmingCharacters(in: .whitespaces)) == nil else { return nil }
        let all = WikiPage.Relation.allCases.map(\.rawValue).joined(separator: " / ")
        return "连到「\(to)」的关系「\(relation)」不在 \(all) 之内，这条线没收进页"
    }

    /// 修订状态（三条路共用）：每一页最多修订一次；修订之后只要不是被取消，用不了就交上一份可审的稿
    static func revised(_ got: CatalogItems.Parsed) -> String { got.revisionNotes.isEmpty ? "重写一次后通过" : "重写一次后仍有没过的" }
    static func fellBack(_ why: String) -> String { "重写\(why)，交的是第一稿" }
    static let noChance = "最后一轮交的，没有机会重写"

    /// 给模型的那一次重写：上次交的原样附上，逐条说哪项、在哪儿
    static func rewriteNote(_ checks: [String], previous: String?) -> String {
        var out = "\n\n（系统：你上一次交的有这几处没过检查。只改这几处，别的照旧，整份重交：\n" + checks.map { "- " + $0 }.joined(separator: "\n") + "）"
        if let previous { out += "\n上一次交的原文：\n" + previous }
        return out
    }

    /// 判不准的三样，只记日志：钩子有没有「当……时」的场景、「现在」每句有没有时间锚、记录是不是拿人名 / 代词开头（不是动词开头）
    static func soft(_ items: [WikiProposal.Item], names: MemoryExtractor.Names) -> [String] {
        var out: [String] = []
        let anchors = ["自", "到", "详见人设", "未注明", "基于"]
        let subjects = [names.user, names.char, "她", "他", "我", "用户", "助手", "AI"].filter { !$0.isEmpty }
        func hook(_ path: String, _ text: String) {
            guard !text.isEmpty, !(text.contains("当") && text.contains("时")) else { return }
            out.append("\(path) · 钩子没写「当……时」的场景：\(text)")
        }
        func now(_ path: String, _ text: String) {
            let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for s in sentences where !anchors.contains(where: s.contains) && s.range(of: date, options: .regularExpression) == nil {
                out.append("\(path) · 「现在」这句没有时间锚：\(s)")
            }
        }
        func records(_ path: String, _ lines: [String]) {
            for line in lines {
                let t = recordText(line)
                if let who = subjects.first(where: t.hasPrefix) { out.append("\(path) · 记录可能不是动词开头（以「\(who)」开头）：\(t)") }
            }
        }
        for item in items {
            switch item.change {
            case .newPage(let page):
                hook(page.path, page.hook)
                now(page.path, page.now)
                records(page.path, page.records)
            case .appendRecords(let path, let lines): records(path, lines)
            case .rewriteNow(let path, _, let new, _): now(path, new)
            case .retag(let path, let oldHook, let newHook, _, _) where oldHook != newHook: hook(path, newHook)
            default: break
            }
        }
        return out
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 提示词：写作者的页面规则 + 条目格式（日常写手、手动 agent、种子正文共用一套；种子只多一条例外）

extension CatalogPrompts {
    /// 新稿第 3 部分（写线不写点）。seed = 种子正文：人设里写过的也完整写，不写「详见人设」，出处写 sources
    static func pageRules(names: MemoryExtractor.Names, seed: Bool = false) -> String {
        let u = names.user, c = names.char
        let cite = seed ? "sources（read 读过的原料路径）" : "fragments（碎片编号）/ aline（A 线层、窗口、段，或原文节点）"
        let anchor = seed ? "「（自 2026-09 起）」「（到 2026-12-01）」" : "「（自 2026-09 起）」「（到 2026-12-01）」或「（详见人设）」"
        let base = seed
            ? """
            3. 种子例外：楼层 Prompt（人设）里写过的事实也完整写进页，不写「详见人设」，不要因为人设里有就跳过、只留空架子。
            """
            : """
            3. 只写增量：人设（楼层提示词）里已有的写「详见人设」，不重抄。动笔前先扫一遍人设里和这页有关的事实：
               碎片说的和人设一样 → 这句写「对花生过敏（详见人设）」；
               碎片有更新 / 补充 → 写增量，带时间锚：「减糖中（自 2026-10 起）」；
               碎片和人设矛盾（人设写近视 500 度，碎片说做了手术）→ 两条都留、各带日期，「现在」按新的写；人设不是 wiki 页，不连线。
            """
        return """
        ## 核心：写线不写点
        碎片是点，wiki 页是线。不是把碎片搬进页面，是从碎片里理出关系，写成段落。三步：
        1. 分组：因果的放一组（对花生过敏 + 随身带肾上腺素笔）；同一件事的放一组（报了 N2 + 12 月考 + 交了报名费）；同类属性的放一组（不吃香菜 + 喜欢面包 + 在减糖）。
        2. 每组写成一句：有因果用因果连「对花生过敏，随身带肾上腺素笔」；有时间用时间锚「减糖中（自 2026-10 起）」；同类用逗号并列「喜欢面包，不吃香菜」。
        3. 组和组之间用句号断开，不用「另外 / 此外 / 同时」去连。
        ✗ 点：\(u)对花生过敏。\(u)喜欢吃面包。\(u)不吃香菜。\(u)最近在减糖。\(u)随身带肾上腺素笔。
        ✓ 线：对花生过敏，随身带肾上腺素笔。减糖中（自 2026-10 起）。喜欢面包，不吃香菜。

        ## 一页 = 标题 + 钩子 + 触发词 + 现在 + 记录 + 连到
        页上不写「用户 / AI / 助手 / 她 / 他」，写名字：\(u)、\(c)。\(c)的观察写「\(c)认为……」，不写成\(u)的客观属性；归因不明的不猜是谁说的；没兑现的承诺照写成承诺，不写成已经做到。正文里引用别人的话用「」，不用半角双引号。

        ### 钩子
        写成「当……时先看这页」：写场景，不写空话；可以放具体的触发词、原话，它们就是搜索命中的入口。
        ✗ \(u)的身体信息
        ✓ 当\(u)说过敏、吃药、身体不舒服、眼睛疼时先看这页
        ✓ 当\(u)说「来不及了」「不想做」「又拖了」时先看这页
        触发词：标题 + 别名（平时怎么叫它）。

        ### 现在
        1. 连贯段落，不是列表：不用 - · ● ▪ 开头的行。
        2. 每句带时间锚：\(anchor)。精确到月或日，看原料给到哪；「下周三」这类相对日期按原料的日期换成具体日子；原料没给日子就写「（时间未注明）」，不编。
        \(base)
        4. 只在确有变化时改「现在」；已经写过的事实不再写。
        5. 「现在」里写了「（到 YYYY-MM-DD）」这种到期日，就在这条 new_page / rewrite_now 上另填 valid_until = 那一天（见条目格式）。
        不同的页重心不同（这是写法建议，按内容自己判断是哪种页）：
        - 普通页（\(u)的身体、偏好，一个人、一只猫……）：按属性分组，每组一句。
          ✗ 饼干是橘猫。饼干 2 岁。饼干是公猫。饼干已绝育。饼干贪吃。饼干 6kg。
          ✓ 橘猫，公，2 岁，已绝育（自 2026-09 起）。贪吃，会自己开橱柜门偷零食（自 2026-09 起）。体重 6kg，兽医要求控制（自 2026-09 检查起）。
        - 行为模式页（楼层/\(u)/行为模式/…）：不记事件，画路径「遇到 X 时会怎么走」——触发条件；路径 阶段 → 阶段 → 阶段；典型时长；接住方式（\(c)该怎么应对）；（基于 YYYY-MM/MM 共 N 次观察）。
          ✗ 9 月拖了毕设。10 月也拖了作品集。每次都拖延。
          ✓ 遇到大截止日时触发。恐慌（「来不及了」）→ 逃避（刷手机、打扫房间）→ 内疚（「我怎么又这样」）→ 深夜赶工。通常拖 2–3 天，截止前一晚通宵完成。接住方式：不催，陪着，帮\(u)把任务拆成 15 分钟小块。（基于 2026-09/10 两次观察）
        - 事页（楼层/事/…）：按时间线写，同一阶段的合成一句，不逐天记流水账；经过引用出处，不重抄。
          ✓ 9 月初被裁，哭了一天后和小方通话决定转产品方向（自 2026-09-03 起）。9 月中开始投简历，面了三家（自 2026-09-10 起）。
        - 项目页：当前状态 + 关键节点。
          ✓ 交互装置方向，12 月截止（到 2026-12-15）。10 月中完成原型，正在调传感器（自 2026-10-15 起）。导师要求加用户测试环节（自 2026-10 起）。
        - 主题页：当前水平 + 方法 + 目标。
          ✓ 目标 N2，报了 12 月考试（到 2026-12-01）。听力是瓶颈，每天背 20 个单词（自 2026-09 起）。跟田中老师每周三上课（自 2026-09 起）。

        ### 记录
        一行一件事，text 写「YYYY-MM-DD 动词短语」：
        1. 正文不超过 30 字（不算日期和出处）。碎片可能 50 字，记录压到 30 字以内，不是碎片的翻译。
        2. 动词开头，不写主语。
        3. 出处不写进 text，写在 \(cite) 里，代码接在行尾；没有出处的行会被扔掉。
        4. 只追加：已有的记录行原封不动。
        5. 原料没写日期就写「日期未注明」，不拿文件时间、今天的日期当事实日期。
        ✗ 2026-10-15 和朋友一起去了公司附近新开的面包店买了很多面包说特别好吃想下次再去
        ✓ 2026-10-15 发现公司附近新面包店，想再去
        ✗ 2026-10-12 饼干半夜踩键盘删了三页毕设
        ✓ 2026-10-12 半夜踩键盘删三页毕设

        ### 连到
        relation 只有四种：补充 / 矛盾 / 共鸣 / 引用，没有「替代」。同一件事的不同面 → 补充；信息冲突 → 矛盾；印证、呼应另一页的观点 → 共鸣；直接提到另一页的内容 → 引用；都不是就不连，不为连而连。why 写一句为什么。
        ✓ 楼层/\(u)/行为模式/拖延曲线 → 楼层/项目/毕设 · 补充 · 毕设是拖延的主要触发源
        ✗ → 楼层/\(u)/概要 · 补充 · \(u)就是\(u)（没信息量，不连）

        ### 新旧不一样
        同一个属性的不同值 = 冲突（住三楼 → 住五楼）；不同属性 = 共存（喜欢猫，也喜欢狗）。
        - 共存：两条都记，不连矛盾线，judgment 写 coexist；
        - 冲突：记录两条都留、各带日期；「现在」按新的写；judgment 写 conflict。另一方在别的页上，才连一条「矛盾」到那一页；另一方是人设，或者就在这一页上（旧说法、旧记录），不连线，也不连回自己这一页。

        ### 更新已有页
        不整页重写，只做该做的：补充的新信息只是一件事 → append 追加记录；补充的新信息改变了现在的样子（比如开始减糖）→ 同时交 rewrite_now（改完的整段「现在」）和 append（这件事的记录），旧记录照旧不动；已有信息变了 → rewrite_now 重写整段「现在」；和另一页有关 → link；触发词变了 → retag。

        ### 各类页整页正反例
        楼层/\(u)/身体
        ✗ {"now": "\(u)对花生过敏。\\n\(u)随身带肾上腺素笔。\\n\(u)在减糖。\\n\(u)近视约 500 度。\\n\(u)喜欢面包。\\n\(u)不吃香菜。\\n\(u)最近睡眠不好。"}
        ✓ {"now": "对花生过敏，随身带肾上腺素笔\(seed ? "" : "（详见人设）")。减糖中（自 2026-10 起）。近视约 500 度，长时间看屏幕眼睛疼。喜欢面包，不吃香菜。最近连续 2 点才睡（自 2026-10 中旬起）。"}
        楼层/\(u)/行为模式/拖延曲线
        ✗ {"now": "\(u) 9 月拖了毕设。\(u) 10 月也拖了作品集。\(u)每次都拖延。"}
        ✓ {"now": "遇到大截止日时触发。恐慌（「来不及了」）→ 逃避（刷手机/打扫房间/逛淘宝）→ 内疚（「我怎么又这样」）→ 深夜赶工。通常拖 2-3 天，截止前一晚通宵完成。接住方式：不催，陪\(u)待着，帮\(u)把任务拆成 15 分钟小块。（基于 2026-09/10 两次观察）"}
        楼层/人/饼干
        ✗ {"now": "饼干是橘猫。\\n饼干 2 岁。\\n饼干是公猫。\\n饼干已绝育。\\n饼干贪吃。\\n饼干会开橱柜门。\\n饼干体重 6kg。"}
        ✓ {"now": "橘猫，公，2 岁，已绝育。贪吃，会自己开橱柜门偷零食。体重 6kg，兽医要求控制（自 2026-09 检查起）。是\(u)独居最重要的陪伴。"}
        楼层/项目/毕设
        ✗ {"now": "\(u)在做毕设。毕设是交互装置。12 月要交。导师让加用户测试。10 月做完了原型。"}
        ✓ {"now": "交互装置方向，12 月截止。10 月中完成原型，正在调传感器（自 2026-10-15 起）。导师要求加用户测试环节。"}
        楼层/事/2026-09 被裁
        ✗ {"now": "9月1号被通知裁员。9月2号哭了一天。9月3号跟小方打电话。9月5号投简历。9月10号面试。"}
        ✓ {"now": "9 月初被裁，哭了一天后跟小方通话决定转产品方向（自 2026-09-03 起）。9 月中开始投简历，面了三家（自 2026-09-10 起）。目前等两家回复。"}
        楼层/主题/日语学习
        ✗ {"now": "\(u)在学日语。目标是 N2。听力最难。每天背 20 个单词。报了 12 月考试。跟田中老师上课。"}
        ✓ {"now": "目标 N2，报了 12 月考试（到 2026-12-01）。听力是瓶颈，每天背 20 个单词。跟田中老师每周三上课（自 2026-09 起）。"}

        ### 交之前对一遍
        「现在」是连贯段落、没有列表行？每句有时间锚？\(seed ? "" : "没重抄人设？")不是碎片的逐条翻译？记录每行不超过 30 字、动词开头、有出处？钩子是「当……时」？行为模式页写的是路径？关系是四种之一？没写「用户 / AI / 助手 / 她 / 他」？旧记录没动？

        \(pathRules(names: names))
        """
    }

    static func itemFormat(names: MemoryExtractor.Names) -> String {
        let u = names.user, c = names.char
        return """
        条目只有这几种：
        - 新开一页：{"type":"new_page","path":"楼层/\(u)/身体","kind":"用户","title":"身体","triggers":["过敏","吃药","眼睛疼"],"hook":"当\(u)说过敏、吃药、身体不舒服、眼睛疼时先看这页","now":"对花生过敏，随身带肾上腺素笔（详见人设）。减糖中（自 2026-10 起）。喜欢面包，不吃香菜。","records":[记录…],"links":[{"to":"楼层/地点/新面包店","relation":"补充","why":"常去买面包"}]}
        - 往已有页追加记录：{"type":"append","path":"…","records":[记录…],"judgment":"coexist"}
        - 改已有页的「现在」：{"type":"rewrite_now","path":"…","now":"改完的整段「现在」","judgment":"conflict"}
        - 已有页连线：{"type":"link","path":"从哪页","to":"连到哪页","relation":"矛盾","why":"一句为什么","judgment":"conflict"}
        - 改已有页的钩子 / 触发词：{"type":"retag","path":"…","hook":"…","triggers":["…"]}
        记录 = {"text":"2026-10-15 发现公司附近新面包店，想再去","fragments":["f3"],"aline":[{"layer":"A2","window":"1a2b3c4d","segment":3}]}：fragments 写碎片编号；aline 写检索出处——A 线的 layer 为 A2 / A3 / A4，window = conv 后面那 8 位，A2 必须写已提供的段号；A4 一天一条（没有 conv 的那种）写 {"layer":"A4","day":"那天的日期"}；原文写 {"layer":"原文","nodeId":"实际提供的节点 id"}，window 可不写，若写必须与该节点窗口一致。两样至少一样。只能引用本次实际提供的出处，不得把 A4 当成 A2。原文里\(c)说的话是\(c)的发言，不是\(u)的事实：写进页要归给\(c)（「\(c)认为」「\(c)说」），不改写成\(u)自述。
        valid_until（只写在 new_page / rewrite_now 上，可不写）："valid_until":"2026-12-01"。「现在」里写了「（到 YYYY-MM-DD）」才填，填那个日子，有好几个填最早的；日子只能来自原料里明确的日期，「现在」里没写到期日就不写。
        judgment 只写在 append / rewrite_now / link 上：新旧冲突写 conflict，共存写 coexist，没有新旧问题就不写。
        covered（和 items 同一层，可不写）：分到这个主题的碎片里，页上已经写过、不用再写的，编号写进 covered，比如 "covered":["f2"]；没用上、页上也没有的别写进去，它们留着下次再整理。covered_page（可不写；整理分组时必须写）：这些碎片写在哪一页上，必须是给过全文 / 读过的页。
        single（和 items 同一层，可不写）：分到这个主题的碎片里，同时满足三条的小事不用进页，编号写进 single：几乎不变（会变的状态，比如最近在减糖，不算）；自己就完整；不属于任何已有页的话题范围。已有页优先：索引里有讲\(u)身体的页，「血型是 O 型」就归那一页（append 或 covered），不算 single；索引里没有任何相关的页，才算 single。它们留在碎片池里照样能被找到。
        """
    }
}

// MARK: - 第二步 · 逐个主题写（每个主题一次调用；plan 4.1）

enum CatalogWriterError: LocalizedError, Equatable {
    case pagesDontFit(String)
    case promptDoesntFit(String)
    case retryDoesntFit(String)

    var errorDescription: String? {
        switch self {
        case .pagesDontFit(let detail): return "这几页的全文放不进当前模型，没写（不裁剪、不分批）：\(detail)"
        case .promptDoesntFit(let detail): return "写作规则放不进当前模型，没写（不裁剪、不换模型）：\(detail)"
        case .retryDoesntFit(let detail): return "重来那次的请求放不进当前模型，没发（不裁剪）：\(detail)"
        }
    }

    /// 系统提示只收得下前 kept 字：从哪一节断开、后面整节没送到的各多长
    static func shortfall(_ system: String, kept: Int) -> String {
        var offset = 0, cutIn = "开头"
        var lost: [(name: String, count: Int)] = []
        for line in system.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                if offset >= kept { lost.append((name, 0)) } else { cutIn = name }
            }
            if offset >= kept, !lost.isEmpty { lost[lost.count - 1].count += line.count + 1 }
            offset += line.count + 1
        }
        let tail = lost.isEmpty ? "" : "，后面整节没送到的：" + lost.map { "「\($0.name)」\($0.count) 字" }.joined(separator: "、")
        return "系统提示共 \(system.count) 字，当前模型只收得下前 \(kept) 字，缺 \(system.count - kept) 字：从「\(cutIn)」中间断开\(tail)"
    }
}

/// 本机模型的真实请求：和 `FragmentModelRoute` 本机路线同一个裁法
enum CatalogLocalTrim {
    static func apply(_ system: String, _ user: String) -> (system: String, user: String) {
        let t = LocalChatProvider.trimmed(system: system, messages: [(role: "user", content: user)], hasImages: false)
        return (t.system, t.history.map(\.content).joined())
    }
}

enum CatalogWriter {
    /// 这个主题动笔前备好的料
    struct Material: Sendable {
        var topic: CatalogSorter.Topic
        var floorPrompt: String
        var indexLines: [String]
        var pageRaw: String?
        /// 读页那一刻全部页的版本（这一页的出自 pageRaw 同一次读）；分组方向只有给过全文的那几页
        var versions: [String: String] = [:]
        /// 分组方向：分组下现有的页（和同名页）全文，与 versions 同一次读
        var groupPages: [(path: String, text: String)] = []
        var search: CatalogRetrieval.Result
        /// 原快照；编号不因检索排序、分配主题而改变。
        var fragments: [CatalogFragment]
        var assignedIds: Set<UUID>? = nil

        var assigned: [CatalogFragment] { fragments.filter { assignedIds?.contains($0.id) ?? true } }

        var labels: [UUID: String] {
            var out: [UUID: String] = [:]
            for (i, f) in fragments.enumerated() where out[f.id] == nil { out[f.id] = CatalogSorter.label(i) }
            return out
        }

        var sources: CatalogSources {
            var s = CatalogSources()
            let given = Set(assigned.map(\.id))
            var seen = Set<UUID>()
            for (i, f) in fragments.enumerated() where given.contains(f.id) && seen.insert(f.id).inserted {
                s.fragments[CatalogSorter.label(i)] = f
            }
            search.receipt.register(in: &s)
            s.versions = versions
            return s
        }
    }

    /// 相关索引：根两支下的分组行 + 这一页所在那层（方向指的是分组本身时，再加这一层）
    static func relatedIndex(_ wiki: WikiStore, path: String) -> [String] {
        var out: [String] = []
        for branch in WikiStore.branches { out += wiki.layerLines(branch).filter { $0.contains("/]]") } }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        if !parent.isEmpty, wiki.folderExists(parent) { out += wiki.layerLines(parent).filter { !out.contains($0) } }
        if wiki.folderExists(path) { out += wiki.layerLines(path).filter { !out.contains($0) } }
        return out
    }

    /// 备料走手动工具同一检索适配，文件读取与分词均在后台。
    static func material(_ topic: CatalogSorter.Topic, fragments: [CatalogFragment], floorPrompt: String,
                         wiki: WikiStore, memoryRoot: URL, now: Date, snapshot: [CatalogFragment]? = nil,
                         conversationIds: Set<String>? = nil,
                         embedder: any MemoryEmbedding = AppleMemoryEmbedder.shared,
                         originalSearch: CatalogRetrieval.OriginalSearch? = nil,
                         cancel: CatalogCancel = CatalogCancel()) async -> Material {
        await cancel.withTaskCancellation {
        let range = DateInterval(start: min(CatalogMaterial.startDate, now), end: now)
        let pool = snapshot ?? fragments
        let assignedIds = Set(fragments.map(\.id))
        let search = await CatalogRetrieval(memoryRoot: memoryRoot, fragments: pool, conversationIds: conversationIds,
                                            embedder: embedder, originalSearch: originalSearch).search(topic.terms, in: range, excludingFragmentIds: assignedIds, cancel: cancel)
        return await Task.detached(priority: .utility) {
            guard !cancel.isCancelled else {
                return Material(topic: topic, floorPrompt: floorPrompt, indexLines: [], pageRaw: nil, search: search, fragments: [], assignedIds: [])
            }
            if topic.group {
                var given: [(path: String, text: String)] = []
                var versions: [String: String] = [:]
                for path in [topic.path] + wiki.pagePaths(under: topic.path) {
                    guard let read = wiki.readVersioned(path) else { continue }
                    given.append((path, read.text))
                    versions[path] = read.version
                }
                guard !cancel.isCancelled else {
                    return Material(topic: topic, floorPrompt: floorPrompt, indexLines: [], pageRaw: nil, search: search, fragments: [], assignedIds: [])
                }
                return Material(topic: topic, floorPrompt: floorPrompt, indexLines: relatedIndex(wiki, path: topic.path), pageRaw: nil,
                                versions: versions, groupPages: given, search: search, fragments: pool, assignedIds: assignedIds)
            }
            let page = topic.existing ? wiki.readVersioned(topic.path) : nil
            guard !cancel.isCancelled else {
                return Material(topic: topic, floorPrompt: floorPrompt, indexLines: [], pageRaw: nil, search: search, fragments: [], assignedIds: [])
            }
            var versions = wiki.versionSnapshot()
            versions[topic.path] = page?.version
            return Material(topic: topic, floorPrompt: floorPrompt, indexLines: relatedIndex(wiki, path: topic.path),
                            pageRaw: page?.text, versions: versions, search: search, fragments: pool, assignedIds: assignedIds)
        }.value
        }
    }

    static func systemPrompt(names: MemoryExtractor.Names) -> String {
        """
        这不是在跟你聊天。你在写\(names.user)和\(names.char)的记忆 wiki：读下面给的原料，把这个主题写成 / 补进 wiki 页，交一批条目给\(names.user)过目。
        输入：楼层提示词（\(names.user)亲手写的人设，权威底图）；相关 wiki 索引；这一页已有的全文（如果有）；搜回来的 A 线 / 原文；分到这个主题的碎片（f 编号 · 日期 · 类 · 归因 · 内容）。

        只输出 JSON，不要别的字：先输出正文对象 {"items":[…],"covered":[…],"single":[…]}；没有要写的就交 {"items":[]}，并用 reason 说明为什么。
        \(CatalogPrompts.itemFormat(names: names))
        \(CatalogPrompts.diagnostics(names: names, standalone: true))

        \(CatalogPrompts.pageRules(names: names))
        """
    }

    static func userContent(_ m: Material, names: MemoryExtractor.Names) -> String {
        var out: [String] = []
        let labels = m.labels
        out.append("【楼层提示词】（\(names.user)亲手写的人设，权威底图：已有的写「详见人设」，不重抄）\n" + (m.floorPrompt.isEmpty ? "（没写）" : m.floorPrompt))
        out.append("【相关索引】\n" + (m.indexLines.isEmpty ? "（wiki 还是空的）" : m.indexLines.joined(separator: "\n")))
        if let raw = m.pageRaw {
            out.append("【已有页全文】\(m.topic.path)\n\(raw)")
        } else if m.topic.group {
            out.append("【整理分组】\(m.topic.title) · \(m.topic.path)：分到这里的碎片没对上现有页。归进下面给了全文的页（只有这几页能追加 / 改现在 / 连线 / 改钩子），或者在 \(m.topic.path)/ 下开新页（页名按说的方面起，一页至少认领 3 条这里的碎片），不建「\(m.topic.path)」这一页本身。写 covered 时要写 covered_page = 页上已经写过它的那一页（必须是下面给了全文的页）")
            out += m.groupPages.map { "【已有页全文】\($0.path)\n\($0.text)" }
        } else {
            let kind = m.topic.kind.map { "类：\($0.rawValue) · " } ?? ""
            let aliases = m.topic.aliases.isEmpty ? "" : " · 别名：\(m.topic.aliases.joined(separator: "、"))"
            out.append("【新主题】\(kind)标题：\(m.topic.title) · 建议路径：\(m.topic.path)\(aliases)")
        }
        if !m.topic.hook.isEmpty {
            out.append("【定好的钩子】\(m.topic.hook)（新开页、改钩子都用这一句）")
        }
        if !m.topic.reason.isEmpty {
            out.append("【为什么提这个方向】（自动发现时的线索，待核实：不是事实，也不是出处；页上只写下面原料支持的内容）\n\(m.topic.reason)")
        }
        out.append("【搜回来的原料】\n" + m.search.receipt.text)
        out.append("【分到这个主题的碎片】\n" + m.assigned.map { f in
            "- \(labels[f.id] ?? "") · \(f.day) · \(f.category) · \(f.attributionText) · \(f.content)"
        }.joined(separator: "\n"))
        return out.joined(separator: "\n\n")
    }

    /// 写一个主题：原始输出先落盘；格式不对同一次里重来，最多 2 次；还不对抛 `.format`。nil = 预算闸 / 空输出。
    /// 硬查 / 格式诊断没过给一次重写：重写还没过就交它；重写放不下、出错、没回或交坏了就交第一稿（都记下修订走到哪一步）
    /// 只有明确引用的和 covered 的碎片会挂进条目；分到却没用上的留在池里
    /// trim = 真实请求会怎么裁（本机模型）：系统提示送不全、给了全文的已有页会被裁掉就不写，明说放不进；之后每次请求都重查
    static func write(_ m: Material, names: MemoryExtractor.Names, wiki: WikiStore, caller: SessionSegmentWriter.Caller,
                      drafts: CatalogDrafts?, cancel: CatalogCancel? = nil, run: CatalogRunRecord? = nil,
                      trim: ((String, String) -> (system: String, user: String))? = nil) async throws -> CatalogItems.Parsed? {
        try cancel?.check()
        let sources = m.sources
        let system = systemPrompt(names: names)
        let user = userContent(m, names: names)
        let pages = m.pageRaw.map { [(m.topic.path, $0)] } ?? m.groupPages.map { ($0.path, $0.text) }
        /// 本机路线第一次请求实际送到的用户文本；之后每次请求都不能挤掉它
        var firstSent: String?
        /// 本机路线：这一次真正要发的请求放不放得下；nil = 放得下
        func overflow(_ requestUser: String) -> String? {
            guard let trim else { return nil }
            let sent = trim(system, requestUser)
            let lost = pages.filter { !sent.user.contains($0.1) && !sent.system.contains($0.1) }
            if !lost.isEmpty {
                return lost.map { "\($0.0)（全文 \($0.1.count) 字）" }.joined(separator: "、")
                    + "；整份请求 \(system.count + requestUser.count) 字，当前模型一次只收得下 \(sent.system.count + sent.user.count) 字"
            }
            if let firstSent, !sent.user.contains(firstSent) {
                return "第一次送到的 \(firstSent.count) 字原料这次会被挤掉；这次请求 \(system.count + requestUser.count) 字，当前模型一次只收得下 \(sent.system.count + sent.user.count) 字"
            }
            return nil
        }
        if let trim {
            let sent = trim(system, user)
            if sent.system != system {
                let kept = zip(sent.system, system).prefix { $0 == $1 }.count
                throw CatalogWriterError.promptDoesntFit(CatalogWriterError.shortfall(system, kept: kept))
            }
            if let why = overflow(user) { throw CatalogWriterError.pagesDontFit(why) }
            firstSent = sent.user
        }
        if let run {
            var evidence = m.search.receipt.evidence()
            evidence.assigned = m.assigned.map(\.content)
            run.recordSearch(evidence)
            let mapping = m.fragments.enumerated().map { "\(CatalogSorter.label($0.offset)) → \($0.element.id.uuidString)" }.joined(separator: "\n")
            run.section("写手 · \(m.topic.title) · 备料", body: "主题路径：\n\(CatalogRunRecord.code(m.topic.path))\n\n主题搜索词（terms，原顺序）：\n\(recordJSON(m.search.aline.terms))\n\n碎片编号与 UUID：\n\(mapping)\n\n读页版本：\n\(recordJSON(m.versions))\n\n实际写手输入：\n\(CatalogRunRecord.code(user))\n\n限量前的入选 A 线全文（仅留档，不另送模型）：\n\(CatalogRunRecord.code(m.search.aline.render()))")
        }
        do {
            var parsed: CatalogItems.Parsed?
            var parseError = ""
            var formatFailures = 0
            /// 没过检查的第一稿：修订只给一次；修订用不了就交它
            var flagged: (parsed: CatalogItems.Parsed, raw: String)?
            var attempt = 0
            func fallBack(_ why: String, _ round: String) -> CatalogItems.Parsed? {
                guard var first = flagged?.parsed else { return nil }
                first.revision = CatalogChecks.fellBack(why)
                run?.section("\(round) · 重写用不了", body: first.revision ?? "")
                return first
            }
            while parsed == nil {
                try cancel?.check()
                attempt += 1
                let round = "写手 · \(m.topic.title) · 第 \(attempt) 次"
                let requestUser: String
                if let f = flagged {
                    requestUser = user + CatalogChecks.rewriteNote(f.parsed.revisionNotes, previous: f.raw)
                    if let why = overflow(requestUser) {
                        parsed = fallBack("那次放不进当前模型（\(why)），没发", round)
                        break
                    }
                } else if formatFailures > 0 {
                    requestUser = user + CatalogJSON.retryNote + "\n" + parseError
                    if let why = overflow(requestUser) { throw CatalogWriterError.retryDoesntFit(why) }
                } else {
                    requestUser = user
                }
                let reply: String?
                do {
                    reply = try await CatalogJSON.request(system: system, user: requestUser, caller: caller, run: run, name: round)
                } catch {
                    guard flagged != nil, !(error is CancellationError), cancel?.isCancelled != true else { throw error }
                    parsed = fallBack("那次出错（\(error.localizedDescription)）", round)
                    break
                }
                try cancel?.check()
                guard let raw = reply else {
                    guard flagged != nil else { return nil }
                    parsed = fallBack("那次没回（预算闸或空输出）", round)
                    break
                }
                let saved = attempt
                let result = await Task.detached(priority: .utility) {
                    var failure = ""
                    let text = FragmentPool.strictObjectText(raw) ?? raw
                    let result = CatalogItems.parse(text, sources: sources, wiki: wiki) { failure = $0 }
                    drafts?.saveSubmit(argumentsJSON: raw, text: "未知/不适用（自动写手仅返回 String，无额外正文信息）",
                                       truncated: nil, parsed: result, topic: m.topic.title, round: saved)
                    if let run {
                        recordValidation(result, parseError: failure, title: "\(round) · 校验", run: run)
                    }
                    return (result, failure)
                }.value
                if var got = result.0 {
                    if flagged == nil, !got.revisionNotes.isEmpty {
                        flagged = (got, raw)
                        run?.section("\(round) · 没过检查，重写一次", body: "实际将追加到原始用户文本后的内容：\n"
                            + CatalogRunRecord.code(CatalogChecks.rewriteNote(got.revisionNotes, previous: raw)))
                        CacheDiagLog.shared.log("📚 整理编目: \(m.topic.title) 没过检查 \(got.revisionNotes.count) 处，重写一次")
                        continue
                    }
                    if flagged != nil {
                        guard got.deliverable else {
                            parsed = fallBack("那次交的没有能用的内容（\(got.dropReasons.joined(separator: "；"))）", round)
                            break
                        }
                        got.revision = CatalogChecks.revised(got)
                    }
                    parsed = got
                } else if flagged != nil {
                    parsed = fallBack("那次交的不是合格的 JSON（\(result.1)）", round)
                } else {
                    parseError = result.1
                    formatFailures += 1
                    if formatFailures < 3 {
                        run?.section("\(round) · 下一轮回灌", body: "实际将追加到原始用户文本后的内容：\n" + CatalogRunRecord.code(CatalogJSON.retryNote + "\n" + parseError))
                    }
                    CacheDiagLog.shared.log("📚 整理编目: \(m.topic.title) 不是合格的 JSON，" + (formatFailures < 3 ? "重来" : "不收"))
                    if formatFailures == 3 { throw MemoryWriterError.format("整理编目「\(m.topic.title)」3 次都不是合格的 JSON") }
                }
            }
            guard var out = parsed else { return nil }
            if let path = m.topic.group ? out.coveredPage.flatMap({ m.versions[$0] == nil ? nil : $0 }) : m.topic.path {
                out.covered = CatalogItems.attachCovered(&out.items, covered: out.covered, path: path, version: m.versions[path])
            }
            if let run {
                recordValidation(out, parseError: "", title: "写手 · \(m.topic.title) · 实际返回", run: run)
                recordChecks(out, names: names, title: "写手 · \(m.topic.title)", run: run)
            }
            return out
        } catch {
            run?.section("写手 · \(m.topic.title) · 中止", body: CatalogRunRecord.code(error is CancellationError ? "已取消。" : "错误：\(error.localizedDescription)"))
            throw error
        }
    }

    private static func recordJSON<T: Encodable>(_ value: T) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return CatalogRunRecord.code(String(decoding: try encoder.encode(value), as: UTF8.self), language: "json")
        } catch {
            return CatalogRunRecord.code("记录编码错误：\(error.localizedDescription)")
        }
    }

    /// 没过检查的（照样交批）、修订走到哪一步，和判不准、只记日志的三样
    static func recordChecks(_ parsed: CatalogItems.Parsed, names: MemoryExtractor.Names, title: String, run: CatalogRunRecord) {
        if !parsed.revisionNotes.isEmpty {
            run.section("\(title) · 没过检查（照样交批，标给她看）", body: parsed.revisionNotes.map { "- " + $0 }.joined(separator: "\n"))
        }
        if let revision = parsed.revision { run.section("\(title) · 修订", body: revision) }
        let soft = CatalogChecks.soft(parsed.items, names: names)
        if !soft.isEmpty {
            run.section("\(title) · 只记日志的检查", body: soft.map { "- " + $0 }.joined(separator: "\n"))
        }
    }

    private static func recordValidation(_ parsed: CatalogItems.Parsed?, parseError: String, title: String, run: CatalogRunRecord) {
        guard let parsed else {
            run.section(title, body: "校验失败：整包格式不合格，未获得可返回的 items。\n\n解析错误（parseError）：\n\(CatalogRunRecord.code(parseError))")
            return
        }
        run.section(title, body: "校验成功。\n\n条目（items）：\n\(recordJSON(parsed.items))\n\n已覆盖碎片（covered）：\n\(recordJSON(parsed.covered))\n\n单条就够（single）：\n\(recordJSON(parsed.single))\n\n丢弃数量（dropped）：\(parsed.dropped)\n\n丢弃原因（dropReasons）：\n\(recordJSON(parsed.dropReasons))\n\n原因（reason）：\n\(CatalogRunRecord.code(parsed.reason ?? "（无）"))\n\n解析错误（parseError）：\n\(CatalogRunRecord.code(parseError))")
    }
}

// MARK: - 分组调整（一层超过 30 行：每天自动那次每个超额层多一次小调用；plan 2.1。手动不做）

enum CatalogRegrouper {
    /// 一个新分组至少放几项
    static let minMembers = 2

    static func systemPrompt(names: MemoryExtractor.Names) -> String {
        """
        这不是在跟你聊天。\(names.user)和\(names.char)的记忆 wiki 里有一层超过 \(WikiStore.layerLimit) 行，太长了。把这一层下面列出来的页和子分组分进几个新的子分组：
        - 每个子分组起一个短名字（比如 模型船 / 航线 / 船展），名字里不要有斜杠；
        - 每个子分组写一句钩子：什么时候会用到这一组，例：\(names.user)提到模型船、试航的时候先看这组；
        - members 只能写下面列出来的路径，一项只放进一组；每组至少 \(minMembers) 项；分不进去的留在原地，不用写。
        只输出一个 JSON 对象，不要别的字：{"groups":[{"name":"航线","hook":"\(names.user)提到模型船、试航的时候先看这组","members":["楼层/事/灯塔航线试航","楼层/事/云桥航线试航"]}]}
        """
    }

    static func userContent(layer: String, lines: [String]) -> String {
        "【这一层】\(layer)（\(lines.count) 行）\n" + lines.joined(separator: "\n")
    }

    private struct Envelope: Decodable {
        let groups: [CatalogJSON.Lossy<Group>]
    }

    private struct Group: Decodable {
        let name: String
        let hook: String?
        let members: [String]
    }

    /// 待批提案里已经有分组调整的层（她还没看，不再提）
    static func pendingLayers(_ store: WikiProposalStore) -> Set<String> {
        var out = Set<String>()
        for p in store.list() {
            for item in p.items where item.state == .pending {
                if case .regroup(let layer, _, _) = item.change { out.insert(layer) }
            }
        }
        return out
    }

    /// nil = 整包不合格；[] = 没有能用的分组。校验：新分组名不带斜杠、这层里还没有同名的页 / 文件夹；
    /// 只挪这一层直接的子项、一项只挪一次；不够 2 项的组扔掉。读 wiki，后台调
    static func parse(_ raw: String, layer: String, wiki: WikiStore) -> [WikiProposal.Item]? {
        guard let text = FragmentPool.strictObjectText(raw), let env = CatalogJSON.decode(Envelope.self, text) else { return nil }
        let (folders, pages) = wiki.children(layer)
        let allowed = Set(folders + pages)
        var taken = Set<String>()
        var groups: [WikiProposal.NewGroup] = []
        var moves: [WikiProposal.Move] = []
        for g in env.groups.compactMap(\.value) {
            let name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = layer + "/" + name
            guard !name.isEmpty, !name.contains("/"), WikiStore.isValidFolderPath(path), !allowed.contains(path),
                  !wiki.pageExists(path), !wiki.folderExists(path), !groups.contains(where: { $0.path == path }) else { continue }
            let members = WikiStore.normalizedWords(g.members.map(CatalogPrompts.normalizedPath)).filter { allowed.contains($0) && !taken.contains($0) }
            guard members.count >= minMembers else { continue }
            taken.formUnion(members)
            groups.append(.init(path: path, hook: g.hook?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
            moves += members.map { .init(from: $0, to: path + "/" + String($0.split(separator: "/").last ?? "")) }
        }
        guard !moves.isEmpty else { return [] }
        return [WikiProposal.Item(change: .regroup(layer: layer, groups: groups, moves: moves), baseVersion: nil)]
    }

    /// 一层一次调用；格式不对重来一次。nil = 预算闸 / 空输出
    static func run(_ layer: String, wiki: WikiStore, names: MemoryExtractor.Names, caller: SessionSegmentWriter.Caller,
                    drafts: CatalogDrafts?, cancel: CatalogCancel? = nil,
                    run: CatalogRunRecord? = nil) async throws -> [WikiProposal.Item]? {
        let lines = await Task.detached(priority: .utility) { wiki.layerLines(layer) }.value
        return try await CatalogJSON.call(system: systemPrompt(names: names), user: userContent(layer: layer, lines: lines), retries: 1,
                                          caller: caller, drafts: drafts, name: "分组-\(layer)", cancel: cancel, run: run) { parse($0, layer: layer, wiki: wiki) }
    }
}
