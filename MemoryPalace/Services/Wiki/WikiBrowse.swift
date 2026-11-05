import Foundation

/// 给人翻 wiki（记忆 app「记忆」格 + 文件库，plan-memory-c3-catalog 4.4 / todo 11）：一层一层列分组和页。同步文件 IO，调用方放后台
struct WikiBrowseEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder(pageCount: Int)
        case page
    }

    let path: String
    let kind: Kind
    let title: String
    let hook: String
    var id: String { path }
}

extension WikiStore {
    /// 这一层：先子分组（有页的才列，带总页数和分组钩子），再页（标题 + 钩子）
    func browse(_ folder: String) -> [WikiBrowseEntry] {
        let (folders, pages) = children(folder)
        var out: [WikiBrowseEntry] = []
        for sub in folders {
            let count = pagePaths(under: sub).count
            guard count > 0 else { continue }
            out.append(WikiBrowseEntry(path: sub, kind: .folder(pageCount: count),
                                       title: String(sub.split(separator: "/").last ?? ""), hook: groupHook(sub) ?? ""))
        }
        for path in pages {
            guard let page = read(path) else { continue }
            out.append(WikiBrowseEntry(path: path, kind: .page, title: page.title, hook: page.hook))
        }
        return out
    }

    /// 两支各几页（顺序同 `branches`）
    func branchPageCounts() -> [WikiBranchCount] {
        Self.branches.map { WikiBranchCount(branch: $0, count: folderExists($0) ? pagePaths(under: $0).count : 0) }
    }

    func modifiedAt(_ path: String) -> Date? {
        guard let url = try? pageURL(path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

struct WikiBranchCount: Identifiable, Equatable, Sendable {
    let branch: String
    let count: Int
    var id: String { branch }
}
