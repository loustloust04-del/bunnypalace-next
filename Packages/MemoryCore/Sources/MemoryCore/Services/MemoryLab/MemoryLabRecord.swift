import Foundation

/// 记忆实验台的一条记录（plan-memory-lab §3）：她说一句 = 一次实验，五样都在这一份里。
/// 除了编号、那句话、时间，字段全是可选的：以后加字段，旧记录照样读得出。
public struct MemoryLabRecord: Codable, Equatable, Sendable, Identifiable {
    public var schema: Int?
    public var id: String
    public var input: Input
    public var environment: Environment?
    public var params: Params?
    public var happened: Happened?
    public var judgment: Judgment?
    /// 这句话在哪几份测试集里（测试集 id）。只是回指：以测试集文件为准，对不上时听测试集的（`MemoryLabStore.membership`）
    public var sets: [String]?
    /// 「同一句话」的键。自由聊说出来的先没有；第一次被挑进测试集时写成它自己的 `id`，以后重放出来的记录带同一个
    public var sentenceId: String?

    /// 这一句是在哪一组参数下跑的：`MemoryLabParamSet.currentId`（现在的设置）或某组的 id。在一组上改过没存就跑的不写
    public var paramsId: String?

    /// 没写 `sentenceId` 的记录，这句话的键就是它自己的编号
    public var sentence: String { sentenceId ?? id }

    /// 这一句算哪一组的。没写 `paramsId` 的旧记录现推：当时和她的设置一样（`differences` 是空的）算「现在的设置」，否则不算任何一组
    public var paramsGroup: String? {
        paramsId ?? (params?.differences?.isEmpty == true ? MemoryLabParamSet.currentId : nil)
    }

    /// 模型有没有回话。没回话的（问模型失败 / 模型不能用）给不出判断：在一组参数下不算跑过
    public var replied: Bool { happened?.reply != nil }

    public init(id: String, input: Input, environment: Environment? = nil, params: Params? = nil,
                happened: Happened? = nil, judgment: Judgment? = nil, sets: [String]? = nil, sentenceId: String? = nil,
                paramsId: String? = nil) {
        schema = 1
        self.id = id
        self.input = input
        self.environment = environment
        self.params = params
        self.happened = happened
        self.judgment = judgment
        self.sets = sets
        self.sentenceId = sentenceId
        self.paramsId = paramsId
    }

    /// 轻读：一条记录里列表和计数用得上的那几样，不解码整段提示词和回执（`MemoryLabStore.heads`）
    public struct Head: Decodable, Equatable, Sendable, Identifiable {
        public var schema: Int?
        public var id: String
        public var input: Input
        public var sentenceId: String?
        public var judgment: Judgment?
        public var sets: [String]?
        public var paramsId: String?
        /// 整份参数里只解码「跟设置比差在哪」这一样（推旧记录算哪一组用），不解码 `tuning` 那些
        public var params: ParamsHead?

        public struct ParamsHead: Decodable, Equatable, Sendable {
            public var differences: [Difference]?
        }

        /// `happened` 里只看有没有回复（连回复的字都不解码）
        public var happened: HappenedHead?

        public struct HappenedHead: Decodable, Equatable, Sendable {
            public var replied: Bool

            private enum Keys: String, CodingKey { case reply }

            init(replied: Bool) { self.replied = replied }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                replied = container.contains(.reply) && (try? container.decodeNil(forKey: .reply)) == false
            }
        }

        public var sentence: String { sentenceId ?? id }

        /// 同 `MemoryLabRecord.replied`
        public var replied: Bool { happened?.replied == true }

        /// 同 `MemoryLabRecord.paramsGroup`
        public var paramsGroup: String? {
            paramsId ?? (params?.differences?.isEmpty == true ? MemoryLabParamSet.currentId : nil)
        }

        public init(_ record: MemoryLabRecord) {
            schema = record.schema
            id = record.id
            input = record.input
            sentenceId = record.sentenceId
            judgment = record.judgment
            sets = record.sets
            paramsId = record.paramsId
            params = record.params.map { ParamsHead(differences: $0.differences) }
            happened = record.happened.map { HappenedHead(replied: $0.reply != nil) }
        }
    }

    // MARK: 输入

    public struct Input: Codable, Equatable, Sendable {
        public var text: String
        public var at: Date

        public init(text: String, at: Date) {
            self.text = text
            self.at = at
        }
    }

    // MARK: 当时的环境

    public struct Environment: Codable, Equatable, Sendable {
        public var profileId: String?
        public var counts: Counts?
        /// 这一轮能用上的记忆（条目 / 页 / 目录 / 助手的记忆 / 上个窗口）的编号 + 版本的哈希：一样 = 那一刻的记忆一样
        public var fingerprint: String?
        public var presetName: String?
        /// 人设 / 预设 / 世界书那几段（宏没展开的原样）的哈希：不随时间变，只在她改了这些时变
        public var promptHash: String?
        public var appVersion: String?
        public var build: String?
        public var commit: String?
        /// 窗口状态的口径；第一片恒为 `firstTurn`（新开一个窗口说第一句）
        public var window: String?

        public static let firstTurn = "firstTurn"

        public init(profileId: String? = nil, counts: Counts? = nil, fingerprint: String? = nil, presetName: String? = nil,
                    promptHash: String? = nil, appVersion: String? = nil, build: String? = nil, commit: String? = nil,
                    window: String? = nil) {
            self.profileId = profileId
            self.counts = counts
            self.fingerprint = fingerprint
            self.presetName = presetName
            self.promptHash = promptHash
            self.appVersion = appVersion
            self.build = build
            self.commit = commit
            self.window = window
        }
    }

    public struct Counts: Codable, Equatable, Sendable {
        /// 批过的原子事实（不含钉住的）
        public var approvedFacts: Int?
        /// 没删的原子事实，批没批过都算
        public var allFacts: Int?
        public var wikiPages: Int?
        public var pinned: Int?

        public init(approvedFacts: Int? = nil, allFacts: Int? = nil, wikiPages: Int? = nil, pinned: Int? = nil) {
            self.approvedFacts = approvedFacts
            self.allFacts = allFacts
            self.wikiPages = wikiPages
            self.pinned = pinned
        }
    }

    // MARK: 这组参数

    public struct Params: Codable, Equatable, Sendable {
        /// 每轮都带的各项勾没勾，键见 `Item`
        public var items: [String: Bool]?
        /// 原子事实每轮全带
        public var everyRound: Bool?
        /// 系统推送给{助手}
        public var systemPush: Bool?
        /// {助手}主动翻
        public var recallTool: Bool?
        public var tuning: RecallTuning?
        public var model: Model?
        /// 跟她那一刻的设置比差在哪（跑的时候算好存下；空 = 一样）
        public var differences: [Difference]?

        public init(items: [String: Bool]? = nil, everyRound: Bool? = nil, systemPush: Bool? = nil, recallTool: Bool? = nil,
                    tuning: RecallTuning? = nil, model: Model? = nil, differences: [Difference]? = nil) {
            self.items = items
            self.everyRound = everyRound
            self.systemPush = systemPush
            self.recallTool = recallTool
            self.tuning = tuning
            self.model = model
            self.differences = differences
        }
    }

    /// `Params.items` / `Difference.key` 用的键
    public enum Item {
        public static let timeline = "timeline"
        public static let pending = "pending"
        public static let selfMemory = "selfMemory"
        public static let rootIndex = "rootIndex"
        public static let previousWindow = "previousWindow"
        public static let pinned = "pinned"
        public static let everyRound = "everyRound"
        public static let systemPush = "systemPush"
        public static let recallTool = "recallTool"
        public static let model = "model"
        /// 系统推送那一页的数：`tuning.` + `RecallTuning.Field.rawValue`（冷却开关是 `tuning.cooldownEnabled`）
        public static let tuningPrefix = "tuning."
    }

    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var name: String?
        public var provider: String?

        public init(id: String, name: String? = nil, provider: String? = nil) {
            self.id = id
            self.name = name
            self.provider = provider
        }
    }

    public struct Difference: Codable, Equatable, Sendable {
        public var key: String
        /// 她设置里的值
        public var settings: String
        /// 这一次用的值
        public var lab: String

        public init(key: String, settings: String, lab: String) {
            self.key = key
            self.settings = settings
            self.lab = lab
        }
    }

    // MARK: 发生了什么

    public struct Happened: Codable, Equatable, Sendable {
        /// 发给模型的有序消息全文（第一圈；后面每圈是它 + 前面几圈的工具来回）
        public var messages: [Message]?
        /// 和真聊天同一张回执：decision（选中 / 候选 / 为什么没放）、delivery（每轮都带了什么）、reads（主动翻了什么）
        public var receipt: RecallTurnReceipt?
        /// 带记忆比不带记忆，提示词多了什么
        public var prompt: PromptDiff?
        /// 回复原样；问模型失败时是空的，原因在 `error`
        public var reply: String?
        public var error: String?
        /// 每一圈的工具调用和回包
        public var rounds: [Round]?
        public var usage: Usage?
        /// 比真聊天少了哪几段（人话，直接给界面列）
        public var missing: [String]?

        public init(messages: [Message]? = nil, receipt: RecallTurnReceipt? = nil, prompt: PromptDiff? = nil, reply: String? = nil,
                    error: String? = nil, rounds: [Round]? = nil, usage: Usage? = nil, missing: [String]? = nil) {
            self.messages = messages
            self.receipt = receipt
            self.prompt = prompt
            self.reply = reply
            self.error = error
            self.rounds = rounds
            self.usage = usage
            self.missing = missing
        }
    }

    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var content: String
        /// 这一段是哪来的（检查器里那个名字：记忆 / 时间轴 / 对话历史 / 插槽名…）
        public var source: String?

        public init(role: String, content: String, source: String? = nil) {
            self.role = role
            self.content = content
            self.source = source
        }
    }

    public struct PromptDiff: Codable, Equatable, Sendable {
        /// 带记忆时多出来 / 变了的段，按提示词里的顺序
        public var segments: [Segment]?
        /// 记忆那一段里每轮都带的那一层
        public var everyRound: String?
        /// 记忆那一段里因为这句话推送的那一层
        public var pushed: String?

        public init(segments: [Segment]? = nil, everyRound: String? = nil, pushed: String? = nil) {
            self.segments = segments
            self.everyRound = everyRound
            self.pushed = pushed
        }

        public struct Segment: Codable, Equatable, Sendable {
            public var source: String
            public var role: String
            public var with: String
            /// 不带记忆时同一段的样子；nil = 那时没有这一段
            public var without: String?

            public init(source: String, role: String, with: String, without: String? = nil) {
                self.source = source
                self.role = role
                self.with = with
                self.without = without
            }
        }
    }

    public struct Round: Codable, Equatable, Sendable {
        public var calls: [Call]

        public init(calls: [Call]) { self.calls = calls }
    }

    public struct Call: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var arguments: String
        public var result: String?
        public var isError: Bool?

        public init(id: String, name: String, arguments: String, result: String? = nil, isError: Bool? = nil) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.result = result
            self.isError = isError
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        /// 真问了几次模型
        public var requests: Int?
        public var input: Int?
        public var output: Int?
        public var cacheRead: Int?
        public var cacheWrite: Int?
        public var costUSD: Double?

        public init(requests: Int? = nil, input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil,
                    cacheWrite: Int? = nil, costUSD: Double? = nil) {
            self.requests = requests
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.costUSD = costUSD
        }
    }

    // MARK: 她的判断

    public enum Verdict: String, Codable, Sendable { case up, down }

    public struct Judgment: Codable, Equatable, Sendable {
        /// nil = 没看过
        public var verdict: Verdict?
        public var note: String?
        public var at: Date?

        public init(verdict: Verdict? = nil, note: String? = nil, at: Date? = nil) {
            self.verdict = verdict
            self.note = note
            self.at = at
        }
    }
}
