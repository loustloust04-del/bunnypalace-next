import Foundation

/// B4 工具结果外置（《minis对比》plan-B4，2026-09-09）。pi `core/tools/truncate.js` 同构：
/// 上限 **2000 行 或 50KB 先到先算**，头截、不切半行；超限的全文落 `tool-results/`，回灌只带头部 + 续读指引。
///
/// 为什么：同一个 tool loop 里每多跑一轮，前面所有工具结果就原样再发一遍；`fs_read` / MCP 原本没有任何上限。
/// 历史轮的结果由 `ToolReplay` 截到 2KB 回放（#089），膨胀只在 loop 内——这里就是 loop 内唯一的收口点。
///
/// 上限即预览（pi 的取舍，粟粟 09-09 拍）：一个 50KB 纯中文结果 ≈ 17K token，每轮仍会重发。
enum ToolResultOffload {
    static let maxLines = 2000
    static let maxBytes = 50 * 1024

    enum TruncatedBy { case none, lines, bytes, firstLine }

    struct Truncation {
        let text: String
        let by: TruncatedBy
        let totalLines: Int
        let totalBytes: Int
        /// 保留下来的完整行数（firstLine 时 = 1，且那一行不完整）
        let shownLines: Int
        var truncated: Bool { by != .none }
    }

    // MARK: - 纯文本

    /// 按 `\n` 切行；末尾换行产生的空尾行不算一行（pi `splitLinesForCounting`）
    static func splitLines(_ s: String) -> [Substring] {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count == 1, lines[0].isEmpty { return [] }
        return lines
    }

    /// 保留头部：先撞到行数上限还是字节上限就按哪个截；首行单独超字节上限 → 按字符边界切那一行
    static func truncateHead(_ content: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> Truncation {
        let lines = splitLines(content)
        let totalBytes = content.utf8.count
        if lines.count <= maxLines && totalBytes <= maxBytes {
            return Truncation(text: content, by: .none, totalLines: lines.count, totalBytes: totalBytes, shownLines: lines.count)
        }
        if let first = lines.first, first.utf8.count > maxBytes {
            return Truncation(text: prefix(first, bytes: maxBytes), by: .firstLine,
                              totalLines: lines.count, totalBytes: totalBytes, shownLines: 1)
        }
        var out: [Substring] = []
        var bytes = 0
        var by: TruncatedBy = .lines
        for line in lines.prefix(maxLines) {
            let cost = line.utf8.count + (out.isEmpty ? 0 : 1)
            if bytes + cost > maxBytes { by = .bytes; break }
            out.append(line)
            bytes += cost
        }
        return Truncation(text: out.joined(separator: "\n"), by: by,
                          totalLines: lines.count, totalBytes: totalBytes, shownLines: out.count)
    }

    private static func prefix(_ line: Substring, bytes limit: Int) -> String {
        var out = ""
        var used = 0
        for ch in line {
            let n = String(ch).utf8.count
            if used + n > limit { break }
            out.append(ch)
            used += n
        }
        return out
    }

    static func formatSize(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes)B" : bytes < 1024 * 1024 ? "\(bytes / 1024)KB" : String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    private static func limitLabel(_ by: TruncatedBy) -> String {
        by == .lines ? "\(maxLines) 行上限" : "\(formatSize(maxBytes)) 上限"
    }

    // MARK: - tool loop 收口点

    /// 非 `fs_read` 的工具结果：超限 → 全文落 `tool-results/`，返回头部 + 尾注；未超限原样返回。
    /// `fs_read` 自己按同一上限头截并指回原文件（`fileRead`），调用方跳过它。
    static func apply(text: String, conversationId: String, toolUseId: String, toolName: String, profileId: String) -> (text: String, offloaded: Bool) {
        let t = truncateHead(text)
        guard t.truncated else { return (text, false) }
        let archive: String
        do {
            let path = try FileLibraryStore.toolResultWrite(conversationId: conversationId, toolUseId: toolUseId,
                                                            toolName: toolName, content: text, profileId: profileId)
            archive = t.by == .firstLine
                ? "完整结果已保存到 \(path)；这一行按行读也取不全，请缩小查询范围或换工具"
                : "完整结果已保存到 \(path)，用 fs_read(path: \"\(path)\", offset: \(t.shownLines + 1)) 续读"
        } catch {
            archive = "完整结果存档失败（\(error.localizedDescription)），只有这段预览"
        }
        let note = t.by == .firstLine
            ? "[首行超过 \(formatSize(maxBytes))，已切断（共 \(t.totalLines) 行 / \(formatSize(t.totalBytes))）。\(archive)]"
            : "[已截断：显示第 1–\(t.shownLines) 行 / 共 \(t.totalLines) 行（\(limitLabel(t.by))）。\(archive)]"
        return (t.text + "\n\n" + note, true)
    }

    // MARK: - fs_read

    /// `fs_read` 的范围读 + 头截：`offset` 1 起始行，`limit` 行数，都可缺省。
    /// 带范围时首行报 `（第 a–b 行 / 共 n 行）`；超限尾注引导 `offset` 续读（pi read 同款）。
    static func fileRead(text: String, path: String, offset: Int?, limit: Int?) -> (text: String, isError: Bool) {
        let all = splitLines(text)
        let total = all.count
        let ranged = offset != nil || limit != nil
        if total == 0 { return (ranged ? "（空文件，共 0 行）" : text, false) }
        let start = max(offset ?? 1, 1)
        if start > total { return ("offset \(start) 超出文件末尾（共 \(total) 行）", true) }
        var slice = all[(start - 1)...]
        if let limit, limit > 0 { slice = slice.prefix(limit) }
        let t = truncateHead(slice.joined(separator: "\n"))
        let end = start + t.shownLines - 1
        var out = ranged ? "（第 \(start)–\(end) 行 / 共 \(total) 行）\n" + t.text : t.text
        switch t.by {
        case .none: break
        case .firstLine:
            out += "\n\n[第 \(start) 行超过 \(formatSize(maxBytes))，已切断。这一行按行读取不全，请用 fs_search 缩小范围]"
        case .lines, .bytes:
            out += "\n\n[已截断：显示第 \(start)–\(end) 行 / 共 \(total) 行（\(limitLabel(t.by))）。用 fs_read(path: \"\(path)\", offset: \(end + 1)) 续读]"
        }
        return (out, false)
    }

    // MARK: - 卡片「打开完整结果」

    /// 从回灌文本里抠出我们自己写进去的存档路径（字符集受控，见 `FileLibraryStore.toolResultComponent`）
    static func embeddedPath(in text: String?) -> String? {
        guard let text,
              let range = text.range(of: #"tool-results/[A-Za-z0-9_\-]+/[A-Za-z0-9_\-]+\.txt"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}
