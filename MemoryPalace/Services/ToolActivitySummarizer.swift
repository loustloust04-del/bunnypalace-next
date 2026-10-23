import Foundation
import SwiftData

@MainActor
enum ToolActivitySummarizer {
    private static var tried: Set<String> = []
    private static var queue: [(MessageNode, [ChatToolStep], ProviderManager?)] = []
    private static var running = false

    static func request(node: MessageNode, steps: [ChatToolStep], providerManager: ProviderManager?) {
        let fingerprint = ChatToolTimeline.fingerprint(steps)
        guard !steps.isEmpty, steps.allSatisfy({ $0.result != nil }),
              node.toolSummaries[fingerprint] == nil,
              tried.insert(node.id + fingerprint).inserted else { return }
        queue.append((node, steps, providerManager))
        pump()
    }

    private static func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let (node, steps, providerManager) = queue.removeFirst()
        Task { @MainActor in
            defer { running = false; pump() }
            let fingerprint = ChatToolTimeline.fingerprint(steps)
            guard node.modelContext != nil, !node.isTrashed else { return }
            let originalSegments = node.segmentsData
            let model = ThinkingSummarizer.allowsAPI(createTime: node.createTime, now: Date())
                ? providerManager.flatMap(ConversationTitler.titleModel) : nil
            guard let raw = await ConversationTitler.generate(
                prompt: ChatToolTimeline.summaryPrompt(steps),
                instructions: "把这些工具步骤概括成一句自然的中文，例如：在文件库搜了两次，读了卡片说明。不超过 35 字，只输出这句话。不要编造步骤或结果，失败必须提到。", kind: .toolSummary,
                model: model, providerManager: providerManager,
                conversationId: node.conversationId, profileId: node.profileId),
                  node.segmentsData == originalSegments, !node.isTrashed,
                  let context = node.modelContext else { return }
            var summary = ThinkingSummarizer.clean(raw)
            guard !summary.isEmpty else { return }
            let failures = steps.filter(\.isError).count
            if failures > 0, !summary.contains("失败") { summary += " · \(failures) 次失败" }
            var summaries = node.toolSummaries
            summaries[fingerprint] = summary
            node.toolSummaries = summaries
            try? context.save()
        }
    }
}
