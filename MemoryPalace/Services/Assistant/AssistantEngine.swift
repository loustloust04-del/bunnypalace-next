import Foundation

/// 小芽用哪个模型（plan-小芽-v3 §2）：空 = 跟随聊天（selectedChatModel），否则是复合模型 id，可以是本机模型
enum XiaoyaModelChoice {
    static let key = "xiaoya.model"
    static let legacyUseLocalKey = "xiaoya.local.enabled"
    static let legacyModelKey = "xiaoya.local.model"

    static func modelId(_ defaults: UserDefaults) -> String {
        let own = defaults.string(forKey: key) ?? ""
        return own.isEmpty ? defaults.string(forKey: "selectedChatModel") ?? "" : own
    }

    /// v2 的「用本地大脑」开关 + 模型 → 这里的一个选择；只迁一次（迁完旧 key 删掉）
    static func migrateLegacy(_ defaults: UserDefaults) {
        guard defaults.object(forKey: legacyUseLocalKey) != nil || defaults.object(forKey: legacyModelKey) != nil else { return }
        if defaults.bool(forKey: legacyUseLocalKey) {
            let model = defaults.string(forKey: legacyModelKey) ?? AssistantLocalModel.light.id
            defaults.set("\(APICredential.localId)/\(model)", forKey: key)
        }
        defaults.removeObject(forKey: legacyUseLocalKey)
        defaults.removeObject(forKey: legacyModelKey)
    }
}

// MARK: - 小芽助手 · 引擎（plan-小芽助手.md §4.2；v2：plan-小芽-v2 §4）
// 复用 ProviderRouter 的原生 tool calling 通路；agent 循环照 ConversationViewModel 的模式：
// 模型出 toolCalls → 执行 → ToolTurn 回灌 → 下一轮，直到纯文本收尾或轮数封顶。
// 写工具不执行，只收集 AssistantAction 提案挂到最终消息上；落地只有 stamp 一个入口。

@Observable
@MainActor
final class AssistantEngine {
    var messages: [AssistantChatMessage] = [] {
        didSet { scheduleSave() }
    }
    var streamingText = ""
    var isGenerating = false
    /// 舞台表情（plan-小芽-v2 §3.2）：生成状态 + 有没有待盖章的卡 + 上一轮失败没 → 主状态；feedback 压在上面
    let feedback = XiaoyaFeedbackClock()
    let ledger: AssistantLedger
    private var readingLabel: String?
    private var lastRunFailed = false

    /// 这一次 send 用的后端：本地大脑开着且装好 → 本机；否则云端（楼层 API）
    @ObservationIgnored private var backend: AssistantBackend?
    /// 这一次是不是本地大脑在答（舞台小票上带个叶子）
    private(set) var usingLocalBrain = false
    @ObservationIgnored private let store: AssistantChatStore
    @ObservationIgnored private let packDefaults: UserDefaults
    private static let maxRounds = 6
    /// 本轮对话（一次 send）收集到的提案
    @ObservationIgnored private var pendingActions: [AssistantAction] = []
    /// 本轮追过的那一句（本地大脑没调工具却说有预览卡片，追一次；实测 1.7B 4/4、4B 3/4 追完会真交）
    @ObservationIgnored private var runNudge: AssistantNudge?
    /// 每次 send / cancel 换一个；回调先核 runId，旧一轮晚到的事件丢掉（astra B9）
    @ObservationIgnored private var runId = UUID()
    @ObservationIgnored private var originProfileId: String?
    @ObservationIgnored private var saveToken = 0
    @ObservationIgnored private var profileObserver: NSObjectProtocol?

    init(store: AssistantChatStore = AssistantChatStore(), ledger: AssistantLedger? = nil, packDefaults: UserDefaults = .standard) {
        self.store = store
        self.ledger = ledger ?? AssistantLedger()
        self.packDefaults = packDefaults
        XiaoyaModelChoice.migrateLegacy(packDefaults)
        messages = store.load()
        profileObserver = NotificationCenter.default.addObserver(forName: .profileWillSwitch, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(quietly: true) }
        }
    }

    deinit {
        if let profileObserver { NotificationCenter.default.removeObserver(profileObserver) }
    }

    var stageState: XiaoyaStageState {
        let base: XiaoyaStageState.Base
        if isGenerating {
            base = readingLabel.map { .reading($0) } ?? .thinking
        } else if messages.contains(where: { $0.actions.contains { $0.status == .pending } }) {
            base = .awaitingStamp
        } else if lastRunFailed {
            base = .error
        } else {
            base = .idle
        }
        return XiaoyaStageState(base: base, feedback: feedback.feedback)
    }

    // MARK: - 对话

    func send(_ text: String, env: AssistantEnv) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        let model = resolveModel(env: env)
        if let model, env.providerManager.credential(for: model)?.type == .localMLX {
            backend = AssistantLocalBackend(modelId: model.modelId)
            usingLocalBrain = true
        } else if let model {
            backend = AssistantCloudBackend(model: model, providerManager: env.providerManager)
            usingLocalBrain = false
        } else {
            messages.append(AssistantChatMessage(isUser: true, text: trimmed))
            messages.append(AssistantChatMessage(isUser: false, text: "我还没接模型呢——去「设置 → API」选一个聊天模型，或者在「设置 → 小芽」给我装个本地大脑，再来找我 🥺"))
            return
        }
        messages.append(AssistantChatMessage(isUser: true, text: trimmed))
        feedback.clear()
        lastRunFailed = false
        readingLabel = nil
        isGenerating = true
        pendingActions = []
        runNudge = nil
        runId = UUID()
        originProfileId = env.profileId
        runRound(env: env, toolTurns: [], round: 0, run: runId)
    }

    func cancel() { cancel(quietly: false) }

    /// quietly：切楼层时自动取消，不闪 Shock
    private func cancel(quietly: Bool) {
        guard isGenerating else { return }
        runId = UUID()
        backend?.cancel()
        if !streamingText.isEmpty || !pendingActions.isEmpty {
            messages.append(AssistantChatMessage(isUser: false, text: streamingText, actions: pendingActions))
        }
        streamingText = ""
        pendingActions = []
        isGenerating = false
        readingLabel = nil
        if !quietly { feedback.flash(.stopped) }
    }

    // MARK: - 盖章 / 丢弃 / 撤销（唯一落地入口，astra B4）

    @discardableResult
    func stamp(_ actionId: UUID, in workspace: AssistantWorkspace) -> Bool {
        guard let (mi, ai) = locate(actionId) else { return false }
        var action = messages[mi].actions[ai]
        guard action.status == .pending, let change = action.change else { return false }
        guard XiaoyaPackPolicy.isEnabled(XiaoyaPack.of(kind: action.kind), defaults: packDefaults) else {
            action.status = .failed
            action.failure = "「\(XiaoyaPack.of(kind: action.kind).title)」能力已经关了，这条不能落地"
            messages[mi].actions[ai] = action
            return false
        }
        // 幂等：账本里已经有这笔（上次落地后写历史前崩了之类），不再落第二次
        if let existing = ledger.entry(forAction: actionId) {
            action.status = .approved
            action.ledgerId = existing.id
            action.change = existing.receipt
            messages[mi].actions[ai] = action
            return true
        }
        let receipt: AssistantChange
        do {
            receipt = try AssistantStamp.apply(change, in: workspace)
        } catch {
            action.status = .failed
            action.failure = error.localizedDescription
            messages[mi].actions[ai] = action
            lastRunFailed = true
            return false
        }
        action.change = receipt
        action.status = .approved
        do {
            action.ledgerId = try ledger.record(actionId: actionId, receipt: receipt).id
        } catch {
            action.failure = "已经生效，但没记进账本（这笔没法撤销）"
        }
        messages[mi].actions[ai] = action
        feedback.flash(.approved)
        return true
    }

    // MARK: 编辑以前的话（v3 §4，D3：没盖章的卡随消息删；盖过章的不回滚，账本里还能撤）

    /// 从这句起（含）往后，盖过章还没撤的提案有几张
    func stampedCount(from messageId: UUID) -> Int {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return 0 }
        return messages[index...].flatMap(\.actions).filter { $0.status == .approved }.count
    }

    /// 这句起往后全删，返回原文给输入框；生成中 / 找不到返回 nil
    func rewind(to messageId: UUID) -> String? {
        guard !isGenerating, let index = messages.firstIndex(where: { $0.id == messageId && $0.isUser }) else { return nil }
        let text = messages[index].text
        messages.removeSubrange(index...)
        lastRunFailed = false
        return text
    }

    func discard(_ actionId: UUID) {
        guard let (mi, ai) = locate(actionId), messages[mi].actions[ai].status == .pending else { return }
        messages[mi].actions[ai].status = .discarded
        feedback.flash(.discarded)
    }

    /// 还能不能撤：盖过章、记进了账本、账本里这笔没被裁掉也没被撤过
    func canUndo(_ action: AssistantAction) -> Bool {
        guard action.status == .approved, let id = action.ledgerId, let entry = ledger.entry(id: id) else { return false }
        return !entry.undone
    }

    /// 盖过章但账本里已经找不到这笔（被裁掉了）
    func isBeyondRetention(_ action: AssistantAction) -> Bool {
        action.status == .approved && action.ledgerId != nil && ledger.entry(id: action.ledgerId!) == nil
    }

    func undo(_ actionId: UUID, in workspace: AssistantWorkspace, force: Bool) -> AssistantUndoOutcome {
        guard let (mi, ai) = locate(actionId) else { return .failed("找不到这条") }
        let action = messages[mi].actions[ai]
        guard canUndo(action), let entry = action.ledgerId.flatMap(ledger.entry(id:)) else {
            return .failed("超出撤销保留范围")
        }
        let outcome = AssistantStamp.undo(entry.receipt, in: workspace, force: force)
        if case .done = outcome {
            try? ledger.markUndone(entry.id)
            messages[mi].actions[ai].status = .undone
        }
        return outcome
    }

    private func locate(_ actionId: UUID) -> (Int, Int)? {
        for (mi, msg) in messages.enumerated() {
            if let ai = msg.actions.firstIndex(where: { $0.id == actionId }) { return (mi, ai) }
        }
        return nil
    }

    // MARK: - 私有

    private func resolveModel(env: AssistantEnv) -> ProviderModel? {
        let id = XiaoyaModelChoice.modelId(packDefaults)
        return id.isEmpty ? nil : env.providerManager.model(byId: id)
    }

    /// wire 历史：30 轮滑动窗口 + 每张提案卡的处理结果（按持久化状态，重启后模型也知道，astra C5）
    /// 处理结果挂在下一句用户话前面，不拼进小芽自己的话：拼进去模型会当成回复格式照抄，不调工具就自己写「已盖章」
    func wireHistory() -> [(role: String, content: String)] {
        var notes: [String] = []
        var wire: [(role: String, content: String)] = []
        for msg in messages.suffix(AssistantChatStore.wireWindowMessages) {
            var text = msg.text
            if msg.isUser {
                if !notes.isEmpty {
                    text = "（系统备注，不是用户说的，也别在回复里写：\(notes.joined(separator: "；"))）\n" + text
                    notes = []
                }
            } else {
                text = Self.vetReply(text, madeProposal: true).text   // 旧记录里照抄出来的假备注也别再喂回去
                notes += msg.actions.map(Self.statusNote)
            }
            wire.append((role: msg.isUser ? "user" : "assistant", content: text))
        }
        return wire
    }

    /// 本机模型不带历史（plan-小芽-v3 §5，D4）：只发她这一句。小芽上一句是反问（没交卡、问号结尾）时，
    /// 把她再上一句并进来写成「上一句。补充：这一句」，让「随便」「你定」接得上。
    /// 不直接带小芽那句反问：Mac 实测带上它 1.7B / 4B 都 0/10 不调工具，并成一句是 12/12
    func localHistory() -> [(role: String, content: String)] {
        guard let userIndex = messages.lastIndex(where: \.isUser) else { return [] }
        let current = messages[userIndex].text
        guard let askIndex = messages[..<userIndex].lastIndex(where: { !$0.isUser && !$0.text.isEmpty }),
              messages[askIndex].actions.isEmpty,
              let last = messages[askIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).last, "？?".contains(last),
              let earlier = messages[..<askIndex].last(where: \.isUser) else {
            return [(role: "user", content: current)]
        }
        let head = earlier.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。！!？?～~")))
        return [(role: "user", content: "\(head)。补充：\(current)")]
    }

    /// 小模型没调工具却在回复里声称交了提案：抹掉它照猫画虎写出来的状态备注，并认出「说有预览卡片其实没有」
    static func vetReply(_ text: String, madeProposal: Bool) -> (text: String, claimedWithoutProposal: Bool) {
        let cleaned = text.replacingOccurrences(of: #"\[提案「[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let claimed = !madeProposal && (cleaned != text.trimmingCharacters(in: .whitespacesAndNewlines) || cleaned.contains("预览卡片"))
        return (cleaned, claimed)
    }

    static func statusNote(_ action: AssistantAction) -> String {
        let name = action.change.map { "\($0.category)：\($0.title)" } ?? action.title
        let state: String = switch action.status {
        case .pending: "等用户盖章"
        case .approved: "用户已盖章，已生效"
        case .discarded: "用户没要"
        case .undone: "用户盖过章后又撤销了"
        case .failed: "没能落地（\(action.failure ?? "原因不明")）"
        case .legacy: "旧提案已失效"
        }
        return "提案「\(name)」\(state)"
    }

    /// 0.5 s 合并一次，编码写盘都在后台（astra C1）
    private func scheduleSave() {
        saveToken += 1
        let token = saveToken
        let snapshot = messages
        let store = store
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.saveToken == token else { return }
            await Task.detached(priority: .utility) { store.save(snapshot) }.value
        }
    }

    private func runRound(env: AssistantEnv, toolTurns: [ToolTurn], round: Int, run: UUID) {
        guard let backend else { return }
        let history = usingLocalBrain ? localHistory() : wireHistory()
        let request = AssistantBackendRequest(
            system: AssistantPrompts.systemPrompt(compact: usingLocalBrain),
            history: history,
            tools: usingLocalBrain
                ? AssistantTools.localDefinitions(for: history.map(\.content).joined(separator: "\n"), page: AssistantContext.shared.page)
                : AssistantTools.definitions,
            toolTurns: toolTurns,
            nudge: runNudge)
        backend.run(request) { [weak self] event in
            guard let self, self.runId == run else { return }
            switch event {
            case .token(let token):
                self.streamingText += token
            case .finished(let fullText):
                let text = fullText.isEmpty ? self.streamingText : fullText
                if self.usingLocalBrain, self.runNudge == nil, round < Self.maxRounds,
                   Self.vetReply(text, madeProposal: !self.pendingActions.isEmpty).claimedWithoutProposal {
                    self.runNudge = AssistantNudge(afterTurns: toolTurns.count, reply: text)
                    self.streamingText = ""
                    self.runRound(env: env, toolTurns: toolTurns, round: round + 1, run: run)
                } else {
                    self.finishRound(text: text)
                }
            case .failed(let error):
                let partial = self.streamingText
                self.lastRunFailed = true
                self.finishRound(text: partial.isEmpty ? "⚠️ \(error)" : partial + "\n\n⚠️ \(error)")
            case .toolCalls(let calls):
                self.handleToolCalls(calls, env: env, toolTurns: toolTurns, round: round, run: run)
            }
        }
    }

    private func handleToolCalls(_ calls: [ToolCallBlock], env: AssistantEnv, toolTurns: [ToolTurn], round: Int, run: UUID) {
        // 楼层在这一轮里被换了：工具不许对着新楼层跑
        guard env.profileId == originProfileId else {
            cancel(quietly: true)
            return
        }
        guard round < Self.maxRounds else {
            feedback.flash(.overwhelmed)
            finishRound(text: streamingText + "\n\n（工具调用达到上限，先这样吧）")
            return
        }
        // 工具调用前模型说的话先落一条（保留它的解说）
        let spoken = streamingText
        streamingText = ""
        if !spoken.isEmpty {
            messages.append(AssistantChatMessage(isUser: false, text: spoken))
        }
        if let label = calls.lazy.compactMap({ XiaoyaStageState.readingLabel(forTool: $0.name) }).first {
            readingLabel = label
        }
        var results: [ToolResultBlock] = []
        for call in calls {
            let outcome = AssistantTools.execute(name: call.name, argumentsJSON: call.argumentsJSON, env: env)
            if outcome.refused { feedback.flash(.refused) }
            if let action = outcome.action {
                pendingActions.append(action)
            }
            results.append(ToolResultBlock(toolUseId: call.id, text: outcome.resultText, isError: outcome.isError))
        }
        runRound(env: env, toolTurns: toolTurns + [ToolTurn(calls: calls, results: results)], round: round + 1, run: run)
    }

    private func finishRound(text: String) {
        let vetted = Self.vetReply(text, madeProposal: !pendingActions.isEmpty)
        var trimmed = vetted.text
        if vetted.claimedWithoutProposal {
            trimmed += "\n\n⚠️ 这次其实没交出提案卡——再跟她说一次试试"
            lastRunFailed = true
        }
        if !trimmed.isEmpty || !pendingActions.isEmpty {
            messages.append(AssistantChatMessage(isUser: false, text: trimmed, actions: pendingActions))
        }
        pendingActions = []
        streamingText = ""
        isGenerating = false
        readingLabel = nil
    }
}
