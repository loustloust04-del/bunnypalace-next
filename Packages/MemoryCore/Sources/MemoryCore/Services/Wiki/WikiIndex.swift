import Foundation

/// wiki 索引（plan-memory-c3-catalog 2.1）：代码从页的 frontmatter 和文件夹生成，每层一份 INDEX.md，不让模型写。
/// 一层超过 30 行只在头上标「待分组」，不自动拆（下次 C3 出「分组调整」提案）
extension WikiStore {
    public static let layerLimit = 30
    public static let overfullMarker = "> 待分组：这一层超过 \(layerLimit) 行"

    // MARK: 分组钩子（文件夹里的 .group.md，frontmatter `钩子:`）

    public func groupHook(_ folder: String) -> String? {
        guard let data = try? Data(contentsOf: folderURL(folder).appendingPathComponent(Self.groupFileName)) else { return nil }
        var lines = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let hook = WikiPage.frontmatter(&lines)["钩子"] ?? ""
        return hook.isEmpty ? nil : hook
    }

    public func setGroupHook(_ folder: String, hook: String) throws {
        guard Self.isValidFolderPath(folder) else { throw WikiError.invalidPath(folder) }
        try Self.writeAtomic(Data("---\n钩子: \(hook)\n---\n".utf8), to: folderURL(folder).appendingPathComponent(Self.groupFileName))
    }

    // MARK: 一层

    /// 这层直接的子文件夹（不隐藏的）和页
    public func children(_ folder: String) -> (folders: [String], pages: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL(folder).path)) ?? []
        var folders: [String] = [], pages: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = folder.isEmpty ? name : folder + "/" + name
            if folderExists(path) {
                if Self.isValidFolderPath(path) { folders.append(path) }
            } else if name.hasSuffix(".md"), name != Self.indexFileName {
                let page = String(path.dropLast(3))
                if Self.isValidPagePath(page) { pages.append(page) }
            }
        }
        return (folders, pages)
    }

    /// 这层索引的行：先子分组（有页的才列），再页
    public func layerLines(_ folder: String) -> [String] {
        let (folders, pages) = children(folder)
        var lines: [String] = []
        for sub in folders {
            let count = pagePaths(under: sub).count
            guard count > 0 else { continue }
            let name = String(sub.split(separator: "/").last ?? "")
            let hook = groupHook(sub).map { " — \($0)" } ?? ""
            lines.append("- [[\(sub)/]] \(name)\(hook)（\(count) 页）")
        }
        for path in pages {
            guard let page = read(path) else { continue }
            lines.append("- [[\(path)]] \(page.title)\(page.factDomainIndexTag)" + (page.hook.isEmpty ? "" : " — \(page.hook)")
                + (page.validUntil.map { "（「现在」\(WikiPage.validUntilKey) \($0)）" } ?? ""))
        }
        return lines
    }

    public func layerMarkdown(_ folder: String) -> String {
        if folder.isEmpty {
            var out = "# C 档案\n"
            for branch in Self.branches {
                let count = pagePaths(under: branch).count
                guard count > 0 else { continue }
                out += "\n## \(branch)" + (groupHook(branch).map { " — \($0)" } ?? "") + "（\(count) 页）\n"
                out += layerLines(branch).map { $0 + "\n" }.joined()
            }
            return out
        }
        let lines = layerLines(folder)
        var out = "# \(folder)\n"
        if lines.count > Self.layerLimit { out += Self.overfullMarker + "\n" }
        out += "\n" + lines.map { $0 + "\n" }.joined()
        return out
    }

    /// 重建一层（""= 根）；内容没变不写
    public func rebuildLayer(_ folder: String) throws {
        let url = folderURL(folder).appendingPathComponent(Self.indexFileName)
        let data = Data(layerMarkdown(folder).utf8)
        if (try? Data(contentsOf: url)) == data { return }
        try Self.writeAtomic(data, to: url)
    }

    // MARK: 重建

    /// 改了这些页（或分组文件夹）：它所在层一路到根，每层重建
    public func rebuildIndexes(affecting paths: [String]) throws {
        try beforeRebuildIndexes?()
        var layers: Set<String> = [""]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for i in 0..<max(parts.count - 1, 0) {
                layers.insert(parts[0...i].joined(separator: "/"))
            }
        }
        for layer in layers.sorted(by: { $0.count > $1.count }) where layer.isEmpty || folderExists(layer) {
            try rebuildLayer(layer)
        }
    }

    /// 全部分组文件夹（含 9 个组本身）
    public func allFolders() -> [String] {
        var out: [String] = []
        func walk(_ folder: String) {
            out.append(folder)
            children(folder).folders.forEach(walk)
        }
        for branch in Self.branches where folderExists(branch) { walk(branch) }
        return out
    }

    public func rebuildAllIndexes() throws {
        try beforeRebuildIndexes?()
        for folder in allFolders() { try rebuildLayer(folder) }
        try rebuildLayer("")
    }

    /// 超过 30 行的层（给以后「分组调整」提案用）；根不算
    public func overfullLayers() -> [String] {
        allFolders().filter { layerLines($0).count > Self.layerLimit }
    }
}
