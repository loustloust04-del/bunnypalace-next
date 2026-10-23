#if DEBUG
import Foundation
import SwiftData

/// --chat-sample：独立演示楼层，全部数据为预置样例，模型仅指向 localhost。
@MainActor
enum ChatSampleSeed {
    nonisolated static var isActive: Bool { CommandLine.arguments.contains("--chat-sample") }
    static let profileId = "chat-sample-profile"
    static let conversationId = "chat-sample-conversation"

    static func inject(pm: ProfileManager, providers: ProviderManager) {
        providers.addCredential(APICredential(id: "chat-sample-mock", name: "示例（离线）", emoji: "",
            type: .openaiCompatible, baseURL: "http://127.0.0.1:9876/v1",
            models: [ProviderModel(credentialId: "chat-sample-mock", modelId: "sample", name: "UI 示例")]))
        providers.setApiKey("sample-not-a-real-key", for: "chat-sample-mock")
        if let profile = pm.profiles.first(where: { $0.id == profileId }) {
            pm.switchTo(profile)
        } else {
            pm.addProfile(Profile(id: profileId, name: "聊天小样", emoji: "", description: "Page1 独立界面演示",
                userName: "你", assistantName: "助手", systemPrompt: "", preferredModel: "", createdAt: Date()))
        }
        let ctx = ModelContext(pm.container)
        let cid = conversationId
        let pid = profileId
        let existing = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId == pid })
        if (try? ctx.fetch(existing).isEmpty) != true {
            let noticeId = "sample-notice"
            if let notice = try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == noticeId && $0.profileId == pid })).first,
               notice.role == "system" {
                notice.role = "assistant"
                notice.content = "（已停止）"
                try? ctx.save()
            }
            return
        }
        let date = Date().addingTimeInterval(-7200)
        let conversation = Conversation(id: cid, title: "聊天小样 · 所有改动", createTime: date,
            updateTime: Date(), currentNodeId: "sample-ask", provider: "api", profileId: pid)
        conversation.selectedModelId = "chat-sample-mock/sample"
        ctx.insert(conversation)
        func node(_ id: String, _ role: String, _ text: String, _ parent: String?, _ children: [String]) -> MessageNode {
            let item = MessageNode(id: id, role: role, content: text, contentType: "text", createTime: date,
                parentId: parent, childrenIds: children, conversationId: cid, profileId: pid)
            ctx.insert(item)
            return item
        }
        let root = node("sample-root", "system", "", nil, ["sample-user", "sample-user-alt"])
        root.sourceVisibility = "hidden"
        _ = node("sample-user", "user", "帮我找聊天界面的资料，再展示密码卡。", "sample-root", ["sample-tools", "sample-assistant-alt"])
        _ = node("sample-user-alt", "user", "这是用户消息的第二版。点气泡外的分页器切回第一版。", "sample-root", [])
        _ = node("sample-assistant-alt", "assistant", "这是助手回复的第二版。点气泡外的分页器切回第一版，继续看工具和召回。", "sample-user", [])
        let assistant = node("sample-tools", "assistant", "已经找到聊天界面的资料。", "sample-user", ["sample-next"])
        let steps = [
            ChatToolStep(id: "sample-search-1", name: "fs_search", inputJSON: #"{"keyword":"聊天界面"}"#, result: "docs/chat.md\nmanual/main-chat.md", isError: false, integration: nil, icon: nil),
            ChatToolStep(id: "sample-search-2", name: "fs_search", inputJSON: #"{"keyword":"密码卡"}"#, result: "docs/secure-ask.md", isError: false, integration: nil, icon: nil),
            ChatToolStep(id: "sample-guide", name: "card_guide", inputJSON: #"{"kind":"ask"}"#, result: "加密提问卡使用 secure=true，秘密保存在钥匙串。这里是预置演示输出。", isError: false, integration: nil, icon: nil),
            ChatToolStep(id: "sample-failed", name: "fs_read", inputJSON: #"{"path":"docs/missing-demo.md"}"#, result: "示例文件不存在（预置失败步骤）", isError: true, integration: nil, icon: nil)
        ]
        assistant.setSegments([.thinking(text: "先搜索资料，再查看提问卡说明。", signature: nil),
            .text("这是独立的 UI 示例。工具结果与总结是预置数据，供你查看外观与展开层级。")]
            + steps.flatMap { step in [MessageSegment.toolUse(id: step.id, name: step.name, inputJSON: step.inputJSON, integrationName: nil, iconName: nil),
                .toolResult(toolUseId: step.id, text: step.result ?? "", isError: step.isError, integrationName: nil)] }
            + [.text("找到两份界面资料和一份密码卡说明；另有一次读取失败。点工具总览展开步骤，点步骤查看原始数据。\n\n本条和上面的用户消息各有两个版本，可用气泡外分页器切换。")])
        assistant.thinkingSummary = "先搜索资料，再查看提问卡说明"
        assistant.toolSummaries = [ChatToolTimeline.fingerprint(steps): "搜了两次，读了卡片说明；一次读取失败"]
        let texts = ["你喜欢暖奶白与柔和的绿色。", "工具和召回要能分别选择行内展开或弹出。", "密码卡按钮使用绿色背景、白色文字。"]
        var hits: [InjectionHit] = []
        for (index, text) in texts.enumerated() {
            let memory = Memory(content: text, category: "preference", profileId: pid, sourceConversationId: cid)
            ctx.insert(memory)
            hits.append(InjectionHit(memoryId: memory.id, snippet: text, category: "preference", score: 0.95 - Double(index) * 0.1, retrieverId: "keyword", catalog: false))
        }
        assistant.setRecallHits(hits)
        _ = node("sample-next", "user", "继续展示部分报错、完整报错和系统通知。", "sample-tools", ["sample-partial"])
        _ = node("sample-partial", "assistant", "这段正文在报错后仍然保留。\n\n⚠️ 示例：请求超时，错误在气泡外居中显示。", "sample-next", ["sample-full-error"])
        _ = node("sample-full-error", "assistant", "⚠️ 示例：服务暂时不可用。", "sample-partial", ["sample-notice"])
        _ = node("sample-notice", "assistant", "（已停止）", "sample-full-error", ["sample-ask"])
        let ask = ChatCard.ask(AskCard(id: "q-demo", question: "示例密码卡：请只填随意的测试文本", secure: true))
        _ = node("sample-ask", "assistant", "点绿色的「填写」体验输入面板；填完后按钮变为「修改」。请勿填真实密码。\n\n" + ask.blockText + "\n\n向上滑可看工具与召回。到设置 → 外观 → 消息显示，分别切换工具和召回的行内／弹出模式。", "sample-notice", [])
        do { try ctx.save(); print("[CHAT-SAMPLE] ready: \(cid)") }
        catch { print("[CHAT-SAMPLE] seed failed: \(error)") }
    }
}
#endif
