import Foundation

/// 记忆条目露面时的那一行（粟粟 11-14「也要以这个主语开头啊，到时候召回的时候也要能看见啊，不然没头没尾的。
/// 至少要像你 memoryd 里那样：猫咪·认为 xxxx」）：存的正文不动，显示 / 带出去时在前面拼上「说的是谁」。
/// 带进聊天的注入行、目录行、recall 结果、工具回话、文件库列表、记忆页 / 整理台 / Edit 页都走这一处，不各拼各的。
public enum MemoryEntryLine {
    /// 同 memoryd 网页卡片的拼法（`web/app.js`：`N1 · 主语 · 正文`）
    public static let separator = " · "

    /// 要拼在前面的主语：没写的、正文本来就以它开头的 = nil（不拼成「岚舟 · 岚舟认为…」）
    public static func lead(subject: String?, content: String) -> String? {
        guard let s = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(s) ? nil : s
    }

    /// `岚舟 · 认为 xxxx`；不用拼的原样返回正文
    public static func text(subject: String?, content: String) -> String {
        lead(subject: subject, content: content).map { $0 + separator + content } ?? content
    }

    /// 出处原话最多存多少字（按 Character）：够认出是哪一句；全文在 Edit 页按出处消息现取
    public static let quoteLimit = 120

    /// 出处那条消息 → 存在条目上的原话：换行并成空格，取开头 `quoteLimit` 个字，截了的带「…」；空消息 = nil
    public static func quote(_ message: String) -> String? {
        let flat = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > quoteLimit ? String(flat.prefix(quoteLimit)) + "…" : flat
    }
}
