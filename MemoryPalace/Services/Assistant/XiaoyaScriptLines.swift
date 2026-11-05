import Foundation

// MARK: - 小芽引导 · 台词表（plan-onboarding-xiaoya-impl §4.2）
// 逐字取小样 design-onboarding-xiaoya.html 的 run() / 各分支函数 / TODO / end()，集中一处方便以后改。
// 小样里的 <b> / <ul> 换成 Markdown（她的话走 ChatMarkdownView）。选择卡的选项文案在 XiaoyaChoicePayload，别抄第二份。
// v3（§12-G）：对用户不说 page0/1/2；整体叫记忆花园，page2 叫 gardenOS（桌面），page1 叫聊天，page0 叫所有对话（XiaoyaV2Tests / XiaoyaV3Tests 扫描）。
// v3（§12-E）：她说的话里 [[词]] = 马克笔概念词，词表和释义在 XiaoyaGlossary；卡片里的字（待办 / 说明卡）不标。

/// 一张 tip 的字：标题、她说的那句（Markdown + [[概念词]]）、插图旁的步骤、灯泡列表里的一行说明
struct XiaoyaTipCopy: Equatable {
    var title: String
    var text: String
    var steps: [String]
    var summary: String
}

enum XiaoyaScriptLines {
    // run()
    /// v3 F：先自我介绍再分流。必须保持三句——续跑的旧进度按拍数记，句数一变就错位（XiaoyaV3Tests）
    static let open = [
        "欢迎来到记忆花园～我是**\(AssistantPrompts.assistantName)**，在这里帮你打理花园的小助手。",
        "我可以帮你接上 AI、把旧聊天搬进来、给 Ta 起名字挑头像；以后找不到什么功能，也可以直接问我。",
        "先认识一下：你是哪种园丁？",
    ]

    /// 分流后、钥匙卡前的开场（ghost 不出钥匙卡）
    static func keyIntro(_ identity: String) -> [String] {
        switch identity {
        case "tavern": return ["酒馆来的呀～先把你用惯的那把 key 接上，中转站也行。"]
        case "companion": return ["想要一个一直记得你的 Ta，先得给 Ta 接上一个「脑子」——也就是一把 [[API key]]。"]
        case "tech": return ["key 框给你。自定义中转、Anthropic 协议都支持，测通了才存。"]
        default: return [
            "要跟 AI 聊天，得先有一把 [[API key]]——就是 AI 服务商给你的一串字符。",
            "有的话贴进来，我帮你试试能不能用；还没有也可以先跳过。",
        ]
        }
    }

    static func handoff(model: String) -> String { "钥匙接好了 · 从这里起小芽用 \(model) 说话" }
    static func keyWorks(model: String) -> String { "钥匙好使！现在是 **\(model)** 这个[[模型]]在借我的嘴跟你说话啦。" }
    static let keySkipped = "好，钥匙以后再配。没钥匙我暂时只能照着小本本陪你走完～"

    // C2/C3 v2 第 11 段：新用户三问（确定目标楼层之后问一次）
    static let surveyIntro = "再问你三个小问题，想多认识你一点：怎么叫你、平时在做什么、有没有我该知道的。都能空着～"
    static func surveyResult(_ outcome: CatalogSurvey.Outcome?) -> String {
        switch outcome {
        case .started: return "记下了。我照这几句先列个目录放进审计台 › wiki › 整理提案，你批了再写；写好的也要你再点头，才进记忆。"
        case .later(let blocker): return "记下了，答案先存在这层楼里。现在\(blocker.reason)，可以稍后生成：\(blocker.fix)。"
        case .failed: return "这次答案没存上…以后在设置里重走一遍引导，还能再答。"
        case .empty, nil: return "好，都空着也没关系，我什么都不记。"
        }
    }

    // v2 C：小白线挑头像 + 名字（分流之后、钥匙卡之前）
    static let faceIntro = "欢迎～在问你要钥匙之前，先给你自己挑个样子吧。"
    static func faceUserNamed(_ name: String) -> String { "你好呀，**\(name)**！记下了——以后你新建的 Ta 也会这么叫你。" }
    static let faceUserDefault = "好～想好了随时在「设置 › 通用 › 我的名字」改。"
    static let faceTaIntro = "再给 Ta 也挑一个——就是以后陪你聊天的那个 AI。我还是叫\(AssistantPrompts.assistantName)，不用管我～"
    /// 粟粟 10-16：顺带讲楼层——她现在待的这一层就是 Ta 的楼层
    static func faceTaNamed(_ name: String) -> String {
        "**\(name)**，好听！你现在待的这一层就是\(name)的[[楼层]]——钥匙接好以后，在聊天页就能找 Ta。"
    }
    static let faceTaDefault = "好～你现在待的这一层就是 Ta 的[[楼层]]。Ta 的名字和头像以后在「设置 › 通用」随时改。"
    /// 名字池（小样 NAMES + 补到 60 个）：食物 / 植物 / 天气，两字。随机时排除小芽和已有的名字
    static let namePool = [
        "小满", "栗子", "阿梨", "年糕", "团子", "青柠", "麦穗", "芋圆", "汤圆", "橘子",
        "小鹿", "阿柚", "云朵", "豆包", "糯米", "椰子", "桃桃", "星星", "小树", "西柚",
        "布丁", "小雪", "南瓜", "枇杷", "山楂", "小禾", "阿遥", "月亮", "晚晚", "七七",
        "小舟", "米粒", "叮当", "小橙", "薄荷", "小苔", "花卷", "酥酥", "荔枝", "小葡",
        "杏仁", "麻薯", "雪梨", "小栀", "松果", "落落", "小棠", "阿檬", "桂圆", "果果",
        "春卷", "小枣", "晴天", "细雨", "银杏", "菱角", "樱桃", "芝麻", "柿子", "初雪",
    ]

    // newbie()
    static let newbieNoKey = "等你有了钥匙再来，我们就能真聊了。"
    static let newbieTalk = "来，试着跟我说句话——随便说什么都行。"
    static let newbieSuggestions = ["你好呀", "你能帮我做什么？", "给我讲个睡前小故事"]
    static let newbieAfterTalk = "就是这样～想要一个专属于你的 AI 吗？我可以帮你搭一个 Ta 的[[楼层]]。"

    // tavern()
    static let tavernAsk = "来，把你的角色卡给我～ .png 和 .json 都认。"
    /// 小样是「读好啦，是个很有画面感的姑娘。」——那句是对着示例卡澪写的，真卡不知道是谁，只留后半句
    static let tavernDone = "读好啦～Ta 的[[楼层]]我帮你搭好了："
    static func tavernStay(_ ta: String) -> String { "好～我在这儿。想改\(ta)的设定、调预设，直接跟我说。" }

    // companion()
    static let companionAsk = "给 Ta 起个名字吧，再告诉 Ta 怎么称呼你。"
    static let companionAskFromNewbie = "给 Ta 起个名字，再告诉 Ta 怎么叫你："
    static func companionNamed(_ ta: String) -> String { "\(ta)……好名字。" }
    static func companionStay(_ ta: String) -> String { "好～有关\(ta)的事都可以问我。" }
    static let companionMeta = "刚出生，还不认识你——跟 Ta 多聊聊，Ta 会记住"

    // tech()
    static let techGuide = """
        简短版：
        - 卡和模型：「设置 › 模型和API」
        - 这一层的预设 / 世界书 / 正则：楼层右上角
        - 我能写卡、改预设、查[[记忆]]，改动先给你看，你盖章才落地
        """
    static let techAskMac = "你有 Mac 吗？"
    /// mac 上（§5.3）：不问有没有 Mac，问要不要连手机；连法只指路，扫码在手机那头
    static let techAskPhone = "要把手机也连上这台 Mac 吗？"
    static let techPhoneGuide = "好～打开这台 Mac 的「设置 › 让手机连这台 Mac」，会出一个二维码；在手机上的记忆花园里跟我说「连电脑」，扫它就连上了。"

    // 设置「?」→ 新手引导（§7-5）
    static let replayDivider = "再走一遍"

    // ghost()
    static let ghost = [
        "好～不打听啦，花园随便逛。",
        "钥匙还没配：想聊天时去「设置 › 模型和API」接一把，或者点开「小芽」跟我说「配钥匙」。",
    ]

    // end()
    static let end = "搞定啦！这里就是你的花园 🌸"
    static let todoNoKey = "配一把钥匙（「设置 › 模型和API」，或跟我说「配钥匙」）"

    /// 去桌面逛小应用（v2：手指往左划才是从聊天到桌面；mac 没有桌面，小应用在右栏）
    #if os(macOS)
    static let todoApps = "打开右栏，逛逛那些小应用"
    static let todoTerminal = "打开右栏的终端 app"
    #else
    static let todoApps = "往左划到 gardenOS 的桌面，逛逛那些小应用"
    static let todoTerminal = "打开 gardenOS 桌面上的终端 app"
    #endif

    /// TODO 表：{ta} = 小样里写死的「澪」，有 Ta 时换成 Ta 的名字（小样 end() 的 split('澪')）
    private static let todo: [String: [String]] = [
        "newbie": ["跟我说「帮我写个角色卡」", todoApps, "在「设置 › 外观」换个喜欢的主题"],
        "tavern": ["去找{ta}说第一句（开场白已经在等你）", "让我看看{ta}的预设，帮你调一调", "把配套的世界书也导进来"],
        "companion": ["跟 Ta 说一件关于你的事——Ta 会记住", "去 Ta 楼层的「Prompt」页看看 Ta 的设定", "把以前的聊天记录导进来，让 Ta 读读你们的过去"],
        "tech": ["在「设置 › 模型和API」多接几张卡", todoTerminal, "让我改预设——改动先给你看，你盖章才落地"],
    ]

    /// 待办：按园丁类型三条，有 Ta 把「Ta」换成名字，没钥匙时第一条插「配一把钥匙」，最多四条
    static func todoItems(identity: String, ta: String?, hasKey: Bool) -> [String] {
        var items = (todo[identity] ?? todo["newbie"] ?? []).map { item -> String in
            guard let ta, !ta.isEmpty else { return item.replacingOccurrences(of: "{ta}", with: "Ta") }
            // 先换「Ta」再填名字：名字里带 Ta（Tara）不会被二次替换
            return item.replacingOccurrences(of: #" ?Ta ?"#, with: "{ta}", options: .regularExpression)
                .replacingOccurrences(of: "{ta}", with: ta)
        }
        if !hasKey { items.insert(todoNoKey, at: 0) }
        return Array(items.prefix(4))
    }

    // MARK: v3 B：Tip 1.1–1.4「怎么划」（收尾只发 1.1，「懂了，下一条」一条条出；只 iPhone）

    static let tipsIntro = "最后教你在 [[gardenOS]] 里怎么划——一次一条，看懂了再给你下一条。"
    static let tipNext = "懂了，下一条"
    static let tipDone = "懂了"
    static let tipLater = "以后再看"
    /// 「以后再看」：剩下没看的都在灯泡里
    static func tipsLater(_ unseen: Int) -> String {
        unseen > 0 ? "好～剩下 \(unseen) 条我收进舞台上的灯泡里了，想看随时点它。" : "好～都收在舞台上的灯泡里了，想看随时点它。"
    }

    /// 回桌面那张按「切换应用」设置出竖条版 / 弧线版（strip = 竖条，默认）
    static func tip(_ kind: XiaoyaTipKind, strip: Bool) -> XiaoyaTipCopy {
        switch kind {
        case .toDesk where strip:
            return XiaoyaTipCopy(title: "回桌面",
                                 text: "在任何 app 里**往左划**，右边会拉出一条竖排 app；点最上面的 **⌂** 就回到 [[gardenOS]] 的桌面。",
                                 steps: ["往左划，拉出竖条", "点最上面的 ⌂"],
                                 summary: "在任何 app 里往左划，点竖条最上面的 ⌂")
        case .toDesk:
            return XiaoyaTipCopy(title: "回桌面",
                                 text: "按住左上角那道**弧线往屏幕中间拖**：拖一小段进后台，拖过半屏直接回 [[gardenOS]] 的桌面。",
                                 steps: ["左上角往中间拖一点 → 后台", "继续拖过半屏 → 桌面"],
                                 summary: "按住左上角的弧线往中间拖，拖过半屏回桌面")
        case .toChat:
            return XiaoyaTipCopy(title: "去聊天",
                                 text: "在桌面**往右划**就是聊天页——跟这一层的 Ta 说话。在 app 里往右划也直接到这儿，app 会留在后台。",
                                 steps: ["桌面往右划", "到聊天页"],
                                 summary: "在桌面往右划就是聊天页")
        case .toList:
            return XiaoyaTipCopy(title: "看所有对话",
                                 text: "聊天页**再往右划**，是对话列表：所有对话都在这儿，楼层也在这儿切。",
                                 steps: ["聊天页往右划", "到对话列表"],
                                 summary: "聊天页再往右划，是对话列表")
        case .floors:
            return XiaoyaTipCopy(title: "楼层是什么",
                                 text: "记忆花园里**一层住一个 Ta**：Ta 的名字、头像、人设、记忆和对话都只在这一层，不串门。在对话列表**顶上**就能换[[楼层]]。我不住在任何一层——你在哪层打开「\(AssistantPrompts.assistantName)」，我就帮哪层。",
                                 steps: ["对话列表顶上点楼层", "换一层，Ta 跟着换"],
                                 summary: "一层住一个 Ta，在对话列表顶上换")
        }
    }

    // MARK: 本地关键词（§7-4：精确匹配，不让模型决定出卡）

    static let recallKey = "配钥匙"
    static let recallTa = "建一个 Ta"
    static let recallPair = "连电脑"
    static let recallImport = "导卡"
    /// 输入框上方常驻的小 chip（引导走完后在小芽 app 里显示）
    static let recallChips = [recallKey, recallTa, recallPair, recallImport]

    static let recallKeyLine = "好～钥匙表在这儿，测通了才存。"
    static let recallPairMac = "连电脑是手机那头的事：在手机上的记忆花园里跟我说「连电脑」，扫一下这台 Mac「设置 › 让手机连这台 Mac」里的二维码就连上了。"

    /// 新建 / 导卡出来的楼层：出口卡上那一行
    static func tavernMeta(_ card: XiaoyaImportedCard) -> String {
        var parts: [String] = []
        if card.greetingCount > 0 { parts.append("开场白已就位") }
        if card.worldBookEntries > 0 { parts.append("世界书 \(card.worldBookEntries) 条已挂上") }
        if card.hasSystemPrompt { parts.append("用卡自带的系统指令") }
        return parts.isEmpty ? "卡已导好" : parts.joined(separator: " · ")
    }

    /// 新楼层出口卡上的一行（粟粟 10-16：讲楼层的概念）
    static let floorExitHint = "这是 Ta 的楼层：Ta 的名字、记忆、对话都住在这层。"

    static func floorFailed(_ why: String) -> String { "没建成：\(why)。再试一次？" }
    static func worldBookImported(_ name: String, ta: String) -> String { "世界书「\(name)」挂到\(ta)的楼层了。" }
    static func presetImported(_ name: String, ta: String) -> String { "预设「\(name)」换上了，只改\(ta)的楼层。" }
    static func importFailed(_ why: String) -> String { "没导进去：\(why)" }
    /// 「导入以前的聊天记录」：聊天记录导进当前楼层（ImportView），指路去 Ta 的楼层
    static func chatHistoryHint(_ ta: String) -> String { "聊天记录要导进\(ta)的楼层：点「去找 \(ta) →」过去，在对话列表上方点「导入」就行～" }
}
