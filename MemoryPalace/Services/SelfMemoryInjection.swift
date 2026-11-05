import Foundation

/// 每轮常驻注入的「我的记忆」段（B3）：五级全文 + 最近 N 条全文 + 其余一行目录 + 指路。
/// 只在写 / 改 / 忘时才变 → 整段进缓存前缀。预算超了：全文降成目录行，目录也装不下就注明还有几条。
enum SelfMemoryInjection {
    static let footer = "（要看全文用 fs_read 读 memory/self/ 下的文件；新的事用 remember 记）"

    /// 尾注只提这一轮能调到的工具（粟粟 10-15）；两个都有时就是 footer 原文，都没有就空
    static func footerText(available: Set<String>) -> String {
        var parts: [String] = []
        if available.contains(FileLibraryTools.Name.read.rawValue) { parts.append("要看全文用 fs_read 读 memory/self/ 下的文件") }
        if available.contains(SelfMemoryTool.rememberName) { parts.append("新的事用 remember 记") }
        return parts.isEmpty ? "" : "（\(parts.joined(separator: "；"))）"
    }

    struct Built: Equatable {
        let text: String
        let tokens: Int
        let fullCount: Int
        let indexCount: Int
        /// 实际装进全文的那几条（预算装不下降成目录行的不在里面）
        let fullSlugs: Set<String>
    }

    /// 为什么带全文：重要度 5 的全部带 / 重要度 <5 的最近 N 条（`MemoryFlags.selfRecentCount`）
    enum Reason: Equatable {
        case five, recent
    }

    /// 全文候选（纯函数，顺序 = 装入顺序）：活着的里重要度 5 的全部 + 重要度 <5 的最近 recentCount 条，各自新→旧。
    /// 能不能真装进全文还看预算，见 `Built.fullSlugs`
    static func fullCandidates(_ all: [SelfMemory], recentCount: Int) -> [(memory: SelfMemory, reason: Reason)] {
        candidates(active(all), recentCount: recentCount)
    }

    private static func active(_ all: [SelfMemory]) -> [SelfMemory] {
        all.filter(\.isActive).sorted { $0.created > $1.created }
    }

    private static func candidates(_ active: [SelfMemory], recentCount: Int) -> [(memory: SelfMemory, reason: Reason)] {
        let five = active.filter { $0.importance >= 5 }.map { (memory: $0, reason: Reason.five) }
        let recent = active.filter { $0.importance < 5 }.prefix(max(0, recentCount)).map { (memory: $0, reason: Reason.recent) }
        return five + recent
    }

    static func build(_ all: [SelfMemory], recentCount: Int, budget: Int) -> Built {
        let active = Self.active(all)
        guard !active.isEmpty, budget > 0 else { return Built(text: "", tokens: 0, fullCount: 0, indexCount: 0, fullSlugs: []) }

        let fullCandidates = candidates(active, recentCount: recentCount).map(\.memory)

        let header = "[我的记忆]"
        let f = DateFormatter()
        f.dateFormat = "MM-dd"

        var used = Memory.estimateTokens(header + footer)
        var fullBlocks: [String] = []
        var fullSlugs = Set<String>()
        for m in fullCandidates {
            let block = "### \(m.description)（\(m.importance) 级 · \(f.string(from: m.created))）\n\(m.body)"
            let cost = Memory.estimateTokens(block)
            guard used + cost <= budget else { continue }
            fullBlocks.append(block)
            fullSlugs.insert(m.slug)
            used += cost
        }

        var indexLines: [String] = []
        let rest = active.filter { !fullSlugs.contains($0.slug) }
        var dropped = 0
        for m in rest {
            let line = "- \(m.description)（\(m.importance) 级 · \(f.string(from: m.created)) · memory/self/\(m.fileName)）"
            let cost = Memory.estimateTokens(line)
            guard used + cost <= budget else { dropped += 1; continue }
            indexLines.append(line)
            used += cost
        }

        var parts = [header]
        parts += fullBlocks
        if !indexLines.isEmpty || dropped > 0 {
            var idx = "目录（其余 \(rest.count) 条）：\n" + indexLines.joined(separator: "\n")
            if dropped > 0 { idx += "\n…还有 \(dropped) 条没放下，看 memory/self/INDEX.md" }
            parts.append(idx)
        }
        parts.append(footer)
        let text = parts.joined(separator: "\n\n")
        return Built(text: text, tokens: Memory.estimateTokens(text), fullCount: fullBlocks.count, indexCount: indexLines.count,
                     fullSlugs: fullSlugs)
    }
}

