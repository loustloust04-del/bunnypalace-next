import Foundation

extension RecallTool {
    static func readWiki(_ requested: Cursor, source conversationSource: any ConversationSource,
                         root: URL, userName: String, assistantName: String,
                         environment: RecallEnvironment) throws -> ExecResult {
        let reader = RecallWikiReader(profileId: requested.profileId, memoryRoot: root, userName: userName,
                                      resolveCurrent: environment.resolveCurrent)
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        var state = requested
        state.layer = initialLayer(.wiki, wiki: state.input.layer)
        let target = state.input.target ?? Target(tree: "c", layer: "index")
        var sourceVersion = target.page?.version ?? target.row?.page.version ?? target.card?.version
        func pageIsMissing() -> Bool {
            guard let page = target.page ?? target.row?.page ?? target.card?.page,
                  page.profileId == state.profileId, let url = try? wiki.pageURL(page.path) else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        func translated<T: Sendable>(_ read: RecallWikiRead<T>, _ contents: (T) -> (blocks: [Block], next: RecallWikiCursor?)) -> ExecResult {
            switch read {
            case .stale:
                return failure(state.layer, "页已改版，请从该页重新定位。", target: target, status: "stale")
            case .unavailable:
                if pageIsMissing() {
                    return failure(state.layer, "页已删除，请从索引重新定位。", target: target, status: "stale")
                }
                return failure(state.layer, "从父层重新定位：来源不可用：页/卡已删除、不公开、未批准，或不属于当前楼层；不会读取隐藏目录。", target: target, status: "unavailable")
            case .invalidTarget:
                return failure(state.layer, "目标不完整或不属于该页记录，请从页重新定位。", target: target)
            case .value(let value):
                let output = contents(value)
                var next: Cursor?
                if let cursor = output.next {
                    var following = state
                    following.wiki = cursor; following.position = 0; following.offset = 0; following.revision = ""
                    next = following
                }
                let nextStep: String
                switch state.input.layer {
                case "index": nextStep = "用返回 target 读 page"
                case "page": nextStep = "用返回 target 读 entry（L1）"
                case "entry": nextStep = "用返回 target 翻下一层"
                default: nextStep = "本原料已读完"
                }
                return deliver(output.blocks, state: state, revision: revision(json(output.blocks) + json(output.next)), target: target,
                               maximumCount: state.input.layer == "index" ? state.tuning.wikiIndexPageLines : (state.input.layer == "page" ? state.tuning.wikiPageRecords : state.tuning.searchPageResults),
                               nextPage: next, nextStep: nextStep,
                               sourceVersion: sourceVersion)
            }
        }
        switch state.input.layer {
        case "index":
            return translated(reader.index(wiki: wiki, folder: state.input.folder ?? "", cursor: state.wiki)) { index in
                sourceVersion = revision(json(index.rows.compactMap { row -> RecallWikiPageTarget? in
                    if case .page(let page) = row { return page.target }
                    return nil
                }))
                let blocks = index.rows.map { row -> Block in
                    switch row {
                    case .folder(let folder):
                        return Block(label: "文件夹 · \(folder.path)", text: "\(folder.title) · \(folder.hook) · \(folder.pageCount)页\n下一步 op=wiki layer=index folder=\(folder.path)")
                    case .page(let page):
                        return Block(label: "页", text: page.title + " · " + page.hook,
                                     targets: [Target(tree: "c", layer: "page", page: page.target)])
                    }
                }
                return (blocks, index.next)
            }
        case "page":
            guard let page = target.page else { return failure(state.layer, "从父层重新定位：target 缺 page。", target: target) }
            return translated(reader.page(wiki: wiki, target: page, cursor: state.wiki)) { page in
                sourceVersion = page.target.version
                var blocks: [Block] = []
                let pageRange = Target(tree: "c", layer: "page", page: page.target)
                if let hook = page.hook, !hook.text.isEmpty { blocks.append(Block(label: page.title + " · 钩子", text: hook.text, counts: false, returnedRange: pageRange)) }
                if let now = page.now, !now.text.isEmpty { blocks.append(Block(label: "现在 · 字符起点 \(now.offset)", text: now.text, counts: false, returnedRange: pageRange)) }
                blocks += page.records.map { row in
                    Block(label: "记录 \(row.target.ordinal)", text: row.body.text,
                          targets: [Target(tree: "c", layer: "entry", row: row.target)])
                }
                blocks += page.links.map { link in
                    Block(label: "连到", text: "只给目标，不展开别页。", targets: [Target(tree: "c", layer: "page", page: link)],
                          counts: false, returnedRange: pageRange)
                }
                return (blocks, page.next)
            }
        case "entry":
            guard let row = target.row else { return failure(state.layer, "从父层重新定位：target 缺 row。", target: target) }
            let read = reader.entry(wiki: wiki, target: row, source: target.source, selection: target.card, cursor: state.wiki)
            if case .value(.fragmentSource(let source)) = read,
               let fragment = try wikiFragment(source, row: row, state: state,
                                               conversationSource: conversationSource,
                                               locateFragment: environment.locateFragment) {
                return deliver([Block(label: "L1 · 碎片（无 seed 卡）", text: fragment.text, targets: [fragment.target],
                                      returnedRange: target)],
                               state: state, revision: fragment.version, target: target, maximumCount: 1,
                               nextStep: "用 original target 读取该碎片的精确原文")
            }
            return translated(read) { entry in
                switch entry {
                case .card(let card):
                    sourceVersion = card.target.version
                    let mentions = card.mentions.map { $0.name + " · " + $0.group + ($0.aliases.map { " · " + $0.joined(separator: "、") } ?? "") }.joined(separator: "\n")
                    let body = [card.title, card.gist, mentions].filter { !$0.isEmpty }.joined(separator: "\n")
                    return ([Block(label: "L1", text: body,
                                   targets: [Target(tree: "c", layer: "original", card: card.target)], returnedRange: target)], card.next)
                case .sources(let sources):
                    let blocks = sources.map { source -> Block in
                        var selected = target
                        selected.source = source
                        return Block(label: "出处选择", text: sourceLabel(source), targets: [selected])
                    }
                    return (blocks, nil)
                case .versionUndetermined(let versions):
                    return (versionBlocks(versions, target: target, label: "本行版本未唯一确定，请显式选择版本"), nil)
                case .legacySource(let source, let approved):
                    let heading = Block(label: "旧记录，版本未记录", text: source.map(sourceLabel) ?? "没有可精确定位的出处。", counts: false)
                    return ([heading] + versionBlocks(approved, target: target, label: "已批准来源版本（不猜最新）"), nil)
                case .fragmentSource(let source):
                    return ([Block(label: "旧来源/碎片，无 seed 卡", text: sourceLabel(source) + "；该页未记录可验证的原文锚，不能冒充精确原文。")], nil)
                case .missingCard(let card):
                    return ([Block(label: "L1 卡缺失", text: "\(card.path) · version=\(card.version)；不能拿其他版本替代。")], nil)
                }
            }
        case "original":
            if target.memoryId != nil, let row = target.row {
                let read = reader.entry(wiki: wiki, target: row, source: target.source)
                guard case .value(.fragmentSource(let source)) = read else {
                    switch read {
                    case .stale: return failure("L2", "页已改版，请从该页重新定位。", target: target, status: "stale")
                    case .unavailable:
                        return pageIsMissing()
                            ? failure("L2", "页已删除，请从索引重新定位。", target: target, status: "stale")
                            : failure("L2", "从父层重新定位：页或该行出处不可用。", target: target, status: "unavailable")
                    default: return failure("L2", "target 不再对应本行碎片出处，请从该页重新定位。", target: target)
                    }
                }
                guard let fragment = try wikiFragment(source, row: row, state: state,
                                                      conversationSource: conversationSource,
                                                      locateFragment: environment.locateFragment),
                      fragment.target.memoryId == target.memoryId else {
                    return pageIsMissing()
                        ? failure("L2", "页已删除，请从索引重新定位。", target: target, status: "stale")
                        : failure("L2", "从父层重新定位：碎片已删除、来源不可见或不能精确定位。", target: target, status: "unavailable")
                }
                guard fragment.version == target.sourceVersion else {
                    return failure("L2", "碎片或原文已改版，请从该页重新定位。", target: target, status: "stale")
                }
                return try readMessages(state, source: conversationSource, userName: userName, assistantName: assistantName,
                                        original: fragment.target, layer: "L2")
            }
            guard let card = target.card else { return failure(state.layer, "从父层重新定位：target 缺 card。", target: target) }
            return translated(reader.original(wiki: wiki, target: card, cursor: state.wiki)) { original in
                sourceVersion = original.target.version
                var label = "L2 · \(original.target.path) · version=\(original.target.version)"
                if let missing = original.missingOriginal { label += " · 原文当时没存，" + missingOriginalLabel(missing) }
                return ([Block(label: label, text: original.text?.text ?? "当前源也没有可读取的精确正文。")], original.next)
            }
        default: return failure(state.layer, "从父层重新定位：wiki layer 无效。", target: target)
        }
    }

    /// 碎片定位：app 注入记忆表查询（`RecallEnvironment.locateFragment`）；没有注入 = 找不到。
    static func wikiFragment(_ source: RecallWikiSourceLocator, row: RecallWikiRowTarget,
                             state: Cursor, conversationSource: any ConversationSource,
                             locateFragment: RecallEnvironment.LocateFragment?) throws
        -> (text: String, version: String, target: Target)? {
        guard case .fragment(let label) = source, let memory = try locateFragment?(label, state) else { return nil }
        let cid = memory.conversationId, nodeId = memory.nodeId
        guard let path = try? path(cid, state: state, source: conversationSource),
              let index = path.messages.firstIndex(where: { $0.id == nodeId }), !path.messages[index].text.isEmpty,
              let range = messageTarget(index..<(index + 1), cid: cid, state: state, path: path) else { return nil }
        let text = WikiProposalSources.strippingPrivateLinks(memory.content)
        let version = revision(text + cid + nodeId + json(path.messages[index]))
        let target = Target(tree: "c", layer: "original", conversationId: cid,
                            fromNodeId: range.fromNodeId, toNodeIdExclusive: range.toNodeIdExclusive, branchAnchor: range.branchAnchor,
                            row: row, source: source, memoryId: memory.memoryId, sourceVersion: version)
        return (text, version, target)
    }

    static func sourceLabel(_ source: RecallWikiSourceLocator) -> String {
        switch source {
        case .seed(let path): return path
        case .legacy(let label), .fragment(let label): return label
        }
    }

    static func versionBlocks(_ versions: [RecallWikiVersion], target: Target, label: String) -> [Block] {
        versions.map { version in
            var selection = target
            selection.card = version.target
            return Block(label: label, text: "\(version.title ?? version.target.path) · version=\(version.target.version) · \(version.madeAt.map { FrontmatterCodec.dateFormatter.string(from: $0) } ?? "时间未记录")", targets: [selection])
        }
    }

    static func missingOriginalLabel(_ missing: RecallWikiMissingOriginal) -> String {
        switch missing {
        case .currentSameVersion: return "当前同版"
        case .changed: return "当前源已改（不是历史原文）"
        case .resegmented: return "当前源已重切"
        case .slotDeleted: return "槽已删除"
        case .empty: return "当前源已清空"
        case .fileMissing: return "当前源文件已删除"
        case .contextChanged: return "来源上下文已改变"
        case .legacySegmentation: return "旧分段无法精确定位"
        case .currentUnavailable: return "当前源不可用"
        case .unreadable(let why): return "当前源不可读：" + why
        }
    }

    static func searchCatalog(_ state: Cursor, root: URL, query: String, after: Date?, before: Date?) async throws -> SearchPage {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        var result = SearchPage(layer: "L1")
        guard (try? SafeWiki.itemType(wiki.root)) == .typeDirectory else { return result }
        let indexer = CatalogRecallIndexer.shared
        indexer.ensure(profileId: state.profileId, wiki: wiki)
        guard let store = indexer.store(profileId: state.profileId),
              indexer.status(profileId: state.profileId).state == .ready else {
            result.indexBuilding = true
            return result
        }
        let indexed = try store.search(terms: [query], profileId: state.profileId)
        let hits = store.verified(indexed, maximumCount: indexed.count).filter {
            (after == nil || $0.updatedAt >= after!) && (before == nil || $0.updatedAt < before!)
        }
        guard state.input.conversationId == nil else { return result }
        let selection = state.position..<(state.position + state.tuning.searchPageResults + 1)
        for hit in hits where hit.kind == .page {
            guard let page = CatalogRecallIndexStore.readPage(hit.path, wiki: wiki), page.version == hit.version else { continue }
            let records = page.page.records.filter { line in
                let parts = CatalogRecordLine.split(line)
                return WikiProposalSources.strippingPrivateLinks(line) == line
                    && !(parts.labels ?? []).contains(where: WikiProposalSources.isPrivate)
            }.map { CatalogRecordLine.split($0).body }
            let evidence = [page.page.hook, page.page.now] + records
            let text = WikiProposalSources.strippingPrivateLinks(evidence.joined(separator: "\n"))
            guard text.localizedStandardContains(query) || page.page.title.localizedStandardContains(query)
                    || page.page.hook.localizedStandardContains(query) else { continue }
            let index = result.identities.count
            result.identities.append(hit.path + "|" + hit.version)
            guard selection.contains(index) else { continue }
            let target = Target(tree: "c", layer: "page",
                                page: .init(profileId: state.profileId, path: hit.path, version: hit.version))
            result.blocks.append(Block(label: "wiki页",
                                       text: centeredSnippet(text, keyword: query, limit: snippetLimit), targets: [target]))
        }
        if !result.identities.isEmpty { result.layer = "wiki页"; return result }
        let cards = hits.filter { $0.kind == .card }
        let l0 = cards.filter { hit in hit.identities.contains { $0.localizedStandardContains(query) } }
        let selected = l0.isEmpty ? cards : l0
        result.directory = !l0.isEmpty
        var seen = Set<String>()
        for hit in selected {
            let identity = hit.path + "|" + hit.version
            guard seen.insert(identity).inserted, let card = hit.card, let parent = hit.parents.first else { continue }
            let index = result.identities.count
            result.identities.append(identity)
            guard selection.contains(index) else { continue }
            let page = RecallWikiPageTarget(profileId: state.profileId, path: parent.path, version: parent.version)
            let cardTarget = RecallWikiCardTarget(page: page, path: hit.path, version: hit.version)
            var targets: [Target] = []
            if let loaded = CatalogRecallIndexStore.readPage(parent.path, wiki: wiki),
               let ordinal = loaded.page.records.firstIndex(where: { (CatalogRecordLine.split($0).labels ?? []).contains(hit.path) }) {
                let row = RecallWikiRowTarget(page: page, ordinal: ordinal, lineHash: CatalogRecordLine.fingerprint(loaded.page.records[ordinal]))
                targets.append(Target(tree: "c", layer: "entry", row: row, card: cardTarget))
            } else {
                targets.append(Target(tree: "c", layer: "page", page: page))
            }
            targets.append(Target(tree: "c", layer: "original", card: cardTarget))
            let evidence = l0.isEmpty ? card.gist : card.title + " · " + card.mentions.joined(separator: "、")
            result.blocks.append(Block(label: l0.isEmpty ? "L1" : "卡 L0 定位",
                                       text: centeredSnippet(evidence, keyword: query, limit: snippetLimit), targets: targets))
        }
        return result
    }
}
