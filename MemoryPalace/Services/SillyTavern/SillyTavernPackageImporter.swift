import Foundation

/// 酒馆整包导入编排（卡库 ⑧a／⑧b）：快照盘点 → 纯解析 → 关联，全部是 DTO，不写任何 app 存储。
/// ⑧c 的持久导入、来源记录、撤回在这之上做。

struct SillyTavernProblem: Equatable {
    let relativePath: String
    let line: Int?
    let reason: String
}

struct SillyTavernCardDTO {
    let relativePath: String
    /// 头像文件名去扩展名：chats/<stem>/ 靠它关联
    let stem: String
    let card: TavernCard
    let hasHelperScripts: Bool
    let regexScripts: [RegexScript]
    let characterBook: WorldBookCodec.Report?
    let worldBinding: String?
}

struct SillyTavernChatDTO {
    let relativePath: String
    let status: SillyTavernParsedChat.Status
    let badLines: [SillyTavernBadLine]
    let personaRef: String?
    let worldRef: String?
    let attachmentRefCount: Int
    let built: SillyTavernBuiltConversation
}

struct SillyTavernCharacterDTO {
    let stem: String
    /// nil = 缺卡的 chat 目录，⑧c 建占位角色楼层
    let cardPath: String?
    let chats: [SillyTavernChatDTO]
    var isPlaceholder: Bool { cardPath == nil }
}

struct SillyTavernWorldDTO {
    let relativePath: String
    let name: String
    let report: WorldBookCodec.Report
}

struct SillyTavernPresetDTO {
    let relativePath: String
    let name: String
    let preset: Preset
    let notes: [String]
    let regexScripts: [RegexScript]
}

struct SillyTavernPersonaDTO {
    let avatarFile: String
    let name: String
    let description: String
    let lorebook: String?
    let hasAvatarFile: Bool
}

struct SillyTavernWorldBinding: Equatable {
    enum Owner: Hashable {
        case global
        case card(String)
        case chat(String)
        case persona(String)
        case characterExtra(String)
    }

    let owner: Owner
    let bookName: String
    /// worlds/<name>.json 存在时的相对路径；nil = 引用了包里没有的书
    let resolvedPath: String?
}

struct SillyTavernGroupDTO {
    let relativePath: String
    let id: String
    let name: String
    let members: [String]
    let chatIds: [String]
}

struct SillyTavernGroupChatDTO {
    let relativePath: String
    let groupId: String?
    let status: SillyTavernParsedChat.Status
    let built: SillyTavernBuiltConversation
    /// 首批只读归档：不续聊、不进成员记忆
    let readOnlyArchive = true
}

struct SillyTavernAttachmentCounts: Equatable {
    var userFiles = 0
    var userImages = 0
    var chatAttachmentRefs = 0
    var messageFileRefs = 0
    var messageMediaRefs = 0
    var globalDataBankRefs = 0
    var characterDataBankRefs = 0
}

/// 盘点页 + 报告用的数字（plan §6.3 / 小样整包导入）
struct SillyTavernPackageSummary: Equatable {
    var cards = 0
    var cardAssets = 0
    var cardsWithHelperScripts = 0
    var cardsWithRegex = 0
    var cardsWithBook = 0
    var chats = 0
    var chatsFailed = 0
    var chatsWithBadLines = 0
    var badChatLines = 0
    var characterDirectories = 0
    var placeholderCharacters = 0
    var placeholderChats = 0
    var messages = 0
    var swipeGroups = 0
    var multiCandidateMessages = 0
    var candidates = 0
    var contentNodes = 0
    var syntheticRoots = 0
    var mesDiffers = 0
    var swipeIdOutOfRange = 0
    var hiddenOrSystemMessages = 0
    var worlds = 0
    var worldsFailed = 0
    var worldBindings = 0
    var unresolvedWorldBindings = 0
    var presets = 0
    var presetsFailed = 0
    var globalRegex = 0
    var presetRegex = 0
    var cardRegex = 0
    var quickReplies = 0
    var personas = 0
    var personaAvatars = 0
    var groups = 0
    var groupChats = 0
    var attachments = SillyTavernAttachmentCounts()
    var backups = 0
    var extensionFiles = 0
    var unknownFiles = 0
    var hasCredentials = false
    var fileCount = 0
    var totalBytes: Int64 = 0
}

struct SillyTavernPackagePlan {
    let snapshot: SillyTavernSnapshot
    let cards: [SillyTavernCardDTO]
    let characters: [SillyTavernCharacterDTO]
    let worlds: [SillyTavernWorldDTO]
    let presets: [SillyTavernPresetDTO]
    let globalRegex: [RegexScript]
    let personas: [SillyTavernPersonaDTO]
    let worldBindings: [SillyTavernWorldBinding]
    let groups: [SillyTavernGroupDTO]
    let groupChats: [SillyTavernGroupChatDTO]
    let problems: [SillyTavernProblem]
    let summary: SillyTavernPackageSummary
    /// 各类文件数，未知文件按顶层目录分
    let categoryCounts: [SillyTavernFileCategory: Int]
    let unknownByTopLevel: [String: Int]
}

enum SillyTavernPackageImporter {

    /// 只读盘点 + 纯解析。staging 留给调用方（⑧c 写入要用原件；不用了 `plan.snapshot.removeStaging()`）
    static func inventory(source: URL, stagingParent: URL, limits: SillyTavernPackageLimits = .standard) throws -> SillyTavernPackagePlan {
        let snapshot = try SillyTavernPackageParser.snapshot(source: source, stagingParent: stagingParent, limits: limits)
        return parse(snapshot)
    }

    static func parse(_ snapshot: SillyTavernSnapshot) -> SillyTavernPackagePlan {
        var problems: [SillyTavernProblem] = []
        var summary = SillyTavernPackageSummary()
        func read(_ entry: SillyTavernManifestEntry) -> Data? {
            do { return try Data(contentsOf: snapshot.url(for: entry.relativePath)) } catch {
                problems.append(.init(relativePath: entry.relativePath, line: nil, reason: "读不出"))
                return nil
            }
        }
        func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

        // settings.json：全局正则、persona、全局 / 角色附加书、Data Bank
        let settings = snapshot.entries(in: .settings).first.flatMap(read)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if snapshot.entries(in: .settings).first != nil && settings == nil {
            problems.append(.init(relativePath: "settings.json", line: nil, reason: "设置文件读不出"))
        }
        let extensionSettings = settings?["extension_settings"] as? [String: Any] ?? [:]
        let powerUser = settings?["power_user"] as? [String: Any] ?? [:]

        // 世界书
        var worlds: [SillyTavernWorldDTO] = []
        for entry in snapshot.entries(in: .world) {
            guard let data = read(entry) else { summary.worldsFailed += 1; continue }
            do {
                worlds.append(.init(relativePath: entry.relativePath, name: stem(entry.relativePath), report: try WorldBookCodec.decodeWorldInfo(data)))
            } catch {
                summary.worldsFailed += 1
                problems.append(.init(relativePath: entry.relativePath, line: nil, reason: error.localizedDescription))
            }
        }
        let worldPaths = Dictionary(snapshot.entries(in: .world).map { (stem($0.relativePath), $0.relativePath) }, uniquingKeysWith: { a, _ in a })
        var bindings: [SillyTavernWorldBinding] = []
        func bind(_ owner: SillyTavernWorldBinding.Owner, _ name: String?) {
            guard let name, !name.isEmpty else { return }
            bindings.append(.init(owner: owner, bookName: name, resolvedPath: worldPaths[name]))
        }

        // 卡（characters/ 直属）
        var cards: [SillyTavernCardDTO] = []
        for entry in snapshot.entries(in: .card) {
            do {
                let card = try TavernCard.parseFile(url: snapshot.url(for: entry.relativePath))
                let ext = cardExtensions(card.rawJSONData)
                var book: WorldBookCodec.Report?
                if card.hasWorldBook, let raw = card.rawJSONData {
                    do { book = try WorldBookCodec.decodeCharacterBook(raw) } catch {
                        problems.append(.init(relativePath: entry.relativePath, line: nil, reason: "卡内世界书：\(error.localizedDescription)"))
                    }
                }
                let world = (ext["world"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let dto = SillyTavernCardDTO(relativePath: entry.relativePath, stem: stem(entry.relativePath), card: card,
                                             hasHelperScripts: hasHelperScripts(ext), regexScripts: card.regexScripts.map(RegexScript.init(from:)),
                                             characterBook: book, worldBinding: world)
                bind(.card(entry.relativePath), world)
                cards.append(dto)
            } catch {
                problems.append(.init(relativePath: entry.relativePath, line: nil, reason: error.localizedDescription))
            }
        }

        // 聊天：按 chats/<stem>/ 目录归角色，不看 header 名字
        var chatsByStem: [String: [SillyTavernChatDTO]] = [:]
        for entry in snapshot.entries(in: .chat) {
            let directory = entry.relativePath.split(separator: "/")[1]
            guard let data = read(entry) else { summary.chatsFailed += 1; continue }
            let parsed = SillyTavernChatParser.parse(data, relativePath: entry.relativePath)
            let built = SwipeBranchBuilder.build(parsed, idPrefix: SwipeBranchBuilder.idPrefix(relativePath: entry.relativePath),
                                                 title: stem(entry.relativePath), fallbackDate: Date(timeIntervalSince1970: 0))
            record(parsed, problems: &problems)
            if !parsed.isSuccess { summary.chatsFailed += 1 }
            bind(.chat(entry.relativePath), parsed.header?.worldRef)
            chatsByStem[String(directory), default: []].append(SillyTavernChatDTO(
                relativePath: entry.relativePath, status: parsed.status, badLines: parsed.badLines,
                personaRef: parsed.header?.personaRef, worldRef: parsed.header?.worldRef,
                attachmentRefCount: parsed.header?.attachmentCount ?? 0, built: built))
            summary.attachments.chatAttachmentRefs += parsed.header?.attachmentCount ?? 0
            summary.attachments.messageFileRefs += parsed.messages.reduce(0) { $0 + $1.fileRefCount }
            summary.attachments.messageMediaRefs += parsed.messages.reduce(0) { $0 + $1.mediaRefCount }
            summary.hiddenOrSystemMessages += parsed.messages.filter { $0.visibility != .normal }.count
        }
        let cardStems = Set(cards.map(\.stem))
        var characters: [SillyTavernCharacterDTO] = cards.map { card in
            SillyTavernCharacterDTO(stem: card.stem, cardPath: card.relativePath,
                                    chats: (chatsByStem[card.stem] ?? []).sorted { $0.relativePath < $1.relativePath })
        }
        for (stem, chats) in chatsByStem.sorted(by: { $0.key < $1.key }) where !cardStems.contains(stem) {
            characters.append(.init(stem: stem, cardPath: nil, chats: chats.sorted { $0.relativePath < $1.relativePath }))
            problems.append(.init(relativePath: "chats/\(stem)", line: nil, reason: "没有对应的卡，按占位角色处理"))
        }

        // 预设 + 预设正则
        var presets: [SillyTavernPresetDTO] = []
        for entry in snapshot.entries(in: .preset) {
            guard let data = read(entry) else { summary.presetsFailed += 1; continue }
            do {
                var result = try Preset.importSillyTavernJSON(data)
                result.preset.name = stem(entry.relativePath)
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let regex = ((json?["extensions"] as? [String: Any])?["regex_scripts"] as? [[String: Any]] ?? []).map(RegexScript.init(from:))
                presets.append(.init(relativePath: entry.relativePath, name: result.preset.name, preset: result.preset,
                                     notes: result.notes, regexScripts: regex))
            } catch {
                summary.presetsFailed += 1
                problems.append(.init(relativePath: entry.relativePath, line: nil, reason: error.localizedDescription))
            }
        }

        // 全局正则
        let globalRegex = (extensionSettings["regex"] as? [[String: Any]] ?? []).map(RegexScript.init(from:))

        // persona：名字表 + 描述表的并集；头像文件另查
        let avatarFiles = Set(snapshot.entries(in: .personaAvatar).map { ($0.relativePath as NSString).lastPathComponent })
        let names = powerUser["personas"] as? [String: Any] ?? [:]
        let descriptions = powerUser["persona_descriptions"] as? [String: Any] ?? [:]
        let personas: [SillyTavernPersonaDTO] = Set(names.keys).union(descriptions.keys).sorted().map { avatar in
            let info = descriptions[avatar] as? [String: Any] ?? [:]
            let lorebook = (info["lorebook"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            bind(.persona(avatar), lorebook)
            return SillyTavernPersonaDTO(avatarFile: avatar, name: names[avatar] as? String ?? "",
                                         description: info["description"] as? String ?? "", lorebook: lorebook,
                                         hasAvatarFile: avatarFiles.contains(avatar))
        }

        // 全局 / 角色附加书
        let worldInfo = (settings?["world_info_settings"] as? [String: Any])?["world_info"] as? [String: Any] ?? [:]
        for name in worldInfo["globalSelect"] as? [String] ?? [] { bind(.global, name) }
        for item in worldInfo["charLore"] as? [[String: Any]] ?? [] {
            let owner = item["name"] as? String ?? ""
            for name in item["extraBooks"] as? [String] ?? [] { bind(.characterExtra(owner), name) }
        }

        // 群聊：只读归档
        var groups: [SillyTavernGroupDTO] = []
        for entry in snapshot.entries(in: .group) {
            guard let data = read(entry), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                problems.append(.init(relativePath: entry.relativePath, line: nil, reason: "群组定义读不出"))
                continue
            }
            var chatIds: [String] = []
            for id in (json["chats"] as? [String] ?? []) + [json["chat_id"] as? String].compactMap({ $0 }) where !chatIds.contains(id) {
                chatIds.append(id)
            }
            groups.append(.init(relativePath: entry.relativePath, id: json["id"] as? String ?? stem(entry.relativePath),
                                name: json["name"] as? String ?? "", members: json["members"] as? [String] ?? [],
                                chatIds: chatIds))
        }
        var groupChats: [SillyTavernGroupChatDTO] = []
        for entry in snapshot.entries(in: .groupChat) {
            guard let data = read(entry) else { continue }
            let parsed = SillyTavernChatParser.parse(data, relativePath: entry.relativePath, requireHeader: false)
            record(parsed, problems: &problems)
            let chatId = stem(entry.relativePath)
            groupChats.append(.init(
                relativePath: entry.relativePath,
                groupId: groups.first { $0.chatIds.contains(chatId) }?.id,
                status: parsed.status,
                built: SwipeBranchBuilder.build(parsed, idPrefix: SwipeBranchBuilder.idPrefix(relativePath: entry.relativePath),
                                                title: chatId, fallbackDate: Date(timeIntervalSince1970: 0))))
        }

        // 数字
        var counts: [SillyTavernFileCategory: Int] = [:]
        var unknownTop: [String: Int] = [:]
        for entry in snapshot.entries {
            counts[entry.category, default: 0] += 1
            if entry.category == .unknown {
                unknownTop[String(entry.relativePath.split(separator: "/").first ?? ""), default: 0] += 1
            }
        }
        summary.cards = cards.count
        summary.cardAssets = counts[.cardAsset] ?? 0
        summary.cardsWithHelperScripts = cards.filter(\.hasHelperScripts).count
        summary.cardsWithRegex = cards.filter { !$0.regexScripts.isEmpty }.count
        summary.cardsWithBook = cards.filter { $0.characterBook != nil }.count
        let allChats = characters.flatMap(\.chats)
        summary.chats = counts[.chat] ?? 0
        summary.chatsWithBadLines = allChats.filter { !$0.badLines.isEmpty }.count
        summary.badChatLines = allChats.reduce(0) { $0 + $1.badLines.count }
        summary.characterDirectories = chatsByStem.count
        summary.placeholderCharacters = characters.filter(\.isPlaceholder).count
        summary.placeholderChats = characters.filter(\.isPlaceholder).reduce(0) { $0 + $1.chats.count }
        for chat in allChats {
            let built = chat.built
            summary.messages += built.messageCount
            summary.swipeGroups += built.swipeGroupCount
            summary.multiCandidateMessages += built.multiCandidateCount
            summary.candidates += built.candidateCount
            summary.contentNodes += built.contentNodeCount
            summary.syntheticRoots += built.syntheticRootId == nil ? 0 : 1
            summary.mesDiffers += built.mesDiffCount
            summary.swipeIdOutOfRange += built.issues.count
        }
        summary.worlds = worlds.count
        summary.worldBindings = bindings.count
        summary.unresolvedWorldBindings = bindings.filter { $0.resolvedPath == nil }.count
        summary.presets = presets.count
        summary.globalRegex = globalRegex.count
        summary.presetRegex = presets.reduce(0) { $0 + $1.regexScripts.count }
        summary.cardRegex = cards.reduce(0) { $0 + $1.regexScripts.count }
        summary.quickReplies = counts[.quickReply] ?? 0
        summary.personas = personas.count
        summary.personaAvatars = counts[.personaAvatar] ?? 0
        summary.groups = groups.count
        summary.groupChats = groupChats.count
        summary.attachments.userFiles = counts[.userFile] ?? 0
        summary.attachments.userImages = counts[.userImage] ?? 0
        summary.attachments.globalDataBankRefs = (extensionSettings["attachments"] as? [Any])?.count ?? 0
        summary.attachments.characterDataBankRefs = (extensionSettings["character_attachments"] as? [String: Any] ?? [:])
            .values.reduce(0) { $0 + (($1 as? [Any])?.count ?? 0) }
        summary.backups = counts[.backup] ?? 0
        summary.extensionFiles = counts[.extensionFile] ?? 0
        summary.unknownFiles = counts[.unknown] ?? 0
        summary.hasCredentials = (counts[.credentials] ?? 0) > 0
        if summary.hasCredentials {
            problems.append(.init(relativePath: SillyTavernPackageParser.credentialsPath, line: nil, reason: "含凭据，不导入"))
        }
        summary.fileCount = snapshot.entries.count
        summary.totalBytes = snapshot.totalBytes

        return SillyTavernPackagePlan(snapshot: snapshot, cards: cards, characters: characters, worlds: worlds, presets: presets,
                                      globalRegex: globalRegex, personas: personas, worldBindings: bindings, groups: groups,
                                      groupChats: groupChats, problems: problems, summary: summary,
                                      categoryCounts: counts, unknownByTopLevel: unknownTop)
    }

    private static func record(_ parsed: SillyTavernParsedChat, problems: inout [SillyTavernProblem]) {
        for bad in parsed.badLines {
            problems.append(.init(relativePath: parsed.relativePath, line: bad.line, reason: bad.reason))
        }
        if case .failed(let reason) = parsed.status {
            problems.append(.init(relativePath: parsed.relativePath, line: nil, reason: reason))
        }
    }

    // MARK: - 卡扩展

    static func cardExtensions(_ raw: Data?) -> [String: Any] {
        guard let raw, let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return [:] }
        return (root["data"] as? [String: Any])?["extensions"] as? [String: Any] ?? root["extensions"] as? [String: Any] ?? [:]
    }

    /// 酒馆助手脚本：新 `tavern_helper.scripts`（对象或键值对数组两种存法）或旧 `TavernHelper_scripts` 非空
    static func hasHelperScripts(_ extensions: [String: Any]) -> Bool {
        if let legacy = extensions["TavernHelper_scripts"] as? [Any], !legacy.isEmpty { return true }
        let helper = extensions["tavern_helper"]
        if let object = helper as? [String: Any], let scripts = object["scripts"] as? [Any] { return !scripts.isEmpty }
        if let pairs = helper as? [[Any]] {
            for pair in pairs where pair.count == 2 && (pair[0] as? String) == "scripts" {
                if let scripts = pair[1] as? [Any] { return !scripts.isEmpty }
            }
        }
        return false
    }
}
