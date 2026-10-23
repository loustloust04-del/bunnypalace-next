import Foundation

/// 来自 hub 既有 reply 帧；引用不是请求关联，必须使用原始 message_id。
struct CCCallReply: Sendable {
    let requestId: String
    let streaming: Bool

    static func fromFrame(_ frame: [String: Any]) -> CCCallReply? {
        guard let id = frame["message_id"] as? String, !id.isEmpty else { return nil }
        return CCCallReply(requestId: id, streaming: (frame["streaming"] as? Bool) == true)
    }
}

/// 语音通话状态机（plan-voice-call T1；V4c 改流式）：半双工规则 + 流式朗读 + [voice] 协议。
/// 纯逻辑：听（STT）/说（`CallSpeechSink`）/发消息全部注入——CallScreen 在接线层赋值，测试注 mock。
/// 下行：VM 的流式 delta → `StreamSpeechGate` 放出整句 → sink；工具边界 / 回复结束 flush。
/// 参照系统的三条铁律都在这层：
/// ① 播放期间闭麦（半双工，防扬声器回灌成"她说的话"死循环）——第一块音频开播就闭
/// ② 播放器空了且本轮结束，隔 resumeDelay 再开麦（防尾音）
/// ③ 通话模式说明只随首句 [voice] 消息走（prompt 组装零改动，缓存前缀不碰）
@MainActor
@Observable
final class CallSession {
    static let shared = CallSession()

    enum UIState: String { case idle, listening, thinking, speaking }

    /// 首句一次性前缀（中性措辞，不涉人称）
    static let preamble = "[通话开始] 接下来带 [voice] 标记的消息是语音转写，请用适合朗读的短句回复。"

    // MARK: - 注入点

    /// 朗读管线（CallScreen 开场注入 `CallSpeechPipeline`；它的三个回调接回 playbackStarted / utteranceChanged / playbackIdle）
    @ObservationIgnored var speech: (any CallSpeechSink)?
    var startListening: @MainActor () -> Void = {}
    var stopListening: @MainActor () -> Void = {}
    /// 把组好的 [voice] 消息发进当前对话（返回 sendMessage 是否受理）
    var sendUserText: @MainActor (String) -> Bool = { _ in false }
    /// 这次发出去的回复走外部落地（CC 桥接：proactive 落地，没有 onToken / assistantTurnDidFinish）
    /// → 记 `externalRequestId`，靠 `externalReply` 认领收口。预建连照做：回复一直不来时由管线的预热上限收口
    var replyLandsExternally: @MainActor () -> Bool = { false }
    /// 发 CC 后当前 user 节点 id，也是发送帧的 message_id；只有对应回复才允许念。
    var sentUserNodeId: @MainActor () -> String? = { nil }
    var activeReplyNodeId: @MainActor () -> String? = { nil }
    var cancelReply: @MainActor () -> Void = {}
    @ObservationIgnored var effectInstruction: String?
    /// 播完恢复听的静默间隙（参照系统实测 250ms；测试调 0）
    var resumeDelay: Duration = .milliseconds(250)

    // MARK: - 状态

    private(set) var active = false
    /// nonisolated 镜像：给后台线程的 prompt 组装读（active 本身 @MainActor）。
    /// 真相源仍是 active，begin/end 同步更新；bool 读写原子，最多晚一轮，通话边界可接受。
    nonisolated(unsafe) static var activeSnapshot = false
    private(set) var callId = ""
    private(set) var startedAt: Date?
    private(set) var conversationId = ""
    /// 第一块音频开播 → 播放器空了且本轮结束 之间 true（半双工的"说"半边）
    private(set) var speaking = false
    /// vm turn 级 busy 的镜像（CallScreen onChange 同步进来，UI 显示"想…"）
    var turnInFlight = false
    var muted = false { didSet { syncMic() } }
    /// AI 正在朗读的句子（UI 大字展示）
    private(set) var currentUtterance = ""

    private var sentPreamble = false
    @ObservationIgnored private var gate = StreamSpeechGate()
    /// 正在流式朗读的回复节点（收到过它的 delta）
    @ObservationIgnored private var streamNodeId: String?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    private var externalRequestId: String?
    @ObservationIgnored private var discardedReplyIds: Set<String> = []
    @ObservationIgnored private var finishedReplyIds: Set<String> = []

    var uiState: UIState {
        if !active { return .idle }
        if speaking { return .speaking }
        if turnInFlight || externalRequestId != nil { return .thinking }
        return .listening
    }

    // MARK: - 生命周期

    func begin(conversationId: String) {
        guard !active else { return }
        // muted 先复位再置 active：didSet 里的 syncMic 有 active 守卫，此序不会双重开麦
        muted = false
        turnInFlight = false
        active = true
        Self.activeSnapshot = true
        self.conversationId = conversationId
        callId = UUID().uuidString
        startedAt = Date()
        sentPreamble = false
        externalRequestId = nil
        discardedReplyIds.removeAll()
        finishedReplyIds.removeAll()
        if let id = activeReplyNodeId() { discardedReplyIds.insert(id) }
        gate.reset()
        streamNodeId = nil
        startListening()
    }

    func end() {
        guard active else { return }
        active = false
        Self.activeSnapshot = false
        resumeTask?.cancel()
        resumeTask = nil
        speech?.cancel()
        gate.reset()
        streamNodeId = nil
        externalRequestId = nil
        speaking = false
        currentUtterance = ""
        stopListening()
    }

    // MARK: - 上行（她说话）

    /// STT final → 组 [voice] 消息发出（partial 只做字幕不进这里）
    @discardableResult
    func userFinalTranscript(_ text: String) -> Bool {
        guard active, !muted, !speaking else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let preamble = Self.preamble + (effectInstruction.map { "\n" + $0 } ?? "")
        let message = sentPreamble
            ? "[voice] \(trimmed)"
            : preamble + "\n[voice] \(trimmed)"
        let accepted = sendUserText(message)
        if accepted {
            sentPreamble = true
            externalRequestId = replyLandsExternally() ? sentUserNodeId() : nil
            // AI 这一轮开始：流式服务先建好连接，第一句出来直接发（V0：首包里建连占大头）
            speech?.prepareTurn()
        }
        return accepted
    }

    // MARK: - 下行（TA 说话）

    /// VM onToken 钩子：流式 delta 进 gate，放出的整句交给管线
    func assistantStreamDelta(_ delta: String, nodeId: String, conversationId convId: String) {
        guard accepts(nodeId: nodeId, conversationId: convId) else { return }
        if streamNodeId != nodeId {
            gate.reset()
            streamNodeId = nodeId
        }
        gate.feed(delta).forEach { speech?.speak($0) }
    }

    /// 工具调用边界（VM 把 streamingText 挪进 segments 那一下）：吐尾巴 + 流式会话收口
    func assistantStreamSegmentBreak(nodeId: String, conversationId convId: String) {
        guard accepts(nodeId: nodeId, conversationId: convId), streamNodeId == nodeId else { return }
        gate.flush().forEach { speech?.speak($0) }
        speech?.endSegment()
    }

    /// turn 收口（ContentView .assistantTurnDidFinish 订阅者调；error / cancel 也走这里）。
    /// 流式念过的只 flush 不重念；整轮一个 delta 都没收到（非流式路径）才用 `fallbackText` 整段过 gate。
    func assistantTurnFinished(nodeId: String, conversationId convId: String, fallbackText: () -> String?) {
        guard accepts(nodeId: nodeId, conversationId: convId) else { return }
        if streamNodeId == nodeId {
            gate.flush().forEach { speech?.speak($0) }
        } else if let text = fallbackText() {
            gate.reset()
            let sentences = gate.feed(text)
            (sentences + gate.flush()).forEach { speech?.speak($0) }
        }
        streamNodeId = nil
        finishedReplyIds.insert(nodeId)
        speech?.endTurn()
    }

    /// CC 普通回复 / 流式 edit 收口：只念本通电话的当前请求，不把占位、重放或主动消息当成回复。
    func externalReply(_ text: String, nodeId: String, conversationId convId: String,
                       requestId: String, streaming: Bool) {
        guard !streaming, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectsExternalReply(requestId: requestId, conversationId: convId),
              accepts(nodeId: nodeId, conversationId: convId) else { return }
        externalRequestId = nil
        assistantTurnFinished(nodeId: nodeId, conversationId: convId) { text }
    }

    func expectsExternalReply(requestId: String, conversationId convId: String) -> Bool {
        active && convId == conversationId && !requestId.isEmpty && externalRequestId == requestId
    }

    /// 停止当前回应；先标失效再取消模型，取消同步收口也不能重念 fallback。
    /// 保持通话，与挂断分开。音频开口检测接入后也使用这个出口。
    func interruptReply() {
        guard active else { return }
        if let id = streamNodeId { discardedReplyIds.insert(id) }
        if let id = activeReplyNodeId() { discardedReplyIds.insert(id) }
        externalRequestId = nil
        gate.reset()
        streamNodeId = nil
        resumeTask?.cancel()
        resumeTask = nil
        speech?.cancel()
        speaking = false
        currentUtterance = ""
        cancelReply()
        turnInFlight = false
        syncMic()
    }

    private func accepts(nodeId: String, conversationId convId: String) -> Bool {
        active && convId == conversationId && !discardedReplyIds.contains(nodeId)
            && !finishedReplyIds.contains(nodeId)
    }

    // MARK: - 管线回调

    /// 第一块音频开播：闭麦
    func playbackStarted() {
        guard active else { return }
        resumeTask?.cancel()
        resumeTask = nil
        guard !speaking else { return }
        speaking = true
        stopListening()
    }

    func utteranceChanged(_ text: String) {
        guard active else { return }
        currentUtterance = text
    }

    /// 播放器空了且本轮已结束：resumeDelay 后开麦
    func playbackIdle() {
        guard active, speaking else { return }
        speaking = false
        currentUtterance = ""
        resumeTask?.cancel()
        let delay = resumeDelay
        // 单例挂 app 生命周期，任务强捕获 self 无泄漏面；end() 取消 + active 守卫收敛
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            resumeTask = nil
            syncMic()
        }
    }

    private func syncMic() {
        guard active, !speaking else { return }
        if muted { stopListening() } else { startListening() }
    }
}
