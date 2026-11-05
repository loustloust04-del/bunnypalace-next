import Foundation

// MARK: - 小芽引导卡 · 数据（plan-onboarding-xiaoya-impl §3 P3）
// 卡定义 + 答案都跟着小芽对话落进 history.json（P4 给 AssistantChatMessage 加 card 字段）。
// 编解码手写：kind 字符串分派 + 全部 decodeIfPresent——缺字段的旧数据能解，新版写的未知卡 / 答案解成 unsupported 不炸整份对话。
// 不含 key、不含任何钥匙串内容（H2：key 草稿只在内存）。

struct XiaoyaChoiceOption: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String?

    init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case id, title, detail }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// 选择卡：小标题 k + 问句 q（都可空，空就不画）+ 选项行
struct XiaoyaChoicePayload: Codable, Equatable {
    var kicker: String
    var question: String
    var options: [XiaoyaChoiceOption]

    init(kicker: String = "", question: String = "", options: [XiaoyaChoiceOption]) {
        self.kicker = kicker
        self.question = question
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case kicker, question, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kicker = try c.decodeIfPresent(String.self, forKey: .kicker) ?? ""
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try c.decodeIfPresent([XiaoyaChoiceOption].self, forKey: .options) ?? []
    }
}

extension XiaoyaChoicePayload {
    // 文案逐字照小样（design-onboarding-xiaoya.html IDS / tech / newbie）；P4 台词表直接引用这里，别抄第二份
    static let identity = XiaoyaChoicePayload(kicker: "选一个", question: "你是哪种园丁？", options: [
        .init(id: "newbie", title: "我是小白", detail: "先聊起来再说，别的慢慢懂"),
        .init(id: "tavern", title: "酒馆用户", detail: "我有角色卡，直接导入"),
        .init(id: "companion", title: "长期陪伴", detail: "想要个记得我的长期搭子"),
        .init(id: "tech", title: "技术用户", detail: "别废话，给我 key 框"),
        .init(id: "ghost", title: "保持神秘", detail: "不定义我，直接进去"),
    ])
    static let hasMac = XiaoyaChoicePayload(options: [.init(id: "yes", title: "有，连上"), .init(id: "no", title: "没有")])
    static let wantTa = XiaoyaChoicePayload(options: [.init(id: "yes", title: "好，建一个 Ta"), .init(id: "no", title: "先跟你聊着")])
    /// mac 上的技术线（§5.3）：代替「有 Mac 吗」
    static let wantPhone = XiaoyaChoicePayload(options: [.init(id: "yes", title: "要，连手机"), .init(id: "no", title: "先不用")])
}

/// 新楼层出口卡上的追加导入（固定落到这张卡的 Ta 楼层，H7）
enum XiaoyaFloorExtra: String, Codable, Equatable, CaseIterable {
    case worldBook, preset, chatHistory

    func label(taName: String) -> String {
        switch self {
        case .worldBook: return "导入世界书（落到\(taName)的楼层）"
        case .preset: return "导入预设"
        case .chatHistory: return "导入以前的聊天记录"
        }
    }
}

/// 一位 Ta：楼层 id（建好才有）+ 名字
struct XiaoyaTaRef: Codable, Equatable {
    var profileId: String?
    var name: String

    init(profileId: String?, name: String) {
        self.profileId = profileId
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case profileId, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Ta"
    }
}

/// 新楼层出口卡：Ta + 一行状态 + 追加导入按钮
struct XiaoyaFloorExitPayload: Codable, Equatable {
    var ta: XiaoyaTaRef
    var meta: String
    var extras: [XiaoyaFloorExtra]

    init(ta: XiaoyaTaRef, meta: String, extras: [XiaoyaFloorExtra] = []) {
        self.ta = ta
        self.meta = meta
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey { case ta, meta, extras }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ta = try c.decodeIfPresent(XiaoyaTaRef.self, forKey: .ta) ?? XiaoyaTaRef(profileId: nil, name: "Ta")
        meta = try c.decodeIfPresent(String.self, forKey: .meta) ?? ""
        // 新版多出来的追加项不认识就丢掉，不让整张卡解不出来
        extras = (try c.decodeIfPresent([String].self, forKey: .extras) ?? []).compactMap(XiaoyaFloorExtra.init(rawValue:))
    }
}

/// 挑头像 + 名字卡给谁（§11-7）：你 / Ta（当前楼层的 AI）。小芽自己的名字不受影响
enum XiaoyaFaceTarget: String, Codable, Equatable {
    case user, ta
}

/// 花园随机头像的「种子」：卡片重画 / 恢复都从它算，不存图（GardenAvatar）
struct XiaoyaAvatarSeed: Codable, Equatable, Hashable {
    var seed: UInt32
    /// flower / animal / letter / star
    var kind: String
    /// 小动物：cat / bunny / bear / sheep / fox
    var species: String?

    init(seed: UInt32, kind: String, species: String? = nil) {
        self.seed = seed
        self.kind = kind
        self.species = species
    }

    private enum CodingKeys: String, CodingKey { case seed, kind, species }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? 1
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "star"
        species = try c.decodeIfPresent(String.self, forKey: .species)
    }
}

/// 挑头像 + 名字卡的答案。avatar = nil 表示从相册选的：图只在内存里交给剧本写进楼层，不进 history.json
struct XiaoyaFaceAnswer: Codable, Equatable {
    var target: XiaoyaFaceTarget
    var avatar: XiaoyaAvatarSeed?
    /// 空串 = 先不改（你：先叫「你」；Ta：沿用原来的名字）
    var name: String
    /// 相册裁好的 512px JPEG：不编码
    var photo: Data?

    init(target: XiaoyaFaceTarget, avatar: XiaoyaAvatarSeed?, name: String, photo: Data? = nil) {
        self.target = target
        self.avatar = avatar
        self.name = name
        self.photo = photo
    }

    private enum CodingKeys: String, CodingKey { case target, avatar, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = XiaoyaFaceTarget(rawValue: try c.decodeIfPresent(String.self, forKey: .target) ?? "") ?? .user
        avatar = try? c.decodeIfPresent(XiaoyaAvatarSeed.self, forKey: .avatar)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        photo = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target.rawValue, forKey: .target)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encode(name, forKey: .name)
    }
}

/// 新用户三问的答案（C2/C3 v2 第 11 段）：空串 = 这一问跳过
struct XiaoyaSurveyAnswer: Codable, Equatable {
    var name: String
    var doing: String
    var note: String

    init(name: String = "", doing: String = "", note: String = "") {
        self.name = name
        self.doing = doing
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case name, doing, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        doing = try c.decodeIfPresent(String.self, forKey: .doing) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    /// 顺序同 CatalogSurvey.questions；只留填了的
    var answers: [CatalogSurvey.Answer] { CatalogSurvey.answers([name, doing, note]) }
}

enum XiaoyaCard: Equatable {
    case choice(XiaoyaChoicePayload)        // ② 分流 / 技术线「有 Mac 吗」/ 小白「建一个 Ta？」
    case keyForm                            // ③–⑦ 填钥匙（草稿在内存，卡上什么都不存）
    case importCard                         // ⑨ 导角色卡
    case nameForm                           // ⑪ 给 Ta 起名
    case floorExit(XiaoyaFloorExitPayload)  // ⑩ ⑭ 新楼层建好：去找 / 继续问我 / 追加导入
    case goTa(XiaoyaTaRef)                  // ⑭ 结束时的出口：去找 X →（小样 end() 的「出口」卡，有 Ta 且没刚出过新楼层卡时）
    case pair                               // ⑫ 扫码连 Mac（只 iOS 画）
    case todo([String])                     // ⑭ 你可以试试（只读）
    case info                               // ⑬ ⑭ 以后在哪儿找我
    case makeTa                             // ⑭ 结束时还没有 Ta：建一个 Ta →
    case face(XiaoyaFaceTarget)             // v2 C：小白线挑头像 + 名字（你 / Ta）
    case tip(XiaoyaTipRef)                  // v2 A：Tip（只读，插图会动）
    case survey(name: String)               // 新用户三问（name = 预填的称呼）
    case unsupported(String)                // 新版写的卡，这版不认识：不画卡，只显示消息 text 兜底

    /// 卡的问句：P4 写消息 text 兜底用（旧版 App 读到时显示成普通一句话）
    var prompt: String {
        switch self {
        case .choice(let p): return p.question.isEmpty ? p.options.map(\.title).joined(separator: " / ") : p.question
        case .keyForm: return "接一把钥匙，我就能真的跟你说话"
        case .importCard: return "把你的角色卡给我"
        case .nameForm: return "Ta 叫什么？"
        case .floorExit(let p): return "\(p.ta.name) 的楼层建好了"
        case .goTa(let ta): return "去找 \(ta.name) →"
        case .pair: return "扫个码，Mac 上的 Claude Code / Codex / 终端就连上了"
        case .todo(let items): return "你可以试试：" + items.joined(separator: "；")
        case .info: return "以后在任何楼层打开「\(AssistantPrompts.assistantName)」，都是在这儿跟我说话"
        case .makeTa: return "你还没有自己的 Ta。想要的话随时跟我说「建一个 Ta」"
        case .face(.user): return "挑一个你的头像和称呼"
        case .face(.ta): return "给 Ta 挑个头像和名字"
        case .tip(let ref): return "Tip \(ref.label)：" + XiaoyaScriptLines.tip(ref.kind, strip: true).title
        case .survey: return "三个小问题：" + CatalogSurvey.questions.map(\.title).joined(separator: "；")
        case .unsupported: return ""
        }
    }
}

extension XiaoyaCard: Codable {
    private enum CodingKeys: String, CodingKey { case kind, choice, floorExit, ta, items, target, tip, name }

    private var kind: String {
        switch self {
        case .choice: return "choice"
        case .keyForm: return "keyForm"
        case .importCard: return "importCard"
        case .nameForm: return "nameForm"
        case .floorExit: return "floorExit"
        case .goTa: return "goTa"
        case .pair: return "pair"
        case .todo: return "todo"
        case .info: return "info"
        case .makeTa: return "makeTa"
        case .face: return "face"
        case .tip: return "tip"
        case .survey: return "survey"
        case .unsupported(let raw): return raw
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        switch kind {
        case "choice": self = .choice(try c.decodeIfPresent(XiaoyaChoicePayload.self, forKey: .choice) ?? XiaoyaChoicePayload(options: []))
        case "keyForm": self = .keyForm
        case "importCard": self = .importCard
        case "nameForm": self = .nameForm
        case "floorExit":
            self = .floorExit(try c.decodeIfPresent(XiaoyaFloorExitPayload.self, forKey: .floorExit)
                ?? XiaoyaFloorExitPayload(ta: XiaoyaTaRef(profileId: nil, name: "Ta"), meta: ""))
        case "goTa": self = .goTa(try c.decodeIfPresent(XiaoyaTaRef.self, forKey: .ta) ?? XiaoyaTaRef(profileId: nil, name: "Ta"))
        case "pair": self = .pair
        case "todo": self = .todo(try c.decodeIfPresent([String].self, forKey: .items) ?? [])
        case "info": self = .info
        case "makeTa": self = .makeTa
        case "face": self = .face(XiaoyaFaceTarget(rawValue: try c.decodeIfPresent(String.self, forKey: .target) ?? "") ?? .user)
        case "tip":
            // 新版加的 tip 种类这版不认识：当新卡，只显示兜底那句
            guard let ref = try? c.decodeIfPresent(XiaoyaTipRef.self, forKey: .tip) else { self = .unsupported(kind); return }
            self = .tip(ref)
        case "survey": self = .survey(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        default: self = .unsupported(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .choice(let p): try c.encode(p, forKey: .choice)
        case .floorExit(let p): try c.encode(p, forKey: .floorExit)
        case .goTa(let ta): try c.encode(ta, forKey: .ta)
        case .todo(let items): try c.encode(items, forKey: .items)
        case .face(let target): try c.encode(target.rawValue, forKey: .target)
        case .tip(let ref): try c.encode(ref, forKey: .tip)
        case .survey(let name): try c.encode(name, forKey: .name)
        case .keyForm, .importCard, .nameForm, .pair, .info, .makeTa, .unsupported: break
        }
    }
}

// MARK: - 答案

/// 钥匙存好了：卡 id（CredentialCommitter.commit 返回的）+ 给人看的服务商名 + 主模型
struct XiaoyaKeySaved: Codable, Equatable {
    var credentialId: String
    var providerName: String
    var modelId: String

    init(credentialId: String, providerName: String, modelId: String) {
        self.credentialId = credentialId
        self.providerName = providerName
        self.modelId = modelId
    }

    private enum CodingKeys: String, CodingKey { case credentialId, providerName, modelId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        credentialId = try c.decodeIfPresent(String.self, forKey: .credentialId) ?? ""
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? ""
    }
}

/// 读好的角色卡摘要。fileURL 是卡片拷进临时目录的那份（不用再开安全作用域），P4 拿它走 cardManager.importFromFile；
/// App 重启后临时文件可能没了——那时这张卡早已答完，P4 只看名字
struct XiaoyaImportedCard: Codable, Equatable, Sendable {
    var name: String
    var greetingCount: Int
    var worldBookEntries: Int
    var hasSystemPrompt: Bool
    var fileURL: URL?

    init(name: String, greetingCount: Int, worldBookEntries: Int, hasSystemPrompt: Bool, fileURL: URL?) {
        self.name = name
        self.greetingCount = greetingCount
        self.worldBookEntries = worldBookEntries
        self.hasSystemPrompt = hasSystemPrompt
        self.fileURL = fileURL
    }

    private enum CodingKeys: String, CodingKey { case name, greetingCount, worldBookEntries, hasSystemPrompt, fileURL }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        greetingCount = try c.decodeIfPresent(Int.self, forKey: .greetingCount) ?? 0
        worldBookEntries = try c.decodeIfPresent(Int.self, forKey: .worldBookEntries) ?? 0
        hasSystemPrompt = try c.decodeIfPresent(Bool.self, forKey: .hasSystemPrompt) ?? false
        fileURL = try c.decodeIfPresent(URL.self, forKey: .fileURL)
    }

    /// 「开场白 2 条 · 内嵌世界书 12 条 · 卡自带系统指令」
    var meta: String {
        var parts = ["开场白 \(greetingCount) 条"]
        if worldBookEntries > 0 { parts.append("内嵌世界书 \(worldBookEntries) 条") }
        if hasSystemPrompt { parts.append("卡自带系统指令") }
        return parts.joined(separator: " · ")
    }
}

/// 起名卡：Ta 名必填；称呼 / 一句话设定选填（空串 = 没填）
struct XiaoyaNameAnswer: Codable, Equatable {
    var taName: String
    var userName: String
    var who: String

    init(taName: String, userName: String = "", who: String = "") {
        self.taName = taName
        self.userName = userName
        self.who = who
    }

    private enum CodingKeys: String, CodingKey { case taName, userName, who }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taName = try c.decodeIfPresent(String.self, forKey: .taName) ?? ""
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        who = try c.decodeIfPresent(String.self, forKey: .who) ?? ""
    }
}

enum XiaoyaFloorChoice: String, Codable, Equatable {
    case go, stay
}

enum XiaoyaCardAnswer: Equatable {
    case picked(String)                     // 选择卡：选项 id
    case keySaved(XiaoyaKeySaved)           // key 卡「就用这个」存好了
    case skipped                            // key 卡「先跳过」
    case imported(XiaoyaImportedCard)       // 导卡卡「好，就是 Ta」
    case named(XiaoyaNameAnswer)            // 起名卡「建好 Ta 的楼层」
    case floor(XiaoyaFloorChoice)           // 出口卡 / goTa 卡：去找 · 继续问我
    case floorExtra(XiaoyaFloorExtra)       // 出口卡追加导入（动作，不收卡——见 closesCard）
    case makeTa                             // 「建一个 Ta →」
    case paired(String)                     // 扫码配好了：CCPairingApply 回的那句
    case later                              // 扫码卡「以后再说」
    case face(XiaoyaFaceAnswer)             // 挑头像 + 名字卡「就这样」
    case tipNext                            // v3 Tip 卡「懂了，下一条」（最后一张是「懂了」）
    case tipLater                           // v3 Tip 卡「以后再看」：剩下的进灯泡
    case survey(XiaoyaSurveyAnswer)         // 三问「就这些」/「都跳过」（全空）
    case unsupported(String)

    /// 这条答案要不要记成卡的答案（XiaoyaCardState.answer）。
    /// 追加导入是可重复的动作；已答 go 后再点「去找 X」也会再发一次 .floor(.go)（小样 floorCard：用过之后照样能跳）——P4 照做跳转，不重记
    var closesCard: Bool {
        if case .floorExtra = self { return false }
        return true
    }

    /// 收起后的一句话：P4 写「你」气泡 / 消息 text 兜底用
    var summary: String {
        switch self {
        case .picked(let id): return id
        case .keySaved(let s): return "\(s.providerName) · \(s.modelId) · 已存好，设成默认模型并收藏"
        case .skipped: return "先跳过了。以后在「设置 › 模型和API」或者跟我说「配钥匙」都行"
        case .imported(let c): return "已导入「\(c.name)」"
        case .named(let n): return "Ta 叫「\(n.taName)」" + (n.userName.isEmpty ? "" : "，叫你「\(n.userName)」")
        case .floor(.go): return "去找 Ta"
        case .floor(.stay): return "继续问我"
        case .floorExtra(let e): return e.label(taName: "Ta")
        case .makeTa: return "建一个 Ta"
        case .paired(let s): return s
        case .later: return "先不连，以后跟我说「连电脑」就行"
        case .face(let a):
            switch a.target {
            case .user: return a.name.isEmpty ? "先叫「你」，以后在设置里改" : "叫你「\(a.name)」"
            case .ta: return a.name.isEmpty ? "Ta 先用原来的名字" : "Ta 叫「\(a.name)」"
            }
        case .tipNext: return "已看"
        case .tipLater: return "收进灯泡了"
        case .survey(let a):
            let filled = zip(["叫我「\(a.name)」", "在做：\(a.doing)", "要知道的：\(a.note)"], [a.name, a.doing, a.note])
                .filter { !$1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.0)
            return filled.isEmpty ? "都跳过了" : filled.joined(separator: "；")
        case .unsupported: return ""
        }
    }
}

extension XiaoyaCardAnswer: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, key, card, name, floor, extra, face, survey }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        switch kind {
        case "picked": self = .picked(try c.decodeIfPresent(String.self, forKey: .value) ?? "")
        case "keySaved":
            self = .keySaved(try c.decodeIfPresent(XiaoyaKeySaved.self, forKey: .key)
                ?? XiaoyaKeySaved(credentialId: "", providerName: "", modelId: ""))
        case "skipped": self = .skipped
        case "imported":
            self = .imported(try c.decodeIfPresent(XiaoyaImportedCard.self, forKey: .card)
                ?? XiaoyaImportedCard(name: "", greetingCount: 0, worldBookEntries: 0, hasSystemPrompt: false, fileURL: nil))
        case "named": self = .named(try c.decodeIfPresent(XiaoyaNameAnswer.self, forKey: .name) ?? XiaoyaNameAnswer(taName: ""))
        case "floor":
            let raw = try c.decodeIfPresent(String.self, forKey: .floor) ?? ""
            self = XiaoyaFloorChoice(rawValue: raw).map { .floor($0) } ?? .unsupported("floor." + raw)
        case "floorExtra":
            let raw = try c.decodeIfPresent(String.self, forKey: .extra) ?? ""
            self = XiaoyaFloorExtra(rawValue: raw).map { .floorExtra($0) } ?? .unsupported("floorExtra." + raw)
        case "makeTa": self = .makeTa
        case "paired": self = .paired(try c.decodeIfPresent(String.self, forKey: .value) ?? "")
        case "later": self = .later
        case "face":
            self = .face(try c.decodeIfPresent(XiaoyaFaceAnswer.self, forKey: .face)
                ?? XiaoyaFaceAnswer(target: .user, avatar: nil, name: ""))
        case "tipNext": self = .tipNext
        case "tipLater": self = .tipLater
        case "survey": self = .survey(try c.decodeIfPresent(XiaoyaSurveyAnswer.self, forKey: .survey) ?? XiaoyaSurveyAnswer())
        default: self = .unsupported(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .picked(let id):
            try c.encode("picked", forKey: .kind); try c.encode(id, forKey: .value)
        case .keySaved(let s):
            try c.encode("keySaved", forKey: .kind); try c.encode(s, forKey: .key)
        case .skipped:
            try c.encode("skipped", forKey: .kind)
        case .imported(let card):
            try c.encode("imported", forKey: .kind); try c.encode(card, forKey: .card)
        case .named(let n):
            try c.encode("named", forKey: .kind); try c.encode(n, forKey: .name)
        case .floor(let f):
            try c.encode("floor", forKey: .kind); try c.encode(f.rawValue, forKey: .floor)
        case .floorExtra(let e):
            try c.encode("floorExtra", forKey: .kind); try c.encode(e.rawValue, forKey: .extra)
        case .makeTa:
            try c.encode("makeTa", forKey: .kind)
        case .paired(let s):
            try c.encode("paired", forKey: .kind); try c.encode(s, forKey: .value)
        case .later:
            try c.encode("later", forKey: .kind)
        case .face(let a):
            try c.encode("face", forKey: .kind); try c.encode(a, forKey: .face)
        case .tipNext:
            try c.encode("tipNext", forKey: .kind)
        case .tipLater:
            try c.encode("tipLater", forKey: .kind)
        case .survey(let a):
            try c.encode("survey", forKey: .kind); try c.encode(a, forKey: .survey)
        case .unsupported(let raw):
            try c.encode(raw, forKey: .kind)
        }
    }
}

// MARK: - 卡 + 答案（P4 挂在 AssistantChatMessage.card 上）

struct XiaoyaCardState: Codable, Equatable {
    var card: XiaoyaCard
    /// nil = 还没答（剧本在等它）
    var answer: XiaoyaCardAnswer?

    init(card: XiaoyaCard, answer: XiaoyaCardAnswer? = nil) {
        self.card = card
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey { case card, answer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = try c.decodeIfPresent(XiaoyaCard.self, forKey: .card) ?? .unsupported("")
        answer = try c.decodeIfPresent(XiaoyaCardAnswer.self, forKey: .answer)
    }

    /// 消息 text 兜底：答了写摘要，没答写问句
    var fallbackText: String {
        if let answer, answer.closesCard, !answer.summary.isEmpty { return answer.summary }
        return card.prompt
    }
}
