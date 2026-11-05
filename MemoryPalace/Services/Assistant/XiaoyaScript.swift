import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

// MARK: - 小芽引导 · 本地剧本引擎（plan-onboarding-xiaoya-impl §4.1 / §4.2）
// 状态机节点 = 小样 NOTES 的 id；每个节点是一串「拍子」（说一句 / 出一张卡 / 换表情 / 落地一件事 / 跳下一节点），
// 台词、顺序、分支逐字照小样 run() 和各分支函数。进度 = 对话本身（history.json 里的卡 + 答案）+ script.json：
// 每走一拍记一次「第几个节点第几拍」，App 被杀 / 切楼层 / 整树重建后读回来，原地接着等那张没答的卡（H6）。
// 剧本消息一律追加在末尾，不插队；钥匙存好之前输入框锁住，之后放开——卡片照样能点，打字走真 AI（§七-6）。
// key 永远不进 JSON：草稿在内存的 XiaoyaKeyCardModel 里，中途被杀就回到空表单（H2）。

enum XiaoyaScriptNode: String, Codable, CaseIterable {
    case open, keyIntro, saved, skipkey
    case replay     // 设置重走（§7-5）：分隔线之后直接出分流卡
    case newbieNoKey, newbieTalk, newbieAfterTalk
    /// v2 C（§11-7）：小白线分流之后、钥匙卡之前——给你挑头像 + 名字 → 给 Ta 挑 → 回一句再进钥匙
    case newbieFace, newbieTaFace, newbieFaceDone
    case tavern, tavernDone, tavernStay
    case companion, companionDone, companionStay
    /// 新楼层建好后的出口卡（从 tavernDone / companionDone 拆出来：三问插在建好之后、出口卡之前）
    case tavernExit, companionExit
    /// 新用户三问（C2/C3 v2 第 11 段）：确定目标楼层之后问一次；surveyDone = 交出去、说一句、回原路
    case survey, surveyDone
    case tech, techPair
    case techPhone  // mac 上技术线：要连手机 → 只指路（§5.3）
    case ghost, end, endQuiet
}

/// script.json（与 history.json 同目录 → 全局备份自动带上）。不含 key
struct XiaoyaScriptProgress: Codable, Equatable {
    var scriptId = XiaoyaScriptProgress.currentScriptId
    var step: XiaoyaScriptNode = .open
    /// 这个节点已经走到第几拍
    var emitted = 0
    /// 剧本正在等的那张卡（消息 id）
    var awaitingMessageId: UUID?
    var identity: String?
    var taProfileId: String?
    var taName: String?
    /// 新楼层出口卡上那一行（导卡时按卡摘要算好存下，重建后照样画得出）
    var taMeta: String?
    var userName: String?
    /// 小白线给 Ta 挑的名字（nil = 没挑 / 沿用原来的）
    var taFaceName: String?
    var keySaved = false
    var keySkipped = false
    var keyProvider: String?
    var keyModel: String?
    var hasMac: Bool?
    var fromNewbie = false
    /// 答了还没落地的导卡 / 起名（落地那一拍被打断，重建后接着落）
    var pendingImport: XiaoyaImportedCard?
    var pendingName: XiaoyaNameAnswer?
    /// 起名落地前先定下的楼层 id（先写进 script.json 再建）：建完没来得及记就被杀，重建后按它复用，不再多建一个 Ta（sol #4）
    var pendingTaId: String?
    /// 三问：问过之后回到哪（问过的标记）、答案落哪层、称呼预填、答案、任务 id（先记下再交，重放不多建）、交的结果
    var surveyThen: XiaoyaScriptNode?
    var surveyProfileId: String?
    var surveyName: String?
    var survey: XiaoyaSurveyAnswer?
    var surveyTaskId: String?
    var surveyResult: CatalogSurvey.Outcome?
    var startedAt = Date()
    var finishedAt: Date?

    static let currentScriptId = "onboarding.v1"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case scriptId, step, emitted, awaitingMessageId, identity, taProfileId, taName, taMeta, userName, taFaceName
        case keySaved, keySkipped, keyProvider, keyModel, hasMac, fromNewbie, pendingImport, pendingName, pendingTaId, startedAt, finishedAt
        case surveyThen, surveyProfileId, surveyName, survey, surveyTaskId, surveyResult
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scriptId = try c.decodeIfPresent(String.self, forKey: .scriptId) ?? Self.currentScriptId
        // 新版加的节点这版不认识：当已走完，不卡在一个画不出来的地方
        let rawStep = try c.decodeIfPresent(String.self, forKey: .step) ?? XiaoyaScriptNode.open.rawValue
        step = XiaoyaScriptNode(rawValue: rawStep) ?? .end
        emitted = try c.decodeIfPresent(Int.self, forKey: .emitted) ?? 0
        awaitingMessageId = try c.decodeIfPresent(UUID.self, forKey: .awaitingMessageId)
        identity = try c.decodeIfPresent(String.self, forKey: .identity)
        taProfileId = try c.decodeIfPresent(String.self, forKey: .taProfileId)
        taName = try c.decodeIfPresent(String.self, forKey: .taName)
        taMeta = try c.decodeIfPresent(String.self, forKey: .taMeta)
        userName = try c.decodeIfPresent(String.self, forKey: .userName)
        taFaceName = try c.decodeIfPresent(String.self, forKey: .taFaceName)
        keySaved = try c.decodeIfPresent(Bool.self, forKey: .keySaved) ?? false
        keySkipped = try c.decodeIfPresent(Bool.self, forKey: .keySkipped) ?? false
        keyProvider = try c.decodeIfPresent(String.self, forKey: .keyProvider)
        keyModel = try c.decodeIfPresent(String.self, forKey: .keyModel)
        hasMac = try c.decodeIfPresent(Bool.self, forKey: .hasMac)
        fromNewbie = try c.decodeIfPresent(Bool.self, forKey: .fromNewbie) ?? false
        pendingImport = try? c.decodeIfPresent(XiaoyaImportedCard.self, forKey: .pendingImport)
        pendingName = try? c.decodeIfPresent(XiaoyaNameAnswer.self, forKey: .pendingName)
        pendingTaId = try c.decodeIfPresent(String.self, forKey: .pendingTaId)
        surveyThen = (try? c.decodeIfPresent(String.self, forKey: .surveyThen)).flatMap { $0.flatMap(XiaoyaScriptNode.init(rawValue:)) }
        surveyProfileId = try c.decodeIfPresent(String.self, forKey: .surveyProfileId)
        surveyName = try c.decodeIfPresent(String.self, forKey: .surveyName)
        survey = try? c.decodeIfPresent(XiaoyaSurveyAnswer.self, forKey: .survey)
        surveyTaskId = try c.decodeIfPresent(String.self, forKey: .surveyTaskId)
        surveyResult = (try? c.decodeIfPresent(CatalogSurvey.Outcome.self, forKey: .surveyResult)) ?? nil
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        if XiaoyaScriptNode(rawValue: rawStep) == nil {
            finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt) ?? Date()
        } else {
            finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        }
    }
}

struct XiaoyaScriptStore: Sendable {
    let fileURL: URL

    /// 跟 history.json 放同一个目录
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("script.json")
    }

    func load() -> XiaoyaScriptProgress? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(XiaoyaScriptProgress.self, from: data)
        } catch {
            // 同 history.json：解不开挪开留底（备份导出会跳过 corrupt），当没走过
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json"))
            return nil
        }
    }

    func save(_ progress: XiaoyaScriptProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 打字节奏：每句前「在打字」（小样 say：0.42 s + 每字 24 ms，封顶 1.5 s），说完停 0.26 s。测试注入零延迟
struct XiaoyaScriptPacing: Sendable {
    var pause: @Sendable (Double) async -> Void

    static let live = XiaoyaScriptPacing { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    static let instant = XiaoyaScriptPacing { _ in }

    static func typing(_ text: String) -> Double { min(1.5, 0.42 + Double(text.count) * 0.024) }
    static let afterLine = 0.26
}

/// 剧本落地要碰的东西：线上由 XiaoyaConversationView 用自己的环境拼（live），测试注入临时目录的管理器
@MainActor
struct XiaoyaScriptWorld {
    var importCard: (XiaoyaImportedCard) async throws -> Profile
    /// (答案, 楼层 id)：这个 id 的楼层已经在了就直接还它（幂等，sol #4）
    var createTa: (XiaoyaNameAnswer, String) throws -> Profile
    /// 切到 Ta 的楼层（出口卡「去找 X」）：回 page1，iOS 收起 page2 的小芽 app
    var goTo: (String) -> Void
    var requestPush: () -> Void
    /// 存好钥匙后小芽实际用哪个模型说话（K3 没接管主模型时还是原来那个）
    var activeModelName: () -> String?
    /// 起名卡填了「怎么称呼你」：写默认称呼（H9）
    var setDefaultUserName: (String) -> Void
    /// 挑头像 + 名字卡答了：写当前楼层（你：称呼 / 头像 + 默认称呼 / 默认头像；Ta：AI 名字 / 头像）
    var applyFace: (XiaoyaFaceAnswer) -> Void = { _ in }
    /// 新用户三问；nil = 不问
    var survey: XiaoyaSurveyWorld? = nil
}

/// 三问落地：目标楼层没在引导里建 Ta 时取当前楼层；交答案 = 写称呼 + 把答案落进那层（同一个任务 id 只建一次），不等模型
@MainActor
struct XiaoyaSurveyWorld {
    var currentProfileId: () -> String?
    /// (答案, 目标楼层 id, 任务 id)
    var submit: (XiaoyaSurveyAnswer, String, String) async -> CatalogSurvey.Outcome
}

/// 一拍
enum XiaoyaBeat: Equatable {
    case say(String)
    case handoff(String)
    case mood(XiaoyaMood, String)
    case card(XiaoyaCard)
    /// 新楼层出口卡：Ta 是谁要等落地那一拍建完楼层才知道，走到这拍时现拼
    case floorExit(extras: [XiaoyaFloorExtra])
    /// end() 的出口：有 Ta → 去找 X；没 Ta → 建一个 Ta
    case exitCard
    /// 小白「跟我说句话」：等她发一句、真 AI 回完再往下
    case awaitTalk
    case effect(XiaoyaScriptEffect)
    case goto(XiaoyaScriptNode)
}

enum XiaoyaScriptEffect: Equatable {
    case buildTavernFloor
    case buildTa
    /// 三问的答案交出去（落进目标楼层，能跑就排队出目录）
    case submitSurvey
    /// 收尾：xiaoyaV1 = done + onboardingCompletedV1 + 推送权限；goToTa = 出口卡点了「去找」，收完尾切过去
    case finish(goToTa: Bool)
}

extension XiaoyaBeat {
    /// 这一拍出的卡要等答案（新楼层出口卡也算）：恢复时这张卡不在历史里就得重出（sol #2）
    var awaitsAnswer: Bool {
        switch self {
        case .card(let card): card.awaitsAnswer
        case .floorExit: true
        default: false
        }
    }
}

extension XiaoyaCard {
    /// 剧本要不要停下来等这张卡的答案
    var awaitsAnswer: Bool {
        switch self {
        case .choice, .keyForm, .importCard, .nameForm, .floorExit, .pair, .face, .survey: return true
        case .goTa, .todo, .info, .makeTa, .tip, .unsupported: return false
        }
    }
}

@Observable
@MainActor
final class XiaoyaScriptRunner {
    nonisolated static let onboardingKey = "onboarding.xiaoyaV1"
    nonisolated static let legacyCompletedKey = "onboardingCompletedV1"

    private(set) var progress: XiaoyaScriptProgress? {
        didSet { if let progress, progress != oldValue { store.save(progress) } }
    }
    /// 剧本台词前的「在打字」（主线 + 召回可能同时在说，计数）
    private var typingCount = 0
    var typing: Bool { typingCount > 0 }
    /// 舞台表情覆盖层（小样 mood()）：盖在引擎主状态上，她一发话就清掉；不落盘
    private(set) var mood: XiaoyaStageState.Scripted?
    /// key 卡的内存草稿：整张卡全程同一个；存好一把后换新的（再「配钥匙」从空表单起）
    private(set) var keyModel: XiaoyaKeyCardModel
    /// 收到过的 tip（tips.json）：舞台边的灯泡按它出历史列表
    private(set) var tips: XiaoyaTipLog
    /// 新收到一条 tip 就 +1：灯泡亮一下（不落盘）
    private(set) var tipPulse = 0
    /// 展开过的马克笔概念词（glossary.json，§12-E）：解释跟在哪句下面 + 灯泡列表「词典」组
    private(set) var glossary: XiaoyaGlossaryLog
    /// 刚答完、该「啪」一下的卡（§12-A）：卡角星爆只在这一刻动一次，不落盘
    private(set) var freshStamp: UUID?

    @ObservationIgnored private weak var engine: AssistantEngine?
    @ObservationIgnored private let store: XiaoyaScriptStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pacing: XiaoyaScriptPacing
    @ObservationIgnored private let pairSupported: Bool
    /// 收尾发不发「怎么划」Tip 1：只 iPhone（mac / iPad 宽屏没有三页翻页，§11-6）
    @ObservationIgnored private let tipsSupported: Bool
    @ObservationIgnored private let tipStore: XiaoyaTipStore
    @ObservationIgnored private let glossaryStore: XiaoyaGlossaryStore
    @ObservationIgnored private let makeKeyModel: @MainActor () -> XiaoyaKeyCardModel
    @ObservationIgnored private var world: XiaoyaScriptWorld?
    @ObservationIgnored private var playToken = 0
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var sideTask: Task<Void, Never>?
    @ObservationIgnored private var keyPhaseSink: AnyCancellable?

    init(store: XiaoyaScriptStore, defaults: UserDefaults, pacing: XiaoyaScriptPacing = .live,
         pairSupported: Bool = XiaoyaScriptRunner.platformPairs, tipsSupported: Bool? = nil,
         makeKeyModel: @escaping @MainActor () -> XiaoyaKeyCardModel = { XiaoyaKeyCardModel() }) {
        self.store = store
        self.defaults = defaults
        self.pacing = pacing
        self.pairSupported = pairSupported
        self.tipsSupported = tipsSupported ?? Self.platformTips
        self.tipStore = XiaoyaTipStore(directory: store.fileURL.deletingLastPathComponent())
        self.glossaryStore = XiaoyaGlossaryStore(directory: store.fileURL.deletingLastPathComponent())
        self.makeKeyModel = makeKeyModel
        self.keyModel = makeKeyModel()
        self.tips = tipStore.load()
        self.glossary = glossaryStore.load()
        self.progress = store.load()
        watchKeyModel()
    }

    /// iPhone 才有「桌面 ↔ 聊天 ↔ 对话列表」三页翻页；iPad 宽屏走右栏面板，同 mac 不发
    static var platformTips: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    nonisolated static var platformPairs: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    func bind(_ engine: AssistantEngine) { self.engine = engine }

    // MARK: 状态

    /// 引导开了还没走完
    var isActive: Bool { progress.map { $0.finishedAt == nil } ?? false }

    /// 钥匙存好之前锁输入框（只能照着卡片答）；走完了放开
    var locksInput: Bool { isActive && progress?.keySaved != true }

    /// 小白线在等她随便说一句
    var awaitingTalk: Bool {
        guard let p = progress, isActive, p.step == .newbieTalk else { return false }
        return p.emitted >= beats(for: p).count
    }

    var inputPlaceholder: String? {
        if locksInput { return "照着上面的卡片回答就好～" }
        if awaitingTalk { return "随便说点什么…" }
        return nil
    }

    var suggestions: [String] { awaitingTalk ? XiaoyaScriptLines.newbieSuggestions : [] }

    /// 召回 chips：引导没在走（走完了 / 从没走过的老用户）才给
    var showsRecallChips: Bool { !isActive }

    // MARK: 开始 / 接上

    /// 从开场白放起（P5 新装判定 / DEBUG「从头放一遍」）。不清历史，剧本消息接在后面
    func start() {
        stopPlaying()
        mood = nil
        typingCount = 0
        resetKeyModel()
        defaults.set("started", forKey: Self.onboardingKey)
        progress = XiaoyaScriptProgress()
        play()
    }

    /// 设置「?」→ 新手引导（§7-5）：先画一条「再走一遍」分隔线，从分流卡重来。历史不清；xiaoyaV1 不改回 started
    /// （走过 / 老用户重走不该挡推送、挡草稿恢复）；proMode 只有重新选了园丁类型才重写（选卡那一步本来就写）
    func replay() {
        stopPlaying()
        mood = nil
        typingCount = 0
        resetKeyModel()
        engine?.messages.append(AssistantChatMessage(isUser: false, text: XiaoyaScriptLines.replayDivider, source: .divider))
        var p = XiaoyaScriptProgress()
        p.step = .replay
        progress = p
        play()
    }

    /// 视图出现时把落地能力交进来；引导没走完就原地接上（重建后从没答的卡接着等）
    func attach(world: XiaoyaScriptWorld) {
        self.world = world
        resume()
    }

    private func resume() {
        guard let p = progress, isActive, playTask == nil, let engine else { return }
        progress = Self.resumable(p, messageIds: Set(engine.messages.map(\.id)), pairSupported: pairSupported, tipsSupported: tipsSupported)
        play()
    }

    /// 接上之前把等待状态理成这台设备答得了的（纯函数）：
    /// ① 平台：iPhone 备份里停在扫码卡、恢复到 mac（mac 画不出扫码卡）→ 改走 mac 的「连手机只指路」再收尾（sol #3）；
    /// ② 最后一拍要等答案（选择卡 / 表单 / 新楼层出口卡）但那张卡不在历史里（history.json 0.5 s 合并写没来得及落盘）→ 退一拍重出（sol #2）。
    /// 出口卡按 script.json 里记的 Ta（id / 名字 / meta）重拼，不重建楼层
    static func resumable(_ progress: XiaoyaScriptProgress, messageIds: Set<UUID>, pairSupported: Bool,
                          tipsSupported: Bool = false) -> XiaoyaScriptProgress {
        var p = progress
        if p.step == .techPair, !pairSupported {
            p.step = .techPhone
            p.emitted = 0
            p.awaitingMessageId = nil
        }
        // 旧版出口卡是 tavernDone / companionDone 的最后一拍（第 11 段拆到 *Exit）：升级前停在那张卡上的，挪到新节点接着等
        if let exit = [XiaoyaScriptNode.tavernDone: XiaoyaScriptNode.tavernExit, .companionDone: .companionExit][p.step],
           p.emitted >= beats(for: p, pairSupported: pairSupported, tipsSupported: tipsSupported).count {
            p.step = exit
            p.emitted = 1
        }
        let beats = beats(for: p, pairSupported: pairSupported, tipsSupported: tipsSupported)
        if p.emitted >= beats.count, let last = beats.last, last.awaitsAnswer,
           !(p.awaitingMessageId.map(messageIds.contains) ?? false) {
            p.emitted = beats.count - 1
            p.awaitingMessageId = nil
        }
        return p
    }

    /// 测试用：等主线和召回都走到停下来的地方
    func idle() async {
        while playTask != nil || sideTask != nil {
            if let playTask { await playTask.value }
            if let sideTask { await sideTask.value; if self.sideTask == sideTask { self.sideTask = nil } }
        }
    }

    // MARK: 答卡

    func answer(_ messageId: UUID, _ answer: XiaoyaCardAnswer) {
        guard let engine, let index = engine.messages.firstIndex(where: { $0.id == messageId }),
              let state = engine.messages[index].card else { return }
        // 出口：每点一次「去找 X」切一次，不记成答案
        if case .floor(.go) = answer {
            if case .goTa(let ta) = state.card { go(to: ta.profileId); return }
            if state.answer != nil, case .floorExit(let payload) = state.card { go(to: payload.ta.profileId); return }
        }
        guard state.answer == nil, answer.closesCard else { return }
        let isMain = isActive && progress?.awaitingMessageId == messageId
        // 只在剧本里才有意义的选择卡（上一轮没答完的分流卡之类），不在等它就不收
        if !isMain, case .choice = state.card { return }
        engine.messages[index].card?.answer = answer
        engine.messages[index].text = Self.fallbackText(state.card, answer)
        if XiaoyaStickerRule.stamps(answer) { freshStamp = messageId }
        if case .keySaved = answer { resetKeyModel() }
        if isMain {
            continueMain(after: state.card, answer)
        } else {
            recall(after: state.card, answer)
        }
    }

    /// 真 AI 回完一句（小白线「跟我说句话」那一步等的就是它）
    func replyFinished() {
        guard awaitingTalk else { return }
        advance(to: .newbieAfterTalk)
    }

    /// 她发话了：剧本表情让位
    func userSpoke() { mood = nil }

    /// 卡角星爆「啪」完了（只动一次）
    func stampPlayed(_ messageId: UUID) {
        if freshStamp == messageId { freshStamp = nil }
    }

    /// 灯泡列表里点开一张 tip：算看过
    func openTip(_ ref: XiaoyaTipRef) {
        guard tips.markSeen(ref) else { return }
        tipStore.save(tips)
    }

    // MARK: 本地关键词（§7-4）

    /// 整句恰好是「配钥匙 / 建一个 Ta / 连电脑 / 导卡」：剧本接，不发给模型。返回 true = 接了
    func intercept(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard XiaoyaScriptLines.recallChips.contains(t), let engine else { return false }
        engine.messages.append(AssistantChatMessage(isUser: true, text: t, source: .script))
        mood = nil
        side { [self] in
            switch t {
            case XiaoyaScriptLines.recallKey:
                await say(XiaoyaScriptLines.recallKeyLine)
                post(.keyForm)
            case XiaoyaScriptLines.recallTa:
                await say(XiaoyaScriptLines.companionAsk)
                post(.nameForm)
            case XiaoyaScriptLines.recallImport:
                await say(XiaoyaScriptLines.tavernAsk)
                post(.importCard)
            default:
                if pairSupported { post(.pair) } else { await say(XiaoyaScriptLines.recallPairMac) }
            }
        }
        return true
    }

    /// 视图里做完的追加导入（世界书 / 预设）报一句结果
    func note(_ line: String) {
        engine?.messages.append(AssistantChatMessage(isUser: false, text: line, source: .script))
    }

    // MARK: 交接（§4.5）

    /// 交接分隔线进 wire 时换成的系统备注（现拼：Ta 楼层这些是交接之后才建的）
    func handoffNote() -> String {
        guard let p = progress else { return "用户刚在这里接好了钥匙，从这句起是真模型在回" }
        var parts: [String] = []
        parts.append("称呼\(callName(p) ?? "没说")")
        if let id = p.identity { parts.append("园丁类型「\(Self.identityTitle(id))」") }
        if p.keySaved {
            let model = p.keyModel.map { "（模型 \($0)）" } ?? ""
            parts.append("已配好 \(p.keyProvider ?? "一家服务商") 的钥匙\(model)")
        }
        parts.append("Ta 的楼层：\(p.taName ?? "还没有")")
        return "用户刚走完开场引导——" + parts.joined(separator: "、")
    }

    /// system prompt「关于你在帮的人」（§7-1：不接记忆系统，现拼 2–4 行）；什么都不知道就不加这层
    func aboutUser(taFloors: [String]) -> String? {
        var lines: [String] = []
        let p = progress
        var head: [String] = []
        if let name = callName(p) { head.append("称呼：\(name)") }
        if let id = p?.identity { head.append("园丁类型：\(Self.identityTitle(id))") }
        if let mac = p?.hasMac { head.append(mac ? "有 Mac" : "没有 Mac") }
        if !head.isEmpty { lines.append(head.joined(separator: "；")) }
        if !taFloors.isEmpty { lines.append("Ta 的楼层：" + taFloors.joined(separator: "、")) }
        if let p, p.keySaved == false, p.keySkipped { lines.append("还没配钥匙（引导里跳过了）") }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// 称呼：默认称呼 → 起名卡填的；都没有 nil。默认称呼在前：卡上填的已经同时写进它，之后设置里改的也只落在它，
    /// 剧本存的那份是当时的快照，排前面会把设置里的新名字永远盖住
    private func callName(_ p: XiaoyaScriptProgress?) -> String? {
        let current = DefaultUserName.value(defaults)
        if !current.isEmpty { return current }
        if let name = p?.userName, !name.isEmpty { return name }
        return nil
    }

    // MARK: 节点 → 拍子（纯函数，小样 run() 逐段对照）

    func beats(for p: XiaoyaScriptProgress) -> [XiaoyaBeat] {
        Self.beats(for: p, pairSupported: pairSupported, tipsSupported: tipsSupported)
    }

    static func beats(for p: XiaoyaScriptProgress, pairSupported: Bool, tipsSupported: Bool = false) -> [XiaoyaBeat] {
        let L = XiaoyaScriptLines.self
        let ta = p.taName ?? p.pendingName?.taName ?? p.pendingImport?.name ?? "Ta"
        let model = p.keyModel ?? "新模型"
        switch p.step {
        case .open:
            return [.mood(.smirk, "在呢")] + L.open.map(XiaoyaBeat.say) + [.card(.choice(.identity))]
        case .replay:
            return [.mood(.smirk, "在呢"), .card(.choice(.identity))]
        case .keyIntro:
            return L.keyIntro(p.identity ?? "newbie").map(XiaoyaBeat.say) + [.mood(.smirk, "等你的钥匙"), .card(.keyForm)]
        case .saved:
            return [.handoff(L.handoff(model: model)), .mood(.cheer, "钥匙好使"), .say(L.keyWorks(model: model)), .goto(branch(p))]
        case .skipkey:
            return [.say(L.keySkipped), .goto(branch(p))]
        case .newbieFace:
            return [.mood(.smirk, "在呢"), .say(L.faceIntro), .card(.face(.user))]
        case .newbieTaFace:
            var beats: [XiaoyaBeat] = []
            if let name = p.userName, !name.isEmpty {
                beats += [.mood(.cheer, "你好，\(name)"), .say(L.faceUserNamed(name))]
            } else {
                beats.append(.say(L.faceUserDefault))
            }
            return beats + [.say(L.faceTaIntro), .mood(.smirk, "在想名字"), .card(.face(.ta))]
        case .newbieFaceDone:
            if let name = p.taFaceName, !name.isEmpty {
                return [.mood(.cheer, "好名字"), .say(L.faceTaNamed(name)), .goto(.keyIntro)]
            }
            return [.say(L.faceTaDefault), .goto(.keyIntro)]
        case .newbieNoKey:
            return [.say(L.newbieNoKey), .goto(.end)]
        case .newbieTalk:
            return [.say(L.newbieTalk), .awaitTalk]
        case .newbieAfterTalk:
            return [.say(L.newbieAfterTalk), .card(.choice(.wantTa))]
        case .tavern:
            return [.say(L.tavernAsk), .card(.importCard)]
        case .tavernDone:
            return [.effect(.buildTavernFloor), .mood(.cheer, "读好了"), .say(L.tavernDone), .goto(.tavernExit)]
        case .tavernExit:
            return [.floorExit(extras: [.worldBook, .preset])]
        case .tavernStay:
            return [.say(L.tavernStay(ta)), .goto(.end)]
        case .companion:
            return [.say(p.fromNewbie ? L.companionAskFromNewbie : L.companionAsk), .card(.nameForm)]
        case .companionDone:
            return [.effect(.buildTa), .say(L.companionNamed(ta)), .goto(.companionExit)]
        case .companionExit:
            return [.floorExit(extras: [.chatHistory])]
        case .survey:
            return [.mood(.smirk, "想多认识你一点"), .say(L.surveyIntro), .card(.survey(name: p.surveyName ?? ""))]
        case .surveyDone:
            return [.effect(.submitSurvey), .say(L.surveyResult(p.surveyResult)), .goto(p.surveyThen ?? .end)]
        case .companionStay:
            return [.say(L.companionStay(ta)), .goto(.end)]
        case .tech:
            guard pairSupported else { return [.say(L.techGuide), .say(L.techAskPhone), .card(.choice(.wantPhone))] }
            return [.say(L.techGuide), .say(L.techAskMac), .card(.choice(.hasMac))]
        case .techPair:
            return [.card(.pair)]
        case .techPhone:
            return [.say(L.techPhoneGuide), .goto(.end)]
        case .ghost:
            return L.ghost.map(XiaoyaBeat.say) + [.card(.info)] + tipBeats(tipsSupported, quiet: false)
                + [.mood(.smirk, "在呢"), .effect(.finish(goToTa: false))]
        case .end, .endQuiet:
            let items = L.todoItems(identity: p.identity ?? "newbie", ta: p.taName, hasKey: p.keySaved)
            var beats: [XiaoyaBeat] = [.mood(.love, "搞定啦"), .say(L.end), .card(.todo(items))]
            if p.step == .end { beats.append(.exitCard) }
            // endQuiet = 出口卡点了「去找 X」，收完尾就切走：tip 只把卡放下（灯泡里能看），不再说话拖时间
            return beats + [.card(.info)] + tipBeats(tipsSupported, quiet: p.step == .endQuiet)
                + [.effect(.finish(goToTa: p.step == .endQuiet))]
        }
    }

    /// 收尾的 Tip 1（§12-B）：info 卡之后、收尾之前只发 1.1；1.2–1.4 等她点「懂了，下一条」（recall 里发），没看的在灯泡里
    static func tipBeats(_ supported: Bool, quiet: Bool) -> [XiaoyaBeat] {
        guard supported, let first = XiaoyaTipCatalog.refs(for: 1).first else { return [] }
        let card = XiaoyaBeat.card(.tip(first))
        if quiet { return [card] }
        return [.mood(.smirk, "教你怎么划"), .say(XiaoyaScriptLines.tipsIntro), card]
    }

    /// 钥匙那一步之后按园丁类型分支（小样 run() 末尾）
    static func branch(_ p: XiaoyaScriptProgress) -> XiaoyaScriptNode {
        switch p.identity {
        case "newbie": return p.keySaved ? .newbieTalk : .newbieNoKey
        case "tavern": return .tavern
        case "companion": return .companion
        case "tech": return .tech
        default: return .end
        }
    }

    // MARK: 主线

    private func continueMain(after card: XiaoyaCard, _ answer: XiaoyaCardAnswer) {
        guard var p = progress else { return }
        p.awaitingMessageId = nil
        var next: XiaoyaScriptNode?
        switch (p.step, answer) {
        case (.open, .picked(let id)), (.replay, .picked(let id)):
            me(Self.identityTitle(id))
            p.identity = id
            // proMode 默认值只在这里写一次（小白 / 陪伴 lite，其余 pro），之后设置里随便改
            defaults.set(id, forKey: "onboardingIdentity")
            defaults.set(!["newbie", "companion"].contains(id), forKey: "settings.proMode")
            switch id {
            case "ghost": next = .ghost
            case "newbie": next = .newbieFace       // 小白先挑头像 + 名字再要钥匙（§11-7）
            default: next = .keyIntro
            }
        case (.newbieFace, .face(let face)):
            me(face.name.isEmpty ? "先这样吧" : "叫我\(face.name)")
            world?.applyFace(face)
            if !face.name.isEmpty { p.userName = face.name }
            next = .newbieTaFace
        case (.newbieTaFace, .face(let face)):
            me(face.name.isEmpty ? "先这样" : "Ta 就叫\(face.name)")
            world?.applyFace(face)
            p.taFaceName = face.name.isEmpty ? nil : face.name
            next = .newbieFaceDone
        case (.keyIntro, .keySaved(let saved)):
            p.keySaved = true
            p.keyProvider = saved.providerName
            p.keyModel = world?.activeModelName() ?? saved.modelId
            next = .saved
        case (.keyIntro, .skipped):
            p.keySkipped = true
            next = .skipkey
        case (.newbieAfterTalk, .picked(let id)):
            if id == "yes" {
                me("好，建一个 Ta")
                p.fromNewbie = true
                next = .companion
            } else {
                me("先跟你聊着")
                next = .end
            }
        case (.tavern, .imported(let imported)):
            p.pendingImport = imported
            p.taMeta = XiaoyaScriptLines.tavernMeta(imported)
            next = .tavernDone
        case (.companion, .named(let named)):
            me("Ta 叫\(named.taName)" + (named.userName.isEmpty ? "" : "，叫我\(named.userName)"))
            p.pendingName = named
            if !named.userName.isEmpty {
                p.userName = named.userName
                world?.setDefaultUserName(named.userName)
            }
            next = .companionDone
        case (.tavernDone, .floor(let choice)), (.companionDone, .floor(let choice)),
             (.tavernExit, .floor(let choice)), (.companionExit, .floor(let choice)):
            if choice == .go {
                next = .endQuiet
            } else {
                me("继续问我")
                next = [.tavernDone, .tavernExit].contains(p.step) ? .tavernStay : .companionStay
            }
        case (.survey, .survey(let answer)):
            me(XiaoyaCardAnswer.survey(answer).summary)
            p.survey = answer
            next = .surveyDone
        case (.tech, .picked(let id)) where pairSupported:
            me(id == "yes" ? "有，连上" : "没有")
            p.hasMac = id == "yes"
            next = id == "yes" ? .techPair : .end
        case (.tech, .picked(let id)):
            // mac 上人就在 Mac 里：问的是要不要连手机，只指路到设置，不出扫码卡（§5.3）
            me(Self.fallbackText(.choice(.wantPhone), .picked(id)))
            p.hasMac = true
            next = id == "yes" ? .techPhone : .end
        case (.techPair, .paired):
            mood = .init(mood: .cheer, status: "连上电脑了")
            next = .end
        case (.techPair, .later):
            next = .end
        default:
            break
        }
        progress = p
        if let next { advance(to: next) }
    }

    private func advance(to node: XiaoyaScriptNode) {
        guard var p = progress else { return }
        p.step = detour(node, &p)
        p.emitted = 0
        p.awaitingMessageId = nil
        progress = p
        play()
    }

    /// 新用户三问（第 11 段）：确定目标楼层之后问一次——引导里建了 Ta，就在出口卡之前问、落 Ta 那层；没建，就在收尾之前问、落当前楼层。
    /// 保持神秘不走这两处；走完引导的老用户不补问，设置里主动重走才会再问
    private func detour(_ node: XiaoyaScriptNode, _ p: inout XiaoyaScriptProgress) -> XiaoyaScriptNode {
        guard [.tavernExit, .companionExit, .end].contains(node), p.surveyThen == nil, let survey = world?.survey,
              let target = p.taProfileId ?? survey.currentProfileId() else { return node }
        p.surveyThen = node
        p.surveyProfileId = target
        p.surveyName = callName(p) ?? ""
        return .survey
    }

    private func play() {
        guard playTask == nil, isActive else { return }
        let token = playToken
        playTask = Task { [weak self] in
            await self?.runMain(token)
            guard let self, self.playToken == token else { return }
            self.playTask = nil
        }
    }

    private func stopPlaying() {
        playToken += 1
        playTask?.cancel()
        playTask = nil
    }

    private enum Outcome {
        case next, wait(UUID?), goto(XiaoyaScriptNode), stall, rewind(XiaoyaScriptNode, Int)
    }

    private func runMain(_ token: Int) async {
        while token == playToken, let p = progress, p.finishedAt == nil {
            let beats = beats(for: p)
            guard p.emitted < beats.count else { return }
            let outcome = await perform(beats[p.emitted], token: token)
            guard token == playToken, var q = progress else { return }
            switch outcome {
            case .next:
                q.emitted += 1
            case .wait(let id):
                q.emitted += 1
                q.awaitingMessageId = id
                progress = q
                return
            case .goto(let node):
                q.step = detour(node, &q)
                q.emitted = 0
            case .stall:
                return
            case .rewind(let node, let emitted):
                q.step = node
                q.emitted = emitted
            }
            progress = q
        }
    }

    private func perform(_ beat: XiaoyaBeat, token: Int) async -> Outcome {
        switch beat {
        case .say(let text):
            await say(text, token: token)
            return .next
        case .handoff(let text):
            engine?.messages.append(AssistantChatMessage(isUser: false, text: text, source: .handoff))
            await pacing.pause(XiaoyaScriptPacing.afterLine)
            return .next
        case .mood(let face, let status):
            mood = .init(mood: face, status: status)
            return .next
        case .card(let card):
            let id = post(card)
            return card.awaitsAnswer ? .wait(id) : .next
        case .floorExit(let extras):
            guard let p = progress else { return .stall }
            let payload = XiaoyaFloorExitPayload(ta: XiaoyaTaRef(profileId: p.taProfileId, name: p.taName ?? "Ta"),
                                                 meta: [.companionDone, .companionExit].contains(p.step) ? XiaoyaScriptLines.companionMeta : (p.taMeta ?? ""),
                                                 extras: extras)
            return .wait(post(.floorExit(payload)))
        case .exitCard:
            if let p = progress, let name = p.taName {
                post(.goTa(XiaoyaTaRef(profileId: p.taProfileId, name: name)))
            } else {
                post(.makeTa)
            }
            return .next
        case .awaitTalk:
            return .wait(nil)
        case .goto(let node):
            return .goto(node)
        case .effect(let effect):
            return await run(effect, token: token)
        }
    }

    private func run(_ effect: XiaoyaScriptEffect, token: Int) async -> Outcome {
        guard let world, var p = progress else { return .stall }
        switch effect {
        case .buildTavernFloor:
            guard let pending = p.pendingImport else { return .next }   // 已经建好了（重建后重放这一拍）
            do {
                let floor = try await world.importCard(pending)
                guard token == playToken, var q = progress else { return .stall }
                q.taProfileId = floor.id
                q.taName = floor.name
                q.pendingImport = nil
                progress = q
                return .next
            } catch {
                guard token == playToken else { return .stall }
                await say(XiaoyaScriptLines.floorFailed(error.localizedDescription), token: token)
                p.pendingImport = nil
                progress = p
                return .rewind(.tavern, 1)   // 重出一张导卡卡
            }
        case .buildTa:
            guard let pending = p.pendingName else { return .next }
            // 先把楼层 id 落进 script.json 再建：建完没来得及记就被杀，重建后同一个 id 复用（sol #4）
            let floorId = p.pendingTaId ?? UUID().uuidString
            if p.pendingTaId == nil {
                p.pendingTaId = floorId
                progress = p
            }
            do {
                let floor = try world.createTa(pending, floorId)
                p.taProfileId = floor.id
                p.taName = floor.name
                p.pendingName = nil
                p.pendingTaId = nil
                progress = p
                return .next
            } catch {
                await say(XiaoyaScriptLines.floorFailed(error.localizedDescription), token: token)
                p.pendingName = nil
                p.pendingTaId = nil
                progress = p
                return .rewind(.companion, 1)   // 重出一张起名卡
            }
        case .submitSurvey:
            guard p.surveyResult == nil else { return .next }
            guard let answer = p.survey, !answer.answers.isEmpty, let target = p.surveyProfileId, let survey = world.survey else {
                p.surveyResult = .empty
                progress = p
                return .next
            }
            // 任务 id 先落进 script.json 再交：交到一半被杀，重放这一拍用同一个 id，不多建
            let taskId = p.surveyTaskId ?? UUID().uuidString
            if p.surveyTaskId == nil {
                p.surveyTaskId = taskId
                progress = p
            }
            let result = await survey.submit(answer, target, taskId)
            guard token == playToken, var q = progress else { return .stall }
            q.surveyResult = result
            progress = q
            return .next
        case .finish(let goToTa):
            defaults.set("done", forKey: Self.onboardingKey)
            // 降级回旧版不再弹六页
            defaults.set(true, forKey: Self.legacyCompletedKey)
            p.finishedAt = Date()
            progress = p
            world.requestPush()
            if goToTa { go(to: p.taProfileId) }
            return .next
        }
    }

    // MARK: 召回（主线没在等的卡：走完引导后点的出口卡、关键词召回出来的卡）

    private func recall(after card: XiaoyaCard, _ answer: XiaoyaCardAnswer) {
        switch answer {
        case .keySaved(let saved):
            let model = world?.activeModelName() ?? saved.modelId
            if var p = progress {
                p.keySaved = true
                p.keyProvider = saved.providerName
                p.keyModel = model
                progress = p
            }
            side { [self] in
                engine?.messages.append(AssistantChatMessage(isUser: false, text: XiaoyaScriptLines.handoff(model: model), source: .handoff))
                mood = .init(mood: .cheer, status: "钥匙好使")
                await say(XiaoyaScriptLines.keyWorks(model: model))
            }
        case .imported(let imported):
            side { [self] in
                guard let world else { return }
                do {
                    let floor = try await world.importCard(imported)
                    noteTa(floor)
                    mood = .init(mood: .cheer, status: "读好了")
                    await say(XiaoyaScriptLines.tavernDone)
                    post(.floorExit(XiaoyaFloorExitPayload(ta: XiaoyaTaRef(profileId: floor.id, name: floor.name),
                                                           meta: XiaoyaScriptLines.tavernMeta(imported), extras: [.worldBook, .preset])))
                } catch {
                    await say(XiaoyaScriptLines.floorFailed(error.localizedDescription))
                    post(.importCard)
                }
            }
        case .named(let named):
            me("Ta 叫\(named.taName)" + (named.userName.isEmpty ? "" : "，叫我\(named.userName)"))
            if !named.userName.isEmpty { world?.setDefaultUserName(named.userName) }
            side { [self] in
                guard let world else { return }
                do {
                    let floor = try world.createTa(named, UUID().uuidString)
                    noteTa(floor)
                    await say(XiaoyaScriptLines.companionNamed(floor.name))
                    post(.floorExit(XiaoyaFloorExitPayload(ta: XiaoyaTaRef(profileId: floor.id, name: floor.name),
                                                           meta: XiaoyaScriptLines.companionMeta, extras: [.chatHistory])))
                } catch {
                    await say(XiaoyaScriptLines.floorFailed(error.localizedDescription))
                    post(.nameForm)
                }
            }
        case .floor(.stay):
            guard case .floorExit(let payload) = card else { return }
            me("继续问我")
            side { [self] in
                await say(payload.extras.contains(.chatHistory)
                          ? XiaoyaScriptLines.companionStay(payload.ta.name) : XiaoyaScriptLines.tavernStay(payload.ta.name))
            }
        case .makeTa:
            side { [self] in
                await say(XiaoyaScriptLines.companionAskFromNewbie)
                post(.nameForm)
            }
        case .paired:
            mood = .init(mood: .cheer, status: "连上电脑了")
        case .tipNext:
            guard case .tip(let ref) = card, let next = XiaoyaTipCatalog.next(after: ref) else { return }
            side { [self] in post(.tip(next)) }
        case .tipLater:
            side { [self] in await say(XiaoyaScriptLines.tipsLater(tips.unseenCount)) }
        default:
            break
        }
    }

    /// 召回里建了 Ta：记成「最近的 Ta」（交接备注 / 关于你在帮的人用）
    private func noteTa(_ floor: Profile) {
        guard var p = progress else { return }
        p.taProfileId = floor.id
        p.taName = floor.name
        progress = p
    }

    /// 召回串成一条队，一段说完再说下一段
    private func side(_ body: @escaping @MainActor () async -> Void) {
        let previous = sideTask
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        sideTask = task
        Task { @MainActor [weak self] in
            await task.value
            if let self, self.sideTask == task { self.sideTask = nil }
        }
    }

    // MARK: 说话 / 出卡

    private func say(_ text: String, token: Int? = nil) async {
        typingCount += 1
        await pacing.pause(XiaoyaScriptPacing.typing(text))
        typingCount = max(0, typingCount - 1)
        if let token, token != playToken { return }
        let message = AssistantChatMessage(isUser: false, text: text, source: .script)
        engine?.messages.append(message)
        noteGlossary(text, messageId: message.id)
        await pacing.pause(XiaoyaScriptPacing.afterLine)
    }

    /// 说了一句带 [[概念词]] 的话：第一次出现的词记下来，解释跟在这句下面（§12-E）
    private func noteGlossary(_ text: String, messageId: UUID) {
        guard !glossary.record(text, messageId: messageId).isEmpty else { return }
        glossaryStore.save(glossary)
    }

    @discardableResult
    private func post(_ card: XiaoyaCard) -> UUID? {
        let message = AssistantChatMessage(isUser: false, text: card.prompt, source: .script, card: XiaoyaCardState(card: card))
        engine?.messages.append(message)
        if case .tip(let ref) = card { noteTip(ref) }
        return engine == nil ? nil : message.id
    }

    /// 发了一张 tip：一组第一次收到时整组进 tips.json（没发的几张算未看），灯泡亮一下；发出来的这张算看过
    private func noteTip(_ ref: XiaoyaTipRef) {
        let fresh = tips.record(ref.number)
        let seen = tips.markSeen(ref)
        if fresh || seen { tipStore.save(tips) }
        if fresh { tipPulse += 1 }
    }

    /// 点卡生成的「你」气泡（小样 me()）：剧本消息，不进模型历史
    private func me(_ text: String) {
        engine?.messages.append(AssistantChatMessage(isUser: true, text: text, source: .script))
    }

    private func go(to profileId: String?) {
        guard let profileId else { return }
        world?.goTo(profileId)
    }

    // MARK: key 卡 → 舞台表情（小样 keyCard 的 mood 调用）

    private func resetKeyModel() {
        keyModel = makeKeyModel()
        watchKeyModel()
    }

    private func watchKeyModel() {
        keyPhaseSink = keyModel.$phase.dropFirst().sink { [weak self] phase in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch phase {
                case .testing: self.mood = .init(mood: .huh, status: "在试钥匙…")
                case .failed: self.mood = .init(mood: .sob, status: "没连上…看下面的原因")
                case .succeeded: self.mood = .init(mood: .cheer, status: "连上啦")
                case .edit: if self.mood?.mood != .smirk { self.mood = .init(mood: .smirk, status: "在呢") }
                }
            }
        }
    }

    // MARK: 纯函数

    /// 恢复了别处走完引导的全量备份（script.json 已收尾）而本机还记着 started（sol #6）：对齐成 done + 旧完成键，
    /// 否则推送授权 / 草稿恢复永远被「引导在走」挡着。只认 started：重走（done / upgraded 下 finishedAt 为 nil）不碰
    nonisolated static func reconcileFinished(defaults: UserDefaults, progress: () -> XiaoyaScriptProgress?) {
        guard defaults.string(forKey: onboardingKey) == "started", progress()?.finishedAt != nil else { return }
        defaults.set("done", forKey: onboardingKey)
        defaults.set(true, forKey: legacyCompletedKey)
    }

    static func identityTitle(_ id: String) -> String {
        XiaoyaChoicePayload.identity.options.first { $0.id == id }?.title ?? id
    }

    /// 答过的卡在消息 text 里留一句人话（旧版 App 显示它）：选择卡写选项标题，不写 id
    static func fallbackText(_ card: XiaoyaCard, _ answer: XiaoyaCardAnswer) -> String {
        if case .picked(let id) = answer, case .choice(let payload) = card,
           let title = payload.options.first(where: { $0.id == id })?.title {
            return title
        }
        return XiaoyaCardState(card: card, answer: answer).fallbackText
    }

    /// key 卡「就用这个」：引导用用户点的模型接管（Adopt.model）；默认 🔑 被占了就挑个没占用的 emoji
    static func commitKey(_ draft: CredentialDraft, key: String, model: String, providerManager pm: ProviderManager) -> String {
        var draft = draft
        if draft.emoji.trimmingCharacters(in: .whitespaces).isEmpty || pm.isEmojiTaken(draft.emoji, excluding: nil) {
            draft.emoji = pm.allocateUnusedEmoji()
        }
        return CredentialCommitter.commit(draft, key: key, existing: nil, adopt: .model(model), providerManager: pm)
    }
}

extension XiaoyaScriptWorld {
    /// 线上：用小芽面板的环境拼（ProfileManager / PresetManager / 卡库 / API 卡都是全 App 那一份）
    static func live(env: AssistantEnv) -> XiaoyaScriptWorld {
        let factory = OnboardingFloorFactory(profiles: env.profileManager, presets: env.presetManager,
                                             cards: env.cardManager, defaults: env.defaults)
        let profiles = env.profileManager
        let pm = env.providerManager
        let defaults = env.defaults
        return XiaoyaScriptWorld(
            importCard: { card in
                guard let url = card.fileURL else { throw CocoaError(.fileNoSuchFile) }
                return try await factory.importCard(at: url)
            },
            createTa: { try factory.createTa(id: $1, name: $0.taName, userName: $0.userName, who: $0.who) },
            goTo: { id in
                guard let floor = profiles.profiles.first(where: { $0.id == id }) else { return }
                XiaoyaApp.leave()
                profiles.switchTo(floor)
            },
            requestPush: {
                #if os(iOS)
                PushAppDelegate.requestAuthorization()
                #endif
            },
            activeModelName: {
                let id = XiaoyaModelChoice.modelId(defaults)
                return id.isEmpty ? nil : pm.model(byId: id)?.modelId
            },
            setDefaultUserName: { DefaultUserName.set($0, defaults: defaults) },
            applyFace: { answer in
                factory.applyFace(answer, avatarJPEG: answer.photo ?? answer.avatar.flatMap { GardenAvatar.jpeg($0) })
            },
            survey: XiaoyaSurveyWorld(
                currentProfileId: { profiles.currentProfile.id },
                submit: { answer, profileId, taskId in
                    factory.applyUserName(answer.name, profileId: profileId)
                    return await CatalogRunner.shared.survey(answer.answers, taskId: taskId, profileId: profileId)
                }))
    }
}
