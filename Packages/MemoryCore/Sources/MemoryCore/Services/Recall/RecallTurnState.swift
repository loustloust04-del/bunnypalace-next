import Foundation
import NaturalLanguage

public struct RecallItem: Codable, Equatable, Sendable {
    public let source: RecallSourceRef
    /// Exact rendered block sent to the provider, not a subsequently reconstructed snippet.
    public let text: String
    public let identities: [String]
    public let tokenCost: Int

    public init(source: RecallSourceRef, text: String, identities: [String], tokenCost: Int) {
        self.source = source
        self.text = text
        self.identities = identities
        self.tokenCost = tokenCost
    }
}

public struct RecallCooldown: Codable, Equatable, Sendable {
    public let source: RecallSourceRef
    public let untilTurn: Int
    /// Public identities captured with the ignored push, so explicit thaw is independent of ranking/budget.
    public var identities: [String]? = nil

    public init(source: RecallSourceRef, untilTurn: Int, identities: [String]? = nil) {
        self.source = source
        self.untilTurn = untilTurn
        self.identities = identities
    }
}

public struct RecallConversationState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var effectiveTurn = 0
    public var branchAnchor = ""
    public var topicAnchor = ""
    public var active: [RecallItem] = []
    /// Only actual pushes without subsequent continuation evidence are observed.
    public var pending: [RecallItem] = []
    public var cooldowns: [RecallCooldown] = []
    public var lastAppliedTurnId: String? = nil

    public init(schemaVersion: Int = 1, effectiveTurn: Int = 0, branchAnchor: String = "", topicAnchor: String = "",
                active: [RecallItem] = [], pending: [RecallItem] = [], cooldowns: [RecallCooldown] = [],
                lastAppliedTurnId: String? = nil) {
        self.schemaVersion = schemaVersion
        self.effectiveTurn = effectiveTurn
        self.branchAnchor = branchAnchor
        self.topicAnchor = topicAnchor
        self.active = active
        self.pending = pending
        self.cooldowns = cooldowns
        self.lastAppliedTurnId = lastAppliedTurnId
    }
}

public struct RecallSuppression: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case cooldown, unavailable, budget, pageLimit }
    public let source: RecallSourceRef
    public let reason: Reason

    public init(source: RecallSourceRef, reason: Reason) {
        self.source = source
        self.reason = reason
    }
}

public struct RecallTurnDecision: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case user, continuation }
    public enum GateReason: String, Codable, Sendable { case disabled, shortInput, search, kept }
    public let turnId: String
    public let branchAnchor: String
    public let origin: Origin
    public let gateReason: GateReason
    public let tuning: RecallTuning
    public let topicAnchor: String
    public let selected: [RecallItem]
    public let candidates: [RecallItem]
    public let suppressions: [RecallSuppression]
    public let ignored: [RecallSourceRef]
    public let thawed: [RecallSourceRef]
    /// Proposal only. Preparing or displaying it never mutates the conversation.
    public let stateAfterResponse: RecallConversationState

    public init(turnId: String, branchAnchor: String, origin: Origin, gateReason: GateReason, tuning: RecallTuning,
                topicAnchor: String, selected: [RecallItem], candidates: [RecallItem], suppressions: [RecallSuppression],
                ignored: [RecallSourceRef], thawed: [RecallSourceRef], stateAfterResponse: RecallConversationState) {
        self.turnId = turnId
        self.branchAnchor = branchAnchor
        self.origin = origin
        self.gateReason = gateReason
        self.tuning = tuning
        self.topicAnchor = topicAnchor
        self.selected = selected
        self.candidates = candidates
        self.suppressions = suppressions
        self.ignored = ignored
        self.thawed = thawed
        self.stateAfterResponse = stateAfterResponse
    }

    /// Delivery may retain only a prefix on the local route; candidates remain the selection proposal.
    public func recordingDelivery(_ delivered: [RecallItem]) -> Self {
        var after = stateAfterResponse
        if gateReason == .search || gateReason == .kept {
            let pending = Set(after.pending.map(\.source))
            after.active = delivered
            after.pending = delivered.filter { pending.contains($0.source) }
        }
        return Self(turnId: turnId, branchAnchor: branchAnchor, origin: origin, gateReason: gateReason,
                    tuning: tuning, topicAnchor: topicAnchor, selected: delivered, candidates: candidates,
                    suppressions: suppressions, ignored: ignored, thawed: thawed, stateAfterResponse: after)
    }
}

public enum RecallAttemptStatus: String, Codable, Sendable {
    case prepared, submitted, responded, interrupted, failed, cancelled
}

public struct RecallAttempt: Codable, Equatable, Sendable {
    public let id: String
    public var status: RecallAttemptStatus
    public var receivedResponse = false
    /// 本 attempt 对应的 delivery id；nil = v1 旧账 / CC
    public var deliveryId: String? = nil

    public init(id: String, status: RecallAttemptStatus, receivedResponse: Bool = false, deliveryId: String? = nil) {
        self.id = id
        self.status = status
        self.receivedResponse = receivedResponse
        self.deliveryId = deliveryId
    }
}

public struct RecallReadReceipt: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let turnId: String
    public let layer: String
    public let target: String
    public var sourceVersion: String? = nil
    public var status: String = "success"
    /// 实际返回的 Target 范围；日期按首末日（含），wiki 按实际记录行，A 原文按 from…last。
    public var returnedRange: [RecallTool.Target]? = nil
    public var next: Next? = nil
    /// 本页实际返回条数；失败 = 0，nil = 旧账
    public var returnedCount: Int? = nil
    /// 仅关闭拒绝：`"master"` / `"window"`；其余 nil
    public var gate: String? = nil

    public init(toolCallId: String, turnId: String, layer: String, target: String, sourceVersion: String? = nil,
                status: String = "success", returnedRange: [RecallTool.Target]? = nil, next: Next? = nil,
                returnedCount: Int? = nil, gate: String? = nil) {
        self.toolCallId = toolCallId
        self.turnId = turnId
        self.layer = layer
        self.target = target
        self.sourceVersion = sourceVersion
        self.status = status
        self.returnedRange = returnedRange
        self.next = next
        self.returnedCount = returnedCount
        self.gate = gate
    }

    public struct Next: Codable, Equatable, Sendable {
        public let hasMore: Bool
        public let cursorIssued: Bool

        public init(hasMore: Bool, cursorIssued: Bool) {
            self.hasMore = hasMore
            self.cursorIssued = cursorIssued
        }
    }

}

public struct RecallTurnReceipt: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var decision: RecallTurnDecision
    public var attempts: [RecallAttempt] = []
    public var reads: [RecallReadReceipt] = []
    public var injectionRecord: MemoryInjectionRecord? = nil
    /// nil = v1 旧账 / user 节点上的非 CC 回执
    public var delivery: RecallDelivery? = nil
    /// 新建回复回执时一次性写（重生成 / `/trigger` / 贴表情）；之后不变
    public var inheritedEffective: Bool? = nil

    public init(decision: RecallTurnDecision) { self.decision = decision }

    @discardableResult
    public mutating func beginAttempt(id: String = UUID().uuidString, deliveryId: String? = nil) -> String {
        guard !attempts.contains(where: { $0.id == id }) else { return id }
        attempts.append(RecallAttempt(id: id, status: .prepared, deliveryId: deliveryId))
        return id
    }

    public mutating func markAttempt(_ id: String, status: RecallAttemptStatus) {
        guard let i = attempts.firstIndex(where: { $0.id == id }) else { return }
        // A terminal callback before the first event is not evidence of an effective send.
        // Only recordResponse is permitted to establish that fact.
        guard status != .responded else { return }
        if attempts[i].receivedResponse && (status == .cancelled || status == .failed) {
            attempts[i].status = .interrupted
        } else {
            attempts[i].status = status
        }
    }

    public mutating func finishAttempt(id: String, status: RecallAttemptStatus) {
        markAttempt(id, status: status)
    }

    /// Called for the first effective content/tool-call event, not HTTP headers or thinking.
    @discardableResult
    public mutating func recordResponse(attemptId: String, state: inout RecallConversationState,
                                 currentTurnId: String, currentBranchAnchor: String, applyState: Bool = true) -> Bool {
        guard decision.turnId == currentTurnId, decision.branchAnchor == currentBranchAnchor,
              let i = attempts.firstIndex(where: { $0.id == attemptId }),
              attempts[i].status == .submitted || attempts[i].status == .responded else { return false }
        let alreadyEffective = hasEffectiveResponse
        attempts[i].receivedResponse = true
        attempts[i].status = .responded
        guard applyState, !alreadyEffective, state.lastAppliedTurnId != decision.turnId,
              state.effectiveTurn <= decision.stateAfterResponse.effectiveTurn else { return false }
        state = decision.stateAfterResponse
        return true
    }

    public var hasEffectiveResponse: Bool {
        attempts.contains(where: \.receivedResponse) || inheritedEffective == true
    }
}

public struct RecallTokenWeights: Equatable, Sendable {
    public let documentCount: Int
    public let frequencies: [String: Int]

    public init(documents: [String], tuning: RecallTuning) {
        self.init(tokenDocuments: documents.map { RecallLexical.tokens($0, tuning: tuning) })
    }

    public init(tokenDocuments: [Set<String>]) {
        documentCount = tokenDocuments.count
        var frequencies: [String: Int] = [:]
        for document in tokenDocuments {
            for token in document { frequencies[token, default: 0] += 1 }
        }
        self.frequencies = frequencies
    }

    public func weight(_ token: String) -> Double {
        log(Double(documentCount + 1) / Double((frequencies[token] ?? 0) + 1)) + 1
    }

    public func continues(_ text: String, anchor: String, active: [RecallItem], tuning: RecallTuning) -> Bool {
        if active.contains(where: { RecallLexical.names($0.identities, in: text, tuning: tuning) || RecallLexical.targets($0.source, in: text) }) { return true }
        let a = RecallLexical.tokens(text, tuning: tuning), b = RecallLexical.tokens(anchor, tuning: tuning)
        let shared = a.intersection(b)
        guard shared.count >= tuning.minimumSharedTerms else { return false }
        let denominator = min(a.reduce(0) { $0 + weight($1) }, b.reduce(0) { $0 + weight($1) })
        return denominator > 0 && shared.reduce(0, { $0 + weight($1) }) / denominator >= tuning.activeOverlapThreshold
    }
}

public enum RecallTurnState {
    /// The search closure is lazy: it is never called for skip, retain, or replay paths.
    public static func prepare(turnId: String, branchAnchor: String, text: String, state: RecallConversationState,
                        existingDecision: RecallTurnDecision? = nil, enabled: Bool = true,
                        tuning: RecallTuning, weights: @autoclosure () -> RecallTokenWeights, budget: Int,
                        resolve: (RecallItem) -> RecallItem?,
                        covers: (RecallItem, RecallItem) -> Bool = { _, _ in false },
                        search: ([RecallCooldown]) -> [RecallItem]) -> RecallTurnDecision {
        let tuning = existingDecision.flatMap { $0.turnId == turnId ? $0.tuning : nil } ?? tuning
        var state = state
        if state.branchAnchor != branchAnchor {
            state.branchAnchor = branchAnchor
            state.active = []
            state.pending = []
            state.topicAnchor = ""
        }
        var suppressions: [RecallSuppression] = []
        func validated(_ items: [RecallItem], cooldowns: [RecallCooldown], turn: Int, thawed: Set<RecallSourceRef>) -> [RecallItem] {
            var selected: [RecallItem] = []
            var used = 0
            var pages = 0
            var seen = Set<RecallSourceRef>()
            for item in items where seen.insert(item.source).inserted {
                guard let current = resolve(item), current.source == item.source else {
                    suppressions.append(.init(source: item.source, reason: .unavailable)); continue
                }
                if !thawed.contains(item.source), cooldowns.contains(where: { $0.source == item.source && $0.untilTurn >= turn }) {
                    suppressions.append(.init(source: item.source, reason: .cooldown)); continue
                }
                if selected.contains(where: { covers($0, current) }) { continue }
                let replaced = selected.filter { covers(current, $0) }
                let freed = replaced.reduce(0) { $0 + $1.tokenCost }
                let freedPages = replaced.filter { $0.source.kind != .fragment }.count
                let isPage = item.source.kind != .fragment
                if isPage && pages - freedPages >= tuning.maximumPages {
                    suppressions.append(.init(source: item.source, reason: .pageLimit)); continue
                }
                guard used - freed + current.tokenCost <= max(0, budget) else {
                    suppressions.append(.init(source: item.source, reason: .budget)); continue
                }
                selected.removeAll { covers(current, $0) }
                used -= freed
                pages -= freedPages
                selected.append(current)
                used += current.tokenCost
                if isPage { pages += 1 }
            }
            return selected
        }
        if !enabled || !tuning.archiveTriggerEnabled {
            var after = state
            after.active = []; after.pending = []; after.topicAnchor = ""
            after.lastAppliedTurnId = turnId
            return .init(turnId: turnId, branchAnchor: branchAnchor, origin: .user, gateReason: .disabled, tuning: tuning,
                         topicAnchor: "", selected: [], candidates: [], suppressions: [], ignored: [], thawed: [], stateAfterResponse: after)
        }
        if let old = existingDecision, old.turnId == turnId {
            let selected = validated(old.selected, cooldowns: [], turn: 0, thawed: [])
            var after = old.stateAfterResponse
            after.branchAnchor = branchAnchor
            if old.gateReason != .shortInput {
                after.active = selected
                let pendingRefs = Set(after.pending.map(\.source))
                after.pending = selected.filter { pendingRefs.contains($0.source) }
            }
            return .init(turnId: old.turnId, branchAnchor: branchAnchor, origin: .continuation, gateReason: old.gateReason, tuning: tuning,
                         topicAnchor: old.topicAnchor, selected: selected, candidates: old.candidates,
                         suppressions: old.suppressions + suppressions, ignored: old.ignored, thawed: old.thawed, stateAfterResponse: after)
        }
        if !RecallLexical.retrospective(text) && RecallLexical.meaningfulLength(text) < tuning.minimumEffectiveLength {
            var after = state
            after.lastAppliedTurnId = turnId
            return .init(turnId: turnId, branchAnchor: branchAnchor, origin: .user, gateReason: .shortInput, tuning: tuning,
                         topicAnchor: state.topicAnchor, selected: [], candidates: [], suppressions: [], ignored: [], thawed: [], stateAfterResponse: after)
        }
        let turn = state.effectiveTurn + 1
        let weights = state.active.isEmpty && state.pending.isEmpty ? nil : weights()
        let keeping = !state.active.isEmpty && weights?.continues(text, anchor: state.topicAnchor, active: state.active, tuning: tuning) == true
        // Generic retrospective grammar cannot thaw an unrelated source.
        var thawed = Set((state.pending + state.active).filter {
            RecallLexical.names($0.identities, in: text, tuning: tuning) || RecallLexical.targets($0.source, in: text)
        }.map(\.source)).union(state.cooldowns.filter {
            RecallLexical.targets($0.source, in: text) || RecallLexical.names($0.identities ?? [], in: text, tuning: tuning)
        }.map(\.source))
        let continued = Set(state.pending.filter {
            weights?.continues(text, anchor: $0.text, active: [$0], tuning: tuning) == true
        }.map(\.source))
        var ignored = state.pending.map(\.source).filter { !continued.contains($0) && !thawed.contains($0) }
        var cooldowns = state.cooldowns.filter { $0.untilTurn >= turn && !thawed.contains($0.source) }
        for source in ignored {
            cooldowns.removeAll { $0.source == source }
            cooldowns.append(.init(source: source, untilTurn: turn + (tuning.cooldownEnabled ? tuning.cooldownTurns : 0) - 1,
                                   identities: state.pending.first { $0.source == source }?.identities))
        }
        let candidates = keeping ? state.active : search(cooldowns)
        thawed.formUnion(candidates.filter {
            RecallLexical.names($0.identities, in: text, tuning: tuning) || RecallLexical.targets($0.source, in: text)
        }.map(\.source))
        cooldowns.removeAll { thawed.contains($0.source) }
        ignored.removeAll { thawed.contains($0) }
        let selected = validated(candidates, cooldowns: cooldowns, turn: turn, thawed: thawed)
        var after = state
        after.effectiveTurn = turn
        after.lastAppliedTurnId = turnId
        after.topicAnchor = text
        after.active = selected
        after.pending = keeping ? [] : selected.filter { !continued.contains($0.source) }
        after.cooldowns = cooldowns
        return .init(turnId: turnId, branchAnchor: branchAnchor, origin: .user, gateReason: keeping ? .kept : .search, tuning: tuning,
                     topicAnchor: text, selected: selected, candidates: candidates, suppressions: suppressions,
                     ignored: ignored, thawed: Array(thawed).sorted { $0.path < $1.path }, stateAfterResponse: after)
    }

    /// Only receipts on the selected path are facts. Materialized conversation state is not replayed.
    public static func recover(receipts: [RecallTurnReceipt], branchAnchor: String, clearActive: Bool = true) -> RecallConversationState {
        var state = RecallConversationState()
        var seen = Set<String>()
        for receipt in receipts {
            let decision = receipt.decision
            // Eligibility withdrawal is not an observation about the user. A persisted prepared
            // disabled send clears inherited context even if the network never responds.
            if decision.gateReason == .disabled {
                state.active = []; state.pending = []; state.topicAnchor = ""
                if receipt.hasEffectiveResponse, seen.insert(decision.turnId).inserted {
                    state.lastAppliedTurnId = decision.turnId
                }
                continue
            }
            guard receipt.hasEffectiveResponse, seen.insert(decision.turnId).inserted else { continue }
            state.lastAppliedTurnId = decision.turnId
            if decision.gateReason == .shortInput { continue }
            state.effectiveTurn += 1
            state.cooldowns.removeAll { $0.untilTurn < state.effectiveTurn || decision.thawed.contains($0.source) }
            for source in decision.ignored {
                state.cooldowns.removeAll { $0.source == source }
                state.cooldowns.append(.init(source: source, untilTurn: state.effectiveTurn + (decision.tuning.cooldownEnabled ? decision.tuning.cooldownTurns : 0) - 1,
                                             identities: state.pending.first { $0.source == source }?.identities))
            }
            state.active = decision.selected
            state.pending = decision.stateAfterResponse.pending
            state.topicAnchor = decision.topicAnchor
        }
        state.branchAnchor = branchAnchor
        if clearActive { state.active = []; state.pending = []; state.topicAnchor = "" }
        return state
    }
}

extension RecallConversationState {
    public func remapped(conversationId: String, nodeIds: [String: String]) -> Self {
        var result = self
        result.branchAnchor = nodeIds[branchAnchor] ?? branchAnchor
        result.lastAppliedTurnId = lastAppliedTurnId.map { nodeIds[$0] ?? $0 }
        result.active = active.map { $0.scoped(to: conversationId) }
        result.pending = pending.map { $0.scoped(to: conversationId) }
        result.cooldowns = cooldowns.map {
            .init(source: $0.source.scoped(to: conversationId), untilTurn: $0.untilTurn, identities: $0.identities)
        }
        return result
    }
}

extension RecallTurnReceipt {
    public func remapped(from oldConversationId: String, conversationId: String, nodeIds: [String: String]) -> Self {
        var result = self
        let old = decision
        result.decision = RecallTurnDecision(
            turnId: nodeIds[old.turnId] ?? old.turnId, branchAnchor: nodeIds[old.branchAnchor] ?? old.branchAnchor,
            origin: old.origin, gateReason: old.gateReason, tuning: old.tuning, topicAnchor: old.topicAnchor,
            selected: old.selected.map { $0.scoped(to: conversationId) },
            candidates: old.candidates.map { $0.scoped(to: conversationId) },
            suppressions: old.suppressions.map { .init(source: $0.source.scoped(to: conversationId), reason: $0.reason) },
            ignored: old.ignored.map { $0.scoped(to: conversationId) }, thawed: old.thawed.map { $0.scoped(to: conversationId) },
            stateAfterResponse: old.stateAfterResponse.remapped(conversationId: conversationId, nodeIds: nodeIds))
        result.reads = reads.map { read in
            func remap(_ target: RecallTool.Target) -> RecallTool.Target {
                var decoded = target
                if decoded.conversationId == oldConversationId {
                    decoded.conversationId = conversationId
                    decoded.fromNodeId = decoded.fromNodeId.map { nodeIds[$0] ?? $0 }
                    decoded.toNodeIdExclusive = decoded.toNodeIdExclusive.map { nodeIds[$0] ?? $0 }
                    decoded.lastNodeId = decoded.lastNodeId.map { nodeIds[$0] ?? $0 }
                }
                return decoded
            }
            let target = (try? RecallTool.decoder.decode(RecallTool.Target.self, from: Data(read.target.utf8)))
                .map { RecallTool.json(remap($0)) } ?? nodeIds[read.target] ?? read.target
            return RecallReadReceipt(toolCallId: read.toolCallId, turnId: nodeIds[read.turnId] ?? read.turnId,
                                     layer: read.layer, target: target,
                                     sourceVersion: read.sourceVersion, status: read.status,
                                     returnedRange: read.returnedRange?.map(remap), next: read.next,
                                     returnedCount: read.returnedCount, gate: read.gate)
        }
        return result
    }
}

private extension RecallSourceRef {
    public func scoped(to conversationId: String) -> Self {
        Self(profileId: profileId, conversationId: conversationId, kind: kind, path: path, version: version)
    }
}

private extension RecallItem {
    public func scoped(to conversationId: String) -> Self {
        Self(source: source.scoped(to: conversationId), text: text, identities: identities, tokenCost: tokenCost)
    }
}
