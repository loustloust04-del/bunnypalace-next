import Foundation

// MARK: - 小芽助手 · 页面上下文（plan-小芽助手.md §4.1）
// 各模块面板 onAppear 上报「用户在哪」，助手组 prompt 时注入。
// MVP 只报页面名；草稿内容摘要留字段，后续按需补。

@Observable
final class AssistantContext {
    static let shared = AssistantContext()

    /// 当前页面标识："preset" | "cardLibrary" | "worldBook" | "memory" | ""（不在已知页）
    private(set) var page: String = ""

    func report(page: String) {
        self.page = page
    }

    /// onDisappear 调用；只有持有者自己清，避免切页瞬间被别的页清掉
    func clear(page: String) {
        if self.page == page { self.page = "" }
    }

    var promptFragment: String {
        switch page {
        case "preset": return "用户当前正在看「Prompt/预设」页。"
        case "cardLibrary": return "用户当前正在看「卡库」页。"
        case "worldBook": return "用户当前正在看「世界书」页。"
        case "memory": return "用户当前正在看「记忆」页。"
        default: return ""
        }
    }
}
