import Foundation

/// 纯代码 wiki 体检：断链、孤页、目录漂移。只报告，不改页、不调模型；每天自动整理后跑一次。
/// 目录（INDEX.md）本来就是代码生成的：有漂移就照现有做法整份重建，报告里记的是重建前的差异
struct WikiHealth: Codable, Equatable, Sendable {
    struct Link: Codable, Equatable, Sendable {
        var from: String
        var to: String
    }

    var at: Date
    /// 「连到」指向的页不存在
    var brokenLinks: [Link] = []
    /// 没有别的页连向它，也不在任何分组（两支下的子文件夹）里
    var orphans: [String] = []
    /// 各层 INDEX.md 和此刻的页对不上的地方（重建前）
    var drift: [String] = []
    /// 有漂移时重建索引没成的原因
    var rebuildError: String? = nil

    var summary: String { "断链 \(brokenLinks.count) · 孤页 \(orphans.count) · 目录漂移 \(drift.count)" }

    var details: String {
        var out: [String] = []
        out.append("断链（「连到」指向的页不存在）：" + (brokenLinks.isEmpty ? "没有" : "\n" + brokenLinks.map { "- \($0.from) → \($0.to)" }.joined(separator: "\n")))
        out.append("孤页（没有页连向它，也不在任何分组里）：" + (orphans.isEmpty ? "没有" : "\n" + orphans.map { "- " + $0 }.joined(separator: "\n")))
        out.append("目录漂移（重建前的差异）：" + (drift.isEmpty ? "没有" : "\n" + drift.map { "- " + $0 }.joined(separator: "\n")))
        if !drift.isEmpty { out.append(rebuildError.map { "索引没重建成：\($0)" } ?? "已按代码重建索引。") }
        return out.joined(separator: "\n\n")
    }

    /// 只读：页、各层索引文件。后台调
    static func check(_ wiki: WikiStore, now: Date) -> WikiHealth {
        var out = WikiHealth(at: now)
        let paths = wiki.pagePaths()
        let existing = Set(paths)
        var linked = Set<String>()
        for path in paths {
            guard let page = wiki.read(path) else { continue }
            for link in page.links where link.target != path {
                if existing.contains(link.target) {
                    linked.insert(link.target)
                } else {
                    out.brokenLinks.append(.init(from: path, to: link.target))
                }
            }
        }
        out.orphans = paths.filter { $0.split(separator: "/").count < 3 && !linked.contains($0) }
        out.drift = drift(wiki, hasPages: !paths.isEmpty)
        return out
    }

    /// 每层 INDEX.md 对照代码此刻会生成的：多列的、漏列的、那一行对不上的；那层有页却没有索引文件也算
    static func drift(_ wiki: WikiStore, hasPages: Bool) -> [String] {
        var out: [String] = []
        for folder in [""] + wiki.allFolders() {
            let name = folder.isEmpty ? "根索引" : folder
            let expected = wiki.layerMarkdown(folder)
            guard let data = try? Data(contentsOf: wiki.folderURL(folder).appendingPathComponent(WikiStore.indexFileName)) else {
                if folder.isEmpty ? hasPages : !wiki.pagePaths(under: folder).isEmpty { out.append("\(name)：没有索引文件") }
                continue
            }
            let actual = String(decoding: data, as: UTF8.self)
            guard actual != expected else { continue }
            let want = entries(expected), have = entries(actual)
            let wanted = Dictionary(want, uniquingKeysWith: { a, _ in a }), had = Dictionary(have, uniquingKeysWith: { a, _ in a })
            var found: [String] = []
            for (target, _) in have where wanted[target] == nil { found.append("\(name)：索引里列了「\(target)」，实际没有") }
            for (target, line) in want {
                guard let old = had[target] else { found.append("\(name)：「\(target)」没列进索引"); continue }
                if old != line { found.append("\(name)：「\(target)」那一行和页对不上") }
            }
            out += found.isEmpty ? ["\(name)：索引文件和代码生成的不一样（页数 / 待分组标记）"] : found
        }
        return out
    }

    /// 「- [[路径]] …」行：路径 → 整行，按出现顺序
    private static func entries(_ text: String) -> [(String, String)] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("- [["), let close = line.range(of: "]]") else { return nil }
            return (String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound]), line)
        }
    }

    static func url(_ wiki: WikiStore) -> URL {
        wiki.root.appendingPathComponent(".sort", isDirectory: true).appendingPathComponent("health.json")
    }

    static func load(_ wiki: WikiStore) -> WikiHealth? {
        (try? Data(contentsOf: url(wiki))).flatMap { try? JSONDecoder().decode(WikiHealth.self, from: $0) }
    }

    func save(_ wiki: WikiStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try WikiStore.writeAtomic(encoder.encode(self), to: Self.url(wiki))
    }
}
