import Foundation

/// 每轮常驻注入的「我的记忆」段（B3）：五级全文 + 最近 N 条全文 + 其余一行目录 + 指路。
/// 只在写 / 改 / 忘时才变 → 整段进缓存前缀。预算超了：全文降成目录行，目录也装不下就注明还有几条。
enum SelfMemoryInjection {
    struct Built: Equatable {
        let text: String
        let tokens: Int
        let fullCount: Int
        let indexCount: Int
    }

    static func build(_ all: [SelfMemory], recentCount: Int, budget: Int) -> Built {
        let active = all.filter(\.isActive).sorted { $0.created > $1.created }
        guard !active.isEmpty, budget > 0 else { return Built(text: "", tokens: 0, fullCount: 0, indexCount: 0) }

        let five = active.filter { $0.importance >= 5 }
        let recent = active.filter { $0.importance < 5 }.prefix(max(0, recentCount))
        let fullCandidates = five + recent

        let header = "[我的记忆]"
        let footer = "（要看全文用 fs_read 读 memory/self/ 下的文件；新的事用 remember 记）"
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
        return Built(text: text, tokens: Memory.estimateTokens(text), fullCount: fullBlocks.count, indexCount: indexLines.count)
    }
}

