import Foundation

/// Y7 的值层；不渲染工具文案、不写盘。调用方提供本轮楼层目录，在后台调用。
/// 值类型见 `RecallWikiReading.swift`。唯一的外部依赖是「当前源」：app 用
/// `CatalogSeedTaskStore` + `WikiProposalSources.current` 解析；没有解析器时按「当前源不可用」处理。
public struct RecallWikiReader: Sendable {
    let profileId: String
    let memoryRoot: URL
    var userName: String
    public var resolveCurrent: RecallEnvironment.ResolveCurrent?

    public init(profileId: String, memoryRoot: URL, userName: String,
                resolveCurrent: RecallEnvironment.ResolveCurrent? = nil) {
        self.profileId = profileId
        self.memoryRoot = memoryRoot
        self.userName = userName
        self.resolveCurrent = resolveCurrent
    }

    private var scope: String { profileId + "|" + memoryRoot.standardizedFileURL.path }

    private func accepts(_ wiki: WikiStore) -> Bool {
        wiki.root.standardizedFileURL == memoryRoot.appendingPathComponent("wiki").standardizedFileURL
            && (try? SafeWiki.itemType(memoryRoot)) == .typeDirectory
            && (try? SafeWiki.itemType(wiki.root)) == .typeDirectory
    }

    private func cursor(_ binding: String, _ revision: String, _ position: Int, _ offset: Int = 0) -> RecallWikiCursor {
        RecallWikiCursor(scope: scope, binding: binding, revision: revision, position: position, offset: offset)
    }

    private func valid(_ cursor: RecallWikiCursor?, binding: String, revision: String) -> Bool {
        guard let cursor else { return true }
        return cursor.scope == scope && cursor.binding == binding && cursor.revision == revision
            && cursor.position >= 0 && cursor.offset >= 0
    }

    private func target(_ page: SafeWiki.Page) -> RecallWikiPageTarget {
        RecallWikiPageTarget(profileId: profileId, path: page.path, version: page.version)
    }

    private func readPage(_ target: RecallWikiPageTarget, wiki: WikiStore) -> RecallWikiRead<SafeWiki.Page> {
        guard accepts(wiki), target.profileId == profileId else { return .unavailable }
        guard let page = CatalogRecallIndexStore.readPage(target.path, wiki: wiki) else { return .unavailable }
        guard target.version == nil || target.version == page.version else { return .stale }
        return .value(page)
    }

    func index(wiki: WikiStore, folder: String = "", cursor input: RecallWikiCursor? = nil) -> RecallWikiRead<RecallWikiIndex> {
        guard accepts(wiki) else { return .unavailable }
        guard folder.isEmpty || (CatalogRecallIndexStore.publicPath(folder) && WikiStore.isValidFolderPath(folder)) else { return .unavailable }
        let safe = SafeWiki.scan(wiki, memoryRoot: memoryRoot)
        guard safe.refused == nil, folder.isEmpty || safe.folders.contains(folder) else { return .unavailable }
        let rows = safe.indexRows(folder)
        let state = rows.map { row -> [String] in
            switch row {
            case .folder(let path, let name, let hook, let count): return [path, name, hook, String(count)]
            case .page(let path, let title, let hook, let version): return [path, title, hook, version]
            }
        }
        guard let encoded = try? JSONEncoder().encode(state) else { return .unavailable }
        let revision = WikiStore.version(of: encoded), binding = "index|" + folder
        guard valid(input, binding: binding, revision: revision), (input?.offset ?? 0) == 0 else { return .stale }
        let start = input?.position ?? 0
        guard start <= rows.count else { return .invalidTarget }
        let end = min(start + 30, rows.count)
        func shown(_ text: String) -> String {
            WikiStore.shown(WikiProposalSources.strippingPrivateLinks(text), user: userName)
        }
        let output = rows[start..<end].map { row -> RecallWikiIndexRow in
            switch row {
            case .folder(let path, let name, let hook, let count):
                return .folder(RecallWikiFolderRow(path: path, title: shown(name), hook: shown(hook), pageCount: count))
            case .page(let path, let title, let hook, let version):
                return .page(RecallWikiPageRow(path: WikiStore.shown(path, user: userName), title: shown(title), hook: shown(hook),
                                               target: RecallWikiPageTarget(profileId: profileId, path: path, version: version)))
            }
        }
        return .value(RecallWikiIndex(folder: folder, rows: output, next: end < rows.count ? cursor(binding, revision, end) : nil))
    }

    private func part(_ text: String, offset: Int, budget: inout Int) -> RecallWikiTextPart {
        let slice = String(text.dropFirst(offset).prefix(budget))
        budget -= slice.count
        return RecallWikiTextPart(text: slice, offset: offset, complete: offset + slice.count == text.count)
    }

    private func locators(_ labels: [String], page: SafeWiki.Page, wiki: WikiStore) -> [RecallWikiSourceLocator] {
        let store = SeedNoteStore(wiki: wiki)
        var legacyLabels: Set<String>?
        return labels.map { label in
            if CatalogRecallIndexStore.publicPath(label), label.hasPrefix("memory/") || label.hasPrefix(CatalogRecordLine.surveyPrefix) {
                return .seed(path: label)
            }
            if legacyLabels == nil {
                legacyLabels = Set((page.page.entries ?? []).compactMap { entry in
                    guard let ref = CatalogRecallIndexStore.reference(entry),
                          let card = store.load(path: ref.path, version: ref.version),
                          card.path == ref.path, card.version == ref.version else { return nil }
                    return CatalogRecordLine.citeLabel(layer: card.layer, filePath: card.path, name: card.name, day: nil)
                })
            }
            return legacyLabels?.contains(label) == true ? .legacy(label: label) : .fragment(label: label)
        }
    }

    public func page(wiki: WikiStore, target requested: RecallWikiPageTarget, cursor input: RecallWikiCursor? = nil) -> RecallWikiRead<RecallWikiPage> {
        let loaded = readPage(requested, wiki: wiki)
        guard case .value(let p) = loaded else {
            return loaded.isStale ? .stale : .unavailable
        }
        let pageTarget = target(p), binding = "page|" + p.path
        guard valid(input, binding: binding, revision: p.version) else { return .stale }
        var position = input?.position ?? 0, offset = input?.offset ?? 0, budget = 3000
        guard position <= 2 + p.page.records.count + p.page.links.count else { return .invalidTarget }
        var output = RecallWikiPage(target: pageTarget, title: p.page.title + p.page.factDomainIndexTag, records: [], links: [])
        while position < 2, budget > 0 {
            let header = WikiProposalSources.strippingPrivateLinks(position == 0 ? p.page.hook : p.page.now)
            guard offset <= header.count else { return .invalidTarget }
            let chunk = part(header, offset: offset, budget: &budget)
            if position == 0 { output.hook = chunk } else { output.now = chunk }
            if !chunk.complete { output.next = cursor(binding, p.version, position, offset + chunk.text.count); return .value(output) }
            position += 1; offset = 0
        }
        while position >= 2, position < 2 + p.page.records.count, budget > 0, output.records.count < 10 {
            let ordinal = position - 2, line = p.page.records[ordinal]
            let parts = CatalogRecordLine.split(line)
            if WikiProposalSources.strippingPrivateLinks(line) != line || (parts.labels ?? []).contains(where: WikiProposalSources.isPrivate) {
                position += 1; offset = 0; continue
            }
            let body = parts.body
            guard offset <= body.count else { return .invalidTarget }
            let chunk = part(body, offset: offset, budget: &budget)
            output.records.append(RecallWikiRecord(target: RecallWikiRowTarget(page: pageTarget, ordinal: ordinal, lineHash: CatalogRecordLine.fingerprint(line)), body: chunk, sources: locators(parts.labels ?? [], page: p, wiki: wiki)))
            if !chunk.complete { output.next = cursor(binding, p.version, position, offset + chunk.text.count); return .value(output) }
            position += 1; offset = 0
        }
        let linkStart = 2 + p.page.records.count
        while position >= linkStart, position < linkStart + p.page.links.count, output.links.count < 30 {
            let path = p.page.links[position - linkStart].target
            if let linked = CatalogRecallIndexStore.readPage(path, wiki: wiki) { output.links.append(target(linked)) }
            position += 1
        }
        if position < linkStart + p.page.links.count { output.next = cursor(binding, p.version, position, offset) }
        return .value(output)
    }

    private func versions(_ page: SafeWiki.Page, source: RecallWikiSourceLocator, wiki: WikiStore) -> [RecallWikiVersion] {
        if case .fragment = source { return [] }
        var paths = Set<String>()
        if case .seed(let path) = source { paths.insert(path) }
        let store = SeedNoteStore(wiki: wiki)
        var output: [RecallWikiVersion] = []
        for entry in Set(page.page.entries ?? []).sorted() {
            guard let ref = CatalogRecallIndexStore.reference(entry) else { continue }
            if case .seed(let path) = source, ref.path != path { continue }
            guard CatalogRecallIndexStore.safeSource(ref.path, wiki: wiki) else { continue }
            let card = store.load(path: ref.path, version: ref.version)
                .flatMap { $0.path == ref.path && $0.version == ref.version ? $0 : nil }
            if case .legacy(let label) = source, let card,
               CatalogRecordLine.citeLabel(layer: card.layer, filePath: ref.path, name: card.name, day: nil) == label {
                paths.insert(ref.path)
            }
            output.append(RecallWikiVersion(target: RecallWikiCardTarget(page: target(page), path: ref.path, version: ref.version),
                                            title: card?.title, madeAt: card?.madeAt))
        }
        // 旧标签只定位 path，不能用某一版的名称匹配暗中消除同 path 的版本歧义。
        output.removeAll { !paths.contains($0.target.path) }
        return output
    }

    func entry(wiki: WikiStore, target row: RecallWikiRowTarget, source selected: RecallWikiSourceLocator? = nil,
               selection: RecallWikiCardTarget? = nil, cursor input: RecallWikiCursor? = nil) -> RecallWikiRead<RecallWikiEntry> {
        guard row.page.version != nil else { return .invalidTarget }
        let loaded = readPage(row.page, wiki: wiki)
        guard case .value(let p) = loaded else { return loaded.isStale ? .stale : .unavailable }
        guard p.page.records.indices.contains(row.ordinal), CatalogRecordLine.fingerprint(p.page.records[row.ordinal]) == row.lineHash else { return .stale }
        let line = p.page.records[row.ordinal]
        let parts = CatalogRecordLine.split(line)
        guard WikiProposalSources.strippingPrivateLinks(line) == line,
              !(parts.labels ?? []).contains(where: WikiProposalSources.isPrivate) else { return .unavailable }
        let sources = locators(parts.labels ?? [], page: p, wiki: wiki)
        if selected == nil, sources.count > 1 { return .value(.sources(sources)) }
        let source = selected ?? sources.first
        guard let source else { return .value(.legacySource(nil, approved: [])) }
        guard sources.contains(source) else { return .invalidTarget }
        if case .fragment = source { return .value(.fragmentSource(source)) }
        if case .seed(let path) = source, !CatalogRecallIndexStore.safeSource(path, wiki: wiki) { return .unavailable }
        let candidates = versions(p, source: source, wiki: wiki)
        if let selection {
            let approved = candidates.isEmpty ? SafeWiki.scan(wiki, memoryRoot: memoryRoot).pages.flatMap { versions($0, source: source, wiki: wiki) } : candidates
            guard approved.contains(where: { $0.target == selection }) else { return .unavailable }
            return l1(selection, wiki: wiki, cursor: input)
        }
        if candidates.count == 1 { return l1(candidates[0].target, wiki: wiki, cursor: input) }
        if candidates.count > 1 { return .value(.versionUndetermined(candidates)) }
        let approved = SafeWiki.scan(wiki, memoryRoot: memoryRoot).pages.flatMap { versions($0, source: source, wiki: wiki) }
        return .value(.legacySource(source, approved: approved))
    }


    private func authorized(_ card: RecallWikiCardTarget, wiki: WikiStore) -> RecallWikiRead<SafeWiki.Page> {
        guard card.page.version != nil, !card.version.isEmpty else { return .invalidTarget }
        let loaded = readPage(card.page, wiki: wiki)
        guard case .value(let page) = loaded else { return loaded }
        guard CatalogRecallIndexStore.safeSource(card.path, wiki: wiki), (page.page.entries ?? []).contains(card.path + "|" + card.version) else { return .unavailable }
        return loaded
    }

    private func l1(_ target: RecallWikiCardTarget, wiki: WikiStore, cursor input: RecallWikiCursor?) -> RecallWikiRead<RecallWikiEntry> {
        let auth = authorized(target, wiki: wiki)
        guard case .value = auth else { return auth.isStale ? .stale : .unavailable }
        guard var card = SeedNoteStore(wiki: wiki).load(path: target.path, version: target.version), card.path == target.path, card.version == target.version else { return .value(.missingCard(target)) }
        let clean = WikiProposalSources.strippingPrivateLinks
        card.title = clean(card.title)
        card.gist = clean(card.gist)
        card.mentions = card.mentions.map {
            .init(name: clean($0.name), group: clean($0.group), aliases: $0.aliases?.map(clean).filter { !$0.isEmpty })
        }
        // 字段分别切片，返回值仍是结构化 L1，不造一份模型展示文字。
        let binding = "entry|" + target.page.path + "|" + target.path + "|" + target.version
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let encoded = try? encoder.encode(card) else { return .unavailable }
        let revision = WikiStore.version(of: encoded)
        guard valid(input, binding: binding, revision: revision), (input?.position ?? 0) == 0 else { return .stale }
        var skip = input?.offset ?? 0, budget = 3000
        let total = card.title.count + card.gist.count + card.mentions.reduce(0) {
            $0 + $1.name.count + $1.group.count + ($1.aliases?.reduce(0) { $0 + $1.count } ?? 0)
        }
        guard skip <= total else { return .invalidTarget }
        var consumed = 0
        func slice(_ text: String) -> String {
            if skip >= text.count { skip -= text.count; return "" }
            let value = String(text.dropFirst(skip).prefix(budget))
            skip = 0; budget -= value.count; consumed += value.count
            return value
        }
        let title = slice(card.title), gist = slice(card.gist)
        let mentions = card.mentions.compactMap { mention -> SeedNoteCard.Mention? in
            let name = slice(mention.name), group = slice(mention.group), aliases = mention.aliases?.map(slice)
            guard !name.isEmpty || !group.isEmpty || aliases?.contains(where: { !$0.isEmpty }) == true else { return nil }
            return .init(name: name, group: group, aliases: aliases)
        }
        let end = (input?.offset ?? 0) + consumed
        let next = end < total ? cursor(binding, revision, 0, end) : nil
        return .value(.card(RecallWikiL1(target: target, title: title, gist: gist, mentions: mentions, factDomain: card.effectiveFactDomain, sourceContext: card.sourceContext, next: next)))
    }

    public func original(wiki: WikiStore, target: RecallWikiCardTarget, cursor input: RecallWikiCursor? = nil) -> RecallWikiRead<RecallWikiOriginal> {
        guard let pageVersion = target.page.version else { return .invalidTarget }
        let auth = authorized(target, wiki: wiki)
        guard case .value = auth else { return auth.isStale ? .stale : .unavailable }
        let store = SeedNoteStore(wiki: wiki)
        guard let card = store.load(path: target.path, version: target.version), card.path == target.path, card.version == target.version else { return .unavailable }
        var text: String?, missing: RecallWikiMissingOriginal?, currentVersion: String?, context = card.sourceContext
        if let original = store.original(path: target.path, version: target.version) {
            text = original.text; context = original.sourceContext
        } else {
            // txt 存在却不可读（含链接）不能伪装成历史缺存，再回落现版本。
            do {
                let dir = try SafeWiki.folder([SeedNoteStore.folderName], under: wiki.root, create: false)
                let url = try SafeWiki.file(SeedNoteStore.key(path: target.path, version: target.version) + ".txt", in: dir)
                if try SafeWiki.itemType(url) != nil { return .unavailable }
            } catch { return .unavailable }
            if let current = resolveCurrent?(card, wiki, profileId, memoryRoot) {
                text = current.text
                currentVersion = current.currentVersion
                missing = current.missing
            } else {
                missing = .currentUnavailable
            }
        }
        let binding = "original|" + target.page.path + "|" + target.path + "|" + target.version
        let revision = WikiStore.version(of: Data((pageVersion + "|" + (currentVersion ?? target.version) + "|" + (text ?? "") + "|" + String(describing: missing)).utf8))
        guard valid(input, binding: binding, revision: revision), (input?.position ?? 0) == 0 else { return .stale }
        let offset = input?.offset ?? 0
        guard offset <= (text?.count ?? 0) else { return .invalidTarget }
        var budget = 3000
        let chunk = text.map { part($0, offset: offset, budget: &budget) }
        let next = chunk.flatMap { $0.complete ? nil : cursor(binding, revision, 0, offset + $0.text.count) }
        return .value(RecallWikiOriginal(target: target, missingOriginal: missing, currentVersion: currentVersion, text: chunk, sourceContext: context, next: next))
    }
}
