import Foundation

/// 写作风格：一段贴在最后一条 user message 末尾的隐藏提示词（<style>…</style>）。
/// 全局库，对话级选一次持续生效，只最新一条带、历史不复读。
struct WritingStyle: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var content: String
    var isBuiltin: Bool

    init(id: String = UUID().uuidString, name: String, content: String, isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.content = content
        self.isBuiltin = isBuiltin
    }
}

extension WritingStyle {
    static let concise = WritingStyle(
        id: "builtin-concise", name: "简洁",
        content: "用最少的话直接回答，去掉铺垫和总结，不展开除非被要求。", isBuiltin: true)
    static let explanatory = WritingStyle(
        id: "builtin-explanatory", name: "详尽",
        content: "像老师讲解一样展开，给背景、举例子、说清「为什么」，循序渐进。", isBuiltin: true)
    static let formal = WritingStyle(
        id: "builtin-formal", name: "正式",
        content: "用正式、专业、克制的措辞，结构清晰，避免口语和俚语。", isBuiltin: true)

    /// Normal = 不选（currentStyleId == ""），不注入、不入库。
    static let allBuiltin: [WritingStyle] = [.concise, .explanatory, .formal]
}
