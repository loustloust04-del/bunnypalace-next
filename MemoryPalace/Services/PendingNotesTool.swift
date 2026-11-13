import MemoryCore
import Foundation

/// {助手}的待续本子：add 记一条 / list 看没做完的 / done 做完了 / faded 淡了。
/// 门 = 总开关 && A4 时间轴开着；执行前复查本窗口的记忆参与。
enum PendingNotesTool {
    static let toolName = "pending_notes"
    /// plan-aline-rewrite A-6：一条待续最多200字。
    static let textCharLimit = 200

    static var enabled: Bool { TimelineConsolidator.enabled }

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "看、标时间轴上的待续（做到一半的事、答应了的事）。add 记一条待续；list 列出还没做完的；做完了用 done，过去了、不用再惦记的用 faded，都要给 id。",
            properties: [
                "action": ["type": "string", "enum": ["add", "list", "done", "faded"],
                           "description": "add = 记一条待续；list = 看没做完的；done = 标做完了；faded = 标淡了"] as [String: Any],
                "id": ["type": "string", "description": "待续的编号（list 里看到的，如 p0003）；done / faded 必填"] as [String: Any],
                "text": ["type": "string", "maxLength": textCharLimit, "description": "add 必填，待续内容，最多\(textCharLimit)字"] as [String: Any],
            ],
            required: ["action"])
    }

    struct Result: Equatable {
        let text: String
        let isError: Bool
    }

    /// 在后台调（读写 memory/pending/）
    static func execute(inputJSON: String, profileId: String, conversationId: String?, memoryEnabled: Bool = true) -> Result {
        guard memoryEnabled else { return Result(text: "这场对话关了记忆参与，不能改待续", isError: true) }
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        // 老待续迁不好 / 本子有认不出的行：照实说，不列也不改（列出来的会缺行，改了会把认不出的那行写丢）
        do { try TimelineDaily.preparePendingForEdit(profileId: profileId) } catch {
            return Result(text: TimelineDaily.pendingProblem(error), isError: true)
        }
        let items = PendingStore.load(profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId)) ?? []
        switch args["action"] as? String {
        case "add":
            guard let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return Result(text: "add 要给非空的 text", isError: true)
            }
            guard text.count <= textCharLimit else { return Result(text: "待续最多\(textCharLimit)字", isError: true) }
            guard text.rangeOfCharacter(from: .newlines) == nil, !text.contains("<"), !text.contains(">") else {
                return Result(text: "待续只能写一行，不能含 < 或 >", isError: true)
            }
            guard let source = conversationId, !source.isEmpty else {
                return Result(text: "add 要有当前窗口", isError: true)
            }
            do {
                let added = try PendingStore.add([text], conversationId: source, day: MemoryDay.key(Date()), anchor: nil, profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
                return Result(text: added.first.map { "记好了：\(line($0))" } ?? "没有新增待续（已存在或没有有效内容）", isError: false)
            } catch {
                return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
            }
        case "list":
            let open = items.filter { $0.state == .open }
            guard !open.isEmpty else { return Result(text: "现在没有没做完的待续", isError: false) }
            let here = open.filter { $0.conversationId == conversationId }
            let others = open.filter { $0.conversationId != conversationId }
            var lines: [String] = []
            if !here.isEmpty { lines += ["这个窗口："] + here.map(line) }
            if !others.isEmpty { lines += ["别的窗口："] + others.map(line) }
            return Result(text: lines.joined(separator: "\n"), isError: false)
        case "done", "faded":
            let state: PendingState = args["action"] as? String == "done" ? .done : .faded
            guard let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                return Result(text: "done / faded 要给 id（先 list 看编号）", isError: true)
            }
            guard let item = items.first(where: { $0.id == id }) else {
                return Result(text: "没找到待续 \(id)，先 list 看编号", isError: true)
            }
            do {
                try PendingStore.setState(id, state, profileId: profileId, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
                return Result(text: "标好了：「\(item.text)」→ \(state.label)", isError: false)
            } catch {
                return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
            }
        default:
            return Result(text: "action 只能是 add / list / done / faded", isError: true)
        }
    }

    private static func line(_ i: PendingItem) -> String {
        "- \(i.id) · \(i.text)（\(i.day) · conv \(i.conversationId.prefix(8))）"
    }
}
