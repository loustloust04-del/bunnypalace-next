import MemoryCore
import Foundation
import SwiftData

/// CC 里的助手用花园的记忆（粟粟 11-14「把每个记忆都暴露接口…无论是对 api 还是对 cc」）。
///
/// 路子同 `TwitterCCBridge`：CC 调 MCP 工具 → mcp-server POST hub `/memory/cmd` → hub 发 `memory_cmd` 帧给 app
/// → 这里在那场对话所在的楼层跑**聊天里同一个工具**（同名、同参数、同一个执行入口），过**同一个闸**
/// （`ToolRegistry.availability` 看开关 / 抽屉，`PermissionGate.toolGate` 看三档权限，每次询问 = 聊天页那张审批卡）→ 回 `memory_result`。
///
/// 楼层：`chat_id` 必填，写进那场对话所在的楼层；不猜「当前楼层」。
/// 留痕：动记忆条目的每一笔进 `MemoryAuditLog`，操作人 = 「CC 里的{助手名}」、来处 = `viaCC`，她在记忆日志里能 Undo。
enum MemoryCCBridge {
    static let commandType = "memory_cmd"
    static let resultType = "memory_result"
    /// 探问帧（hub 问「这场对话是不是你的」）和回包里「是不是我的」那一项
    static let probeKey = "probe"
    static let mineKey = "mine"

    /// CC 用得到的工具。改这张表记得重新生成 `cc-bridge/memory-tools.json`（`bun run memory-tools.ts`），那边有测试对着金样查
    static let toolNames: [String] = [
        RecallTool.toolName, MemoryCardTool.toolName,
        SelfMemoryTool.rememberName, SelfMemoryTool.editName, SelfMemoryTool.forgetName,
        PendingNotesTool.toolName,
        FileLibraryTools.Name.list.rawValue, FileLibraryTools.Name.read.rawValue, FileLibraryTools.Name.search.rawValue,
        FileLibraryTools.Name.write.rawValue, FileLibraryTools.Name.append.rawValue, FileLibraryTools.Name.edit.rawValue,
        FileLibraryTools.Name.rename.rawValue, FileLibraryTools.Name.delete.rawValue,
    ]

    /// 文件工具在 CC 这头看得到、写得到的两处：记忆（memory/）和这一层的 Prompt 文件夹；文件库别的内容不在这单的范围里
    static let fileRoots = [FileLibraryStore.memoryVirtualPrefix, PromptFolder.root + "/"]

    /// hub 等回包的时限里留给传输的余量（秒）：问她的那张卡先于 hub 超时收口，CC 不会拿到「超时」之后这边又写进去
    static let transportMargin: TimeInterval = 10
    /// 帧里没带时限时按 hub 的默认算
    static let defaultTimeout: TimeInterval = 30

    static func actorName(_ assistantName: String) -> String {
        "CC 里的\(MemoryCardTool.actorName(assistantName))"
    }

    #if os(macOS)
    private static let deviceLabel = "电脑"
    #else
    private static let deviceLabel = "手机"
    #endif

    @MainActor
    static func handle(_ frame: [String: Any], profiles: [Profile], context: ModelContext,
                       ask: @escaping PermissionGate.Ask = { await PermissionPromptCenter.shared.decide($0, detail: $1, approval: $2) }) async -> [String: Any] {
        let id = frame["id"] as? String ?? ""
        func reply(_ ok: Bool, _ text: String) -> [String: Any] {
            ["type": resultType, "id": id, "ok": ok, "result": text]
        }
        // hub 先问一圈「这场对话是不是你的」（两台设备都连着时只把命令发给有这场对话的那台，`cc-bridge/memory-route.ts`）：
        // 立刻答，什么都不执行
        if frame[probeKey] as? Bool == true {
            let chatId = frame["chat_id"] as? String ?? ""
            let mine = !chatId.isEmpty && ((try? context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == chatId }))) ?? 0) > 0
            return ["type": resultType, "id": id, "ok": true, mineKey: mine, "result": mine ? "mine" : "not mine"]
        }
        guard let tool = frame["tool"] as? String, toolNames.contains(tool) else {
            return reply(false, "tool 只能是 \(toolNames.joined(separator: " / "))")
        }
        guard let chatId = frame["chat_id"] as? String, !chatId.isEmpty else {
            return reply(false, "要给 chat_id（<channel> 里那个）：记忆按那场对话所在的楼层读写")
        }
        let desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == chatId })
        guard let conversation = (try? context.fetch(desc))?.first else {
            // 立刻回错（不让对方等到超时），并标明「不是我的」：hub 下次会重新问一圈这场对话在哪台
            var notMine = reply(false, "\(deviceLabel)上的花园里找不到 chat_id 对应的对话，没法确定是哪一层的记忆。这次没做成")
            notMine[mineKey] = false
            return notMine
        }
        let profileId = conversation.profileId
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            return reply(false, "找不到楼层 \(profileId)")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: frame["input"] as? [String: Any] ?? [:]),
              var args = String(data: data, encoding: .utf8) else {
            return reply(false, "参数不是 JSON object")
        }

        // 和聊天里的工具循环同一串：参数预检 → 开关 / 抽屉复查 → 权限闸 → 去掉没声明的键 → 执行
        if tool != RecallTool.toolName,
           let bad = ToolCallPreflight.check(name: tool, argumentsJSON: args, required: ToolCallPreflight.requiredFields(for: tool, mcpServerIds: [])) {
            return reply(false, bad.message)
        }
        if let outside = outsideMemory(tool: tool, argumentsJSON: args) { return reply(false, outside) }
        let participation = EffectiveMemoryParticipation.resolve(profileId: profileId, conversation: conversation, preset: nil)
        let gateContext = ToolGateContext(family: .anthropic, deferMCP: false, profileId: profileId, drawer: ToolDrawerStore.shared.state,
                                          userName: profile.userName, memoryWriteTools: participation.writeTools)
        func unavailable() -> String? {
            guard ToolRegistry.availability(of: tool, gateContext) == false else { return nil }
            if !conversation.memoryEnabled, ToolRegistry.memoryWriteNames.contains(tool) {
                return "\(tool)：这场对话关了记忆参与，这次做不了。如实告诉对方，不要再试。"
            }
            return "\(tool) 在花园里现在没开（记忆的开关或工具抽屉里关着），这次做不了。如实告诉对方，不要再试。"
        }
        // 这一档是「不允许」：聊天里是不下发这个工具，CC 那头工具一直在清单上，要把原因说给它（闸的原话，不问她）
        if PermissionCenter.level(PermissionDomain.forCall(named: tool, argumentsJSON: args), profileId: profileId) == .notAllowed,
           case .deny(let denial) = await PermissionGate.toolGate(toolName: tool, argumentsJSON: args, conversation: conversation, context: context, ask: ask) {
            return reply(false, denial)
        }
        if let msg = unavailable() { return reply(false, msg) }

        let budget = (frame["timeout_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? defaultTimeout
        let gate = await withDeadline(max(budget - transportMargin, 1)) { [args] in
            await PermissionGate.toolGate(toolName: tool, argumentsJSON: args, conversation: conversation, context: context, ask: ask)
        }
        switch gate {
        case .deny(let denial): return reply(false, denial)
        case .proceed(let allowed): args = allowed
        }
        if let msg = unavailable() { return reply(false, msg) }   // 等她点的时候开关可能变了
        if tool != RecallTool.toolName {
            args = ToolCallPreflight.droppingUndeclared(args, schema: ToolCallPreflight.schema(for: tool, mcpServerIds: []))
        }

        let r = await execute(tool: tool, argumentsJSON: args, conversation: conversation, profile: profile,
                              participates: participation.participates, context: context)
        let wrote = ToolRegistry.memoryWriteNames.contains(tool) || FileLibraryTools.Name(rawValue: tool).map(FileLibraryTools.writeNames.contains) == true
        guard !r.isError, wrote else { return reply(!r.isError, r.text) }
        return reply(true, r.text + "\n（在\(deviceLabel)上的花园 ·「\(profile.name)」这一层）")
    }

    /// 文件工具在 CC 这头只碰 `fileRoots`：给了路径的（读一份 / 写 / 改 / 挪 / 删）每一个路径都要在这两处里
    private static func outsideMemory(tool: String, argumentsJSON: String) -> String? {
        guard FileLibraryTools.Name(rawValue: tool) != nil else { return nil }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let paths = ["path", "old_path", "new_path"].compactMap { (args[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return paths.allSatisfy { path in fileRoots.contains(where: path.hasPrefix) } ? nil
            : "CC 这边的文件工具只碰花园的记忆（memory/ 开头）和这一层的 Prompt（\(PromptFolder.root)/ 开头），路径要以这两个之一开头"
    }

    @MainActor
    private static func execute(tool: String, argumentsJSON args: String, conversation: Conversation, profile: Profile,
                                participates: Bool, context: ModelContext) async -> (text: String, isError: Bool) {
        let profileId = profile.id, conversationId = conversation.id, memoryEnabled = conversation.memoryEnabled
        switch tool {
        case RecallTool.toolName:
            let r = await RecallTool.execute(
                inputJSON: args, profileId: profileId, currentConversationId: conversationId,
                userName: profile.userName.isEmpty ? "用户" : profile.userName,
                assistantName: profile.assistantName.isEmpty ? "AI" : profile.assistantName,
                source: SwiftDataConversationSource(container: context.container),
                memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId),
                memoryParticipation: participates,
                environment: RecallTool.l1Environment(container: context.container))
            if !r.hitMemoryIds.isEmpty { try? SwiftDataMemoryStore().recordAccess(ids: r.hitMemoryIds, context: context) }
            return (r.text, r.isError)
        case MemoryCardTool.toolName:
            let r = MemoryCardTool.execute(inputJSON: args, profileId: profileId, conversationId: conversationId, memoryEnabled: memoryEnabled,
                                           actor: actorName(profile.assistantName), via: MemoryAuditLog.viaCC, context: context)
            return (r.text, r.isError)
        case PendingNotesTool.toolName:
            let r = await Task.detached {
                PendingNotesTool.execute(inputJSON: args, profileId: profileId, conversationId: conversationId, memoryEnabled: memoryEnabled)
            }.value
            return (r.text, r.isError)
        case _ where SelfMemoryTool.names.contains(tool):
            let r = memoryEnabled
                ? SelfMemoryTool.execute(name: tool, inputJSON: args, profileId: profileId, conversationId: conversationId)
                : SelfMemoryTool.Result(text: "这场对话关了记忆参与，不能写记忆", isError: true)
            return (r.text, r.isError)
        default:
            // 同聊天里的文件工具一个入口：写 memory/ = 写那种记忆、写 Prompt 文件夹 = 改那一段；留痕里记「CC 里的{助手名}」、来处 CC
            let r = await FileLibraryTools.run(name: tool, inputJSON: args, profileId: profileId, userName: profile.userName,
                                               actor: actorName(profile.assistantName), conversation: conversation, via: MemoryAuditLog.viaCC, context: context)
            guard !r.isError, [FileLibraryTools.Name.list.rawValue, FileLibraryTools.Name.search.rawValue].contains(tool) else { return (r.text, r.isError) }
            // fs_list / fs_search 的回执一行一个文件、以路径开头：只留记忆和 Prompt 文件夹的
            let lines = r.text.split(separator: "\n", omittingEmptySubsequences: true).filter { line in fileRoots.contains(where: line.hasPrefix) }
            let empty = tool == FileLibraryTools.Name.list.rawValue ? "（memory/ 和 \(PromptFolder.root)/ 下还没有文件）" : "无命中"
            return (lines.isEmpty ? empty : lines.joined(separator: "\n"), false)
        }
    }

    /// 到点还没出结果就取消（挂着的审批卡按超时收口、不写）
    @MainActor
    private static func withDeadline(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async -> ToolGate) async -> ToolGate {
        let work = Task { @MainActor in await operation() }
        let timer = Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))) != nil else { return }
            work.cancel()
        }
        defer { timer.cancel() }
        return await work.value
    }
}
