import Foundation

/// 每轮读取的楼层读侧参数快照；后续分页/检索参数只保存配置，不在此启用功能。
public struct RecallTuning: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var archiveTriggerEnabled: Bool = false
    public var cooldownEnabled: Bool = true
    /// NFKC 后字母、汉字、数字达到此长度才按普通新话题处理。
    public var minimumEffectiveLength: Int
    /// 保持话题所需的不同共享有效词数量。
    public var minimumSharedTerms: Int
    /// 保持话题所需的 IDF 加权词面重合率。
    public var activeOverlapThreshold: Double
    /// 未接茬的实际推送连续抑制多少个有效用户轮。
    public var cooldownTurns: Int
    /// 身份命中最多回看多少条真实消息，仍受话题边界限制。
    public var identityLookbackMessages: Int
    /// 自动召回允许带入的真实页与独立卡的页位总数。
    public var maximumPages: Int
    /// 当前真实用户句最多提供多少个不同检索词。
    public var maximumQueryTerms: Int
    /// 汉字检索词至少包含多少个字符。
    public var minimumHanTermLength: Int
    /// 拉丁检索词至少包含多少个字符。
    public var minimumLatinTermLength: Int
    /// 普通全文命中至少需要多少个不同有效词。
    public var minimumFullTextTerms: Int
    /// 普通全文命中至少覆盖多少比例的查询 IDF 权重。
    public var fullTextCoverageThreshold: Double
    /// 新窗上窗快照最多保留多少条可见真实消息。
    public var previousWindowMessages: Int
    /// 每个真实用户轮最多执行多少次 recall 调用。
    public var maximumRecallCalls: Int
    /// 单次 recall 正文最多返回多少个 Swift Character。
    public var maximumBodyCharacters: Int
    /// 单次 recall 含定位元数据的总回包字符上限。
    public var maximumResponseCharacters: Int
    /// 日期翻页每次最多推进多少个记忆日。
    public var datePageDays: Int
    /// 日期页每次最多返回多少条事件。
    public var datePageEvents: Int
    /// 窗口页每次最多列出多少个摘要段。
    public var windowPageSegments: Int
    /// 搜索页每次最多列出多少项命中。
    public var searchPageResults: Int
    /// wiki 索引每页最多返回多少行。
    public var wikiIndexPageLines: Int
    /// wiki 页每次最多返回多少行记录。
    public var wikiPageRecords: Int
    /// 原文页每次最多返回多少条真实消息。
    public var originalPageMessages: Int

    public init(schemaVersion: Int, archiveTriggerEnabled: Bool = false, cooldownEnabled: Bool = true,
                minimumEffectiveLength: Int, minimumSharedTerms: Int, activeOverlapThreshold: Double,
                cooldownTurns: Int, identityLookbackMessages: Int, maximumPages: Int, maximumQueryTerms: Int,
                minimumHanTermLength: Int, minimumLatinTermLength: Int, minimumFullTextTerms: Int,
                fullTextCoverageThreshold: Double, previousWindowMessages: Int, maximumRecallCalls: Int,
                maximumBodyCharacters: Int, maximumResponseCharacters: Int, datePageDays: Int, datePageEvents: Int,
                windowPageSegments: Int, searchPageResults: Int, wikiIndexPageLines: Int, wikiPageRecords: Int,
                originalPageMessages: Int) {
        self.schemaVersion = schemaVersion
        self.archiveTriggerEnabled = archiveTriggerEnabled
        self.cooldownEnabled = cooldownEnabled
        self.minimumEffectiveLength = minimumEffectiveLength
        self.minimumSharedTerms = minimumSharedTerms
        self.activeOverlapThreshold = activeOverlapThreshold
        self.cooldownTurns = cooldownTurns
        self.identityLookbackMessages = identityLookbackMessages
        self.maximumPages = maximumPages
        self.maximumQueryTerms = maximumQueryTerms
        self.minimumHanTermLength = minimumHanTermLength
        self.minimumLatinTermLength = minimumLatinTermLength
        self.minimumFullTextTerms = minimumFullTextTerms
        self.fullTextCoverageThreshold = fullTextCoverageThreshold
        self.previousWindowMessages = previousWindowMessages
        self.maximumRecallCalls = maximumRecallCalls
        self.maximumBodyCharacters = maximumBodyCharacters
        self.maximumResponseCharacters = maximumResponseCharacters
        self.datePageDays = datePageDays
        self.datePageEvents = datePageEvents
        self.windowPageSegments = windowPageSegments
        self.searchPageResults = searchPageResults
        self.wikiIndexPageLines = wikiIndexPageLines
        self.wikiPageRecords = wikiPageRecords
        self.originalPageMessages = originalPageMessages
    }

    public static let defaults = RecallTuning(
        schemaVersion: 1,
        minimumEffectiveLength: 4, minimumSharedTerms: 2, activeOverlapThreshold: 0.5,
        cooldownTurns: 3, identityLookbackMessages: 4, maximumPages: 3,
        maximumQueryTerms: 6, minimumHanTermLength: 2, minimumLatinTermLength: 3,
        minimumFullTextTerms: 2, fullTextCoverageThreshold: 0.6,
        previousWindowMessages: 6, maximumRecallCalls: 3,
        maximumBodyCharacters: 3000, maximumResponseCharacters: 4000,
        datePageDays: 1, datePageEvents: 12, windowPageSegments: 10,
        searchPageResults: 5, wikiIndexPageLines: 30, wikiPageRecords: 10,
        originalPageMessages: 8
    )

    /// 参数元数据集中提供合法范围、界面步长与中文说明；不参与语义分类。
    public enum Field: String, CaseIterable, CodingKey, Sendable {
        case minimumEffectiveLength, minimumSharedTerms, activeOverlapThreshold
        case cooldownTurns, identityLookbackMessages, maximumPages
        case maximumQueryTerms, minimumHanTermLength, minimumLatinTermLength
        case minimumFullTextTerms, fullTextCoverageThreshold, previousWindowMessages
        case maximumRecallCalls, maximumBodyCharacters, maximumResponseCharacters
        case datePageDays, datePageEvents, windowPageSegments, searchPageResults
        case wikiIndexPageLines, wikiPageRecords, originalPageMessages

        public var title: String {
            switch self {
            case .minimumEffectiveLength: "太短的不找"
            case .minimumSharedTerms: "至少几个词一样"
            case .activeOverlapThreshold: "词的分量够不够"
            case .cooldownTurns: "停几句"
            case .identityLookbackMessages: "往回看几条消息"
            case .maximumPages: "一轮最多几页"
            case .maximumQueryTerms: "一句话最多取几个词"
            case .minimumHanTermLength: "汉字词至少几个字"
            case .minimumLatinTermLength: "英文词至少几个字母"
            case .minimumFullTextTerms: "命中至少几个词"
            case .fullTextCoverageThreshold: "分量覆盖"
            case .previousWindowMessages: "上一个窗口最后几条"
            case .maximumRecallCalls: "最多翻几次"
            case .maximumBodyCharacters: "正文最多几个字"
            case .maximumResponseCharacters: "连目录一共最多几个字"
            case .datePageDays: "时间轴：一页几天"
            case .datePageEvents: "时间轴：最多几件事"
            case .windowPageSegments: "窗口总结：一页几段"
            case .searchPageResults: "搜索：一页几条"
            case .wikiIndexPageLines: "档案目录：一页几行"
            case .wikiPageRecords: "档案页记录：一页几条"
            case .originalPageMessages: "原文：一页几条消息"
            }
        }

        public var explanation: String {
            switch self {
            case .minimumEffectiveLength: "去掉标点、表情后不够这么多字就不找（「嗯」「哈哈」不触发）。问「上次」「还记得」这种回看的句子不受这条限制。"
            case .minimumSharedTerms, .activeOverlapThreshold: "这句话和上个话题有这么多词是同一个、而且这些词分量够重，就当还在聊同一件事：上轮带的页接着带，不重新找。切了话题就清掉重找。"
            case .cooldownTurns: "带了一页你没接这个话，之后这么多句不再带它；你点名提到它就解冻。"
            case .identityLookbackMessages: "在最近这几条里找页名和触发词；只看本话题之内，不越过切题的那一句。"
            case .maximumPages: "聊到哪页带哪页"
            case .maximumQueryTerms, .minimumFullTextTerms, .fullTextCoverageThreshold: "页名没对上时搜全文"
            case .minimumHanTermLength, .minimumLatinTermLength: "比这短的词不参与匹配。单字名字的楼层把汉字那条调到 1。"
            case .previousWindowMessages: "开新窗口时记下最后聊的那个窗口最后这么多条，这个窗口每轮都带。"
            case .maximumRecallCalls: "同一句话里助手最多调几次翻记忆；翻错、翻下一页都算。"
            case .maximumBodyCharacters, .maximumResponseCharacters: "一次读多少"
            case .datePageDays, .datePageEvents, .windowPageSegments, .searchPageResults,
                 .wikiIndexPageLines, .wikiPageRecords, .originalPageMessages: "每页多少"
            }
        }

        public enum Page: String, Sendable {
            case archiveTrigger = "档案触发"
            case recallBrowse = "翻记忆"
            case openWindow = "开窗口带什么"
        }

        public var page: Page {
            switch self {
            case .previousWindowMessages: .openWindow
            case .maximumRecallCalls, .maximumBodyCharacters, .maximumResponseCharacters,
                 .datePageDays, .datePageEvents, .windowPageSegments, .searchPageResults,
                 .wikiIndexPageLines, .wikiPageRecords, .originalPageMessages: .recallBrowse
            default: .archiveTrigger
            }
        }

        public var group: String {
            switch self {
            case .minimumEffectiveLength: "什么时候找"
            case .minimumSharedTerms, .activeOverlapThreshold: "还在聊同一件事"
            case .cooldownTurns: "冷却"
            case .identityLookbackMessages, .minimumHanTermLength, .minimumLatinTermLength: "怎么找页"
            case .maximumPages: "自动想起 · 聊到了才带"
            case .maximumQueryTerms, .minimumFullTextTerms, .fullTextCoverageThreshold: "全文兜底"
            case .previousWindowMessages: "每轮都带的"
            case .maximumRecallCalls: "一轮翻几次"
            case .maximumBodyCharacters, .maximumResponseCharacters: "一次读多少"
            default: "每页多少"
            }
        }

        public var connectedSlice: Int {
            switch self {
            case .maximumQueryTerms, .minimumFullTextTerms, .fullTextCoverageThreshold: 2
            case .maximumBodyCharacters, .maximumResponseCharacters, .datePageDays, .datePageEvents,
                 .windowPageSegments, .searchPageResults, .wikiIndexPageLines,
                 .wikiPageRecords, .originalPageMessages: 3
            case .previousWindowMessages: 4
            default: 1
            }
        }

        public static let archiveTriggerFields: Set<Field> = Set(allCases.filter {
            $0.page == .archiveTrigger && $0 != .maximumPages
        })

        public static let recallBrowseFields: Set<Field> = Set(allCases.filter { $0.page == .recallBrowse })

        public var range: ClosedRange<Double> {
            switch self {
            case .minimumEffectiveLength: 1...100
            case .minimumSharedTerms: 1...32
            case .activeOverlapThreshold, .fullTextCoverageThreshold: 0...1
            case .cooldownTurns: 0...30
            case .identityLookbackMessages, .maximumQueryTerms, .minimumFullTextTerms,
                 .previousWindowMessages, .maximumRecallCalls: 1...50
            case .maximumPages, .minimumHanTermLength: 1...20
            case .minimumLatinTermLength: 1...30
            case .maximumBodyCharacters: 100...30000
            case .maximumResponseCharacters: 100...40000
            case .datePageDays: 1...31
            case .datePageEvents, .windowPageSegments, .searchPageResults,
                 .wikiPageRecords, .originalPageMessages: 1...100
            case .wikiIndexPageLines: 1...300
            }
        }

        public var isFraction: Bool {
            self == .activeOverlapThreshold || self == .fullTextCoverageThreshold
        }

        public var step: Double {
            switch self {
            case .activeOverlapThreshold, .fullTextCoverageThreshold: 0.05
            case .maximumBodyCharacters, .maximumResponseCharacters: 100
            default: 1
            }
        }

        public var integerKeyPath: WritableKeyPath<RecallTuning, Int>? {
            switch self {
            case .minimumEffectiveLength: \.minimumEffectiveLength
            case .minimumSharedTerms: \.minimumSharedTerms
            case .cooldownTurns: \.cooldownTurns
            case .identityLookbackMessages: \.identityLookbackMessages
            case .maximumPages: \.maximumPages
            case .maximumQueryTerms: \.maximumQueryTerms
            case .minimumHanTermLength: \.minimumHanTermLength
            case .minimumLatinTermLength: \.minimumLatinTermLength
            case .minimumFullTextTerms: \.minimumFullTextTerms
            case .previousWindowMessages: \.previousWindowMessages
            case .maximumRecallCalls: \.maximumRecallCalls
            case .maximumBodyCharacters: \.maximumBodyCharacters
            case .maximumResponseCharacters: \.maximumResponseCharacters
            case .datePageDays: \.datePageDays
            case .datePageEvents: \.datePageEvents
            case .windowPageSegments: \.windowPageSegments
            case .searchPageResults: \.searchPageResults
            case .wikiIndexPageLines: \.wikiIndexPageLines
            case .wikiPageRecords: \.wikiPageRecords
            case .originalPageMessages: \.originalPageMessages
            case .activeOverlapThreshold, .fullTextCoverageThreshold: nil
            }
        }

        public func value(in tuning: RecallTuning) -> Double {
            if let path = integerKeyPath { return Double(tuning[keyPath: path]) }
            return self == .activeOverlapThreshold ? tuning.activeOverlapThreshold : tuning.fullTextCoverageThreshold
        }

        public func set(_ value: Double, in tuning: inout RecallTuning) {
            let finite = value.isFinite ? value : self.value(in: .defaults)
            let bounded = min(max(finite, range.lowerBound), range.upperBound)
            if let path = integerKeyPath {
                tuning[keyPath: path] = Int(bounded.rounded())
            } else if self == .activeOverlapThreshold {
                tuning.activeOverlapThreshold = bounded
            } else {
                tuning.fullTextCoverageThreshold = bounded
            }
            if self == .maximumBodyCharacters || self == .maximumResponseCharacters {
                tuning.maximumBodyCharacters = min(tuning.maximumBodyCharacters, tuning.maximumResponseCharacters)
            }
        }
    }

    public var validated: RecallTuning {
        var result = self
        result.schemaVersion = Self.defaults.schemaVersion
        // 先规范化总回包，再逐字段写入原始值，避免正文被旧总限额提前收紧。
        Field.maximumResponseCharacters.set(Double(maximumResponseCharacters), in: &result)
        for field in Field.allCases { field.set(field.value(in: self), in: &result) }
        return result
    }

    // 手写 Codable 只为兼容缺字段的旧配置；完整显式成员初始化仍由编译器生成。
    private enum VersionKey: String, CodingKey { case schemaVersion, archiveTriggerEnabled, cooldownEnabled }

    public func encode(to encoder: Encoder) throws {
        var version = encoder.container(keyedBy: VersionKey.self)
        try version.encode(schemaVersion, forKey: .schemaVersion)
        try version.encode(archiveTriggerEnabled, forKey: .archiveTriggerEnabled)
        try version.encode(cooldownEnabled, forKey: .cooldownEnabled)
        var fields = encoder.container(keyedBy: Field.self)
        for field in Field.allCases {
            if let path = field.integerKeyPath {
                try fields.encode(self[keyPath: path], forKey: field)
            } else {
                try fields.encode(field.value(in: self), forKey: field)
            }
        }
    }
}

public extension RecallTuning {
    init(from decoder: Decoder) throws {
        self = Self.defaults
        let version = try decoder.container(keyedBy: VersionKey.self)
        schemaVersion = try version.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.defaults.schemaVersion
        archiveTriggerEnabled = try version.decodeIfPresent(Bool.self, forKey: .archiveTriggerEnabled) ?? Self.defaults.archiveTriggerEnabled
        cooldownEnabled = try version.decodeIfPresent(Bool.self, forKey: .cooldownEnabled) ?? Self.defaults.cooldownEnabled
        let fields = try decoder.container(keyedBy: Field.self)
        for field in Field.allCases {
            if let path = field.integerKeyPath {
                if let value = try fields.decodeIfPresent(Int.self, forKey: field) { self[keyPath: path] = value }
            } else if let value = try fields.decodeIfPresent(Double.self, forKey: field) {
                if field == .activeOverlapThreshold { activeOverlapThreshold = value }
                else { fullTextCoverageThreshold = value }
            }
        }
    }
}

/// 单个结构化设置存档内按显式楼层 ID 分区；切楼层无需搬动全局键。
public enum RecallTuningStore {}

public extension RecallTuningStore {
    static let storageKey = "recallTuningByProfile_v1"
    private static let lock = NSLock()

    static func load(profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> RecallTuning {
        lock.lock()
        defer { lock.unlock() }
        return archive(defaults: defaults)[profileId]?.validated ?? .defaults
    }

    static func save(_ tuning: RecallTuning, profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) {
        lock.lock()
        defer { lock.unlock() }
        var values = archive(defaults: defaults)
        values[profileId] = tuning.validated
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: storageKey) }
    }

    static func reset(profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) {
        lock.lock()
        defer { lock.unlock() }
        var values = archive(defaults: defaults)
        values.removeValue(forKey: profileId)
        if values.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func reset(profileId: String, fields: Set<RecallTuning.Field>, defaults: UserDefaults = MemoryReadEnvironment.defaults) {
        lock.lock()
        defer { lock.unlock() }
        var values = archive(defaults: defaults)
        var tuning = values[profileId]?.validated ?? .defaults
        if fields.contains(.maximumResponseCharacters) {
            RecallTuning.Field.maximumResponseCharacters.set(Double(RecallTuning.defaults.maximumResponseCharacters), in: &tuning)
        }
        for field in fields { field.set(field.value(in: .defaults), in: &tuning) }
        values[profileId] = tuning.validated
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: storageKey) }
    }

    private static func archive(defaults: UserDefaults) -> [String: RecallTuning] {
        guard let data = defaults.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([String: RecallTuning].self, from: data) else { return [:] }
        return values
    }
}
