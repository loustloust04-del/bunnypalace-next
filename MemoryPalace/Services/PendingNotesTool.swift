import Foundation

/// {助手}自己标待续的工具（v5 §3-2，学惦记小本本）：list 看没做完的 / done 做完了 / faded 淡了。
/// 门 = 总开关 && A4 时间轴开着；这场对话关了「记忆参与」由分发处拒绝
enum PendingNotesTool {
    static let toolName = "pending_notes"

    static var enabled: Bool { TimelineConsolidator.enabled }

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "看、标时间轴上的待续（做到一半的事、答应了的事）。list 列出还没做完的；做完了用 done，过去了、不用再惦记的用 faded，都要给 id。",
            properties: [
                "action": ["type": "string", "enum": ["list", "done", "faded"],
                           "description": "list = 看没做完的；done = 标做完了；faded = 标淡了"] as [String: Any],
                "id": ["type": "string", "description": "待续的编号（list 里看到的，如 p0003）；done / faded 必填"] as [String: Any],
            ],
            required: ["action"])
    }

    struct Result: Equatable {
        let text: String
        let isError: Bool
    }

    /// 在后台调（读写 memory/pending/）
    static func execute(inputJSON: String, profileId: String, conversationId: String?) -> Result {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        // 老待续迁不好 / 本子有认不出的行：照实说，不列也不改（列出来的会缺行，改了会把认不出的那行写丢）
        do { try TimelineDaily.preparePendingForEdit(profileId: profileId) } catch {
            return Result(text: TimelineDaily.pendingProblem(error), isError: true)
        }
        let items = PendingStore.load(profileId: profileId) ?? []
        switch args["action"] as? String {
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
                try PendingStore.setState(id, state, profileId: profileId)
                return Result(text: "标好了：「\(item.text)」→ \(state.label)", isError: false)
            } catch {
                return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
            }
        default:
            return Result(text: "action 只能是 list / done / faded", isError: true)
        }
    }

    private static func line(_ i: PendingItem) -> String {
        "- \(i.id) · \(i.text)（\(i.day) · conv \(i.conversationId.prefix(8))）"
    }
}
