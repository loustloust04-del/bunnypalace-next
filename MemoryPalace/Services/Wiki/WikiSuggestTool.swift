import MemoryCore
import Foundation

/// {助手}主动给记忆 wiki 提整理方向（C2/C3 v2 第 4 段）：只交一条待批方向（动哪页、为什么），
/// 批了才去查原料、写，写好的正文再批一次。不写页、不碰碎片，不放宽 fs 对 memory/ 的只读
enum WikiSuggestTool {
    static let toolName = "suggest_wiki_direction"

    static var enabled: Bool { MemoryWriterSettings.writes(.c3) }

    /// 注册表里的那份（本人那组是宏，名字未知）；真下发 / inspect 走 `definition(userName:)`
    static var definition: ToolDefinition { definition(userName: "") }

    /// 下发给模型的定义：路径说明里本人那组写成当前名字（直接下发和「更多工具」的 inspect 共用，经 ToolRegistry）
    static func definition(userName: String) -> ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "给记忆 wiki 提一个整理方向：动哪一页（已有页或新开一页）、为什么。只是提议，用户在审计台批了才会去查原料、写页，写好的正文还要用户再批一次才进 wiki。",
            properties: [
                "path": ["type": "string", "description": WikiStore.shown("目标页路径，第一段是 \(WikiStore.branchesText) 之一，最后一段是页名，比如 地点/云桥城", user: userName)] as [String: Any],
                "title": ["type": "string", "description": "页标题（不写 = 路径最后一段）"] as [String: Any],
                "reason": ["type": "string", "description": "为什么要动这页：聊到了什么新事实、什么变了"] as [String: Any],
            ],
            required: ["path", "reason"])
    }

    struct Result: Equatable {
        let text: String
        let isError: Bool
    }

    private struct Args: Decodable {
        let path: String?
        let title: String?
        let reason: String?
    }

    /// 在后台调（读写 wiki/.proposals/）
    /// userName = 楼层用户名：路径第一段写名字的落成 {{user}}，回给模型的话里再显示成名字
    static func execute(inputJSON: String, wiki: WikiStore, profileId: String, userName: String = "", now: Date = Date()) -> Result {
        let r = run(inputJSON: inputJSON, wiki: wiki, profileId: profileId, userName: userName, now: now)
        return Result(text: WikiStore.shown(r.text, user: userName), isError: r.isError)
    }

    private static func run(inputJSON: String, wiki: WikiStore, profileId: String, userName: String, now: Date) -> Result {
        guard let args = CatalogJSON.decode(Args.self, inputJSON.isEmpty ? "{}" : inputJSON) else {
            return Result(text: "参数不是合格的 JSON", isError: true)
        }
        let path = WikiStore.stored(CatalogPrompts.normalizedPath(args.path ?? ""), user: userName)
        guard WikiStore.isValidPagePath(path) else {
            return Result(text: "path 第一段要是 \(WikiStore.branchesText) 之一，最后一段是页名，比如 地点/云桥城", isError: true)
        }
        let reason = (args.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return Result(text: "要写 reason：为什么动这页", isError: true) }
        let store = WikiProposalStore(wiki: wiki)
        if CatalogSorter.priorDirections(store).pending.contains(CatalogSorter.target(path, group: false)) {
            return Result(text: "「\(path)」已经有一个待批的整理方向，等用户批了再说", isError: false)
        }
        let page = wiki.read(path)
        let given = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = page?.title ?? (given.isEmpty ? String(path.split(separator: "/").last ?? "") : given)
        let direction = WikiProposal.Direction(path: path, title: title, hook: page?.hook ?? "", kind: page?.kind, aliases: page?.triggers ?? [],
                                               action: page == nil ? .newPage : .update, reason: reason, mode: .agent)
        let proposal = WikiProposal(origin: .assistant, createdAt: now, title: title, items: [WikiProposal.Item(change: .direction(direction))])
        do {
            try store.save(proposal)
        } catch {
            return Result(text: "没存成：\(error.localizedDescription)", isError: true)
        }
        MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: true, note: "助手提了整理方向「\(title)」（\(path)），等批", model: "", now: now, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        return Result(text: "已经交给用户：\(page == nil ? "新开" : "更新")「\(title)」。在审计台 › wiki › 整理提案里，用户批了才会去查、写，写好的正文还要再批。", isError: false)
    }
}
