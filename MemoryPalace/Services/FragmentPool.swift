import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

/// C2 本机路线被停（进后台 / 内存警告）= 被打断，不算失败、不记健康，下一轮重来。
/// staleClaim = 认领已经超时作废（10-16 astra #3）：这包不落库、不动水位、不记失败
enum FragmentPoolError: LocalizedError, Equatable {
    case interrupted
    case staleClaim
    case local(String)

    var errorDescription: String? {
        switch self {
        case .interrupted: return "被打断了（app 进了后台）"
        case .staleClaim: return "认领超时作废了"
        case .local(let message): return message
        }
    }
}

// MARK: - C2 用哪个模型（默认跟提取模型；选了本机、没装 / 在后台 → 这一轮用提取模型）

enum FragmentModelRoute {
    static let key = "mem_model_c2"
    /// 跟「提取模型」（老值；现在空就是跟提取模型）
    static let extractChoice = "extract"
    static let localPrefix = "local:"

    enum Route: Equatable {
        case local(modelId: String)
        case remote(ProviderModel)
    }

    struct Resolved: Equatable {
        let route: Route
        /// 实际跑的模型名（日志、状态那行）
        let displayName: String
        /// 想用本机却退回提取模型时写清为什么
        let fallbackNote: String?
        /// 选了本机但本机模型没下（一次性提示用）
        let localMissing: Bool

        var isLocal: Bool { if case .local = route { return true } else { return false } }
    }

    static func localName(_ modelId: String) -> String {
        switch modelId {
        case AssistantLocalModel.smart.id: return "本机 4B"
        case AssistantLocalModel.light.id: return "本机 1.7B"
        default: return "本机模型"
        }
    }

    /// 选择器读的时候：老值 "extract" 就是默认项（空）
    static func pickerChoice(_ choice: String) -> String {
        choice == extractChoice ? "" : choice
    }

    /// 选了本机哪一款；空（默认）/ 云上模型 = nil
    static func localModelId(choice: String) -> String? {
        choice.hasPrefix(localPrefix) ? String(choice.dropFirst(localPrefix.count)) : nil
    }

    /// 纯函数：空 = 提取模型；选了本机、装了且在前台 → 本机，否则 → 提取模型并写清；单选了某张卡上的模型 → 它（卡停了退提取模型）
    static func resolve(choice: String, memoryModel: ProviderModel, remoteModels: [ProviderModel],
                        localSupported: Bool, appActive: Bool, localInstalled: (String) -> Bool) -> Resolved {
        if let id = localModelId(choice: choice) {
            if localSupported, localInstalled(id), appActive {
                return Resolved(route: .local(modelId: id), displayName: localName(id), fallbackNote: nil, localMissing: false)
            }
            let why = !localSupported ? "这台设备跑不了本机模型" : (!localInstalled(id) ? "本机模型没下" : "app 在后台")
            return Resolved(route: .remote(memoryModel), displayName: memoryModel.name, fallbackNote: "\(why)，这一轮用 \(memoryModel.name)",
                            localMissing: localSupported && !localInstalled(id))
        }
        if choice != extractChoice, let m = remoteModels.first(where: { $0.id == choice }) {
            return Resolved(route: .remote(m), displayName: m.name, fallbackNote: nil, localMissing: false)
        }
        return Resolved(route: .remote(memoryModel), displayName: memoryModel.name, fallbackNote: nil, localMissing: false)
    }

    /// 后台写手选模型的卡：去掉本机卡（本机走 C2 自己的那一项；ProviderRouter 对本机的拒绝保留）
    static func remoteCredentials(_ enabled: [APICredential]) -> [APICredential] {
        enabled.filter { $0.type != .localMLX && !$0.models.isEmpty }
    }

    /// app 里的真解析（主线程：要看 app 在不在前台）。choiceKey = 读哪一项的单选（C3 同一套，`CatalogModelRoute.key`）
    @MainActor
    static func resolve(providerManager: ProviderManager, chatFallback: ProviderModel, defaults: UserDefaults = .standard,
                        choiceKey: String = key) -> Resolved {
        let memory = ConversationViewModel.memoryModel(providerManager: providerManager, fallback: chatFallback)
        #if os(iOS)
        let active = UIApplication.shared.applicationState != .background
        #else
        let active = true
        #endif
        return resolve(choice: defaults.string(forKey: choiceKey) ?? "", memoryModel: memory,
                       remoteModels: remoteCredentials(providerManager.enabledProviders).flatMap(\.models),
                       localSupported: LocalLLMService.isSupported, appActive: active,
                       localInstalled: { AssistantModelStore.installedDirectory(modelId: $0) != nil })
    }

    /// 按路线拿 caller：本机 → 排 `LocalLLMService` 的队（$0，按 0 花费记账）；云上 → 记忆写手同一个 caller（写入预算 + 全局闸 + 记花费，记在 kind 名下：C2 碎片池 / C3 整理编目）。
    /// 写入预算超了两条路都停（astra #12：超了后台写手停，本机也算后台写手）
    static func caller(for route: Route, providerManager: ProviderManager, conversationId: String, profileId: String, kind: UsageKind = .memory,
                       budgetExceeded: @escaping () -> Bool = { WriteBudgetStore.exceeded() },
                       preflight: ((String) async -> String?)? = nil) -> SessionSegmentWriter.Caller {
        switch route {
        case .local(let id):
            return { system, user in
                if budgetExceeded() {
                    CacheDiagLog.shared.log("🧠 \(kind.label)（本机）: 跳过（写入预算用完）")
                    return nil
                }
                return try await runLocal(modelId: id, system: system, user: user)
            }
        case .remote(let model):
            return SessionSegmentWriter.modelCaller(model: model, providerManager: providerManager,
                                                    conversationId: conversationId, profileId: profileId, kind: kind, preflight: preflight)
        }
    }

    /// 本机路线留给对话那截的字数：按实际 system 字数算（和 `LocalChatProvider.trimmed` 同一口径：system 截 3000 字、总共 6000 字、至少 500），
    /// 再让出重来时补的那句，免得重来那次开头被 trimmed 截掉
    static func localUserBudget(system: String, retryChars: Int = FragmentPool.retryNote.count) -> Int {
        let sys = system.count > LocalChatProvider.systemBudget ? LocalChatProvider.systemBudget + 1 : system.count
        return max(LocalChatProvider.totalBudget - sys, 500) - retryChars
    }

    @MainActor
    private static func runLocal(modelId: String, system: String, user: String) async throws -> String? {
        #if os(iOS)
        guard UIApplication.shared.applicationState != .background else { throw FragmentPoolError.interrupted }
        #endif
        let trimmed = LocalChatProvider.trimmed(system: system, messages: [(role: "user", content: user)], hasImages: false)
        let request = AssistantBackendRequest(system: trimmed.system, history: trimmed.history, tools: [], toolTurns: [], maxTokens: 1024)
        return try await withCheckedThrowingContinuation { continuation in
            LocalLLMService.shared.run(modelId: modelId, request: request) { event in
                switch event {
                case .token:
                    break
                case .finished(let text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: t.isEmpty ? nil : t)
                case .toolCalls:
                    continuation.resume(returning: nil)
                case .failed(let message):
                    continuation.resume(throwing: message.contains("被停下") || message.contains("模拟器")
                                        ? FragmentPoolError.interrupted : FragmentPoolError.local(message))
                }
            }
        }
    }
}

// MARK: - C2 碎片池：小小模型填严格 JSON（v5 §3-1、plan §七）

/// 只看称呼 + 这一截消息（`[3]` 编号），不带主提示词；只交 `{"fragments":[…]}`（Scarlett 脱水各字段 + category）。
/// JSON 或单卡不合格都只重写一次；最终一包才落库，第二轮坏卡丢弃。
/// 只加不改不删，一字不差的不加
enum FragmentPool {
    struct Message: Equatable {
        let id: String
        let role: String
        let content: String
        let date: Date?
    }

    struct Fragment: Decodable, Equatable {
        let msg: Int
        let content: String
        let tags: [String]
        let importance: Int
        let emotion: Int
        let resolved: Bool?
        let category: String
        var subject: String? = nil
        var speaker: String? = nil
        /// 带明确日子的事到哪天（YYYY-MM-DD，规格 4⅞-3）；类型 / 日期不对只丢这个字段
        var validUntil: Loose? = nil

        enum CodingKeys: String, CodingKey {
            case msg, content, tags, importance, emotion, resolved, category, subject, speaker
            case validUntil = "valid_until"
        }
    }

    /// 解不成字符串就当没写（不连累整张卡）
    struct Loose: Decodable, Equatable {
        let value: String?

        init(_ value: String?) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    /// 解出来的一包：合格的卡 + 拒收几张
    struct Batch: Equatable {
        let fragments: [Fragment]
        let rejected: Int
        var rejectionReasons: [String] = []
    }

    static let categories = ["preference", "fact", "relationship", "goal", "context"]
    static let speakers = ["用户自述", "AI 观察", "AI 承诺"]
    static let maxMessageChars = 600
    static let maxContentChars = 200
    static let maxSubjectChars = 40
    static let maxTags = 5

    /// 提示词编辑页的自定义模板（新 key；老的 AUDN 形状模板对不上这张表，不迁移）
    static let customPromptKey = "customFragmentPrompt"

    /// e62b23fa4 的默认全文，仅识别旧编辑器保存的未修改默认；不作为出站模板。
    private static let legacyDefaultTemplate = """
这不是在跟你聊天。你是填表的工具：读下面这段对话，把里面的事实一条一条填进表里。
事实 = 过一个月还成立、还用得上的事：{{USER_NAME}}是谁、有什么、在做什么、喜欢 / 讨厌什么、身体和生活的状况、和{{CHAR_NAME}}之间定下的约定和关系变化。
大多数对话里没有新事实，交 {"fragments":[]} 是正常的。宁可漏，不要凑。

只输出一个 JSON 对象，不要别的字：{"fragments":[{"msg":3,"content":"……","tags":["……"],"importance":3,"emotion":0,"resolved":null,"category":"fact"}]}；没有就 {"fragments":[]}。
- msg：这件事出自第几条（方括号里的编号）。日期不用写。
- content：一件事一条，120 字以内，干的陈述句，主语写名字（{{USER_NAME}} / {{CHAR_NAME}}），不用「我」「你」，不写感受评价。
- tags：关键词，最多 5 个。
- importance：1 到 5，5 = 一直要记得。
- emotion：-2 到 2，这件事带的情绪，0 = 平常。
- resolved：事情了结了填 true，还悬着填 false，说不上填 null。
- category：preference / fact / relationship / goal / context 选一个。
  relationship 只放{{USER_NAME}}和{{CHAR_NAME}}之间定下的约定、关系变化；拿不准填 fact。
- valid_until：只有带明确日子的事才写（复诊、截止、约好的那天），写到那天为止，格式 YYYY-MM-DD；「明天」「下周三」这类相对日期按那条消息自己的日期（编号后面那个日子）换算成日子，没标日子的按这一截最后一天（{{DATE}}）。没有就不写这个字段。
亲密互动里{{USER_NAME}}说的自身喜好、身体感受、边界都是真事，要记；只有括号里的动作描写和架空设定才算演出来的剧情。

不记：
- 客套闲聊、在问不是在说的（比如「这个报错是啥意思」）、报错 / 网络 / 工具失败、演出来的剧情（跳出剧情说的真事照记）。
- 对话经过：谁说了什么、谁承认 / 解释 / 道歉、谁看不懂谁——这些是时间轴的事，不是事实。
- {{CHAR_NAME}}说的话、做的事（只有对{{USER_NAME}}的承诺例外）。
- 把一句话原样抄成一条：content 必须是你自己写的陈述句，不是某一条消息的复制。
- 正在进行的工作步骤（「在写 plan」「收到单子了」）；只记做成了 / 定下来的结果。

坏例子（这些都不该进表）：
- 「{{CHAR_NAME}}承认漏画了船帆」——对话经过
- 「{{USER_NAME}}：这艘模型船要装两面帆吗？」——把一句提问原样抄了
- 「{{CHAR_NAME}}：船帆已经加进去了」——{{CHAR_NAME}}自己的话
好例子：
- 「{{USER_NAME}}在制作灯塔航线模型船，10-15 定下双帆方案」
例子只示范写法，别把例子里的事填进表。
"""

    static let defaultTemplate = """
这不是聊天。读两边对话，只把值得长期记住的事实填表。只记{{USER_NAME}}的事实；{{CHAR_NAME}}只有对{{USER_NAME}}的承诺或约定例外。
按顺序判断：
1. 一个月后还成立、还用得上吗？不确定、临时请求、纯讨论不记。
2. 是属性、状态、偏好或关系变化吗？记独立可读的状态句。
3. 是定下的结论或决定吗？写具体结论，不写「同意了」「决定照做」之类过程。
4. 是{{CHAR_NAME}}对{{USER_NAME}}的承诺吗？记，category=relationship；其他{{CHAR_NAME}}的话，包括普通观察和评价，不记。
大多数对话没有新事实，没有就 {"fragments":[]}，不要凑。

只输出一个 JSON 对象，不要别的字：
{"fragments":[{"msg":3,"content":"……","tags":["……"],"importance":3,"emotion":0,"resolved":null,"category":"fact","subject":"……","speaker":"用户自述"}]}
content、subject、tags 里引用词语一律用「」，不要用英文双引号。
- msg / content / tags / importance / emotion / category / subject / speaker 必填，格式如下。
- msg：事实出自哪条消息，填方括号里的编号；两边上下文可帮你读懂，不把助手的观察变成用户自述。
- content：一件事一条，1–3 句，≤200 字，脱离原文能读懂的状态句或结论句；主语写名字或明确事物，不用「我」「你」「那个」。不要原样复制消息。
- subject：这件事说的那个人或东西的名字本身，不写「X 的 Y」这种方面短语，方面写进 content 和 tags；同一个人或东西有几种叫法，用这段对话里最常用的那个。不能为空，最多 40 个字（按 Character 计），超长要改写，不裁剪。
- speaker：只填「用户自述」或「AI 承诺」，按事实来源归因，不按 content 的主语猜。
- tags：关键词数组，最多 5 个，没有填 []。
- importance：1–5，5 = 一直要记得。
- emotion：必填整数，-2…2，0 = 平常。
- resolved：已了结 true，还悬着 false，说不上 null。
- category：preference（偏好）/ fact（事实）/ relationship（两人约定或关系变化）/ goal（目标）/ context（状况）选一个。
- valid_until：只有带明确日子的事才写到那天为止，格式 YYYY-MM-DD。相对日期按来源消息编号后的日期换算；没标日期按这一截最后一天（{{DATE}}）；没有明确日期就不写，不猜。

亲密互动里{{USER_NAME}}说的自身喜好、真实身体感受和边界都是真事，要记；括号动作描写、架空动作不是现实事实。持久共享角色设定沿对话上下文理解，不把演出来的一次动作当现实经历。
不记工具日志、报错或工具失败、临时步骤、对话经过、一次性请求、提问和未定的讨论。只记做成了或定下来的结果。

以下全是编造的正反例，只示范写法，不填进表：
- 坏：{{USER_NAME}}同意了那个规则。好：《灯塔航线》规则定为每局三轮、轮流领航。
- 坏：{{CHAR_NAME}}说配色很好。这是普通观察，不记。
- 好：{{CHAR_NAME}}承诺下次陪{{USER_NAME}}画《云桥城》地图。subject={{CHAR_NAME}}，speaker=AI 承诺，category=relationship。
- 坏：「帮我查一下模型船胶水的价格」。一次请求，不记。
- 好：{{USER_NAME}}制作模型船时只用水性颜料。subject={{USER_NAME}}，speaker=用户自述。
- 坏：subject={{USER_NAME}}的作息、subject={{USER_NAME}}的模型船船帆。好：subject={{USER_NAME}}、subject=模型船，作息、船帆写进 content 和 tags。

写后自检：每条是否长期有用、独立可读、有明确主语和来源？是否写出了结论而非过程、没有原样复制、没有混入工具或助手观察？字段齐全、枚举和日期正确、content≤200 字、tags≤5；不合格的改写或删掉，不为填表编事实。
"""

    /// day = 这截对话最后一天（没标日子的消息换算「下周三」用）；不给 = 今天
    static func systemPrompt(names: MemoryExtractor.Names, defaults: UserDefaults = .standard, day: String? = nil) -> String {
        expandedPrompt(customTemplate(defaults) ?? defaultTemplate, names: names, day: day)
    }

    /// 现在生效的自定义模板（没有 / 是旧默认 = nil）：试写台把它导成「现在的自定义」配方
    static func activeCustomTemplate(defaults: UserDefaults = .standard) -> String? {
        customTemplate(defaults)
    }

    private static func customTemplate(_ defaults: UserDefaults) -> String? {
        guard let text = defaults.string(forKey: customPromptKey) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != legacyDefaultTemplate else { return nil }
        return text
    }

    private static func expandedPrompt(_ template: String, names: MemoryExtractor.Names, day: String?) -> String {
        template.replacingOccurrences(of: "{{USER_NAME}}", with: names.user)
            .replacingOccurrences(of: "{{CHAR_NAME}}", with: names.char)
            .replacingOccurrences(of: "{{DATE}}", with: day ?? MemoryDay.key(Date()))
    }

    /// 每条前面一个编号和它那天 `[3] 2026-10-18 · 粟粟：……`（记忆日 05:00 分界、设备时区；没时间的不带），每条最多 600 字；
    /// charBudget 给本机路线（装不下从最早的往外丢，编号不变）
    static func userContent(_ messages: [Message], names: MemoryExtractor.Names, charBudget: Int? = nil) -> String {
        window(messages, names: names, charBudget: charBudget).text
    }

    /// 送进去的那截 + 模型看得到的编号（被预算丢掉的前几条不算）
    static func window(_ messages: [Message], names: MemoryExtractor.Names, charBudget: Int?) -> (text: String, visible: ClosedRange<Int>) {
        var lines = messages.enumerated().map { i, m -> String in
            let label = m.role == "user" ? names.user : names.char
            let text = m.content.count > maxMessageChars ? String(m.content.prefix(maxMessageChars)) + "…" : m.content
            return "[\(i + 1)] " + (m.date.map { MemoryDay.key($0) + " · " } ?? "") + "\(label)：\(text)"
        }
        if let charBudget {
            while lines.count > 1, lines.reduce(0, { $0 + $1.count + 2 }) > charBudget { lines.removeFirst() }
        }
        return (lines.joined(separator: "\n\n"), (messages.count - lines.count + 1)...max(messages.count, 1))
    }

    // MARK: - 严格解析（纯函数）

    /// 整包正好一个 JSON 对象，只容一层 ```json（或 ```）围栏；别的字一律不合格。返回去掉围栏的对象文本。
    /// 开头那一块 `<think>…</think>`（模型开了思考）先剥掉再按上面的规则判；没收尾的不合格
    static func strictObjectText(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<think>") {
            guard let end = t.range(of: "</think>") else { return nil }
            t = t[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.hasPrefix("```") {
            guard t.hasSuffix("```"), t.count >= 6 else { return nil }
            t = String(t.dropFirst(3).dropLast(3))
            if t.hasPrefix("json") { t = String(t.dropFirst(4)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("```") { return nil }
        }
        guard t.hasPrefix("{"), t.hasSuffix("}") else { return nil }
        return t
    }

    private struct Envelope: Decodable {
        let fragments: [Lossy]
    }

    private struct Lossy: Decodable {
        let value: Fragment?
        let reason: String?

        init(from decoder: Decoder) throws {
            do {
                let fields = try decoder.container(keyedBy: Fragment.CodingKeys.self)
                for key in [Fragment.CodingKeys.subject, .speaker] where fields.contains(key) {
                    _ = try fields.decode(String.self, forKey: key)
                }
                value = try Fragment(from: decoder)
                reason = nil
            } catch {
                value = nil
                reason = decodingReason(error)
            }
        }
    }

    private static func decodingReason(_ error: Error, text: String? = nil) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            let parser = (context.underlyingError ?? error) as NSError
            let debug = parser.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription
            var reason = "JSON 数据格式不合法（解析器：\(debug)）"
            if let text, let offset = parser.userInfo["NSJSONSerializationErrorIndex"] as? Int,
               let byteIndex = text.utf8.index(text.utf8.startIndex, offsetBy: max(0, offset), limitedBy: text.utf8.endIndex),
               let position = String.Index(byteIndex, within: text) {
                let lower = text.index(position, offsetBy: -10, limitedBy: text.startIndex) ?? text.startIndex
                let upper = text.index(position, offsetBy: 10, limitedBy: text.endIndex) ?? text.endIndex
                reason += "；第 \(text.distance(from: text.startIndex, to: position) + 1) 字符附近：\(text[lower..<upper])"
            }
            return reason + #"；字符串里的双引号要写成 \" 或改用「」。"#
        case DecodingError.keyNotFound(let key, _): return "缺少字段 \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context):
            return "\(context.codingPath.last?.stringValue ?? "卡片") 类型不合法或为 null"
        default: return "JSON 数据格式不合法"
        }
    }

    /// nil = 整包不合格；卡片错误保留原因供唯一一次整包重写。
    static func parse(_ raw: String, visible: ClosedRange<Int>, messages: [Message] = [],
                      requireAttribution: Bool = true) -> Batch? {
        try? decodedBatch(raw, visible: visible, messages: messages, requireAttribution: requireAttribution)
    }

    /// 同 `parse`，整包不合格时带上原因（试写台的检查要显示哪条没过）
    static func parseExplained(_ raw: String, visible: ClosedRange<Int>, messages: [Message] = [],
                               requireAttribution: Bool = true) -> (batch: Batch?, problem: String?) {
        do {
            return (try decodedBatch(raw, visible: visible, messages: messages, requireAttribution: requireAttribution), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func decodedBatch(_ raw: String, visible: ClosedRange<Int>, messages: [Message],
                                     requireAttribution: Bool) throws -> Batch {
        guard let text = strictObjectText(raw), let data = text.data(using: .utf8) else {
            throw MemoryWriterError.format("必须只输出一个 JSON 对象")
        }
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw MemoryWriterError.format(decodingReason(error, text: text)) }
        var kept: [Fragment] = []
        var reasons: [String] = []
        for (index, item) in env.fragments.enumerated() {
            guard var f = item.value else {
                reasons.append("第 \(index + 1) 张：\(item.reason ?? "卡片格式不合法")")
                continue
            }
            let content = f.content.trimmingCharacters(in: .whitespacesAndNewlines)
            f.subject = f.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
            f.speaker = f.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = validationReason(f, content: content, visible: visible, messages: messages, requireAttribution: requireAttribution) {
                reasons.append("第 \(index + 1) 张：\(reason)")
                continue
            }
            kept.append(Fragment(msg: f.msg, content: content,
                                 tags: f.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                                 importance: f.importance, emotion: f.emotion, resolved: f.resolved, category: f.category,
                                 subject: f.subject, speaker: f.speaker,
                                 validUntil: validDay(f.validUntil?.value).map { Loose($0) }))
        }
        return Batch(fragments: kept, rejected: reasons.count, rejectionReasons: reasons)
    }

    private static let copyIgnored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)

    private static func validationReason(_ f: Fragment, content: String, visible: ClosedRange<Int>, messages: [Message],
                                         requireAttribution: Bool) -> String? {
        guard visible.contains(f.msg) else { return "msg 不在本次可见编号内" }
        guard !content.isEmpty else { return "content 不能为空" }
        guard content.count <= maxContentChars else { return "content 超过 200 字，不能裁剪" }
        guard f.tags.count <= maxTags else { return "tags 超过 5 个" }
        guard (1...5).contains(f.importance) else { return "importance 必须为 1–5" }
        guard (-2...2).contains(f.emotion) else { return "emotion 必须为 -2…2" }
        guard categories.contains(f.category) else { return "category 不在允许枚举内" }
        if requireAttribution && (f.subject == nil || f.speaker == nil) { return "新默认必须填写 subject / speaker" }
        if let subject = f.subject {
            if subject.isEmpty { return "subject 不能为空" }
            if subject.count > maxSubjectChars { return "subject 超过 40 字，不能裁剪" }
        }
        if let speaker = f.speaker, !speakers.contains(speaker) || (requireAttribution && speaker == "AI 观察") {
            return "speaker 不在允许枚举内"
        }
        if messages.indices.contains(f.msg - 1),
           content.lazy.filter({ $0.unicodeScalars.allSatisfy { !copyIgnored.contains($0) } }).elementsEqual(
            messages[f.msg - 1].content.lazy.filter { $0.unicodeScalars.allSatisfy { !copyIgnored.contains($0) } }) {
            return "content 去掉空白、标点和符号后与 msg 原文完全相同，必须改写"
        }
        return nil
    }

    /// 「2026-10-22」：四位年 - 两位月 - 两位日、日历上真有这天（2-30 这种不算）
    static func validDay(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), t.count == 10,
              t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = MemoryDay.date(ofKey: t) else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) == t ? t : nil
    }

    /// 到哪天为止 → 那一天的记忆日结束（次日 05:00）
    static func validUntilDate(_ day: String, calendar: Calendar = .current) -> Date? {
        guard let d = MemoryDay.date(ofKey: day, calendar: calendar), let next = calendar.date(byAdding: .day, value: 1, to: d) else { return nil }
        return MemoryDay.boundary(of: next, calendar: calendar)
    }

    /// 仅反馈第一处具体错误及总数，不把模型的坏输出再次灌入提示词。
    static let retryNote = "\n\n上一次不合格：请修正后重交完整的 {\"fragments\":[…]} JSON 对象，不要别的字。\n原因："

    /// 整包或单卡失败都只重写一次；第二轮只保留合格卡，不先写第一轮。
    static func run(_ messages: [Message], names: MemoryExtractor.Names, local: Bool = false,
                    defaults: UserDefaults = .standard, onFirstRejection: ((Int, String) -> Void)? = nil,
                    caller: SessionSegmentWriter.Caller) async throws -> Batch? {
        guard !messages.isEmpty else { return Batch(fragments: [], rejected: 0) }
        let custom = customTemplate(defaults)
        let system = expandedPrompt(custom ?? defaultTemplate, names: names, day: messages.last?.date.map { MemoryDay.key($0) })
        let sent = window(messages, names: names, charBudget: local ? FragmentModelRoute.localUserBudget(system: system) : nil)
        guard let raw = try await caller(system, sent.text) else { return nil }
        let reason: String
        var rejected = 1
        do {
            let batch = try decodedBatch(raw, visible: sent.visible, messages: messages, requireAttribution: custom == nil)
            if batch.rejected == 0 { return batch }
            rejected = batch.rejected
            reason = batch.rejectionReasons.first ?? "卡片校验失败"
        } catch { reason = error.localizedDescription }
        onFirstRejection?(rejected, reason)
        CacheDiagLog.shared.log("🧠 碎片池: \(reason)，重写一次")
        let note = retryNote + reason + "；共 \(rejected) 张不合格"
        let retrySent = window(messages, names: names,
                               charBudget: local ? FragmentModelRoute.localUserBudget(system: system, retryChars: note.count) : nil)
        guard let retry = try await caller(system, retrySent.text + note) else { return nil }
        return try decodedBatch(retry, visible: retrySent.visible, messages: messages, requireAttribution: custom == nil)
    }

    /// 落库：只加；一字不差的不加。出处 = 第几条消息（发生日按 05:00 日界）。返回新加了几条。
    /// 字段（importance 等）全部赋好后只存一次（10-16 astra #5：先存正文再补字段，中间被杀会留下认不出是 C2 的半成品）；
    /// 存不成就把这次插进去的撤掉再抛，免得没存的留在 context 里、下次重来被当成「一字不差」跳过
    @discardableResult
    static func write(_ fragments: [Fragment], messages: [Message], profileId: String, conversationId: String?,
                      extractedBy: String, store: MemoryStore, context: ModelContext) throws -> Int {
        guard !fragments.isEmpty else { return 0 }
        var contents = Set(store.listAll(profileId: profileId, context: context).map(\.content))
        var inserted: [Memory] = []
        for f in fragments {
            guard !contents.contains(f.content), messages.indices.contains(f.msg - 1) else { continue }
            let source = messages[f.msg - 1]
            let m = store.insertUnsaved(content: f.content, category: f.category, keywords: f.tags, profileId: profileId,
                                        isUserExplicit: false, extractedBy: extractedBy, sourceConversationId: conversationId,
                                        sourceQuote: nil, sourceNodeId: source.id, context: context)
            m.occurredDay = MemoryDay.key(source.date ?? Date())
            m.importance = f.importance
            m.emotion = f.emotion
            m.resolved = f.resolved
            m.validUntil = f.validUntil?.value.flatMap { validUntilDate($0) }
            m.subject = f.subject
            m.speaker = f.speaker
            contents.insert(f.content)
            inserted.append(m)
        }
        guard !inserted.isEmpty else { return 0 }
        do {
            try context.save()
        } catch {
            for m in inserted { context.delete(m) }
            throw error
        }
        return inserted.count
    }

    /// 日志那条：「记下 4 条 · 拒收 1 张（格式不对）」
    static func note(added: Int, rejected: Int, fallback: String?) -> String {
        var s = "记下 \(added) 条"
        if rejected > 0 { s += " · 拒收 \(rejected) 张（格式不对）" }
        if let fallback { s += " · \(fallback)" }
        return s
    }

    // MARK: - 跑一包（API / CC 两条路共用）

    /// 一包的结果
    enum Outcome: Equatable {
        /// 预算闸 / 空输出 / 被打断 / 断网 / 开关关了 / 认领作废：不算失败，这一截留着下次再来
        case skipped
        /// 写成了（合法空包也算）
        case done(added: Int)
        /// 两次都不是合格 JSON，整包拒收（记了失败）：这一截不再重试
        case rejected
        /// 记了失败但没写成（请求出错 / 超时 / 落库失败）：这一截留着下次再来（10-16 astra #2）
        case failed

        /// 水位能不能提交（API / CC 同一规矩）：只有写成（含合法空包）或整包拒收；网络 / 存储失败一律放回
        var settled: Bool {
            switch self {
            case .done, .rejected: return true
            case .skipped, .failed: return false
            }
        }
    }

    /// 跑一包：调模型（前后复查开关，astra #1）→ 落库 → 记健康状态和日志
    static func process(_ messages: [Message], names: MemoryExtractor.Names, caller: @escaping SessionSegmentWriter.Caller,
                        local: Bool, profileId: String, modelName: String, fallbackNote: String?,
                        write: ([Fragment]) async throws -> Int) async -> Outcome {
        var firstRejectionNote: String?
        var firstRejected: Int?
        func recordSkipped(_ reason: String) {
            guard let firstRejectionNote else { return }
            MemoryWriteLog.record(.extract, profileId: profileId, ok: false,
                                  note: "\(firstRejectionNote) · 跳过：\(reason)", model: modelName, rejected: firstRejected)
        }
        do {
            let gated = SessionSegmentWriter.gated({ MemoryHealthStore.isOn(.extract) }, caller)
            guard let batch = try await run(messages, names: names, local: local, onFirstRejection: { count, reason in
                firstRejected = count
                firstRejectionNote = "首轮拒收 \(count) 张：\(reason)"
            }, caller: gated) else {
                recordSkipped("预算闸 / 空输出 / 开关关了")
                return .skipped
            }
            if batch.fragments.isEmpty && batch.rejected > 0 {
                let error = MemoryWriterError.format("重写后拒收 \(batch.rejected) 张：\(batch.rejectionReasons.first ?? "卡片校验失败")")
                guard recordFailure(error, profileId: profileId, modelName: modelName,
                                    note: firstRejectionNote, rejected: batch.rejected) else {
                    recordSkipped(error.localizedDescription)
                    return .skipped
                }
                return .rejected
            }
            let added = try await write(batch.fragments)
            let finalNote = note(added: added, rejected: batch.rejected, fallback: fallbackNote)
            MemoryHealthStore.recordOK(.extract, profileId: profileId, modelName: modelName,
                                       note: firstRejectionNote.map { "\($0) · \(finalNote)" } ?? finalNote, rejected: batch.rejected)
            return .done(added: added)
        } catch {
            guard recordFailure(error, profileId: profileId, modelName: modelName, note: firstRejectionNote) else {
                recordSkipped(error.localizedDescription)
                return .skipped
            }
            return error is MemoryWriterError ? .rejected : .failed
        }
    }

    /// 一包没成：被打断 / 断网不算；开关关着不计（不红）；整包拒收（两次都不是合格 JSON）照记失败、日志记拒收 1——
    /// 连续 3 包状态卡那行就红（failStreak，astra 车头 #13），成功一包清零。返回 true = 记了失败
    @discardableResult
    static func recordFailure(_ error: Error, profileId: String, modelName: String,
                              note: String? = nil, rejected: Int? = nil) -> Bool {
        if case FragmentPoolError.interrupted = error { return false }
        if case FragmentPoolError.staleClaim = error { return false }
        guard !SessionCloseout.isTransient(error), MemoryHealthStore.isOn(.extract) else { return false }
        let message = note.map { "\($0) · \(error.localizedDescription)" } ?? error.localizedDescription
        MemoryHealthStore.recordError(.extract, profileId: profileId, message: message, modelName: modelName,
                                      rejected: rejected ?? (error is MemoryWriterError ? 1 : nil))
        return true
    }
}

// MARK: - 窗口触发（每满 N 条新消息，API / CC 共用一份水位；plan-memory-audit-desk 第三节）

/// 每个窗口记到哪条了（落盘 `mem_c2_marks`，最多 300 个窗口、超了扔最久没动的；第一次见到一个窗口先记下当前位置，不回头补，免得升级后把老对话重新过一遍）。
/// 水位成功处理后才提交（astra #3）：`due` 只认领，跑完 `finish`——写成 / 合法空包 / 整包拒收才提交，别的放回（10-16 astra #2）。
/// 顺序认领（10-16 astra #1）：从水位之后取前 N 条，水位只推进到这一批末尾；积压超过 N 条分批，一次触发认领一批
/// （每轮回复落地都会再触发，积压几轮就追上；不在一次触发里连打几次模型）。
/// 每次认领带一个 token（10-16 astra #3）：提交 / 放回 / 写库前都要对上，超时作废的旧任务落不了库、动不了水位、也清不掉新任务的认领。
/// 同一个窗口同一时刻只认领一截（认领只在内存里）；快照里找不到水位、又比水位还旧 = 晚到的旧快照，不倒退、不重复提取（astra #4）
actor FragmentWatch {
    static let shared = FragmentWatch()
    /// 每满几条写一次（两边加起来），C2 二级页可调
    static let everyKey = "mem_c2_every"
    static let defaultEvery = 20
    static let everyRange = 6...40
    static let marksKey = "mem_c2_marks"
    static let maxMarks = 300
    /// 认领了这么久还没交回（本机模型卡死之类）就当丢了
    static let claimTimeout: TimeInterval = 15 * 60

    static func every(_ defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: everyKey)
        return v == 0 ? defaultEvery : min(max(v, everyRange.lowerBound), everyRange.upperBound)
    }

    /// 认领到的一截：range = 路径里的下标；token = 这次认领的身份
    struct Claim: Equatable {
        let range: Range<Int>
        let token: UUID
    }

    private struct Mark {
        let id: String
        let date: Date?
    }

    private let defaults: UserDefaults
    private var watermark: [String: (mark: Mark, touched: Date)]
    private var inFlight: [String: (mark: Mark, at: Date, token: UUID)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [String: (mark: Mark, touched: Date)] = [:]
        for (cid, raw) in defaults.dictionary(forKey: Self.marksKey) ?? [:] {
            guard let d = raw as? [String: Any], let id = d["id"] as? String, let u = d["u"] as? Double else { continue }
            loaded[cid] = (Mark(id: id, date: (d["d"] as? Double).map(Date.init(timeIntervalSince1970:))), Date(timeIntervalSince1970: u))
        }
        watermark = loaded
    }

    /// 满 N 条新消息 → 认领水位之后的前 N 条；不够 / 第一次见 / 这个窗口正在跑 / 旧快照 → nil。dates 和 pathIds 一一对应。
    /// threshold 不给 = 读设置 `mem_c2_every`
    func due(conversationId: String, pathIds: [String], dates: [Date?], threshold: Int? = nil, now: Date = Date()) -> Claim? {
        guard let last = pathIds.last else { return nil }
        let n = threshold ?? Self.every(defaults)
        if let f = inFlight[conversationId], now.timeIntervalSince(f.at) < Self.claimTimeout { return nil }
        guard let mark = watermark[conversationId]?.mark else {
            setMark(Mark(id: last, date: dates.last ?? nil), for: conversationId, now: now)
            return nil
        }
        let range: Range<Int>
        if let i = pathIds.lastIndex(of: mark.id) {
            guard pathIds.count - (i + 1) >= n else { return nil }
            range = (i + 1)..<(i + 1 + n)
        } else {
            // 找不到水位：比水位还旧的快照（晚到）→ 不动；不然是切过分支 → 只看最后 N 条，水位挪到新分支最后一条（原语义不变）
            if let md = mark.date, let ld = dates.last ?? nil, ld <= md { return nil }
            guard pathIds.count >= n else { return nil }
            range = (pathIds.count - n)..<pathIds.count
        }
        let end = range.upperBound - 1
        let token = UUID()
        inFlight[conversationId] = (Mark(id: pathIds[end], date: dates.indices.contains(end) ? dates[end] : nil), now, token)
        return Claim(range: range, token: token)
    }

    private func setMark(_ mark: Mark, for conversationId: String, now: Date) {
        watermark[conversationId] = (mark, now)
        if watermark.count > Self.maxMarks {
            let drop = watermark.sorted { $0.value.touched < $1.value.touched }.prefix(watermark.count - Self.maxMarks)
            for (cid, _) in drop { watermark[cid] = nil }
        }
        var out: [String: [String: Any]] = [:]
        for (cid, v) in watermark {
            var d: [String: Any] = ["id": v.mark.id, "u": v.touched.timeIntervalSince1970]
            if let date = v.mark.date { d["d"] = date.timeIntervalSince1970 }
            out[cid] = d
        }
        defaults.set(out, forKey: Self.marksKey)
    }

    /// 这次认领还作数：token 对得上、没超时（写库前查一次）
    func holds(conversationId: String, token: UUID, now: Date = Date()) -> Bool {
        guard let f = inFlight[conversationId], f.token == token else { return false }
        return now.timeIntervalSince(f.at) < Self.claimTimeout
    }

    /// 这一截处理完了：水位挪到这一批最后一条。token 对不上不动；对得上但已超时 = 作废，只清认领、水位不动
    func commit(conversationId: String, token: UUID, now: Date = Date()) {
        guard let f = inFlight[conversationId], f.token == token else { return }
        inFlight[conversationId] = nil
        guard now.timeIntervalSince(f.at) < Self.claimTimeout else { return }
        setMark(f.mark, for: conversationId, now: now)
    }

    /// 这一截没处理成：水位不动，下次再认领。token 对不上不动（清不掉别人的认领）
    func release(conversationId: String, token: UUID) {
        guard inFlight[conversationId]?.token == token else { return }
        inFlight[conversationId] = nil
    }

    /// 跑完一包按结果收尾（API / CC 同一规矩）：`outcome.settled` 才提交，别的放回
    func finish(conversationId: String, claim: Claim, outcome: FragmentPool.Outcome, now: Date = Date()) {
        if outcome.settled {
            commit(conversationId: conversationId, token: claim.token, now: now)
        } else {
            release(conversationId: conversationId, token: claim.token)
        }
    }
}
