import MemoryCore
import Foundation
import SwiftData

/// 本地重放的执行壳：楼层安装（只写 `Memory` 表）+ 轮次重放 + 快照源。
/// 纯函数 / 护栏 / 偏好隔离在包里（`MemoryCore.Services.MemoryBench`）。
extension MemoryBenchLocalExecutor {
    private struct OfflineEmbedder: MemoryEmbedding {
        var isReady: Bool { false }
        var revision: Int { 0 }
        func embed(_ text: String) -> [Float]? { nil }
    }

    static func execute(testCase: MemoryBenchCase, recipe: MemoryBenchRecipe, bundle: Bundle = .main) async throws -> String {
        let task = Task.detached {
            let input = try testCase.input.decode(MemoryBenchRecallInput.self)
            if input.snapshot == "floor" { throw Failure("本楼层快照还没接上，先用内置 24 题") }
            guard !input.turns.isEmpty, TimeZone(identifier: input.profile.timeZone) != nil else { throw Failure("轮序或时区无效") }
            // execute currently has no calendar injection. Never change process-global timezone during concurrent cells.
            guard input.profile.timeZone == Calendar.current.timeZone.identifier else {
                throw Failure("recall 工具只接受宿主时区 \(Calendar.current.timeZone.identifier)，无法隔离重放 \(input.profile.timeZone)")
            }
            let (floor, variant) = try MemoryBenchRecallFloor.load(input.snapshot, in: bundle)
            let token = UUID().uuidString
            let pid = "memory-bench-\(token)"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(pid, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = preferencesSuite(named: pid)
            guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("隔离偏好不可用") }
            defer { removePreferences(defaults, suite: suite) }
            defaults.set(variant.master, forKey: "mem_master")
            defaults.set(true, forKey: MemoryOpenWindow.cKey)
            defaults.set(false, forKey: MemoryOpenWindow.b4Key)
            defaults.set(true, forKey: "mem_inject_keyword")
            defaults.set(false, forKey: "mem_inject_full")
            defaults.set(false, forKey: "mem_inject_vector")
            defaults.set(false, forKey: "mem_inject_graph")
            defaults.set(false, forKey: "mem_inject_catalog")
            defaults.set(variant.budget, forKey: "mem_inject_budget")
            let tuning = try MemoryBenchJSON.object(recipe.params).decode(RecallTuning.self).validated
            RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
            let container = try ModelContainer(for: Memory.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
            try install(floor, profileId: pid, container: container, root: root, wiki: wiki)
            CatalogRecallIndexer.shared.ensure(profileId: pid, wiki: wiki)
            do {
                try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
                let result = try await MemoryReadEnvironment.$preferences.withValue(.init(defaults)) {
                    try await replay(input, floor: floor, variant: variant, profileId: pid, container: container,
                                     root: root, wiki: wiki, defaults: defaults, tuning: tuning)
                }
                CatalogRecallIndexer.shared.deleteProfile(pid, wiki: wiki)
                try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
                let output = String(decoding: try MemoryBench.lineEncoder.encode(result), as: UTF8.self)
                return output.replacingOccurrences(of: pid, with: "bench-xingyan")
            } catch {
                CatalogRecallIndexer.shared.deleteProfile(pid, wiki: wiki)
                try? await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func install(_ floor: MemoryBenchRecallFloor, profileId: String, container: ModelContainer, root: URL, wiki: WikiStore) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // 文件半边在包里；这里只补 X 半边（`Memory` 行是 SwiftData，包不碰）
        try floor.installFiles(root: root, wiki: wiki)
        for (i, fragment) in floor.fragments.enumerated() {
            let memory = Memory(content: fragment.text, category: "fact", keywords: [fragment.subject], profileId: profileId,
                                isUserExplicit: fragment.pinned, extractedBy: "fictional", sourceConversationId: fragment.conversationId)
            memory.id = fragment.id
            memory.sourceNodeId = fragment.nodeId
            memory.subject = fragment.subject
            memory.occurredDay = "2026-10-31"
            memory.createdAt = floor.now.addingTimeInterval(Double(i))
            memory.updatedAt = memory.createdAt
            memory.lastAccessedAt = memory.createdAt
            memory.reviewedAt = fragment.reviewed ? floor.now : nil
            memory.supersededAt = fragment.superseded ? floor.now : nil
            context.insert(memory)
        }
        try context.save()
    }

    private static func replay(_ input: MemoryBenchRecallInput, floor: MemoryBenchRecallFloor, variant: MemoryBenchRecallFloor.Variant,
                               profileId: String, container: ModelContainer, root: URL, wiki: WikiStore,
                               defaults: UserDefaults, tuning: RecallTuning) async throws -> MemoryBenchRecallOutput {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let profile = Profile(id: profileId, name: "星砚虚构楼层", emoji: "", description: "", userName: input.profile.userName, assistantName: input.profile.assistantName)
        let snapshot = WikiInjection.load(wiki)
        let cid = variant.currentConversationId ?? "bench-current-window"
        let windowOn = floor.windows.first { $0.id == cid }.map { $0.memoryEnabled && !$0.trashed } ?? true
        // 夹具窗 → 包里的隐藏集规则（一处算）：已删 / 关参与窗里出的碎片不进 X（plan-memory-participation §2.4）
        let hiddenSources = EffectiveMemoryParticipation.hiddenSources(floor.windows.map {
            ConversationWindow(id: $0.id, profileId: profileId, title: $0.title,
                               createTime: floor.now, updateTime: floor.now,
                               isTrashed: $0.trashed, memoryEnabled: $0.memoryEnabled)
        })
        let legacy = MemoryWindowChoices.legacy(profileId: profileId, defaults: defaults)
        let participation = EffectiveMemoryParticipation(.init(
            master: variant.master, window: windowOn, slot: true, choices: nil,
            legacy: legacy.participationChoices,
            a2Checked: MemoryOpenWindow.isChecked(.a2, profileId: profileId, defaults: defaults),
            archiveTrigger: tuning.archiveTriggerEnabled))
        var state = RecallConversationState()
        var turns: [MemoryBenchRecallOutput.Turn] = []
        var previous: RecallTool.ExecResult?
        var calls = 0
        var guardrail = MemoryBenchRecallOutput.Guard()
        let forbidden = Forbidden(floor)
        for (index, turn) in input.turns.enumerated() {
            try Task.checkCancellation()
            var fullText: RecallFullTextCandidates?
            if participation.fullText {
                fullText = await RecallFullTextRetriever.fetch(profileId: profileId, text: turn.text, snapshot: snapshot,
                    excluding: { [input.profile.userName, input.profile.assistantName] }, tuning: tuning, source: { wiki }, indexer: .shared,
                    timeout: 60, keeping: (state.active + state.pending).map(\.source).filter { $0.kind == .card })
            }
            let inputs = MemoryInjector.roundInputs(profileId: profileId, participation: participation, store: SwiftDataMemoryStore(), context: context,
                wikiStore: wiki, warmedWiki: .init(generation: 0, snapshot: snapshot, fullText: fullText), useCachedWiki: false,
                hiddenSources: hiddenSources)
            let selection = RecallSelection.prepare(profile: profile, conversationId: cid, turnId: "turn:\(index + 1)", branchAnchor: "bench-branch",
                text: turn.text, state: state, existingDecision: nil, inputs: inputs, recentMessages: input.turns.prefix(index + 1).map(\.text),
                now: floor.now, tuning: tuning, enabled: participation.on)
            let decision = selection.decision
            state = decision.stateAfterResponse
            var sources = selection.layers.pages.map { MemoryBenchRecallOutput.Source(source: "page:\($0.page.path)|\($0.page.version)", layer: "wiki页") }
            sources += decision.selected.filter { $0.source.kind == .card }.map { .init(source: "card:\($0.source.path)|\($0.source.version)", layer: "L1") }
            let stableRetrievers = Set(MemoryInjector.activeRetrievers().filter { $0.layer == .stable }.map(\.id))
            sources += selection.layers.hits.filter { !stableRetrievers.contains($0.retrieverId) }
                .map { .init(source: "memory:\($0.memoryId.uuidString)", layer: "L1") }
            sources.sort { $0.source < $1.source }
            var reasons: [String: String] = [:]
            for suppression in decision.suppressions {
                let ref = suppression.source
                let key = ref.kind == .fragment ? "memory:\(ref.path)" : "\(ref.kind.rawValue):\(ref.path)|\(ref.version)"
                reasons[key] = suppression.reason == .cooldown ? "冷却" : suppression.reason == .budget || suppression.reason == .pageLimit ? "预算" : "无资料"
            }
            for page in floor.pages where !page.approved {
                if let raw = page.versions.last { reasons["page:\(page.path)|\(WikiStore.version(of: Data(raw.utf8)))"] = "未批" }
            }
            let reason = decision.gateReason == .shortInput ? "门槛" : decision.gateReason == .disabled ? "关闭" : decision.gateReason == .kept ? "保持" :
                fullText?.hits.isEmpty == false && sources.isEmpty ? "门槛" : sources.isEmpty ? "无资料" : "搜索"
            var reads: [MemoryBenchRecallOutput.Y] = []
            var turnCalls = 0
            for operation in turn.ops ?? [] {
                try Task.checkCancellation()
                calls += 1
                turnCalls += 1
                if turnCalls > tuning.maximumRecallCalls {
                    reads.append(.init(op: operation.op, layer: reads.last?.layer ?? "原文", status: "limited", target: "", sourceVersion: nil,
                                       returnedRange: [], next: .init(hasMore: false, cursorIssued: false), deepest: nil))
                    continue
                }
                let resolved = try resolve(.object(operation.args), previous: previous)
                guard case .object(var args) = resolved else { throw Failure("调用参数不是对象") }
                args["op"] = .string(operation.op)
                let json = String(decoding: try MemoryBench.lineEncoder.encode(MemoryBenchJSON.object(args)), as: UTF8.self)
                let requested = try RecallTool.decoder.decode(RecallTool.Input.self, from: Data(json.utf8))
                let before = requested.cursor.flatMap(RecallTool.decodeCursor)
                let result = await RecallTool.execute(inputJSON: json, profileId: profileId, currentConversationId: cid,
                    userName: input.profile.userName, assistantName: input.profile.assistantName,
                    source: floor.conversationSource(profileId: profileId), memoryRoot: root,
                    defaults: defaults, tuning: tuning, memoryParticipation: participation.participates,
                    environment: RecallTool.l1Environment(container: container, embedder: OfflineEmbedder()))
                observe(result, requested: before?.input ?? requested, floor: floor, forbidden: forbidden, guardrail: &guardrail)
                if let read = result.read {
                    let actual = !result.isError && !(read.returnedRange ?? []).isEmpty
                    // Index revisions include the runtime profile ID. Persist its canonical source identity, not that random salt.
                    let version = read.layer == "wiki索引"
                        ? RecallTool.revision(RecallTool.json(result.targets).replacingOccurrences(of: profileId, with: "bench-xingyan"))
                        : read.sourceVersion
                    let after = result.cursor.flatMap(RecallTool.decodeCursor)
                    let bounds = rangeBounds(read.returnedRange ?? [], op: operation.op, before: before, after: after, floor: floor)
                    reads.append(.init(op: operation.op, layer: read.layer, status: read.status, target: read.target, sourceVersion: version,
                        returnedRange: read.returnedRange, next: read.next, deepest: actual ? read.layer : nil,
                        continuation: requested.cursor != nil, start: position(before), end: after.map(position),
                        rangeStart: bounds?.0, rangeEnd: bounds?.1, targets: result.targets))
                }
                previous = result
            }
            if leaks(selection.layers.stable + selection.layers.volatile, forbidden: forbidden) { guardrail.privacyLeak = true }
            turns.append(.init(x: .init(searched: decision.gateReason == .search, kept: decision.gateReason == .kept,
                reason: reason, sources: sources, reasons: reasons, path: decision.tuning.archiveTriggerEnabled ? "x" : "legacy",
                fullText: fullText?.status.state.rawValue), y: reads))
        }
        return .init(turns: turns, deepestLayer: MemoryBenchRecallOutput.deepest(turns.flatMap(\.y)), calls: calls, guardrail: guardrail)
    }
}
