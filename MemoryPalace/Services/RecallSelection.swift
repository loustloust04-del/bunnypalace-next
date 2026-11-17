import MemoryCore
import Foundation

/// The sole chat-side selector. It returns a value for assembly; no conversation or receipt is mutated.
enum RecallSelection {
    static func prepare(profile: Profile, conversationId: String, turnId: String, branchAnchor: String,
                        text: String, state: RecallConversationState, existingDecision: RecallTurnDecision?,
                        inputs: MemoryInjector.RoundInputs, recentMessages: [String], now: Date,
                        tuning: RecallTuning, enabled: Bool = true,
                        windowIds: Set<String> = [], windowSince: Date? = nil) -> (decision: RecallTurnDecision, layers: RecallMemoryLayers) {
        let tuning = existingDecision.flatMap { $0.turnId == turnId ? $0.tuning : nil } ?? tuning
        let context = EffectiveCharacterContext(profile: profile)
        let excluded = [profile.userName, profile.assistantName, context.userName, context.charName]
            + (inputs.wiki?.stopWords ?? [])
        let blocked = Set(excluded.map(RecallLexical.normalized))
        let pages = enabled && tuning.archiveTriggerEnabled ? (inputs.wiki?.pages ?? []).filter {
            WikiStore.isValidPagePath($0.path) && !WikiProposalSources.isPrivate($0.path)
        } : []
        let pageByPath = Dictionary(pages.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let memories = enabled ? inputs.memories.filter {
            $0.profileId == profile.id && MemoryInjector.isInjectable($0)
                && !($0.organizedPage.map(WikiProposalSources.isPrivate) ?? false)
        } : []
        // 批过的记忆条目每轮全带：都已经在了，「聊到才带」不再单独推它们（wiki 页照旧聊到才带）
        let everyRound = enabled && inputs.everyRound
        let memoryById = Dictionary(memories.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        /// 出处就在眼前的记忆条目不推回同一个窗口（同时间轴 / 段摘要「还在历史窗口里的不注」）：来自这场对话，且出处那条消息还在
        /// 这一轮发出去的历史里；没有出处消息的（助手在这里亲手记的）看它是不是在历史窗口最早那条之后写下的。
        /// `windowIds` / `windowSince` = 这一轮历史窗口里的消息 id、最早那条的时间；没给 = 不滤
        func inView(_ memory: Memory) -> Bool {
            guard !conversationId.isEmpty, memory.sourceConversationId == conversationId else { return false }
            if let node = memory.sourceNodeId { return windowIds.contains(node) }
            return windowSince.map { memory.createdAt >= $0 } ?? false
        }
        let archiveTitle = PromptAssembler.archiveLabel(profile)
        var stableParts = [inputs.selfMemory?.text ?? ""].filter { !$0.isEmpty }
        // 保留单位与拼接同处旁录：顺序 = 层里出现的顺序（plan-memory-receipt §2.2 顺序陷阱）
        var units: [RecallDeliveryUnit] = []
        if let selfMemory = inputs.selfMemory, !selfMemory.text.isEmpty {
            units.append(RecallDeliveryUnit(
                kind: RecallDeliveryItem.Kind.selfMemory, ref: "selfMemory", text: selfMemory.text,
                tokens: selfMemory.tokens,
                shown: "全文 \(selfMemory.fullCount) · 目录 \(selfMemory.indexCount)",
                members: selfMemory.fullSlugs.sorted(), segment: .memoryStable))
        }
        var remaining = max(0, inputs.archiveBudget)
        // This uses the existing shared archive allowance, not a new X percentage pool.
        if enabled, inputs.rootIndex ?? MemoryOpenWindow.isChecked(.c, profileId: profile.id), let wiki = inputs.wiki {
            let root = WikiInjection.indexBlock(wiki, user: profile.userName)
            if !root.isEmpty, Memory.estimateTokens(root) <= remaining {
                stableParts.append(root)
                remaining -= Memory.estimateTokens(root)
                units.append(RecallDeliveryUnit(
                    kind: RecallDeliveryItem.Kind.rootIndex, ref: "rootIndex",
                    version: WikiStore.version(of: Data(root.utf8)), text: root,
                    tokens: Memory.estimateTokens(root),
                    shown: "根索引 \(root.components(separatedBy: "\n").count) 行", segment: .memoryStable))
            }
        }
        // 卡的目录（Z）：只在卡靠「聊到了才带」带时出——那时没聊到的卡不在提示里，助手得知道有哪些可翻
        if enabled, tuning.archiveTriggerEnabled, !everyRound {
            let index = MemoryInjector.cardIndex(memories.filter { !$0.isUserExplicit })
            let cost = Memory.estimateTokens(index.text)
            if !index.text.isEmpty, cost <= remaining {
                stableParts.append(index.text)
                remaining -= cost
                units.append(RecallDeliveryUnit(
                    kind: RecallDeliveryItem.Kind.cardIndex, ref: "cardIndex",
                    version: WikiStore.version(of: Data(index.text.utf8)), text: index.text, tokens: cost,
                    shown: "卡的目录 \(index.groups) 组", segment: .memoryStable))
            }
        }
        // 钉住的：进了这一轮原料的就带（带不带进原料只听「钉住的」那一勾）
        let pinnedRetriever = PersistentRetriever()
        var pinnedIds = Set<UUID>()
        var stableHits: [InjectionHit] = []
        var pinnedLines: [String] = []
        var expiredPinned: [Memory] = []
        for hit in pinnedRetriever.retrieve(memories, recent: []) where !pinnedIds.contains(hit.memory.id) {
            let memory = hit.memory
            let line = MemoryInjector.injectionPayload(memory, stable: true, catalog: false, now: now).text
            let cost = Memory.estimateTokens(line) + (pinnedLines.isEmpty ? Memory.estimateTokens("[\(archiveTitle)]\n") : 0)
            guard cost <= remaining else { continue }
            remaining -= cost
            pinnedIds.insert(memory.id)
            pinnedLines.append(line)
            let pinnedRef = memoryRef(memory)
            units.append(RecallDeliveryUnit(
                kind: RecallDeliveryItem.Kind.pinned, ref: MemoryDelivery.key(pinnedRef),
                version: pinnedRef.version, text: line, tokens: Memory.estimateTokens(line),
                shown: String(memory.lineText.prefix(60)), segment: .memoryStable))
            if WikiInjection.isExpired(memory, now: now) { expiredPinned.append(memory) }
            stableHits.append(InjectionHit(memoryId: memory.id, snippet: String(memory.lineText.prefix(60)),
                                           category: memory.category, score: hit.score, retrieverId: pinnedRetriever.id, catalog: false))
        }
        if !pinnedLines.isEmpty { stableParts.append("[\(archiveTitle)]\n" + pinnedLines.joined(separator: "\n")) }
        let expiredReminder = MemoryInjector.expiredPinnedReminder(expiredPinned, budget: remaining)
        remaining -= expiredReminder.cost
        if !expiredReminder.text.isEmpty {
            units.append(RecallDeliveryUnit(
                kind: RecallDeliveryItem.Kind.expiredReminder, ref: "expired", text: expiredReminder.text,
                tokens: Memory.estimateTokens(expiredReminder.text), shown: "已过期 \(expiredPinned.count) 项",
                members: expiredPinned.map(\.id.uuidString), segment: .memoryVolatile))
        }
        // Z7 单独按记忆注入上限渲染，不占 B4 / 档案预算；总上下文仍由 composePrompt 裁剪。
        if enabled, let previous = inputs.previousWindow {
            let rendered = previous.render(user: context.userName, assistant: context.charName, budget: MemoryInjector.tokenBudget)
            if !rendered.text.isEmpty {
                stableParts.append(rendered.text)
                units.append(RecallDeliveryUnit(
                    kind: RecallDeliveryItem.Kind.previousWindow, ref: "previousWindow:\(previous.sourceId)",
                    version: previous.leafId, text: rendered.text, tokens: rendered.tokens,
                    shown: "上个窗口 \(rendered.count) 条",
                    members: previous.messages.suffix(rendered.count).map(\.nodeId), segment: .memoryStable))
            }
        }

        func pageRef(_ page: WikiInjectionSnapshot.Page) -> RecallSourceRef {
            // Hand-built snapshots (tests/legacy callers) still get a content identity, never an empty version.
            let version = page.version.isEmpty
                ? WikiStore.version(of: Data(([page.title, page.hook, page.now, page.validUntil ?? ""] + page.triggers).joined(separator: "\u{0}").utf8))
                : page.version
            return RecallSourceRef(profileId: profile.id, conversationId: conversationId, kind: .page, path: page.path, version: version)
        }
        func pageItem(_ page: WikiInjectionSnapshot.Page, word: String) -> RecallItem {
            let payload = WikiInjection.hitsBlock([WikiPageHit(page: page, word: word)], now: now, user: profile.userName)
            let identities = ([page.title] + page.triggers).filter {
                !blocked.contains(RecallLexical.normalized($0)) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.map { WikiStore.shown($0, user: profile.userName) }
            return RecallItem(source: pageRef(page), text: payload, identities: identities, tokenCost: Memory.estimateTokens(payload))
        }
        func memoryRef(_ memory: Memory) -> RecallSourceRef {
            let version = WikiStore.version(of: Data([memory.content, memory.category,
                memory.updatedAt.timeIntervalSince1970.description, memory.validUntil?.timeIntervalSince1970.description ?? "",
                memory.organizedPage ?? "", memory.keywords.joined(separator: "\u{0}"), memory.subject ?? ""].joined(separator: "\u{0}").utf8))
            return RecallSourceRef(profileId: profile.id, conversationId: conversationId, kind: .fragment,
                                   path: memory.id.uuidString, version: version)
        }
        let fragmentHeader = "[\(archiveTitle)·本轮相关]"
        // keywords are retrieval hints, not public entity identities. Only a recorded subject is an identity.
        func identities(_ memory: Memory) -> [String] {
            [memory.subject].compactMap { $0 }.filter { !$0.isEmpty && !blocked.contains(RecallLexical.normalized($0)) }
        }
        /// 一张卡 = 一行；「本轮相关」的头和目录模式的指路在下面拼 volatile 时整组只出一次
        func memoryItem(_ memory: Memory) -> RecallItem {
            let line = MemoryInjector.injectionPayload(memory, stable: false, catalog: MemoryFlags.catalogInjection, now: now).text
            return RecallItem(source: memoryRef(memory), text: line, identities: identities(memory), tokenCost: Memory.estimateTokens(line))
        }
        let batch = inputs.fullText.flatMap { $0.profileId == profile.id && $0.text == text ? $0 : nil }
        let cardHits = (((batch?.status.state == .ready ? batch?.hits : nil) ?? []) + (batch?.kept ?? [])).filter {
            $0.kind == .card && CatalogRecallIndexStore.publicPath($0.path)
                && $0.cardKey == SeedNoteStore.key(path: $0.path, version: $0.version)
                && $0.parents.contains { pageByPath[$0.path]?.version == $0.version }
        }
        func cardItem(_ hit: CatalogRecallIndexStore.Hit) -> RecallItem? {
            guard let card = hit.card else { return nil }
            let parents = hit.parents.filter { pageByPath[$0.path]?.version == $0.version }
            let payload = WikiInjection.cardBlock(card, path: hit.path, version: hit.version, parents: parents, user: profile.userName)
            let identities = hit.identities.filter { !blocked.contains(RecallLexical.normalized($0)) }
            return RecallItem(source: .init(profileId: profile.id, conversationId: conversationId, kind: .card,
                                           path: hit.path, version: hit.version),
                              text: payload, identities: identities, tokenCost: Memory.estimateTokens(payload))
        }
        func covers(_ parent: RecallItem, _ child: RecallItem) -> Bool {
            guard parent.source.kind == .page, child.source.kind == .card else { return false }
            return cardHits.first { $0.path == child.source.path && $0.version == child.source.version }?
                .parents.contains { $0.path == parent.source.path && $0.version == parent.source.version } == true
        }
        func resolve(_ item: RecallItem) -> RecallItem? {
            guard item.source.profileId == profile.id, item.source.conversationId == conversationId else { return nil }
            switch item.source.kind {
            case .page:
                guard let page = pageByPath[item.source.path], pageRef(page) == item.source else { return nil }
                return pageItem(page, word: page.title)
            case .fragment:
                guard !everyRound, let memory = memoryById[item.source.path], !memory.isUserExplicit, !inView(memory),
                      memory.organizedPage == nil, memoryRef(memory) == item.source else { return nil }
                return memoryItem(memory)
            case .card:
                return cardHits.first { $0.path == item.source.path && $0.version == item.source.version }.flatMap(cardItem)
            }
        }
        let fragmentDocuments = everyRound ? [] : memories.filter { !$0.isUserExplicit && $0.organizedPage == nil }
        func corpus() -> RecallCorpus {
            // 这一步每个要找的轮次都走：只拿决定词面的东西（页的版本、卡的正文和标签）算签名，
            // 不给每张卡算内容摘要（真数据 300 张卡时那一项占了一轮挑选的大半时间）
            var signature = Hasher()
            for page in pages {
                signature.combine(page.path)
                signature.combine(pageRef(page).version)
            }
            for memory in fragmentDocuments {
                signature.combine(memory.id)
                signature.combine(memory.content)
                signature.combine(memory.keywords)
            }
            let key = "\(pages.count)|\(fragmentDocuments.count)|\(signature.finalize())"
            return RecallCorpusCache.shared.corpus(profileId: profile.id, signature: key, tuning: tuning) {
                let pageDocuments = pages.map { RecallLexical.tokens($0.lexicalDocument, tuning: tuning) }
                let cards = fragmentDocuments.map {
                    ($0.id.uuidString, RecallFullText.fragmentTokens(([$0.content] + $0.keywords).joined(separator: "\n"), tuning: tuning))
                }
                return RecallCorpus(weights: RecallTokenWeights(tokenDocuments: pageDocuments + cards.map(\.1)),
                                    fragmentTokens: Dictionary(cards, uniquingKeysWith: { first, _ in first }))
            }
        }
        var searchedHits: [UUID: InjectionHit] = [:]
        // 卡那一组的头只出一次，先从预算里留出来
        let itemBudget = max(0, remaining - (fragmentDocuments.isEmpty ? 0 : Memory.estimateTokens(fragmentHeader + "\n")))
        let decision = RecallTurnState.prepare(turnId: turnId, branchAnchor: branchAnchor, text: text, state: state,
                                              existingDecision: existingDecision, enabled: enabled,
                                              tuning: tuning, weights: corpus().weights, budget: itemBudget, resolve: resolve, covers: covers) { cooldowns in
            // A new topic's lower bound is this true user message, never prior topic/history text.
            // recentMessages remains in the public bridge signature for callers' real-history context.
            let snapshot = WikiInjectionSnapshot(pages: pages, stopWords: inputs.wiki?.stopWords ?? [])
            let hits = WikiInjection.hits(snapshot, recent: [text], excluding: excluded, tuning: tuning)
            let x1 = hits.map { pageItem($0.page, word: $0.word) }
            let hasX1 = x1.contains { item in
                let thawed = RecallLexical.names(item.identities, in: text, tuning: tuning) || RecallLexical.targets(item.source, in: text)
                let cooled = cooldowns.contains {
                    $0.source == item.source && $0.untilTurn >= state.effectiveTurn + 1
                }
                return item.tokenCost <= remaining && (!cooled || thawed)
            }
            let x2 = !hasX1 ? batch.map {
                RecallFullText.ranked($0, text: text, profileId: profile.id, excluding: excluded, tuning: tuning)
                    .compactMap { hit -> RecallItem? in
                        if hit.kind == .page {
                            guard let page = pageByPath[hit.path], pageRef(page).version == hit.version else { return nil }
                            return pageItem(page, word: page.title)
                        }
                        return cardHits.first { $0.docId == hit.docId }.flatMap(cardItem)
                    }
            } ?? [] : []
            let selectedPages = hasX1 ? x1 : x1 + x2
            // X3：只带这一句聊到的卡（`RecallFullText.fragmentHits`）；每轮全带勾着时没有候选（上面 `fragmentDocuments` 是空的）
            let built = corpus()
            let documents = fragmentDocuments.filter { !pinnedIds.contains($0.id) && !inView($0) }.map {
                RecallFragmentDocument(id: $0.id.uuidString, tokens: built.fragmentTokens[$0.id.uuidString] ?? [],
                                       identities: identities($0), priority: $0.recallPriority, createdAt: $0.createdAt)
            }
            let matched = RecallFullText.fragmentHits(text: text, documents: documents, weights: built.weights,
                                                      excluding: excluded, tuning: tuning)
            return selectedPages + matched.compactMap { hit -> RecallItem? in
                guard let memory = memoryById[hit.id] else { return nil }
                searchedHits[memory.id] = InjectionHit(memoryId: memory.id, snippet: String(memory.lineText.prefix(60)),
                                                       category: memory.category, score: nil,
                                                       retrieverId: hit.match == .lexical ? "keyword" : "named",
                                                       catalog: MemoryFlags.catalogInjection)
                return memoryItem(memory)
            }
        }
        let selectedPages = decision.selected.compactMap { item -> WikiPageHit? in
            guard item.source.kind == .page, let page = pageByPath[item.source.path] else { return nil }
            let word = WikiInjection.match(item.identities, in: text)?.word ?? page.title
            return WikiPageHit(page: page, word: word)
        }
        var fragmentHits = decision.selected.compactMap { item -> InjectionHit? in
            guard item.source.kind == .fragment, let memory = memoryById[item.source.path] else { return nil }
            return searchedHits[memory.id] ?? InjectionHit(memoryId: memory.id, snippet: String(memory.lineText.prefix(60)),
                                                         category: memory.category, score: nil, retrieverId: "active", catalog: MemoryFlags.catalogInjection)
        }
        func unitShown(_ item: RecallItem) -> String {
            switch item.source.kind {
            case .page: return pageByPath[item.source.path]?.title ?? item.identities.first ?? item.source.path
            case .card: return item.identities.first ?? item.source.path
            case .fragment: return memoryById[item.source.path].map { String($0.lineText.prefix(60)) } ?? item.source.path
            }
        }
        func sourceKind(_ source: RecallSourceRef) -> String {
            switch source.kind {
            case .page: return RecallDeliveryItem.Kind.page
            case .card: return RecallDeliveryItem.Kind.card
            case .fragment: return RecallDeliveryItem.Kind.fragment
            }
        }
        var volatile = expiredReminder.text
        func record(_ item: RecallItem) {
            units.append(RecallDeliveryUnit(
                kind: sourceKind(item.source), ref: MemoryDelivery.key(item.source), version: item.source.version,
                text: item.text, tokens: item.tokenCost, shown: unitShown(item), segment: .memoryVolatile))
        }
        for item in decision.selected where item.source.kind != .fragment {
            if !volatile.isEmpty { volatile += "\n\n" }
            volatile += item.text
            record(item)
        }
        let selectedFragments = decision.selected.filter { $0.source.kind == .fragment }
        if !selectedFragments.isEmpty {
            if !volatile.isEmpty { volatile += "\n\n" }
            volatile += fragmentHeader + "\n" + selectedFragments.map(\.text).joined(separator: "\n")
            if MemoryFlags.catalogInjection && RecallTool.enabled { volatile += MemoryInjector.recallCatalogHint }
            selectedFragments.forEach(record)
        }
        // 不靠「聊到才带」带的那几路：每轮全带，或聊到才带关着时试验的按意思找。预算 = 这一轮页和卡用剩下的
        let cardRetrievers = enabled
            ? MemoryInjector.cardRetrievers(everyRound: everyRound, triggerOn: tuning.archiveTriggerEnabled) : []
        if !cardRetrievers.isEmpty {
            let fragments = MemoryInjector.buildInjectionSplit(
                memories: memories.filter { !pinnedIds.contains($0.id) }, cards: cardRetrievers, recentMessages: recentMessages,
                budget: max(0, remaining - decision.selected.reduce(0) { $0 + $1.tokenCost }), now: now)
            fragmentHits = fragments.hits
            if !fragments.volatile.isEmpty {
                if !volatile.isEmpty { volatile += "\n\n" }
                volatile += fragmentHeader + "\n" + fragments.volatile
                // 只旁录实际拼进 volatile 的项：内层 stable 命中不在这段 wire 上，内层过期提醒单列
                for line in fragments.volatileLines {
                    guard let memoryId = line.memoryId else {
                        units.append(RecallDeliveryUnit(
                            kind: RecallDeliveryItem.Kind.expiredReminder, ref: "expired", text: line.text,
                            tokens: Memory.estimateTokens(line.text), shown: "已过期 \(line.expiredIds.count) 项",
                            members: line.expiredIds.map(\.uuidString), segment: .memoryVolatile))
                        continue
                    }
                    guard let memory = memoryById[memoryId.uuidString] else { continue }
                    let ref = memoryRef(memory)
                    units.append(RecallDeliveryUnit(
                        kind: RecallDeliveryItem.Kind.legacyFragment, ref: MemoryDelivery.key(ref),
                        version: ref.version, text: line.text, tokens: Memory.estimateTokens(line.text),
                        shown: String(memory.lineText.prefix(60)), segment: .memoryVolatile))
                }
            }
        }
        return (decision, RecallMemoryLayers(stable: stableParts.joined(separator: "\n\n"),
                                             volatile: volatile,
                                             hits: stableHits + fragmentHits, pages: selectedPages,
                                             units: units))
    }
}

/// 一层楼这一版语料的词面：词的分量（页 + 没整理进页的卡）和每张卡自己的词
private struct RecallCorpus {
    let weights: RecallTokenWeights
    let fragmentTokens: [String: Set<String>]
}

/// Bounded cache keyed by the public corpus versions, not query text or other floors' contents.
private final class RecallCorpusCache: @unchecked Sendable {
    static let shared = RecallCorpusCache()
    private let lock = NSLock()
    private var entries: [String: RecallCorpus] = [:]

    func corpus(profileId: String, signature: String, tuning: RecallTuning, build: () -> RecallCorpus) -> RecallCorpus {
        let key = profileId + "\u{0}" + "\(tuning.minimumHanTermLength)|\(tuning.minimumLatinTermLength)" + "\u{0}" + signature
        if let found = lock.withLock({ entries[key] }) { return found }
        let result = build()
        lock.withLock {
            if entries.count >= 16 { entries.removeAll(keepingCapacity: true) }
            entries[key] = result
        }
        return result
    }
}
