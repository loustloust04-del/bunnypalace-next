#if DEBUG && os(iOS)
import Foundation
import SwiftData

/// [PROBE 键盘 seed] Debug-only 启动注入 api 对话 + 22 条消息，
/// 给 KeyboardLatestVisibleUITests 复现「点输入框最新消息不起来」（research-keyboard-list-inset §7）。
/// provider="api"：不能用 cc 对话——机器人发送会打进生产 hub（hub 测试隔离铁律）。
///
/// 触发：`xcrun simctl launch <udid> <bundle> -- --kb-probe-seed`
enum KeyboardProbeSeed {
    static let markerKey = "probeKbSeedDone_v1"
    static let convId = "probe-kb-conv-1"

    static var shouldAutoSelectProbeConv: Bool {
        CommandLine.arguments.contains("--kb-probe-seed")
    }

    static func injectIfNeeded(container: ModelContainer, profileId: String) {
        guard CommandLine.arguments.contains("--kb-probe-seed") else { return }
        if UserDefaults.standard.bool(forKey: markerKey) {
            PROBE("[PROBE 键盘 seed] already done, skip")
            return
        }

        let ctx = ModelContext(container)
        let now = Date()
        // 22 条线性消息：够场景③翻历史 500pt+；尾条 user = 机器人断言锚
        let total = 22
        var nodes: [MessageNode] = []
        // 思考链样本（ThinkingExpandUITests 用）：[thinking] 标签走 extractThinking 渲染成可折叠气泡；
        // 40 行 ≈ 展开高度 800pt+，够复现「点开跳远」
        let longThinking = "[thinking]" + (1...40).map { "思考取证第 \($0) 行：这一行撑起展开后的高度变化量。" }.joined(separator: "\n") + "[/thinking]"
        for i in 0..<total {
            let isLast = i == total - 1
            let hasThinking = i == 11 || i == total - 1
            let node = MessageNode(
                id: "probe-kb-msg-\(i)",
                role: i % 2 == 0 ? "user" : "assistant",
                content: isLast ? longThinking + "KBMARKER123"
                    : (hasThinking ? longThinking : "") + "键盘取证填充消息 \(i)：这一条撑起可翻的历史高度，正文再加一句话让气泡有两行。",
                contentType: "text",
                createTime: now.addingTimeInterval(Double(i - total) * 60),
                parentId: i == 0 ? nil : "probe-kb-msg-\(i - 1)",
                childrenIds: isLast ? [] : ["probe-kb-msg-\(i + 1)"],
                conversationId: convId,
                profileId: profileId
            )
            nodes.append(node)
        }
        let conv = Conversation(
            id: convId,
            title: "[PROBE] 键盘避让测试对话",
            createTime: now,
            updateTime: now,
            currentNodeId: "probe-kb-msg-\(total - 1)",
            provider: "api",
            profileId: profileId
        )
        ctx.insert(conv)
        nodes.forEach { ctx.insert($0) }

        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: markerKey)
            PROBE("[PROBE 键盘 seed] injected conv=\(convId) + \(total) msgs")
        } catch {
            PROBE("[PROBE 键盘 seed] FAILED: \(error)")
        }
    }
}
#endif
