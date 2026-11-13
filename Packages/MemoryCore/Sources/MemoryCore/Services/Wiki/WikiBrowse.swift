import Foundation

/// 给人翻 wiki（记忆 app「记忆」格 + 文件库，plan-memory-c3-catalog 4.4 / todo 11）：一层一层列分组和页。同步文件 IO，调用方放后台
public struct WikiBrowseEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder(pageCount: Int)
        case page
    }

    public let path: String
    public let kind: Kind
    public let title: String
    public let hook: String
    public var version: String? = nil
    public var id: String { path }

    public init(path: String, kind: Kind, title: String, hook: String, version: String? = nil) {
        self.path = path
        self.kind = kind
        self.title = title
        self.hook = hook
        self.version = version
    }
}

extension WikiStore {
    /// 这一层：先子分组（有页的才列，带总页数和分组钩子），再页（标题 + 钩子）
    public func browse(_ folder: String) -> [WikiBrowseEntry] {
        let (folders, pages) = children(folder)
        var out: [WikiBrowseEntry] = []
        for sub in folders {
            let count = pagePaths(under: sub).count
            guard count > 0 else { continue }
            out.append(WikiBrowseEntry(path: sub, kind: .folder(pageCount: count),
                                       title: String(sub.split(separator: "/").last ?? ""), hook: groupHook(sub) ?? ""))
        }
        for path in pages {
            guard let current = readVersioned(path) else { continue }
            let page = WikiPage.parse(current.text, path: path)
            out.append(WikiBrowseEntry(path: path, kind: .page, title: page.title, hook: page.hook, version: current.version))
        }
        return out
    }

    /// 9 个组各几页（顺序同 `branches`）
    public func branchPageCounts() -> [WikiBranchCount] {
        Self.branches.map { WikiBranchCount(branch: $0, count: folderExists($0) ? pagePaths(under: $0).count : 0) }
    }

    public func modifiedAt(_ path: String) -> Date? {
        guard let url = try? pageURL(path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

public struct WikiBranchCount: Identifiable, Equatable, Sendable {
    public let branch: String
    public let count: Int
    public var id: String { branch }

    public init(branch: String, count: Int) {
        self.branch = branch
        self.count = count
    }
}
