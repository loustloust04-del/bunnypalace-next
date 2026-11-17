import Foundation
import SwiftData

/// 工具调用过闸的结果（审批卡，粟粟 10-03）：放行用哪份参数，或者回给模型的拒绝说明
enum ToolGate: Equatable {
    case proceed(String)
    case deny(String)
}

enum PermissionGate {
    /// 一个决定 → 放行 / 拒绝，以及要不要写进对话授权（true 允许 / false 拒绝 / nil 不写）。
    /// 老弹窗的允许 / 拒绝照旧记下；卡上的「允许这一次 / 拒绝 / 改了再允许」只管这一次
    static func outcome(_ decision: PermissionPromptCenter.Decision, domain: PermissionDomain,
                        originalArgs: String) -> (gate: ToolGate, record: Bool?) {
        switch decision {
        case .allowed:
            return (.proceed(originalArgs), true)
        case .allowedOnce:
            return (.proceed(originalArgs), nil)
        case .modified(let json):
            guard (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] != nil else {
                return (.deny("permission_denied：改过的参数不是合法 JSON，本次未执行。"), nil)
            }
            return (.proceed(json), nil)
        case .denied:
            return (.deny("permission_denied：用户本次未允许「\(domain.displayName)」。\(PermissionCenter.adjustHint)"), false)
        case .deniedOnce:
            return (.deny("permission_denied：用户拒绝了这次「\(domain.displayName)」调用，本次未执行。"), nil)
        case .timedOut:
            return (.deny("permission_denied：等待用户确认「\(domain.displayName)」超时，本次未执行。可以稍后再试。"), nil)
        }
    }
}

extension PermissionGate {
    /// 问她一次（默认 = 聊天页那张审批卡 / 弹窗）；测试换成直接给答案的
    typealias Ask = @MainActor (PermissionDomain, _ detail: String?, PermissionPromptCenter.Approval) async -> PermissionPromptCenter.Decision

    /// 工具调用过闸（聊天里的工具循环、CC 那头动记忆 `MemoryCCBridge` 都走这一个）：
    /// 自动允许 = 放行；不允许 = 拒；每次询问 = 这个对话没答过就出卡问（正看着这个对话出在对话底部，否则弹窗）
    @MainActor
    static func toolGate(toolName: String, argumentsJSON: String = "", conversation: Conversation, context: ModelContext,
                         ask: Ask = { await PermissionPromptCenter.shared.decide($0, detail: $1, approval: $2) }) async -> ToolGate {
        if toolName == AskUserTool.toolName || toolName == TurnStatusTool.toolName { return .proceed(argumentsJSON) }
        let domain = PermissionDomain.forCall(named: toolName, argumentsJSON: argumentsJSON)
        switch PermissionCenter.level(domain, profileId: conversation.profileId) {
        case .bypass:
            return .proceed(argumentsJSON)
        case .notAllowed:
            if let app = PermissionCenter.blockingApp(domain, profileId: conversation.profileId) {
                return .deny(PermissionCenter.notInstalledDenial(app))   // atrium P3⑥a：没装 App 挡住的，说清是哪个 App
            }
            return .deny("permission_denied：用户未允许「\(domain.displayName)」。\(PermissionCenter.adjustHint)")
        case .askOnce:
            var grants = PermissionGrants(raw: conversation.permGrantsRaw)
            let everyCall = domain.asksEveryCall   // 记忆条目：一笔一问，不读写对话授权（粟粟 11-14）
            if everyCall || !grants.isResolved(domain) {
                // 卡上多出的一行（命令预览 / 这次要查什么 / 要动的那张记忆条目）：`PermissionGate.detail`
                let detail = PermissionGate.detail(domain: domain, toolName: toolName, argumentsJSON: argumentsJSON, profileId: conversation.profileId, context: context)
                let approval = PermissionPromptCenter.Approval(conversationId: conversation.id, toolName: toolName, argumentsJSON: argumentsJSON, conversationGrant: !everyCall)
                // 正看着这个对话：审批卡出在对话底部（完整命令 / 参数，可改命令，不超时）；否则照旧弹窗
                let decision: PermissionPromptCenter.Decision
                #if os(iOS)
                if domain == .browserOperate, BrowserOperator.shared.hasOpenBrowser {
                    // 花园浏览器正盖着聊天：卡出在浏览器里（plan-ai-browser-operate 收尾）
                    switch await BrowserOperator.shared.askPermission() {
                    case .once: decision = .allowedOnce
                    case .conversation: decision = .allowed
                    case .deny: decision = .deniedOnce
                    }
                } else {
                    decision = await ask(domain, detail, approval)
                }
                #else
                decision = await ask(domain, detail, approval)
                #endif
                // 超时（卡没弹出来 / 走开）、卡上「允许这一次 / 拒绝 / 改了再允许」都不写对话授权，下次再问
                let outcome = PermissionGate.outcome(decision, domain: domain, originalArgs: argumentsJSON)
                if let allow = outcome.record, !everyCall {
                    grants.record(domain, allow: allow)
                    conversation.permGrantsRaw = grants.raw
                    try? context.save()
                }
                return outcome.gate
            }
            return grants.isAllowed(domain) ? .proceed(argumentsJSON)
                : .deny("permission_denied：用户本次未允许「\(domain.displayName)」。\(PermissionCenter.adjustHint)")
        }
    }
}

extension PermissionDomain {
    /// 「每次询问」是一笔一问：不记对话授权，卡上没有「本对话都允许」（粟粟 11-14「卡片一个一个批」）——动记忆、动 Prompt 的四个域。
    /// 别的域照旧每个对话问一次
    var asksEveryCall: Bool { [.memoryCards, .memorySelf, .memoryFiles, .promptEdit].contains(self) }
}

extension PermissionGate {
    /// 询问卡上多出的那一行：跑命令 = 命令第一行（截 80 字，plan-离线沙箱-phase1 §1.3）；编程会话 = 这次要查什么（R-WN5 #10）；
    /// 记忆条目 = 要动的那张现在写的是什么。别的域没有
    @MainActor
    static func detail(domain: PermissionDomain, toolName: String, argumentsJSON: String, profileId: String, context: ModelContext) -> String? {
        if domain == .shell, let cmd = DeviceToolIO.str(DeviceToolIO.args(argumentsJSON), "command") {
            let firstLine = cmd.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? cmd
            return "$ " + String(firstLine.prefix(80))
        }
        #if os(macOS)
        if domain == .codingSessions { return CodingTools.permissionDetail(name: toolName, argumentsJSON: argumentsJSON) }
        #endif
        // 文件工具写 Prompt 文件夹 / memory/：改的是哪一段、现在写的是什么
        if domain == .promptEdit { return PromptFolderTools.permissionDetail(toolName: toolName, argumentsJSON: argumentsJSON, profileId: profileId) }
        if FileLibraryTools.Name(rawValue: toolName) != nil, [.memoryCards, .memorySelf, .memoryFiles].contains(domain) {
            return MemoryFolderWrite.permissionDetail(toolName: toolName, argumentsJSON: argumentsJSON, profileId: profileId, context: context)
        }
        if domain == .memoryCards { return MemoryCardTool.permissionDetail(argumentsJSON: argumentsJSON, profileId: profileId, context: context) }
        return nil
    }
}

/// 审批卡上显示什么：跑命令显示完整命令（能改），其余参数一项一项列（长值截断，完整参数另展开）
struct ApprovalPreview {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    static let maxValueLength = 160

    let toolName: String
    let argumentsJSON: String
    /// run_command 的完整命令（不截断）
    let command: String?
    /// 其余参数，按名字排序
    let rows: [Row]

    init(toolName: String, argumentsJSON: String) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        let object = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let isCommand = toolName == RunCommandTool.toolName
        command = isCommand ? object["command"] as? String : nil
        rows = object.keys.sorted()
            .filter { !(isCommand && $0 == "command") }
            .map { Row(label: $0, value: Self.short(Self.text(object[$0]))) }
    }

    /// 这次只有跑命令能改（粟粟 10-03）
    var canEditCommand: Bool { command != nil }

    /// 参数排版好的完整 JSON（「完整参数」展开看）
    var prettyJSON: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return argumentsJSON }
        return text
    }

    static func replacingCommand(in argumentsJSON: String, with command: String) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else { return nil }
        object["command"] = command
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case nil: return ""
        case let v?:
            guard JSONSerialization.isValidJSONObject(v),
                  let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(v)" }
            return String(data: data, encoding: .utf8) ?? "\(v)"
        }
    }

    private static func short(_ s: String) -> String {
        s.count > maxValueLength ? String(s.prefix(maxValueLength)) + "…" : s
    }
}
