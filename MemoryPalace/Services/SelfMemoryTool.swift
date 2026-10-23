import Foundation

/// AI 写自己记忆的三个工具（记忆修复第二刀 B2）：remember / edit_memory / forget_memory。
/// 读、搜继续用 fs_read / fs_search（memory/ 本来就可读）。受记忆总开关管；对话关了「记忆参与」由分发处拒绝。
enum SelfMemoryTool {
    static let rememberName = "remember"
    static let editName = "edit_memory"
    static let forgetName = "forget_memory"
    static let names: Set<String> = [rememberName, editName, forgetName]

    static var enabled: Bool { MemoryFlags.masterEnabled }

    private static let typeProp: [String: Any] = [
        "type": "string", "enum": SelfMemoryStore.types,
        "description": "user=关于对方 / feedback=对方对我怎么做的要求 / project=我们在做的事 / reference=资料指路",
    ]
    private static let importanceProp: [String: Any] = ["type": "integer", "description": "1–5，5 = 永远要记得（每轮都带着全文）"]

    private static let rememberProps: [String: Any] = [
        "name": ["type": "string", "description": "短标题（也是文件名），如「剧场要日常化」"] as [String: Any],
        "description": ["type": "string", "description": "一行摘要，目录里显示这一行"] as [String: Any],
        "type": typeProp,
        "importance": importanceProp,
        "body": ["type": "string", "description": "正文：第一人称，带原话，写清为什么记"] as [String: Any],
        "asked_by_user": ["type": "boolean", "description": "true = 对方明确让我记的（不计每日上限）"] as [String: Any],
    ]

    private static let editProps: [String: Any] = [
        "target": ["type": "string", "description": "要改哪条：标题或文件名"] as [String: Any],
        "description": ["type": "string", "description": "新的一行摘要"] as [String: Any],
        "type": typeProp,
        "importance": importanceProp,
        "body": ["type": "string", "description": "新的正文（整段替换）"] as [String: Any],
    ]

    private static let forgetProps: [String: Any] = [
        "target": ["type": "string", "description": "要忘掉哪条：标题或文件名"] as [String: Any],
        "reason": ["type": "string", "description": "一句话：为什么忘掉"] as [String: Any],
    ]

    private static let rememberDescription = "记住一件事，存进我自己的记忆（memory/self/）。对方说「记住…」「别忘了…」时必须调这个工具（asked_by_user=true）；需要的话可以同时调日历、提醒等别的工具，但它们不能代替 remember。另外值得记的：对方告诉我新的、重要的事实或偏好；我们之间发生了值得记的事。闲聊、一次性的问题不记，不要什么都记。正文用第一人称，带上对方的原话（用「」括起来），写清为什么记。我自己主动记每天有上限，对方让我记的不算。"

    /// 发了 remember 就进工具提示的记忆分工段（#069：分工只在这里说一次）；按这一轮下发了哪些工具生成，只随设置变、前缀稳定
    static func systemHint(available: Set<String>) -> String {
        var lines = [
            "〔我的记忆〕",
            "- 对方说「记住…」「别忘了…」：必须用 remember 记进 memory/self/。要记的是个日子也照样 remember；另外出纪念日块、建日程都可以，但那只是额外的，日程不算记住。要记住的事不要写成文件。",
            "- 改或忘掉你记过的：edit_memory / forget_memory。",
        ]
        if available.contains(RecallTool.toolName) {
            lines.append("- 想起我们说过的话、后台从聊天里整理的关于对方的档案：recall。")
        }
        if available.contains(FileLibraryTools.Name.read.rawValue) {
            lines.append("- 翻你自己记的记忆文件：fs_read / fs_search（memory/self/）；memory/cc/ 是 CC 那边的你记的笔记，只读。")
        }
        return lines.joined(separator: "\n")
    }

    static var definitions: [ToolDefinition] {
        let remember = ToolDefinition(name: rememberName, description: rememberDescription,
                                      properties: rememberProps, required: ["name", "description", "body"])
        let edit = ToolDefinition(name: editName,
                                  description: "改我自己记过的某条记忆（memory/self/ 里的）。给 target（标题或文件名），只传要改的字段。",
                                  properties: editProps, required: ["target"])
        let forget = ToolDefinition(name: forgetName,
                                    description: "把我记过的某条标成失效（不删文件，对方能复活）。记错了、过时了才用。",
                                    properties: forgetProps, required: ["target"])
        return [remember, edit, forget]
    }

    struct Result: Equatable {
        let text: String
        let isError: Bool
    }

    static func execute(name: String, inputJSON: String, profileId: String, conversationId: String?, now: Date = Date()) -> Result {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        func str(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let list = SelfMemoryStore.list(profileId: profileId)
        let bodyLimit = MemoryFlags.selfBodyLimit

        switch name {
        case rememberName:
            guard let title = str("name"), let desc = str("description"), let body = str("body") else {
                return Result(text: "remember 需要 name、description、body", isError: true)
            }
            guard body.count <= bodyLimit else {
                return Result(text: "正文 \(body.count) 字，超过上限 \(bodyLimit) 字，精简一下再记", isError: true)
            }
            let asked = args["asked_by_user"] as? Bool ?? false
            if !asked {
                let limit = MemoryFlags.selfDailyLimit
                guard SelfMemoryStore.todaySelfCount(list, now: now) < limit else {
                    return Result(text: "今天我自己已经记了 \(limit) 条，留到明天；对方让我记的不受这个限制", isError: true)
                }
            }
            let m = SelfMemory(
                slug: SelfMemoryStore.uniqueSlug(for: title, existing: list),
                name: title, description: desc,
                type: str("type").flatMap { SelfMemoryStore.types.contains($0) ? $0 : nil } ?? "user",
                importance: SelfMemoryStore.clampImportance(args["importance"] as? Int ?? 3),
                origin: asked ? "asked" : "self",
                created: now, source: conversationId, superseded: nil, body: body
            )
            do {
                try SelfMemoryStore.save(m, profileId: profileId)
                return Result(text: "记住了：\(desc)（memory/self/\(m.fileName)，\(m.importance) 级）", isError: false)
            } catch {
                return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
            }

        case editName:
            guard let target = str("target"), var m = SelfMemoryStore.find(target, in: list) else {
                return Result(text: "没找到这条记忆：\(str("target") ?? "")。先用 fs_read 看 memory/self/INDEX.md", isError: true)
            }
            if let d = str("description") { m.description = d }
            if let t = str("type"), SelfMemoryStore.types.contains(t) { m.type = t }
            if let i = args["importance"] as? Int { m.importance = SelfMemoryStore.clampImportance(i) }
            if let b = str("body") {
                guard b.count <= bodyLimit else {
                    return Result(text: "正文 \(b.count) 字，超过上限 \(bodyLimit) 字", isError: true)
                }
                m.body = b
            }
            do {
                try SelfMemoryStore.save(m, profileId: profileId)
                return Result(text: "改好了：\(m.description)", isError: false)
            } catch {
                return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
            }

        case forgetName:
            guard let target = str("target"), var m = SelfMemoryStore.find(target, in: list) else {
                return Result(text: "没找到这条记忆：\(str("target") ?? "")", isError: true)
            }
            guard m.isActive else { return Result(text: "这条已经失效了", isError: false) }
            m.superseded = now
            do {
                try SelfMemoryStore.save(m, profileId: profileId)
                return Result(text: "忘掉了：\(m.description)（对方能在「记忆」页里复活）", isError: false)
            } catch {
                return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
            }

        default:
            return Result(text: "未知工具 \(name)", isError: true)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
