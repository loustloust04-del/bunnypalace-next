import Foundation
import Observation

/// 工具抽屉（#093 plan-tool-drawer §2.2）：每个内建工具直接给 / 收起 / 关，全局默认 + 楼层覆盖。
/// 存 UserDefaults 一个小 JSON（`toolDrawer.v1`），启动读一次，之后只读内存快照——组 prompt 的主线程不新增读盘。
/// 每台设备各记各的，不跨设备同步（同权限档位）。
@MainActor
@Observable
final class ToolDrawerStore {
    static let shared = ToolDrawerStore(defaults: .standard)
    static let defaultsKey = "toolDrawer.v1"

    private(set) var state: ToolDrawerState
    /// 每改一次 +1（Prompt 页预览防抖键、抽屉页重算用）
    private(set) var version = 0

    /// 每个对话上一次真发出去的工具签名（只在内存，app 重启就没了——没记录不提示，不猜）
    private(set) var sentSignatures: [String: ToolSignature] = [:]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        state = ToolDrawerState.decoded(defaults.data(forKey: Self.defaultsKey))
    }

    /// 测试用：直接改了 defaults 之后刷新内存快照
    func reload() {
        state = ToolDrawerState.decoded(defaults.data(forKey: Self.defaultsKey))
        version += 1
    }

    /// 真发送时记一笔（三处实发调 toolInjection 的地方）
    func recordSent(conversationId: String, signature: ToolSignature) {
        guard sentSignatures[conversationId] != signature else { return }
        sentSignatures[conversationId] = signature
    }

    func sentSignature(conversationId: String) -> ToolSignature? {
        sentSignatures[conversationId]
    }

    /// 下一轮的工具和上次实发不同 → 工具定义在缓存前缀最前面，下一轮整段重写一次。没有上次的记录不提示
    static func cacheBreaks(sent: ToolSignature?, next: ToolSignature) -> Bool {
        guard let sent else { return false }
        return sent != next
    }

    func update(_ body: (inout ToolDrawerState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        state = next
        version += 1
        if next == .defaults {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(next.encoded(), forKey: Self.defaultsKey)
        }
    }
}

/// 「这一轮发了哪些工具」：清单里的名字 + 清单外调得到的（收起的内建 + 收进目录的 MCP，astra #5），都按名字排（顺序不进签名）
struct ToolSignature: Equatable {
    let tools: [String]
    let catalog: [String]

    /// offered = toolInjection 给的「这一轮调得到的名字」（清单 + 收起 + defer 的 MCP）
    init(tools: [[String: Any]]?, offered: Set<String>?) {
        let names = (tools ?? []).compactMap { t in
            (t["name"] as? String) ?? ((t["function"] as? [String: Any])?["name"] as? String)
        }
        self.tools = names.sorted()
        catalog = (offered ?? []).subtracting(names).sorted()
    }
}

/// 工具抽屉顶部的数字（#093 §2.4）：和实发同一个 toolInjectionDetailed（silent）算，不跑整轮组装
struct ToolDrawerPreview: Equatable {
    let toolCount: Int
    let tuckedCount: Int
    /// tools 数组（sortedKeys 序列化）粗估
    let definitionTokens: Int
    /// 追加进系统提示的工具说明粗估
    let hintTokens: Int
    let absentReason: ToolsAbsentReason?
    let modelName: String
    let signature: ToolSignature

    init(tools: [[String: Any]]?, systemHint: String, tucked: [String], offered: Set<String>?, absentReason: ToolsAbsentReason?, modelName: String) {
        toolCount = tools?.count ?? 0
        tuckedCount = tucked.count
        let json = tools.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        definitionTokens = json.isEmpty ? 0 : TokenEstimator.estimate(json)
        hintTokens = systemHint.isEmpty ? 0 : TokenEstimator.estimate(systemHint)
        self.absentReason = absentReason
        self.modelName = modelName
        signature = ToolSignature(tools: tools, offered: offered)
    }
}
