import Foundation
import SwiftData

// MARK: - Character Card (全局资产，存 BlobStore)

struct CharacterCard: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var description: String = ""
    var personality: String = ""
    var scenario: String = ""
    var firstMes: String = ""
    var alternateGreetings: [String] = []
    var mesExample: String = ""
    var systemPrompt: String = ""
    var postHistoryInstructions: String = ""
    var creatorNotes: String = ""
    /// ⑧c-4：原 PNG / 原 JSON envelope 拆到 cardlibrary/cards/<卡id>.<ext>，blob 只留引用；`imageData` / `rawJSONData` 按需读文件
    var originals = CardOriginals()
    var characterBookName: String?
    var characterBookEntriesData: Data?  // JSON encoded [[String: Any]]
    var createdAt: Date = Date()
    var regexScripts: [RegexScript] = []
    var tags: [String] = []
    var creator: String?
    var characterVersion: String?
    enum BindingState: String, Codable { case unbound, active, missing }
    enum ExtensionConsent: String, Codable { case unknown, allowed, deferred }
    var linkedProfileId: String?
    var bindingState: BindingState = .unbound
    var extensionConsent: ExtensionConsent = .unknown
    /// 第二批 B5：卡里网页「替你发消息」（问我 / 直接发 / 只填输入框）；blob 缺键 = unknown，unknown 不写键
    var sendConsent: CardSendConsent = .unknown
    var archivedAt: Date?

    /// 判空不改正文，重复的候选也保留。
    var greetings: [String] {
        ([firstMes] + alternateGreetings).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var scriptCount: Int {
        // 原 JSON 已拆到文件：用落盘时记下的数，卡墙不为了角标整读原件
        if originals.inlineRawJSON == nil, let cached = originals.scriptCount { return cached }
        return scriptPayloads.reduce(0) { $0 + Self.scriptCount($1) }
    }

    /// 脚本树计数：文件夹按里面的脚本数算（助手 flattenScriptTree 同口径）
    static func scriptCount(_ tree: [Any]) -> Int {
        tree.reduce(0) { n, item in
            guard let dict = item as? [String: Any], dict["type"] as? String == "folder" else { return n + 1 }
            return n + (dict["scripts"] as? [Any] ?? []).count
        }
    }

    private var scriptPayloads: [[Any]] {
        guard let rawJSONData,
              let raw = try? JSONSerialization.jsonObject(with: rawJSONData) as? [String: Any] else { return [] }
        let data = raw["data"] as? [String: Any] ?? raw
        return [Self.helperScripts(data["extensions"] as? [String: Any] ?? [:])]
    }

    /// 酒馆助手的卡脚本（第二批 B1，照助手 store/settings/character.ts）：`tavern_helper` 是字典或键值对数组
    /// （`Object.fromEntries`，同键后者为准）；有新键就不看旧键 `TavernHelper_scripts`
    static func helperScripts(_ extensions: [String: Any]) -> [Any] {
        if let helper = extensions["tavern_helper"] {
            if let object = helper as? [String: Any] { return object["scripts"] as? [Any] ?? [] }
            let pairs = (helper as? [Any] ?? []).compactMap { $0 as? [Any] }
            return pairs.last { $0.count == 2 && ($0[0] as? String) == "scripts" }?[1] as? [Any] ?? []
        }
        return extensions["TavernHelper_scripts"] as? [Any] ?? []
    }

    /// 后台脚本正文（文件夹展开）：静态扫描「用到了还不支持的」用。读原 JSON 文件，别放在频繁刷新的地方
    var helperScriptSources: [String] {
        (scriptPayloads.first ?? []).flatMap { item -> [String] in
            guard let dict = item as? [String: Any] else { return [] }
            if dict["type"] as? String == "folder" {
                return (dict["scripts"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["content"] as? String }
            }
            return [dict["content"] as? String].compactMap { $0 }
        }
    }

    /// 开场 / 备选开场里有前端网页（`<script` 或助手的前端识别标记）
    var hasFrontendGreeting: Bool { greetings.contains(where: CardFrontendDetector.isFrontend) }

    /// 要问许可的卡：带正则 / 后台脚本，或纯前端（开场网页）——角色页许可横幅、设置页授权列表同一口径
    var needsExtensionConsent: Bool { !regexScripts.isEmpty || scriptCount > 0 || hasFrontendGreeting }

    /// 静态扫描：后台脚本 + 开场 + 正则替换模板里用到的本批不支持功能（读原 JSON 文件）
    var unsupportedFeatures: [CardUnsupportedFeature] {
        CardFeatureScanner.scan(helperScriptSources + greetings + regexScripts.map(\.replaceString))
    }

    func hasSameExtensions(as other: CharacterCard) -> Bool {
        guard regexScripts == other.regexScripts else { return false }
        // 同一份原 JSON（内容 sha 相同）脚本必然相同，不用读两遍文件
        if originals.rawJSONSHA256 == other.originals.rawJSONSHA256 { return true }
        return NSArray(array: scriptPayloads).isEqual(to: other.scriptPayloads)
    }

    /// 无绑定楼层卡的导出始终从当前楼层生成，不另存快照。
    init(profile: Profile) {
        name = profile.name
        description = profile.characterDescription
        personality = profile.characterPersonality
        scenario = profile.scenario
        mesExample = profile.chatExamples
        systemPrompt = profile.systemPrompt
        postHistoryInstructions = profile.postInstructions
        imageData = profile.coverImageData
    }

    /// 是否包含世界书
    var hasWorldBook: Bool {
        if let data = characterBookEntriesData,
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return !entries.isEmpty
        }
        return false
    }

    /// 世界书条目数
    var worldBookEntryCount: Int {
        guard let data = characterBookEntriesData,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return entries.count
    }

    /// 世界书原始条目
    var characterBookEntries: [[String: Any]] {
        guard let data = characterBookEntriesData,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries
    }

    /// 从 TavernCard 解析结果转换
    init(from card: TavernCard) {
        self.name = card.name
        self.rawJSONData = card.rawJSONData
        self.regexScripts = card.regexScripts.map { RegexScript(from: $0) }
        self.tags = card.tags
        self.creator = card.creator
        self.characterVersion = card.characterVersion
        self.description = card.description
        self.personality = card.personality
        self.scenario = card.scenario
        self.firstMes = card.firstMes
        self.alternateGreetings = card.alternateGreetings
        self.mesExample = card.mesExample
        self.systemPrompt = card.systemPrompt
        self.postHistoryInstructions = card.postHistoryInstructions
        self.creatorNotes = card.creatorNotes
        self.imageData = card.imageData
        // ⑧c-4：封面 / 楼层头像用 ≤512px 缩略图，原 PNG 只在卡上留一份
        self.originals.thumbnail = CardImageThumbnail.make(from: card.imageData)
        self.characterBookName = card.characterBookName
        // characterBookEntries 是 [[String: Any]]，不能直接 Codable，转 JSON Data
        if !card.characterBookEntries.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: card.characterBookEntries) {
            self.characterBookEntriesData = data
        }
    }
}

extension CharacterCard {
    enum CodingKeys: String, CodingKey {
        case id, name, description, personality, scenario, firstMes, mesExample, systemPrompt
        case postHistoryInstructions, creatorNotes, alternateGreetings, imageData
        case characterBookName, characterBookEntriesData, createdAt, rawJSONData
        case regexScripts, tags, creator, characterVersion
        case linkedProfileId, bindingState, extensionConsent, archivedAt
        // ⑧c-4：原件拆出后的引用 + 派生字段
        case imageFile, rawJSONFile, imageSHA256, rawJSONSHA256, thumbnailData, scriptCount
        case scriptCountVersion
        case sendConsent
    }

    /// ⑧c-4 之前的编码（原件内嵌、没有引用字段）。只给撤回比对旧的首次内容 hash 用
    static let legacyInlineEncoding = CodingUserInfoKey(rawValue: "CharacterCard.legacyInlineEncoding")!
    /// 第二批 B1 之前的编码（脚本数缓存按旧算法、没有版本号）。只给撤回比对旧的首次内容 hash 用
    static let preB1Encoding = CodingUserInfoKey(rawValue: "CharacterCard.preB1Encoding")!

    /// B1 之前的脚本数算法（只认字典形态的 `tavern_helper`，再加上旧键），只给 preB1 编码复现旧 hash
    private var preB1ScriptCount: Int {
        guard let rawJSONData,
              let raw = try? JSONSerialization.jsonObject(with: rawJSONData) as? [String: Any] else { return 0 }
        let data = raw["data"] as? [String: Any] ?? raw
        let extensions = data["extensions"] as? [String: Any] ?? [:]
        let helper = extensions["tavern_helper"] as? [String: Any] ?? [:]
        return (helper["scripts"] as? [Any] ?? []).count + (extensions["TavernHelper_scripts"] as? [Any] ?? []).count
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(personality, forKey: .personality)
        try c.encode(scenario, forKey: .scenario)
        try c.encode(firstMes, forKey: .firstMes)
        try c.encode(alternateGreetings, forKey: .alternateGreetings)
        try c.encode(mesExample, forKey: .mesExample)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(postHistoryInstructions, forKey: .postHistoryInstructions)
        try c.encode(creatorNotes, forKey: .creatorNotes)
        try c.encodeIfPresent(characterBookName, forKey: .characterBookName)
        try c.encodeIfPresent(characterBookEntriesData, forKey: .characterBookEntriesData)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(regexScripts, forKey: .regexScripts)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(creator, forKey: .creator)
        try c.encodeIfPresent(characterVersion, forKey: .characterVersion)
        try c.encodeIfPresent(linkedProfileId, forKey: .linkedProfileId)
        try c.encode(bindingState, forKey: .bindingState)
        try c.encode(extensionConsent, forKey: .extensionConsent)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        if encoder.userInfo[Self.legacyInlineEncoding] as? Bool == true {
            try c.encodeIfPresent(imageData, forKey: .imageData)
            try c.encodeIfPresent(rawJSONData, forKey: .rawJSONData)
            return
        }
        // 还没拆出去的（新建 / 改过还没落盘）按旧键内嵌；CharacterCardManager 写 blob 前一律拆出
        try c.encodeIfPresent(originals.inlineImage, forKey: .imageData)
        try c.encodeIfPresent(originals.inlineRawJSON, forKey: .rawJSONData)
        try c.encodeIfPresent(originals.imageFile, forKey: .imageFile)
        try c.encodeIfPresent(originals.rawJSONFile, forKey: .rawJSONFile)
        try c.encodeIfPresent(originals.imageSHA256, forKey: .imageSHA256)
        try c.encodeIfPresent(originals.rawJSONSHA256, forKey: .rawJSONSHA256)
        try c.encodeIfPresent(originals.thumbnail, forKey: .thumbnailData)
        if encoder.userInfo[Self.preB1Encoding] as? Bool == true {
            try c.encodeIfPresent(originals.scriptCount.map { _ in preB1ScriptCount }, forKey: .scriptCount)
            return
        }
        try c.encodeIfPresent(originals.scriptCount, forKey: .scriptCount)
        if originals.scriptCount != nil { try c.encode(CardOriginals.scriptCountVersion, forKey: .scriptCountVersion) }
        // B5：只在问过之后写键，没问过的卡 blob 字节不变（撤回 / 导入指纹不受影响）
        if sendConsent != .unknown { try c.encode(sendConsent, forKey: .sendConsent) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        scenario = try c.decodeIfPresent(String.self, forKey: .scenario) ?? ""
        firstMes = try c.decodeIfPresent(String.self, forKey: .firstMes) ?? ""
        mesExample = try c.decodeIfPresent(String.self, forKey: .mesExample) ?? ""
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        postHistoryInstructions = try c.decodeIfPresent(String.self, forKey: .postHistoryInstructions) ?? ""
        creatorNotes = try c.decodeIfPresent(String.self, forKey: .creatorNotes) ?? ""
        alternateGreetings = try c.decodeIfPresent([String].self, forKey: .alternateGreetings) ?? []
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        characterBookName = try c.decodeIfPresent(String.self, forKey: .characterBookName)
        characterBookEntriesData = try c.decodeIfPresent(Data.self, forKey: .characterBookEntriesData)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        rawJSONData = try c.decodeIfPresent(Data.self, forKey: .rawJSONData)
        regexScripts = try c.decodeIfPresent([RegexScript].self, forKey: .regexScripts) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        characterVersion = try c.decodeIfPresent(String.self, forKey: .characterVersion)
        linkedProfileId = try c.decodeIfPresent(String.self, forKey: .linkedProfileId)
        bindingState = try c.decodeIfPresent(BindingState.self, forKey: .bindingState) ?? .unbound
        extensionConsent = try c.decodeIfPresent(ExtensionConsent.self, forKey: .extensionConsent) ?? .unknown
        sendConsent = (try? c.decodeIfPresent(CardSendConsent.self, forKey: .sendConsent)) ?? .unknown
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        if originals.inlineImage == nil {
            originals.imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
            originals.imageSHA256 = try c.decodeIfPresent(String.self, forKey: .imageSHA256)
        }
        if originals.inlineRawJSON == nil {
            originals.rawJSONFile = try c.decodeIfPresent(String.self, forKey: .rawJSONFile)
            originals.rawJSONSHA256 = try c.decodeIfPresent(String.self, forKey: .rawJSONSHA256)
            // 旧算法的缓存（没版本号 / 版本对不上）不要，管理器读出后重算
            if try c.decodeIfPresent(Int.self, forKey: .scriptCountVersion) == CardOriginals.scriptCountVersion {
                originals.scriptCount = try c.decodeIfPresent(Int.self, forKey: .scriptCount)
            }
        }
        originals.thumbnail = try c.decodeIfPresent(Data.self, forKey: .thumbnailData)
    }

    /// 原 PNG：内存里有（新建 / 改过 / 老数据内嵌）就直接给，已拆出就读文件（每次读，调用方别放在频繁刷新的地方）
    var imageData: Data? {
        get { originals.inlineImage ?? originals.read(originals.imageFile) }
        set {
            originals.inlineImage = newValue
            originals.imageFile = nil
            originals.imageSHA256 = newValue.map(CardLibraryStorage.sha256)
            originals.thumbnail = nil
        }
    }

    /// 原 JSON envelope：同上
    var rawJSONData: Data? {
        get { originals.inlineRawJSON ?? originals.read(originals.rawJSONFile) }
        set {
            originals.inlineRawJSON = newValue
            originals.rawJSONFile = nil
            originals.rawJSONSHA256 = newValue.map(CardLibraryStorage.sha256)
            originals.scriptCount = nil
        }
    }

    /// 封面显示用：有缩略图用缩略图，不整读原 PNG
    var coverImageData: Data? { originals.thumbnail ?? imageData }

    func decodeWorldBook() throws -> WorldBookCodec.Report {
        if let rawJSONData { return try WorldBookCodec.decodeCharacterBook(rawJSONData) }
        let data = try JSONSerialization.data(withJSONObject: [
            "name": characterBookName ?? "\(name)的世界书", "entries": characterBookEntries
        ])
        return try WorldBookCodec.decodeCharacterBook(data)
    }

    /// 只覆盖真正改过的受支持字段，未编辑时连 JSON 排版也不动。
    func exportJSON() throws -> Data {
        let original = try rawJSONData.map { CharacterCard(from: try TavernCard.parseJSON(data: $0)) }
        let current = editableJSONFields
        let baseline = original?.editableJSONFields ?? [:]
        let changed = current.filter { key, value in
            guard let before = baseline[key] else { return true }
            return !NSDictionary(dictionary: [key: value]).isEqual(to: [key: before])
        }
        if changed.isEmpty, let rawJSONData { return rawJSONData }
        var envelope = try rawJSONData.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] }
            ?? ["spec": "chara_card_v2", "spec_version": "2.0"]
        var data = envelope["data"] as? [String: Any] ?? [:]
        for (key, value) in changed { data[key] = value }
        envelope["data"] = data
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    private var editableJSONFields: [String: Any] {
        ["name": name, "description": description, "personality": personality, "scenario": scenario,
         "first_mes": firstMes, "mes_example": mesExample, "system_prompt": systemPrompt,
         "post_history_instructions": postHistoryInstructions, "creator_notes": creatorNotes,
         "tags": tags, "creator": creator ?? "", "character_version": characterVersion ?? "",
         "alternate_greetings": alternateGreetings]
    }
}

// MARK: - Character Card Manager

@Observable
final class CharacterCardManager {
    private static let storageKey = "savedCharacterCards"

    private(set) var cards: [CharacterCard]
    private let root: URL?
    /// ⑧c-4：卡原件目录（和 blobs/ 同级的 cardlibrary/cards/）
    @ObservationIgnored let originals: CardOriginalStore
    private var loadError: Error?
    @ObservationIgnored private var floorService: CharacterFloorService?
    /// 第二批 B9：示例卡删过的标记写在这里
    @ObservationIgnored let defaults: UserDefaults

    init(root: URL? = nil, libraryRoot: URL? = nil, defaults: UserDefaults = .standard) {
        let root = BlobStore.resolvedRoot(root, defaults: defaults)
        self.root = root
        self.defaults = defaults
        self.originals = CardOriginalStore(directory: CardOriginalStore.directory(blobRoot: root, libraryRoot: libraryRoot))
        do {
            let data = try BlobStore.read(forKey: Self.storageKey, root: root, defaults: defaults)
            var loaded = try data.map { try JSONDecoder().decode([CharacterCard].self, from: $0) } ?? []
            for index in loaded.indices { loaded[index].originals.directory = originals.directory }
            // 第二批 B1：脚本数缓存是旧算法的（解码时已丢）→ 读一次原 JSON 重算，和下面的迁移一起写回；写失败下次启动再算
            var recounted = false
            for index in loaded.indices where loaded[index].originals.scriptCount == nil && loaded[index].originals.rawJSONFile != nil {
                loaded[index].originals.scriptCount = loaded[index].scriptCount
                recounted = true
            }
            self.cards = loaded
            // 老数据迁移：原件内嵌的拆到文件；写文件 + 回读校验 + 写 blob 都成功才换成引用，失败保持原样（下次启动再试）
            if loaded.contains(where: \.originals.hasInline) || recounted {
                do { self.cards = try write(loaded) } catch {
                    NSLog("卡原件拆分失败，保持内嵌：%@", error.localizedDescription)
                }
            }
        } catch {
            self.cards = []
            self.loadError = error
            NSLog("卡库读取失败，保留原文件并阻止覆盖：%@", error.localizedDescription)
        }
    }

    /// 从文件导入角色卡到卡库
    @discardableResult
    func importFromFile(url: URL) throws -> CharacterCard {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let tavernCard = try TavernCard.parseFile(url: url)
        let card = CharacterCard(from: tavernCard)
        if card.hasWorldBook { _ = try card.decodeWorldBook() }
        try add(card)
        return card
    }

    /// resetsConsent：规则 / 脚本变了就把许可打回 unknown（外来替换走默认）；
    /// 正则页里粟粟自己改这张卡的规则传 false，不打回（⑤b）
    func update(_ card: CharacterCard, resetsConsent: Bool = true) throws {
        guard let idx = cards.firstIndex(where: { $0.id == card.id }) else { return }
        var next = cards
        var updated = card
        if resetsConsent, !card.hasSameExtensions(as: cards[idx]) {
            updated.extensionConsent = .unknown
            updated.sendConsent = .unknown      // B5：替你发消息同一时机打回
        }
        next[idx] = updated
        try persist(next)
    }

    /// 写入成功后才发布，失败不会让卡墙显示未落盘的修改。
    func add(_ card: CharacterCard) throws {
        try persist(cards + [card])
    }

    /// 整包导入（⑧c）：一次写入
    func add(contentsOf newCards: [CharacterCard]) throws {
        let ids = Set(newCards.map(\.id))
        try persist(cards.filter { !ids.contains($0.id) } + newCards)
    }

    /// 按清单直接移除（⑧c 恢复 / 撤回），不走归档语义
    func remove(ids: Set<String>) throws {
        try persist(cards.filter { !ids.contains($0.id) })
    }

    func delete(_ card: CharacterCard) throws {
        guard var latest = cards.first(where: { $0.id == card.id }) else { return }
        if latest.bindingState == .unbound {
            try persist(cards.filter { $0.id != card.id })
        } else {
            latest.archivedAt = Date()
            try update(latest)
        }
    }

    @MainActor
    func floors(profileManager: ProfileManager, presetManager: PresetManager) -> CharacterFloorService {
        if let floorService { return floorService }
        let service = CharacterFloorService(cards: self, profiles: profileManager, presets: presetManager)
        floorService = service
        return service
    }

    func markMissing(profileId: String) throws {
        var next = cards
        for index in next.indices where next[index].linkedProfileId == profileId && next[index].bindingState == .active {
            next[index].bindingState = .missing
        }
        try persist(next)
    }

    // MARK: - Persistence

    private func persist(_ next: [CharacterCard]) throws {
        if let loadError { throw loadError }
        let sampleWasShown = cards.contains { $0.id == CardSample.id && $0.archivedAt == nil }
        cards = try write(next)
        // B9：示例卡从墙上消失（删除 / 归档 / 移除）就记下，之后不再补回
        if sampleWasShown, !cards.contains(where: { $0.id == CardSample.id && $0.archivedAt == nil }) {
            defaults.set(true, forKey: CardLibraryPreferences.sampleCardDismissedKey)
        }
    }

    /// 内嵌原件先拆到文件（每份回读校验），再写 blob；blob 写成功后才清没人引用的原件
    private func write(_ next: [CharacterCard]) throws -> [CharacterCard] {
        var stored = next
        for index in stored.indices {
            if stored[index].originals.hasInline {
                stored[index].originals = try originals.externalize(stored[index].originals, id: stored[index].id,
                                                                    scriptCount: stored[index].scriptCount)
            }
            stored[index].originals.directory = originals.directory
        }
        let data = try JSONEncoder().encode(stored)
        try BlobStore.set(data, forKey: Self.storageKey, root: root)
        originals.removeUnreferenced(keeping: stored)
        return stored
    }

    /// 存储里的卡引用的原件文件都在（⑧c 提交核对用）
    func originalsPresent(_ card: CharacterCard) -> Bool {
        originals.exists(card.originals.imageFile) && originals.exists(card.originals.rawJSONFile)
    }
}
