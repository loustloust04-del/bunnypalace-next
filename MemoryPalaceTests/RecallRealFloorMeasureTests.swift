import MemoryCore
import XCTest
@testable import 记忆花园

/// 真数据量级测量（不调模型，只出数量）：把本机一份真实楼层快照里她说过的每句话，按窗口、按先后重放给
/// `RecallSelection.prepare`（聊天实发用的同一个函数），数「聊到了才带」在默认参数下一轮带进几张记忆条目、多少 token。
///
/// 默认跳过。跑法：
/// `TEST_RUNNER_MP_RECALL_FLOOR_DIR=<快照的 exports 目录> TEST_RUNNER_MP_RECALL_MEASURE_OUT=<结果.json> xcodebuild test … -only-testing:MemoryPalaceTests/RecallRealFloorMeasureTests`
/// （可选 `TEST_RUNNER_MP_RECALL_NAMES_FILE`：她和助手在那层楼的名字，见下）
/// 全量跑一遍约 17 分钟（1.7 万句 × 三趟）；只想看耗时加 `TEST_RUNNER_MP_RECALL_MEASURE_MAX_TURNS=3000`。
/// 目录里要有 `floor-snapshot-*.json`（`FloorSnapshot`）和 `fragments.json`（那层楼的卡）。
/// 结果只有数字：不打印、不落盘任何正文、标题、名字。
final class RecallRealFloorMeasureTests: XCTestCase {
    private struct Card: Decodable {
        let content: String
        let category: String
        let conversationId: String
        let day: String
        let importance: Int?
        let organized: Bool
        let reviewed: Bool
        let sourceNodeId: String
        let subject: String?
    }

    private struct Turn {
        let id: String
        let text: String
        let at: Date
    }

    private struct Window {
        let id: String
        let isCC: Bool
        let turns: [Turn]
    }

    /// 一种口径的结果（全是数量）
    private struct Tally: Encodable {
        var windows = 0
        var turns = 0
        var gateShort = 0
        var gateKept = 0
        var gateSearch = 0
        /// 带了至少一张卡的轮数
        var turnsWithCards = 0
        /// 各轮带的卡数之和（同一张卡在话题保持的几轮里各算一次）
        var cardInstances = 0
        var maxCardsInTurn = 0
        var turnsByCardCount: [String: Int] = [:]
        var volatileTokens = 0
        var maxVolatileTokens = 0
        /// 这一轮新找到的卡里：词面对上的 / 点名的；话题没换接着带的
        var lexicalInstances = 0
        var namedInstances = 0
        var carriedInstances = 0
        /// 带的卡里来源窗口就是当前窗口的
        var sameWindowInstances = 0
        /// 够格但被「一轮最多几张卡」挡下的
        var overCap = 0
        var turnsOverCap = 0
        /// 至少被带过一次的不同的卡
        var distinctCards = 0
        var candidateCards = 0
        /// 卡的目录（每轮都在的那一段）最多多少 token
        var cardIndexTokens = 0
        /// 只看词面这一条规则、不过上限 / 冷却 / 话题保持时的原始命中（过了「太短的不找」的轮次里）：
        /// strict = 这句话所有的词都算分母；corpusOnly = 只算卡里出现过的词
        var rawTurns = 0
        var rawStrictTurnsWithHit = 0
        var rawStrictHits = 0
        var rawCorpusOnlyTurnsWithHit = 0
        var rawCorpusOnlyHits = 0
        var rawNamedTurnsWithHit = 0
        var rawNamedHits = 0
        /// 挑选这一步（`RecallSelection.prepare`）本身花的时间
        var selectSeconds = 0.0
        var slowestSelectMilliseconds = 0.0
        /// 这一句超过 2000 字的轮数（整段贴进来的）
        var longTurns = 0

        mutating func add(_ other: Tally) {
            windows += other.windows; turns += other.turns
            gateShort += other.gateShort; gateKept += other.gateKept; gateSearch += other.gateSearch
            turnsWithCards += other.turnsWithCards; cardInstances += other.cardInstances
            maxCardsInTurn = max(maxCardsInTurn, other.maxCardsInTurn)
            turnsByCardCount.merge(counts: other.turnsByCardCount)
            volatileTokens += other.volatileTokens; maxVolatileTokens = max(maxVolatileTokens, other.maxVolatileTokens)
            lexicalInstances += other.lexicalInstances; namedInstances += other.namedInstances; carriedInstances += other.carriedInstances
            sameWindowInstances += other.sameWindowInstances
            overCap += other.overCap; turnsOverCap += other.turnsOverCap
            cardIndexTokens = max(cardIndexTokens, other.cardIndexTokens)
            rawTurns += other.rawTurns
            rawStrictTurnsWithHit += other.rawStrictTurnsWithHit; rawStrictHits += other.rawStrictHits
            rawCorpusOnlyTurnsWithHit += other.rawCorpusOnlyTurnsWithHit; rawCorpusOnlyHits += other.rawCorpusOnlyHits
            rawNamedTurnsWithHit += other.rawNamedTurnsWithHit; rawNamedHits += other.rawNamedHits
            selectSeconds += other.selectSeconds
            slowestSelectMilliseconds = max(slowestSelectMilliseconds, other.slowestSelectMilliseconds)
            longTurns += other.longTurns
        }
    }

    private func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    func testMeasureCardsBroughtPerTurnOnRealFloor() throws {
        guard let directory = environment("MP_RECALL_FLOOR_DIR") else {
            throw XCTSkip("没给 MP_RECALL_FLOOR_DIR：真数据测量默认不跑")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let snapshotName = try XCTUnwrap(names.filter(FloorSnapshotExportFolder.isSnapshotFileName).sorted().last, "目录里没有 floor-snapshot-*.json")
        let floor = try JSONDecoder().decode(FloorSnapshot.self, from: Data(contentsOf: folder.appendingPathComponent(snapshotName)))
        let cards = try JSONDecoder().decode([Card].self, from: Data(contentsOf: folder.appendingPathComponent("fragments.json")))
        let profileId = try XCTUnwrap(floor.profileId ?? floor.windows.first?.profileId, "快照里没有楼层编号")

        // 她和助手在这层楼的名字（聊天时这两个名字不触发）不进仓库也不打印：
        // 给了 MP_RECALL_NAMES_FILE（本机一份 {"user":…,"assistant":…}）就用它；没给就取卡上「说的是谁」出现最多的两个
        struct Names: Decodable { let user: String; let assistant: String }
        let subjects = Dictionary(grouping: cards.compactMap(\.subject).filter { !$0.isEmpty }, by: { $0 })
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }.map(\.key)
        let given = try environment("MP_RECALL_NAMES_FILE").map {
            try JSONDecoder().decode(Names.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }
        let profile = Profile(id: profileId, name: "", emoji: "", description: "",
                              userName: given?.user ?? subjects.first ?? "",
                              assistantName: given?.assistant ?? subjects.dropFirst().first ?? "")

        let source = SnapshotConversationSource(floor: floor)
        var nodeTime: [String: Date] = [:]
        var windows: [Window] = []
        for window in try source.windows(profileId: profileId, updatedSince: nil, includeTrashed: false) where window.memoryEnabled {
            let nodes = try source.nodes(profileId: profileId, conversationId: window.id)
            for node in nodes { if let at = node.createTime { nodeTime[node.id] = at } }
            let turns = visiblePath(window: window, nodes: nodes).compactMap { node -> Turn? in
                guard node.role == "user", !node.isSyntheticRoot, !node.isTrashed, node.sourceVisibility == nil,
                      node.contentType == "text", !node.content.isEmpty, let at = node.createTime else { return nil }
                return Turn(id: node.id, text: node.content, at: at)
            }
            if !turns.isEmpty { windows.append(Window(id: window.id, isCC: window.isCC, turns: turns)) }
        }
        // 回收站里的窗口上面没取节点：卡的来源消息时间另从快照原件里补
        for window in floor.windows { for node in window.nodes { if let at = node.at, nodeTime[node.id] == nil { nodeTime[node.id] = at } } }

        // 只想快速看耗时：MP_RECALL_MEASURE_MAX_TURNS 给每一趟封个顶（到了就不再开新窗口）
        let turnLimit = environment("MP_RECALL_MEASURE_MAX_TURNS").flatMap(Int.init) ?? .max

        func memories(_ selected: [Card]) -> [(memory: Memory, born: Date?)] {
            selected.map { card in
                let memory = Memory(content: card.content, category: card.category, profileId: profileId,
                                    extractedBy: "measure", sourceConversationId: card.conversationId)
                memory.sourceNodeId = card.sourceNodeId
                memory.subject = card.subject
                memory.importance = card.importance
                memory.occurredDay = card.day
                let born = nodeTime[card.sourceNodeId]
                memory.createdAt = born ?? .distantPast
                memory.updatedAt = memory.createdAt
                memory.reviewedAt = memory.createdAt
                // 整理进页的卡生产上不走 X3（由页带）；快照里没有页，这里只按同样的规则把它们排除
                memory.organizedPage = card.organized ? "整理/已进页" : nil
                return (memory, born)
            }
        }

        /// 一趟重放出两份：全部窗口、只算走 API 的窗口
        func run(_ pool: [(memory: Memory, born: Date?)], causal: Bool, raw: Bool) -> (all: Tally, api: Tally) {
            var total = Tally()
            var apiOnly = Tally()
            var seenAll = Set<String>()
            var seenAPI = Set<String>()
            let tuning = RecallTuning.defaults
            let blocked = Set([profile.userName, profile.assistantName].map(RecallLexical.normalized))
            let rawDocuments = !raw ? [] : pool.map(\.memory).filter { $0.organizedPage == nil }.map { memory in
                RecallFragmentDocument(id: memory.id.uuidString,
                                       tokens: RecallFullText.fragmentTokens(([memory.content] + memory.keywords).joined(separator: "\n"), tuning: tuning),
                                       identities: [memory.subject].compactMap { $0 }.filter { !$0.isEmpty && !blocked.contains(RecallLexical.normalized($0)) },
                                       priority: memory.recallPriority, createdAt: memory.createdAt)
            }
            let rawWeights = RecallTokenWeights(tokenDocuments: rawDocuments.map(\.tokens))
            for window in windows where total.turns < turnLimit {
              var tally = Tally()
              var seen = Set<String>()
              autoreleasepool {
                tally.windows += 1
                var state = RecallConversationState()
                for turn in window.turns {
                    // causal：只有来源消息早于这一句的卡才算「那时已经记下」；来源消息没时间的不算
                    let available = causal ? pool.filter { ($0.born ?? .distantFuture) < turn.at }.map(\.memory) : pool.map(\.memory)
                    let inputs = MemoryInjector.RoundInputs(memories: available, selfMemory: nil, archiveBudget: MemoryInjector.tokenBudget)
                    let started = Date()
                    let result = RecallSelection.prepare(profile: profile, conversationId: window.id, turnId: turn.id, branchAnchor: "measure",
                                                         text: turn.text, state: state, existingDecision: nil, inputs: inputs,
                                                         recentMessages: [turn.text], now: turn.at, tuning: tuning)
                    let spent = Date().timeIntervalSince(started)
                    tally.selectSeconds += spent
                    tally.slowestSelectMilliseconds = max(tally.slowestSelectMilliseconds, spent * 1000)
                    if turn.text.count > 2000 { tally.longTurns += 1 }
                    state = result.decision.stateAfterResponse
                    tally.turns += 1
                    switch result.decision.gateReason {
                    case .shortInput: tally.gateShort += 1
                    case .kept: tally.gateKept += 1
                    case .search: tally.gateSearch += 1
                    case .disabled: break
                    }
                    let brought = result.decision.selected.filter { $0.source.kind == .fragment }
                    tally.turnsByCardCount[String(brought.count), default: 0] += 1
                    let over = result.decision.suppressions.filter { $0.reason == .pageLimit && $0.source.kind == .fragment }.count
                    tally.overCap += over
                    if over > 0 { tally.turnsOverCap += 1 }
                    tally.cardIndexTokens = max(tally.cardIndexTokens, Memory.estimateTokens(result.layers.stable))
                    if !rawDocuments.isEmpty, result.decision.gateReason != .shortInput {
                        tally.rawTurns += 1
                        for corpusOnly in [false, true] {
                            let hits = RecallFullText.fragmentHits(text: turn.text, documents: rawDocuments, weights: rawWeights,
                                                                   excluding: [profile.userName, profile.assistantName], tuning: tuning,
                                                                   corpusTermsOnly: corpusOnly)
                            let lexical = hits.filter { $0.match == .lexical }.count
                            if corpusOnly {
                                tally.rawCorpusOnlyHits += lexical
                                if lexical > 0 { tally.rawCorpusOnlyTurnsWithHit += 1 }
                            } else {
                                tally.rawStrictHits += lexical
                                if lexical > 0 { tally.rawStrictTurnsWithHit += 1 }
                                let named = hits.count - lexical
                                tally.rawNamedHits += named
                                if named > 0 { tally.rawNamedTurnsWithHit += 1 }
                            }
                        }
                    }
                    guard !brought.isEmpty else { continue }
                    let tokens = Memory.estimateTokens(result.layers.volatile)
                    tally.turnsWithCards += 1
                    tally.cardInstances += brought.count
                    tally.maxCardsInTurn = max(tally.maxCardsInTurn, brought.count)
                    tally.volatileTokens += tokens
                    tally.maxVolatileTokens = max(tally.maxVolatileTokens, tokens)
                    let byId = Dictionary(available.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
                    for item in brought {
                        seen.insert(item.source.path)
                        if byId[item.source.path]?.sourceConversationId == window.id { tally.sameWindowInstances += 1 }
                    }
                    for hit in result.layers.hits {
                        switch hit.retrieverId {
                        case "keyword": tally.lexicalInstances += 1
                        case "named": tally.namedInstances += 1
                        case "active": tally.carriedInstances += 1
                        default: break
                        }
                    }
                }
              }
              total.add(tally)
              seenAll.formUnion(seen)
              if !window.isCC {
                  apiOnly.add(tally)
                  seenAPI.formUnion(seen)
              }
              print("RECALL-MEASURE-PROGRESS windows \(total.windows)/\(windows.count) turns \(total.turns)")
            }
            total.distinctCards = seenAll.count
            apiOnly.distinctCards = seenAPI.count
            total.candidateCards = pool.filter { $0.memory.organizedPage == nil }.count
            apiOnly.candidateCards = total.candidateCards
            return (total, apiOnly)
        }

        let everything = memories(cards)
        let reviewedOnly = memories(cards.filter(\.reviewed))
        // 「全量带」的对照：不筛选时这些卡一共多少 token（注入预算内能装多少是另一回事）
        let fullTokens = everything.filter { $0.memory.organizedPage == nil }.reduce(0) {
            $0 + MemoryInjector.injectionPayload($1.memory, stable: false, catalog: false, now: Date()).cost
        }
        struct Report: Encodable {
            var cardsInExport: Int
            var cardsReviewedInExport: Int
            var cardsOrganizedInExport: Int
            var cardsWithSubject: Int
            var cardsWhoseSubjectIsAParticipant: Int
            var distinctSubjects: Int
            var allCandidatesTokensIfBroughtWhole: Int
            var runs: [String: Tally]
        }
        let participants = Set([profile.userName, profile.assistantName].map(RecallLexical.normalized))
        var report = Report(
            cardsInExport: cards.count, cardsReviewedInExport: cards.filter(\.reviewed).count,
            cardsOrganizedInExport: cards.filter(\.organized).count,
            cardsWithSubject: cards.filter { !($0.subject ?? "").isEmpty }.count,
            cardsWhoseSubjectIsAParticipant: cards.filter { participants.contains(RecallLexical.normalized($0.subject ?? "\u{0}")) }.count,
            distinctSubjects: Set(cards.compactMap(\.subject).filter { !$0.isEmpty }).count,
            allCandidatesTokensIfBroughtWhole: fullTokens,
            runs: [:])
        let causal = run(everything, causal: true, raw: false)
        report.runs["allApproved.causal"] = causal.all
        report.runs["allApproved.causal.apiWindows"] = causal.api
        let today = run(everything, causal: false, raw: true)
        report.runs["allApproved.today"] = today.all
        report.runs["allApproved.today.apiWindows"] = today.api
        report.runs["reviewedOnly.today"] = run(reviewedOnly, causal: false, raw: false).all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let out = environment("MP_RECALL_MEASURE_OUT") { try data.write(to: URL(fileURLWithPath: out)) }
        print("RECALL-MEASURE " + String(decoding: data, as: UTF8.self))
    }
}

private extension Dictionary where Key == String, Value == Int {
    mutating func merge(counts other: [String: Int]) {
        for (key, value) in other { self[key, default: 0] += value }
    }
}
