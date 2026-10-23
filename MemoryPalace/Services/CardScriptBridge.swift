import Foundation

// 卡库第二批 B3 / B4（plan-card-library-batch2 §3 B3–B4，research §3.2–3.4）：
// 卡里网页（交互 iframe）调酒馆助手 API 的原生侧纯逻辑——校验链、限频、参数 schema、
// 楼层 / swipe 映射、写消息计划（本楼及之后的闸）、变量惰性初始化与上限、快照截窗口、事件差分。
// 不碰 SwiftData / WebKit：Page2 宿主把当前路径整理成值类型喂进来，单测直接用。

enum CardScriptLimits {
    /// 单次 call 参数（JSON）上限
    static let argsBytes = 256 * 1024
    /// 同一实例每秒最多 call 次数
    static let callsPerSecond = 20
    /// 快照（同步读用）上限，超了从最早的楼层截掉
    static let snapshotBytes = 1_000_000
    /// 单个变量表上限
    static let variableTableBytes = 256 * 1024
    /// 自动高度夹在这之间（pt）
    static let minFrameHeight = 120.0
    static let maxFrameHeight = 2000.0

    static func clampHeight(_ h: Double) -> Double {
        guard h.isFinite else { return minFrameHeight }
        return min(max(h.rounded(.up), minFrameHeight), maxFrameHeight)
    }
}

/// 原生只认这几个方法：其余助手 API 要么在子页内读快照 / 本地实现，要么是「暂不支持」。
/// B5：triggerSlash（triggerSlashWithResult 在子页里走同一个）
enum CardScriptMethod: String, CaseIterable {
    case replaceVariables
    case setChatMessages
    case triggerSlash
}

enum CardScriptRejection: Error, Equatable {
    case unregisteredToken
    case notInteractive
    case identityMismatch
    case notPermitted(String)
    case methodNotAllowed(String)
    case badArguments(String)
    case tooLarge(String)
    case rateLimited
    case outOfRange(String)
    case earlierFloor
    case unsupported(String)
    /// B5：替你发消息被拒（正在生成 / 3 秒内点过 / 非卡聊天 / 你没允许……），文案原样给子页和轻提示
    case refused(String)

    /// 前三步不可信（token / 模式 / 身份对不上）：不回包，只记日志
    var isSilent: Bool {
        switch self {
        case .unregisteredToken, .notInteractive, .identityMismatch: return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .unregisteredToken: return "实例未登记"
        case .notInteractive: return "不是交互实例"
        case .identityMismatch: return "实例身份对不上"
        case .notPermitted(let why): return why
        case .methodNotAllowed(let m): return "记忆花园暂不支持 \(m)"
        case .badArguments(let why): return "参数不对：\(why)"
        case .tooLarge(let what): return "\(what)太大"
        case .rateLimited: return "调用太频繁（每秒最多 \(CardScriptLimits.callsPerSecond) 次）"
        case .outOfRange(let why): return why
        case .earlierFloor: return "卡里的网页只能改本楼及之后的消息"
        case .unsupported(let what): return "记忆花园暂不支持 \(what)"
        case .refused(let why): return why
        }
    }
}

/// 同一实例（token）滑动 1 秒窗口限频
struct CardScriptRateLimiter {
    private var hits: [String: [TimeInterval]] = [:]
    let limit: Int
    let window: TimeInterval

    init(limit: Int = CardScriptLimits.callsPerSecond, window: TimeInterval = 1) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(_ key: String, now: TimeInterval) -> Bool {
        var list = (hits[key] ?? []).filter { now - $0 < window }
        guard list.count < limit else { hits[key] = list; return false }
        list.append(now)
        hits[key] = list
        return true
    }

    mutating func forget(_ key: String) { hits[key] = nil }
}

/// 原生校验链（plan B3）：token 已登记 → 交互模式 → 身份与发起时一致 → 卡 allowed + 总开关 → 方法白名单 →
/// 参数 schema + 大小上限 →（作用域 / message_id 在执行时按当下路径解析）→ 限频
enum CardScriptGate {
    struct Input {
        /// 登记表里这个 token 的身份 / 模式；nil = 没登记
        var registered: (identity: HTMLEmbedIdentity, interactive: Bool)?
        /// 消息里自报的 nodeId / segmentId（父页按来源 iframe 填）
        var claimedNodeId: String
        var claimedSegmentId: String
        /// 当前宿主唯一交互实例的 token 与身份
        var activeToken: String?
        var token: String
        /// 宿主眼下的楼层 / 对话
        var currentProfileId: String
        var currentConversationId: String
        /// nil = 可以运行；否则是关总开关 / 撤卡许可的原因
        var runDenial: String?
        var method: String
        var args: String
    }

    static func check(_ input: Input, limiter: inout CardScriptRateLimiter, now: TimeInterval) -> Result<CardScriptRequest, CardScriptRejection> {
        guard let reg = input.registered else { return .failure(.unregisteredToken) }
        guard reg.interactive else { return .failure(.notInteractive) }
        let id = reg.identity
        guard id.nodeId == input.claimedNodeId, id.segmentId == input.claimedSegmentId,
              id.profileId == input.currentProfileId, id.conversationId == input.currentConversationId,
              input.activeToken == input.token else { return .failure(.identityMismatch) }
        if let denial = input.runDenial { return .failure(.notPermitted(denial)) }
        guard let method = CardScriptMethod(rawValue: input.method) else { return .failure(.methodNotAllowed(input.method)) }
        guard input.args.utf8.count <= CardScriptLimits.argsBytes else { return .failure(.tooLarge("参数")) }
        let parsed = CardScriptRequest.parse(method: method, args: input.args)
        guard case .success = parsed else { return parsed }
        guard limiter.allow(input.token, now: now) else { return .failure(.rateLimited) }
        return parsed
    }
}

// MARK: - 请求

enum CardVariableScope: Equatable {
    case chat
    /// message_id：nil = 最新一楼，负数从末尾数
    case message(Int?)
}

struct CardMessageWrite: Equatable {
    var messageId: Int
    var message: String?
    /// message 变量（JSON 对象）
    var data: Data?
    var swipeId: Int?
}

enum CardScriptRequest: Equatable {
    case replaceVariables(scope: CardVariableScope, table: Data)
    case setChatMessages([CardMessageWrite], refresh: String)
    /// B5：slash 命令原文（解析在 CardSlash.plan，执行要过 sendConsent 与防护）
    case triggerSlash(String)

    static let refreshModes: Set<String> = ["none", "affected", "all"]
    /// setChatMessages 里认得但本批不做的字段
    static let unsupportedMessageKeys = ["swipes", "swipes_data", "swipes_info", "name", "role", "is_hidden", "extra"]

    static func parse(method: CardScriptMethod, args: String) -> Result<CardScriptRequest, CardScriptRejection> {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] else {
            return .failure(.badArguments("不是 JSON 对象"))
        }
        switch method {
        case .replaceVariables:
            guard let vars = obj["variables"] as? [String: Any] else { return .failure(.badArguments("variables 必须是对象")) }
            let option = obj["option"] as? [String: Any] ?? [:]
            let type = option["type"] as? String ?? "chat"
            let scope: CardVariableScope
            switch type {
            case "chat": scope = .chat
            case "message":
                if option["message_id"] == nil || (option["message_id"] as? String) == "latest" {
                    scope = .message(nil)
                } else if let id = integer(option["message_id"]) {
                    scope = .message(id)
                } else {
                    return .failure(.badArguments("message_id 必须是整数或 'latest'"))
                }
            default: return .failure(.unsupported("\(type) 作用域的变量"))
            }
            switch CardVariables.encode(vars) {
            case .success(let data): return .success(.replaceVariables(scope: scope, table: data))
            case .failure(let e): return .failure(e)
            }

        case .setChatMessages:
            guard let list = obj["messages"] as? [Any] else { return .failure(.badArguments("messages 必须是数组")) }
            guard list.count <= 256 else { return .failure(.tooLarge("一次改的消息")) }
            let refresh = (obj["option"] as? [String: Any])?["refresh"] as? String ?? "affected"
            guard refreshModes.contains(refresh) else { return .failure(.badArguments("refresh 只能是 none / affected / all")) }
            var writes: [CardMessageWrite] = []
            for item in list {
                guard let m = item as? [String: Any], let id = integer(m["message_id"]) else {
                    return .failure(.badArguments("每条都要有整数 message_id"))
                }
                if let key = unsupportedMessageKeys.first(where: { m[$0] != nil }) {
                    return .failure(.unsupported("setChatMessages 的 \(key)"))
                }
                var w = CardMessageWrite(messageId: id)
                if let v = m["message"] {
                    guard let s = v as? String else { return .failure(.badArguments("message 必须是字符串")) }
                    w.message = s
                }
                if let v = m["data"] {
                    guard let d = v as? [String: Any] else { return .failure(.badArguments("data 必须是对象")) }
                    switch CardVariables.encode(d) {
                    case .success(let data): w.data = data
                    case .failure(let e): return .failure(e)
                    }
                }
                if let v = m["swipe_id"] {
                    guard let s = integer(v) else { return .failure(.badArguments("swipe_id 必须是整数")) }
                    w.swipeId = s
                }
                writes.append(w)
            }
            return .success(.setChatMessages(writes, refresh: refresh))

        case .triggerSlash:
            guard let command = obj["command"] as? String else { return .failure(.badArguments("command 必须是字符串")) }
            guard command.utf8.count <= CardSlash.maxBytes else { return .failure(.tooLarge("slash 命令")) }
            return .success(.triggerSlash(command))
        }
    }

    /// JSON 数字 → Int（拒小数 / 布尔 / 越界）
    static func integer(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }
}

// MARK: - 楼层 / swipe

/// 当前路径上的一楼（Page2 宿主从 currentPath + branchInfoMap 整理）：楼层＝路径下标（合成根 / 不显示节点不算楼），
/// swipes＝分叉点的孩子，顺序与 `‹ n / m ›` 分支切换一致
struct CardPathFloor: Equatable {
    let nodeId: String
    /// 分叉点（可能是不显示的合成根）；nil = 这楼只有一个候选
    let forkId: String?
    let swipeCount: Int
    let swipeIndex: Int

    init(nodeId: String, forkId: String? = nil, swipeCount: Int = 1, swipeIndex: Int = 0) {
        self.nodeId = nodeId
        self.forkId = swipeCount > 1 ? forkId : nil
        self.swipeCount = max(swipeCount, 1)
        self.swipeIndex = min(max(swipeIndex, 0), max(swipeCount, 1) - 1)
    }
}

enum CardWriteStep: Equatable {
    case editMessage(nodeId: String, text: String)
    case setMessageVariables(nodeId: String, table: Data)
    case setChatVariables(Data)
    case switchSwipe(forkId: String, index: Int)
}

enum CardScriptPlanner {
    /// message_id（负数从末尾数）→ 楼层号；越界 nil
    static func resolve(_ id: Int?, count: Int) -> Int? {
        let n = id ?? -1
        let floor = n < 0 ? count + n : n
        return (0..<count).contains(floor) ? floor : nil
    }

    /// 写计划：先正文 / 变量（按调用当下的路径解析成节点），后切 swipe（切了以后的楼层会换成别的分支）。
    /// 正文只许本楼及之后：任何一条改到更早楼层 → 整个调用拒，什么都不写
    static func plan(_ request: CardScriptRequest, path: [CardPathFloor], ownNodeId: String) -> Result<[CardWriteStep], CardScriptRejection> {
        switch request {
        case .replaceVariables(let scope, let table):
            switch scope {
            case .chat: return .success([.setChatVariables(table)])
            case .message(let id):
                guard let floor = resolve(id, count: path.count) else {
                    return .failure(.outOfRange("楼层号 \(id.map(String.init) ?? "latest") 超出范围 [\(-path.count), \(path.count))"))
                }
                return .success([.setMessageVariables(nodeId: path[floor].nodeId, table: table)])
            }

        case .setChatMessages(let writes, _):
            let own = path.firstIndex { $0.nodeId == ownNodeId }
            // 同楼多条合并（后写的字段覆盖），按楼层升序；不存在的楼层跳过（同酒馆助手）
            var merged: [Int: CardMessageWrite] = [:]
            for w in writes {
                guard let floor = resolve(w.messageId, count: path.count) else { continue }
                var cur = merged[floor] ?? CardMessageWrite(messageId: floor)
                if let m = w.message { cur.message = m }
                if let d = w.data { cur.data = d }
                if let s = w.swipeId { cur.swipeId = s }
                merged[floor] = cur
            }
            var edits: [CardWriteStep] = []
            var swipes: [CardWriteStep] = []
            for floor in merged.keys.sorted() {
                let w = merged[floor]!
                let target = path[floor]
                if w.message != nil || w.data != nil {
                    if let text = w.message {
                        guard let own, floor >= own else { return .failure(.earlierFloor) }
                        edits.append(.editMessage(nodeId: target.nodeId, text: text))
                    }
                    if let d = w.data { edits.append(.setMessageVariables(nodeId: target.nodeId, table: d)) }
                } else if let s = w.swipeId {
                    let index = min(max(s, 0), target.swipeCount - 1)
                    if let fork = target.forkId, index != target.swipeIndex {
                        swipes.append(.switchSwipe(forkId: fork, index: index))
                    }
                }
            }
            return .success(edits + swipes)

        case .triggerSlash:
            return .failure(.methodNotAllowed("triggerSlash"))     // 不是写计划，宿主另走 CardSlash
        }
    }
}

// MARK: - 变量

enum CardVariables {
    static func encode(_ table: [String: Any]) -> Result<Data, CardScriptRejection> {
        guard JSONSerialization.isValidJSONObject(table),
              let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]) else {
            return .failure(.badArguments("变量表不是合法 JSON"))
        }
        guard data.count <= CardScriptLimits.variableTableBytes else { return .failure(.tooLarge("变量表（上限 256KB）")) }
        return .success(data)
    }

    static func decode(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// chat 变量惰性初始化：导入对话的 `header.chat_metadata.variables`（header 存的是原行字符串）；sourceMetadata 只读不改
    static func chatInitial(conversationMetadata: Data?) -> [String: Any] {
        guard let meta = object(conversationMetadata) else { return [:] }
        var header: [String: Any]?
        if let s = meta["header"] as? String { header = object(Data(s.utf8)) } else { header = meta["header"] as? [String: Any] }
        return ((header?["chat_metadata"] as? [String: Any])?["variables"] as? [String: Any]) ?? [:]
    }

    /// message 变量惰性初始化：酒馆把整个 `variables[]`（按 swipe 分页）挂在选中候选上；拆给第 i 个兄弟，越界 / 不是对象给空
    static func messageInitial(nodeMetadata: Data?, selectedMetadata: Data?, fallbackIndex: Int) -> [String: Any] {
        let index = (object(nodeMetadata)?["candidate"] as? Int) ?? fallbackIndex
        guard let fields = object(selectedMetadata)?["fields"] as? [String: Any] else { return [:] }
        switch fields["variables"] {
        case let list as [Any]:
            return list.indices.contains(index) ? (list[index] as? [String: Any] ?? [:]) : [:]
        case let dict as [String: Any]:
            return dict[String(index)] as? [String: Any] ?? [:]
        default:
            return [:]
        }
    }

    /// 兄弟里哪个是导入时的选中候选（带整行原件和 variables 的那个）
    static func isSelectedCandidate(_ metadata: Data?) -> Bool {
        (object(metadata)?["selected"] as? Bool) == true
    }

    static func effectiveChat(stored: Data?, conversationMetadata: Data?) -> [String: Any] {
        decode(stored) ?? chatInitial(conversationMetadata: conversationMetadata)
    }

    static func effectiveMessage(stored: Data?, nodeMetadata: Data?, selectedMetadata: Data?, fallbackIndex: Int) -> [String: Any] {
        decode(stored) ?? messageInitial(nodeMetadata: nodeMetadata, selectedMetadata: selectedMetadata, fallbackIndex: fallbackIndex)
    }
}

// MARK: - 快照

/// 一楼的快照（getChatMessages 读的形状）：message_id / role / name / message / data / swipe_id / swipes / swipes_data
struct CardSnapshotFloor {
    let role: String
    let name: String
    let message: String
    let swipeId: Int
    let swipes: [String]
    let swipesData: [[String: Any]]

    func json(id: Int) -> [String: Any] {
        let data = swipesData.indices.contains(swipeId) ? swipesData[swipeId] : [:]
        return ["message_id": id, "role": role, "name": name, "is_hidden": false, "message": message,
                "data": data, "swipe_id": swipeId, "swipes": swipes, "swipes_data": swipesData]
    }
}

enum CardScriptSnapshot {
    /// 从最新一楼往前装，超 maxBytes 就停（截窗口）；本楼若被截掉也单独带上。
    /// 输出可直接嵌进 `<script>`（`<` 转义成 <）
    static func build(count: Int, floor: (Int) -> CardSnapshotFloor, currentId: Int, chat: [String: Any],
                      charName: String, userName: String, maxBytes: Int = CardScriptLimits.snapshotBytes) -> String {
        func size(_ o: Any) -> Int {
            (try? JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed]))?.count ?? 0
        }
        var budget = maxBytes - size(chat) - 512
        // 本楼先占预算：被截到窗口外也单独带上
        let own: [String: Any]? = (0..<count).contains(currentId) ? floor(currentId).json(id: currentId) : nil
        if let own { budget -= size(own) + 1 }
        var messages: [[String: Any]] = []
        var first = count
        var i = count - 1
        while i >= 0 {
            if i == currentId, let own {
                messages.append(own)
            } else {
                let m = floor(i).json(id: i)
                let s = size(m) + 1
                if s > budget { break }
                budget -= s
                messages.append(m)
            }
            first = i
            i -= 1
        }
        messages.reverse()
        if let own, currentId < first { messages.insert(own, at: 0) }
        let snapshot: [String: Any] = [
            "v": 1, "messages": messages, "firstId": first, "lastId": count - 1, "currentId": currentId,
            "truncated": first > 0, "chat": chat, "char": charName, "user": userName,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return scriptSafe(s)
    }

    /// JSON 嵌进 `<script>`：`<` 一律 <（JSON 里 `<` 只可能出现在字符串里，等价）；U+2028/2029 也转
    static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

// MARK: - 事件

/// 一楼的签名（差分用）
struct CardEventFloorSig: Equatable {
    let nodeId: String
    let role: String
    let contentHash: Int
    let forkId: String?
}

struct CardScriptEvent: Equatable {
    let name: String
    /// JSON 数组字面量，原样转给子页的 listener
    let args: String
}

/// 原生在发送 / 收到 / 编辑 / 删除 / 切分支 / 生成开始结束时推给活跃交互实例；事件名与参数形状照酒馆助手 `tavern_events`
enum CardScriptEvents {
    static let messageSent = "message_sent"
    static let messageReceived = "message_received"
    static let messageEdited = "message_edited"
    static let messageUpdated = "message_updated"
    static let messageDeleted = "message_deleted"
    static let messageSwiped = "message_swiped"
    static let generationStarted = "generation_started"
    static let generationEnded = "generation_ended"

    static func diff(old: [CardEventFloorSig], new: [CardEventFloorSig], wasGenerating: Bool, isGenerating: Bool) -> [CardScriptEvent] {
        var out: [CardScriptEvent] = []
        func emit(_ name: String, _ args: String) { out.append(CardScriptEvent(name: name, args: args)) }
        if !wasGenerating && isGenerating { emit(generationStarted, #"["normal",{},false]"#) }

        let common = zip(old, new).prefix { $0.nodeId == $1.nodeId }.count
        // 同一节点正文变了（生成中的末尾那条不算）
        for i in 0..<common where old[i].contentHash != new[i].contentHash {
            if (isGenerating || wasGenerating) && i == new.count - 1 { continue }   // 生成中的末尾那条：结束时报收到
            emit(messageEdited, "[\(i)]")
            emit(messageUpdated, "[\(i)]")
        }
        let oldIds = old.map(\.nodeId), newIds = new.map(\.nodeId)
        if common < old.count && common < new.count {
            if let fork = new[common].forkId, old[common].forkId == fork {
                emit(messageSwiped, "[\(common)]")
            } else if new.count < old.count && Set(newIds).isSubset(of: Set(oldIds)) {
                emit(messageDeleted, "[\(new.count)]")     // 中间删了一条：酒馆报删后的长度
            }
        } else if new.count > old.count {
            for k in old.count..<new.count {
                if new[k].role == "user" { emit(messageSent, "[\(k)]") }
                else if !(isGenerating && k == new.count - 1) { emit(messageReceived, #"[\#(k),"normal"]"#) }
            }
        } else if new.count < old.count {
            emit(messageDeleted, "[\(new.count)]")
        }
        if wasGenerating && !isGenerating, let last = new.indices.last, new[last].role == "assistant" {
            let receivedAlready = out.contains { $0.name == messageReceived && $0.args.hasPrefix("[\(last),") }
            if !receivedAlready { emit(messageReceived, #"[\#(last),"normal"]"#) }
            emit(generationEnded, "[\(last)]")
        }
        return out
    }
}

// MARK: - B5 替你发消息（triggerSlash）

/// 卡的「替你发消息」许可：存在卡 blob 的 `sendConsent`（缺键 = unknown）；卡的规则 / 脚本一变就打回 unknown（同 extensionConsent）
enum CardSendConsent: String, Codable, CaseIterable {
    case unknown, allowed, denied
}

/// 解析好的一条命令（参数、`{{pipe}}`、管道注入都已展开）
enum CardSlashAction: Equatable {
    case send(String)
    case trigger
    case echo(String)
    case setInput(String)
}

/// 宿主真正执行的步骤：`/send 文字` 紧跟 `/trigger` 合成一步 = 你手动发这句话（同一个发送入口）
enum CardSlashStep: Equatable {
    /// 只追加用户消息，不生成
    case append(String)
    /// 发送 + 回复（= 手动发送）
    case sendAndReply(String)
    /// 在末尾生成一次
    case reply
    case toast(String)
    case fillInput(String)
}

struct CardSlashPlan: Equatable {
    let actions: [CardSlashAction]
    /// 管道最后的值（triggerSlash / triggerSlashWithResult 的返回值）
    let result: String

    var sendTexts: [String] { actions.compactMap { if case .send(let t) = $0 { return t } else { return nil } } }
    var triggers: Bool { actions.contains(.trigger) }
    /// 含 /send 或 /trigger：要过 sendConsent 和防护
    var needsConsent: Bool { triggers || !sendTexts.isEmpty }

    /// 允许时照序执行
    var steps: [CardSlashStep] {
        var out: [CardSlashStep] = []
        var i = 0
        while i < actions.count {
            switch actions[i] {
            case .send(let text):
                if i + 1 < actions.count, actions[i + 1] == .trigger {
                    out.append(.sendAndReply(text))
                    i += 2
                    continue
                }
                out.append(.append(text))
            case .trigger: out.append(.reply)
            case .echo(let text): out.append(.toast(text))
            case .setInput(let text): out.append(.fillInput(text))
            }
            i += 1
        }
        return out
    }

    /// 不允许：要发的话原位改成填进输入框、不生成；echo / setinput 照常；末尾一条轻提示
    func degradedSteps(cardName: String) -> [CardSlashStep] {
        var out: [CardSlashStep] = actions.compactMap {
            switch $0 {
            case .send(let text): return .fillInput(text)
            case .trigger: return nil
            case .echo(let text): return .toast(text)
            case .setInput(let text): return .fillInput(text)
            }
        }
        out.append(.toast(sendTexts.isEmpty ? "「\(cardName)」不能替你让 AI 回复" : "「\(cardName)」不能替你发消息，要发的话放进了输入框"))
        return out
    }
}

/// 酒馆 slash 的白名单子集（照 SlashCommandParser / SlashCommandClosure）：`/send` `/trigger` `/echo` `/setinput`，
/// `|` 串起来按顺序执行（`||` 不把上一条的结果注进下一条），`\|` 是字面的竖线，`{{ }}` 里的竖线不算分隔；
/// 没写参数的命令吃上一条的结果；`{{pipe}}` / `{{char}}` / `{{user}}` 展开。
/// `/send` `/echo` 是酒馆的 rawQuotes 命令：默认引号原样保留（`raw=false` 才去掉），`/setinput` 去引号
enum CardSlash {
    static let commands: Set<String> = ["send", "trigger", "echo", "setinput"]
    static let maxBytes = 8 * 1024
    private static let rawQuoteCommands: Set<String> = ["send", "echo"]
    /// 改变语义、本批不做的参数
    private static let unsupportedNamed: [String: Set<String>] = ["send": ["at", "name"], "echo": ["onClick"]]

    struct Command: Equatable {
        var name: String
        var named: [String: String] = [:]
        /// nil = 没写参数（吃管道）
        var unnamed: String?
        var injectPipe = true
    }

    static func parse(_ text: String) -> Result<[Command], CardScriptRejection> {
        if text.contains("{:") { return .failure(.unsupported("slash 闭包 {: … :}")) }
        var out: [Command] = []
        for (segment, inject) in split(text) {
            let s = segment.drop { $0.isWhitespace }
            guard s.hasPrefix("/") else { continue }                                    // 不是命令的字：酒馆直接丢掉
            if s.hasPrefix("//") || s.hasPrefix("/#") || s.hasPrefix("/*") { continue }   // 注释
            let body = s.dropFirst()
            let name = String(body.prefix { !$0.isWhitespace })
            guard commands.contains(name) else { return .failure(.unsupported("/\(name)")) }
            var rest = body.dropFirst(name.count).drop { $0.isWhitespace }
            var cmd = Command(name: name)
            cmd.injectPipe = inject
            while let key = namedKey(rest) {
                rest = rest.dropFirst(key.count + 1)
                let value: Substring
                if rest.first == "\"" {
                    let open = rest.index(after: rest.startIndex)
                    guard let close = rest[open...].firstIndex(of: "\"") else { return .failure(.badArguments("/\(name) 的 \(key)= 引号没闭合")) }
                    value = rest[open..<close]
                    rest = rest[rest.index(after: close)...]
                } else if rest.first == "[" {
                    guard let close = rest.firstIndex(of: "]") else { return .failure(.badArguments("/\(name) 的 \(key)= 方括号没闭合")) }
                    value = rest[rest.startIndex...close]
                    rest = rest[rest.index(after: close)...]
                } else {
                    value = rest.prefix { !$0.isWhitespace }
                    rest = rest.dropFirst(value.count)
                }
                if unsupportedNamed[name]?.contains(key) == true { return .failure(.unsupported("/\(name) 的 \(key) 参数")) }
                cmd.named[key] = unescape(String(value))
                rest = rest.drop { $0.isWhitespace }
            }
            let raw = rawQuoteCommands.contains(name) && !["false", "off", "0", "no"].contains(cmd.named["raw"]?.lowercased() ?? "")
            if !rest.allSatisfy(\.isWhitespace) {
                if !raw, rest.first == "\"" {
                    let open = rest.index(after: rest.startIndex)
                    guard let close = rest[open...].firstIndex(of: "\"") else { return .failure(.badArguments("/\(name) 的引号没闭合")) }
                    let tail = String(rest[rest.index(after: close)...]).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                    cmd.unnamed = String(rest[open..<close]) + tail
                } else {
                    cmd.unnamed = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            out.append(cmd)
        }
        return .success(out)
    }

    /// 解析 + 照序求值成动作；`{{char}}` / `{{user}}` 用有效身份的名字
    static func plan(_ text: String, charName: String, userName: String) -> Result<CardSlashPlan, CardScriptRejection> {
        let commands: [Command]
        switch parse(text) {
        case .failure(let e): return .failure(e)
        case .success(let c): commands = c
        }
        guard !commands.isEmpty else { return .failure(.badArguments("没有可执行的命令")) }
        var pipe = ""
        var actions: [CardSlashAction] = []
        for (i, cmd) in commands.enumerated() {
            var value = ""
            if let u = cmd.unnamed {
                value = unescape(macros(u, pipe: pipe, char: charName, user: userName))   // 先展开宏再去转义（同酒馆）
            } else if i > 0 && cmd.injectPipe {
                value = pipe
            }
            switch cmd.name {
            case "send":
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return .failure(.badArguments("/send 没有要发的文字")) }
                guard !actions.contains(.trigger) else { return .failure(.refused("/trigger 之后不能再 /send")) }
                actions.append(.send(text))
                pipe = ""
            case "trigger":
                guard !actions.contains(.trigger) else { return .failure(.refused("一次只能让 AI 回复一次")) }
                actions.append(.trigger)
                pipe = ""
            case "echo":
                if !value.isEmpty { actions.append(.echo(value)) }
                pipe = value
            default:    // setinput
                actions.append(.setInput(value))
                pipe = value
            }
        }
        return .success(CardSlashPlan(actions: actions, result: pipe))
    }

    /// 按 `|` 切（`||` = 下一条不注入管道；`\|` 字面竖线；`{{ }}` 里不切）
    private static func split(_ text: String) -> [(String, Bool)] {
        let c = Array(text)
        var out: [(String, Bool)] = []
        var cur = "", depth = 0, inject = true, i = 0
        while i < c.count {
            let ch = c[i]
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            if ch == "\\", next == "|" { cur.append("|"); i += 2; continue }
            if ch == "\\", let n = next, n == "{" || n == "}" { cur.append(ch); cur.append(n); i += 2; continue }
            if ch == "{", next == "{" { depth += 1; cur += "{{"; i += 2; continue }
            if ch == "}", next == "}" { depth = max(0, depth - 1); cur += "}}"; i += 2; continue }
            if ch == "|", depth == 0 {
                out.append((cur, inject))
                cur = ""
                if next == "|" { inject = false; i += 2 } else { inject = true; i += 1 }
                continue
            }
            cur.append(ch)
            i += 1
        }
        out.append((cur, inject))
        return out
    }

    private static func namedKey(_ s: Substring) -> String? {
        let key = s.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        guard !key.isEmpty, s.dropFirst(key.count).first == "=" else { return nil }
        return String(key)
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\{", with: "{").replacingOccurrences(of: "\\}", with: "}")
    }

    private static func macros(_ s: String, pipe: String, char: String, user: String) -> String {
        var out = s
        for (name, value) in [("pipe", pipe), ("char", char), ("user", user)] {
            out = out.replacingOccurrences(of: "{{\(name)}}", with: value, options: .caseInsensitive)
        }
        return out
    }
}

/// 同一张卡 3 秒内最多一次（只算要发消息 / 生成的调用）
struct CardSlashThrottle {
    static let interval: TimeInterval = 3
    private var last: [String: TimeInterval] = [:]

    mutating func allow(_ cardId: String, now: TimeInterval) -> Bool {
        if let t = last[cardId], now - t < Self.interval { return false }
        last[cardId] = now
        return true
    }
}

/// 确认框要显示的东西（小样 ①）
struct CardSendConfirmation: Equatable {
    let cardName: String
    let texts: [String]
    let replies: Bool
}

enum CardSendChoice: Equatable {
    case allowAlways, once, deny
}

/// triggerSlash 的放行判断（原生校验链之后）：哪个实例在调 / 卡与许可 / 正在生成 / 等确认 / 3 秒 → 直接跑、先问、降级
enum CardSlashGate {
    /// 交互实例怎么来的：用户点了「运行」/ B6 自动运行
    enum Origin: Equatable { case user, auto }

    struct Card: Equatable {
        let id: String
        let name: String
        let consent: CardSendConsent
        /// 卡已启用 + 总开关开
        let allowed: Bool
    }

    struct Input {
        var plan: CardSlashPlan
        /// nil = 不是当前的交互实例
        var origin: Origin?
        /// nil = 非卡聊天
        var card: Card?
        var generating: Bool
        var awaitingConfirm: Bool
    }

    enum Decision: Equatable {
        case run([CardSlashStep])
        case ask(CardSendConfirmation)
        case degrade([CardSlashStep])
    }

    static let busy = CardScriptRejection.refused("正在生成回复，等这条写完再点")
    static let awaiting = CardScriptRejection.refused("上一条还在等你确认")
    static let tooFast = CardScriptRejection.refused("点得太快了：同一张卡 3 秒内只能发一次")
    /// 这三种被拒除了回给卡，还在聊天里轻提示一下（你点了按钮却没反应会以为坏了）
    static func notifies(_ why: CardScriptRejection) -> Bool { [busy, awaiting, tooFast].contains(why) }

    static func decide(_ input: Input, throttle: inout CardSlashThrottle, now: TimeInterval) -> Result<Decision, CardScriptRejection> {
        guard let origin = input.origin else { return .failure(.refused("只有正在运行的网页能用 triggerSlash")) }
        guard let card = input.card else { return .failure(.refused("只有卡聊天里的网页能用 triggerSlash")) }
        guard origin == .user || card.allowed else { return .failure(.refused("「\(card.name)」还没启用")) }
        let plan = input.plan
        guard plan.needsConsent else { return .success(.run(plan.steps)) }
        if input.generating { return .failure(busy) }
        if input.awaitingConfirm { return .failure(awaiting) }
        guard throttle.allow(card.id, now: now) else { return .failure(tooFast) }
        switch card.consent {
        case .allowed: return .success(.run(plan.steps))
        case .denied: return .success(.degrade(plan.degradedSteps(cardName: card.name)))
        case .unknown: return .success(.ask(CardSendConfirmation(cardName: card.name, texts: plan.sendTexts, replies: plan.triggers)))
        }
    }
}

// MARK: - B6 自动运行最新一条

/// 已许可的卡 + 总开关开：对话里最新一条助手消息的第一个网页段自动进交互。
/// 「新消息」= 最新一条助手消息换了（新回复 / 切分支 / 切对话）；生成中先不动；手动运行的别的段留到下一条新消息
enum CardAutoRun {
    struct Message: Equatable {
        let nodeId: String
        let isAssistant: Bool
        /// 第一个网页段；nil = 这条没有网页
        let firstHTMLSegment: String?
        let streaming: Bool
    }

    struct State: Equatable {
        var seen = false
        var latestNodeId: String?
    }

    enum Action: Equatable {
        case none
        case run(nodeId: String, segmentId: String)
        case stop
    }

    static func decide(_ messages: [Message], state: inout State, enabled: Bool, interactiveSegmentKey: String?) -> Action {
        guard enabled else { state = State(); return .none }
        let last = messages.last { $0.isAssistant }
        if last?.streaming == true { return .none }
        let id = last?.nodeId
        if state.seen && state.latestNodeId == id { return .none }
        let first = !state.seen
        state = State(seen: true, latestNodeId: id)
        if let last, let seg = last.firstHTMLSegment {
            return interactiveSegmentKey == "\(last.nodeId)|\(seg)" ? .none : .run(nodeId: last.nodeId, segmentId: seg)
        }
        return !first && interactiveSegmentKey != nil ? .stop : .none
    }
}

// MARK: - 「edited」标记（小样 ②）

/// 被卡里的网页改过正文（MessageNode.cardEditedAt）的消息：分支行后 11 号浅灰「edited」+ 小笔，点开浮层（Page2 / 原生同一份文案）
enum CardEditedText {
    static let label = "edited"
    static let note = "网页只能改这一条和之后的消息。"

    static func title(cardName: String?, at date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let who = cardName.map { "「\($0)」的网页" } ?? "卡里的网页"
        return "这条消息被\(who)在 \(f.string(from: date)) 改过。"
    }
}
