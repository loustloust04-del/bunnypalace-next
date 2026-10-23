import Foundation
import SwiftData

/// 思考过程的一句话总结（plan-thinking-branch）：复用起标题的小模型链（`ConversationTitler.generate`）。
/// 新消息（创建 30 分钟内）走整条链：端上 Apple 模型 → 便宜 API；老消息只用端上模型（翻历史不花钱）。
/// 串行一次一条；本次启动内每条只试一次（失败不反复重试）。
@MainActor
enum ThinkingSummarizer {
    nonisolated static let freshWindow: TimeInterval = 30 * 60
    private static let instructions = "用一句话概括这段思考在想什么。中文，不超过 20 个字，只输出这句话，不加引号和解释。"

    private static var tried: Set<String> = []
    private static var queue: [(node: MessageNode, thinking: String, providerManager: ProviderManager?)] = []
    private static var running = false

    static func request(_ node: MessageNode, thinking: String, providerManager: ProviderManager?) {
        guard node.thinkingSummary == nil, !thinking.isEmpty, tried.insert(node.id).inserted else { return }
        queue.append((node, thinking, providerManager))
        pump()
    }

    private static func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let job = queue.removeFirst()
        Task { @MainActor in
            defer {
                running = false
                pump()
            }
            let model = allowsAPI(createTime: job.node.createTime, now: Date())
                ? job.providerManager.flatMap(ConversationTitler.titleModel) : nil
            guard let raw = await ConversationTitler.generate(
                prompt: String(job.thinking.prefix(1200)), instructions: instructions, kind: .thinking, model: model,
                providerManager: job.providerManager, conversationId: job.node.conversationId, profileId: job.node.profileId)
            else { return }
            let summary = clean(raw)
            guard !summary.isEmpty, job.node.thinkingSummary == nil, let context = job.node.modelContext else { return }
            job.node.thinkingSummary = summary
            try? context.save()
        }
    }

    nonisolated static func allowsAPI(createTime: Date?, now: Date) -> Bool {
        guard let createTime else { return false }
        return now.timeIntervalSince(createTime) < freshWindow
    }

    /// 模型输出 → 一句话：第一行，去「总结：」前缀、引号、句末标点，≤ 40 字
    nonisolated static func clean(_ raw: String) -> String {
        var t = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        t = t.replacingOccurrences(of: #"^\s*(总结|概括|一句话|Summary)\s*[:：]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’「」『』《》*#。.！!？?，,；;"))
        return String(t.prefix(40))
    }

    /// 还没有总结时顶着用：思考原文清洗后的第一句，按显示宽度截断
    nonisolated static func firstSentence(_ thinking: String) -> String? {
        let plain = ConversationTitler.plainText(thinking)
        guard !plain.isEmpty else { return nil }
        let end = plain.firstIndex { "。！？!?；".contains($0) } ?? plain.endIndex
        let sentence = String(plain[..<end]).trimmingCharacters(in: .whitespaces)
        return sentence.isEmpty ? nil : ConversationTitler.sanitizedFallback(firstUser: sentence)
    }
}
