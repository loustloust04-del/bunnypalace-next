import CryptoKit
import Foundation

/// 入口共用同一个任务机制（目录 / 正文两批），只记是从哪进来的；survey = 新用户三问（原料只有这次的答案）
public enum CatalogSeedEntry: String, Codable, Sendable {
    case cc, persona, survey

    public var label: String {
        switch self {
        case .cc: return "CC 记忆"
        case .persona: return "人设"
        case .survey: return "新用户三问"
        }
    }
}

/// 这一次能读的原料（白名单）：Prompt 按段、CC 记忆按文件、现有 wiki 各层索引和每页全文。
/// wiki 只认楼层 wiki 根里真实的文件夹 / 文件：符号链接（文件或文件夹）一律不收，真实路径必须还在这层楼的 wiki 里
public struct CatalogSeedMaterials: Sendable {
    public struct Item: Equatable, Sendable {
        public var path: String
        public var name: String
        /// Prompt / CC / wiki
        public var layer: String
        public var text: String
        public var version: String
        public var sourceContext: SeedSourceContext? = nil

        public init(path: String, name: String, layer: String, text: String, version: String, sourceContext: SeedSourceContext? = nil) {
            self.path = path
            self.name = name
            self.layer = layer
            self.text = text
            self.version = version
            self.sourceContext = sourceContext
        }
    }

    public static let wikiPrefix = "memory/wiki/"
    public static let wikiIndexPath = wikiPrefix + WikiStore.indexFileName

    public var items: [Item] = []
    /// 没读的（CC 跳过的、private_ 只有数量；wiki 根是链接时的说明）
    public var skipped: [String] = []

    public static func wikiPath(_ page: String) -> String { wikiPrefix + page + ".md" }

    public static func indexPath(_ folder: String) -> String {
        folder.isEmpty ? wikiIndexPath : wikiPrefix + folder + "/" + WikiStore.indexFileName
    }

    /// `memory/wiki/人/阿青.md` → `人/阿青`
    public static func pagePath(_ path: String) -> String? {
        guard path.hasPrefix(wikiPrefix), path.hasSuffix(".md") else { return nil }
        let page = String(path.dropFirst(wikiPrefix.count).dropLast(3))
        return WikiStore.isValidPagePath(page) ? page : nil
    }

    /// `memory/wiki/人/INDEX.md` → `人`（根索引 = ""）
    public static func indexFolder(_ path: String) -> String? {
        if path == wikiIndexPath { return "" }
        let tail = "/" + WikiStore.indexFileName
        guard path.hasPrefix(wikiPrefix), path.hasSuffix(tail) else { return nil }
        let folder = String(path.dropFirst(wikiPrefix.count).dropLast(tail.count))
        return WikiStore.isValidFolderPath(folder) ? folder : nil
    }


    /// wiki 各层索引 + 每页全文（只认 SafeWiki 扫出来的真实文件）
    public mutating func addWiki(_ wiki: WikiStore, memoryRoot: URL) {
        let safe = SafeWiki.scan(wiki, memoryRoot: memoryRoot)
        if let note = safe.refused { skipped.append(note) }
        if !safe.pages.isEmpty {
            for folder in [""] + safe.folders where safe.count(under: folder) > 0 {
                let text = safe.index(folder)
                items.append(Item(path: Self.indexPath(folder), name: folder.isEmpty ? "wiki 根索引" : "wiki 索引 · \(folder)", layer: "wiki",
                                  text: text, version: WikiStore.version(of: Data(text.utf8))))
            }
        }
        for page in safe.pages {
            items.append(Item(path: Self.wikiPath(page.path), name: page.page.title, layer: "wiki", text: page.text, version: page.version))
        }
    }

    public init(items: [Item] = [], skipped: [String] = []) {
        self.items = items
        self.skipped = skipped
    }
}

/// 只认楼层 wiki 根里真实存在的普通文件 / 文件夹（不跟符号链接、不出根），索引也按这份算，不借 WikiStore 的读页（它会跟链接）。
/// 名字以 private_ 开头（不分大小写，`CCMemorySync.isExcluded`）的页和文件夹在打开之前就跳过：不读正文、不进索引（astra 10-23 P1）
public struct SafeWiki: Sendable {
    public struct Page: Sendable {
        public var path: String
        public var text: String
        public var version: String
        public var page: WikiPage

        public init(path: String, text: String, version: String, page: WikiPage) {
            self.path = path
            self.text = text
            self.version = version
            self.page = page
        }
    }

    public var pages: [Page] = []
    /// 真实的分组文件夹（含 9 个组本身），按路径排
    public var folders: [String] = []
    public var hooks: [String: String] = [:]
    /// wiki 根本身不可信时的说明
    public var refused: String?

    private static let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]

    public static func isPlainFile(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
        return v.isRegularFile == true && v.isSymbolicLink != true
    }

    /// wiki 根下的内部存储（原料快照 / 要点卡 / 对齐聚类结果 / 任务文件）走不通的原因
    public enum PathError: Error, LocalizedError, Equatable {
        case link(String)
        case notFolder(String)
        case notFile(String)
        case outside(String)
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .link(let p): return "\(p) 是链接，不跟"
            case .notFolder(let p): return "\(p) 不是文件夹"
            case .notFile(let p): return "\(p) 不是普通文件"
            case .outside(let p): return "\(p) 不在这层楼的 wiki 里"
            case .missing(let p): return "\(p) 不在"
            }
        }
    }

    /// lstat 看到的类型（不跟链接）；不存在 = nil，别的错 = 抛
    public static func itemType(_ url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    /// 真实路径（realpath：系统链接全解开，/var 和 /private/var 落到同一个写法）；不存在 = nil
    private static func canonical(_ url: URL) -> String? {
        guard let p = realpath(url.path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// 两边都按 realpath 规范化后比（根上方的系统链接两边一样解开）；根和目标都得已经在
    private static func inside(_ url: URL, _ root: URL) -> Bool {
        guard let base = canonical(root), let target = canonical(url) else { return false }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// 只按字面拆路径（去空段、「.」、「..」退一级），不碰文件系统：
    /// `standardizedFileURL` 只在路径存在时才去掉开头的 /private，根在、子文件夹还没建时两边写法会对不上（😷 真机 10-24 回归）
    private static func lexical(_ url: URL) -> [String] {
        var out: [String] = []
        for c in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(String(c))
        }
        return out
    }

    /// 楼层目录（wiki 根的上一级）和 wiki 根本身都必须是真文件夹、不是链接（整个 wiki 换成指向别层的链接要拒）；
    /// 楼层目录往上是系统路径（/var → /private/var 这类），不查。create = 缺了就从楼层目录出发建
    private static func checkRoot(_ root: URL, create: Bool) throws {
        let floor = root.deletingLastPathComponent()
        for (url, isRoot) in [(floor, false), (root, true)] {
            let shown = isRoot ? "wiki 文件夹" : "楼层文件夹"
            switch try itemType(url) {
            case .typeDirectory?:
                continue
            case .typeSymbolicLink?:
                throw PathError.link(shown)
            case nil:
                guard create else { throw PathError.missing(shown) }
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: !isRoot)
                } catch {
                    guard try itemType(url) == .typeDirectory else { throw error }
                }
            default:
                throw PathError.notFolder(shown)
            }
        }
    }

    /// 楼层 wiki 根下的一个内部文件夹（`.cards`、`.proposals/<任务>/materials` …）：先验楼层目录和根本身，再从根起逐级查，每一级都必须是真文件夹、不是链接；
    /// create = 缺的那一级先查完上一级再建；最后按 realpath 仍在根里。不在又不建 = `.missing`
    public static func folder(_ parts: [String], under root: URL, create: Bool) throws -> URL {
        var url = root
        var walked: [String] = []
        try checkRoot(root, create: create)
        for part in parts {
            walked.append(part)
            let shown = walked.joined(separator: "/")
            guard !part.isEmpty, part != ".", part != "..", !part.contains("/") else { throw PathError.outside(shown) }
            url = url.appendingPathComponent(part, isDirectory: true)
            switch try itemType(url) {
            case .typeDirectory?:
                continue
            case .typeSymbolicLink?:
                throw PathError.link(shown)
            case nil:
                guard create else { throw PathError.missing(shown) }
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                } catch {
                    guard try itemType(url) == .typeDirectory else { throw error }
                }
            default:
                throw PathError.notFolder(shown)
            }
        }
        guard !walked.isEmpty, inside(url, root) else { throw PathError.outside(walked.joined(separator: "/")) }
        return url
    }

    /// 已知 URL 的那个内部文件夹（必须在 root 下面），规矩同上
    public static func folder(_ url: URL, under root: URL, create: Bool = false) throws -> URL {
        let base = lexical(root), target = lexical(url)
        guard target.count > base.count, target.starts(with: base) else { throw PathError.outside(url.lastPathComponent) }
        return try folder(Array(target.dropFirst(base.count)), under: root, create: create)
    }

    /// 内部文件夹里的一个文件：名字只有一段；在的话必须是普通文件、不是链接（不在 = 可以写；读的调用方自己判在不在）
    public static func file(_ name: String, in folder: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw PathError.outside(name) }
        let url = folder.appendingPathComponent(name)
        switch try itemType(url) {
        case nil, .typeRegular?: return url
        case .typeSymbolicLink?: throw PathError.link(name)
        default: throw PathError.notFile(name)
        }
    }

    /// 读一个内部文件：文件夹从根起逐级不跟链接、文件是普通文件；哪一步不对 / 不在 = nil
    public static func read(_ name: String, in parts: [String], under root: URL) -> Data? {
        guard let dir = try? folder(parts, under: root, create: false), let url = try? file(name, in: dir),
              (try? itemType(url)) == .typeRegular else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 写一个内部文件：先逐级查（缺的建）再原子写；路径上有链接 / 出根就抛，不写
    public static func write(_ data: Data, name: String, in parts: [String], under root: URL) throws {
        let dir = try folder(parts, under: root, create: true)
        try WikiStore.writeAtomic(data, to: try file(name, in: dir))
    }

    /// 删内部文件或显式指定的目录：逐级查过、不跟链接（不在 = 没事；路径上是链接 / 别的 = 抛，不删）
    public static func remove(_ name: String, in parts: [String], under root: URL, isFolder: Bool = false) throws {
        let dir: URL
        do {
            dir = try folder(parts, under: root, create: false)
        } catch PathError.missing {
            return
        }
        let url: URL
        do { url = isFolder ? try folder(parts + [name], under: root, create: false) : try file(name, in: dir) }
        catch PathError.missing { return }
        guard try itemType(url) == (isFolder ? .typeDirectory : .typeRegular) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// 内部文件夹里的条目（文件夹逐级查过；不在 / 不对 = 空）。只返回名字，调用方按类型再筛
    public static func names(in parts: [String], under root: URL) -> (folder: URL, names: [String])? {
        guard let dir = try? folder(parts, under: root, create: false) else { return nil }
        return (dir, (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    public static func scan(_ wiki: WikiStore, memoryRoot: URL) -> SafeWiki {
        scan(wiki, memoryRoot: memoryRoot, check: {})
    }

    /// `check`：每个文件之前调一次（详情页离开时取消用）；种子走上面那个不传的
    public static func scan(_ wiki: WikiStore, memoryRoot: URL, check: () throws -> Void) rethrows -> SafeWiki {
        var out = SafeWiki()
        let root = wiki.root
        guard let rootValues = try? root.resourceValues(forKeys: Set(keys)) else { return out }
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let realMemory = memoryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true, realRoot.hasPrefix(realMemory + "/") else {
            out.refused = "wiki 文件夹是链接或不在这层楼里，没读"
            return out
        }
        let base = root.standardizedFileURL.path + "/"
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en {
            try check()
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if CCMemorySync.isExcluded(name: url.lastPathComponent) {
                if v.isDirectory == true { en.skipDescendants() }
                continue
            }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if v.isSymbolicLink == true {
                if v.isDirectory == true { en.skipDescendants() }
                continue
            }
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(realRoot + "/") else {
                if v.isDirectory == true { en.skipDescendants() }
                continue
            }
            if v.isDirectory == true {
                if WikiStore.isValidFolderPath(rel) {
                    out.folders.append(rel)
                    let group = url.appendingPathComponent(WikiStore.groupFileName)
                    if isPlainFile(group), let data = try? Data(contentsOf: group) {
                        var lines = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                        if let hook = WikiPage.frontmatter(&lines)["钩子"], !hook.isEmpty { out.hooks[rel] = hook }
                    }
                } else {
                    en.skipDescendants()
                }
                continue
            }
            guard v.isRegularFile == true, rel.hasSuffix(".md"), url.lastPathComponent != WikiStore.indexFileName else { continue }
            let page = String(rel.dropLast(3))
            guard WikiStore.isValidPagePath(page), let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            out.pages.append(Page(path: page, text: text, version: WikiStore.version(of: data), page: WikiPage.parse(text, path: page)))
        }
        out.pages.sort { $0.path < $1.path }
        out.folders.sort()
        return out
    }

    private static func parent(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    public func count(under folder: String) -> Int {
        folder.isEmpty ? pages.count : pages.filter { $0.path.hasPrefix(folder + "/") }.count
    }

    public enum IndexRow: Equatable, Sendable {
        case folder(path: String, name: String, hook: String, pageCount: Int)
        case page(path: String, title: String, hook: String, version: String)
    }

    public func indexRows(_ folder: String) -> [IndexRow] {
        var out: [IndexRow] = []
        let children = folder.isEmpty ? WikiStore.branches : folders.filter { Self.parent($0) == folder }
        for sub in children {
            let n = count(under: sub)
            guard folder.isEmpty || n > 0 else { continue }
            out.append(.folder(path: sub, name: String(sub.split(separator: "/").last ?? ""), hook: hooks[sub] ?? "", pageCount: n))
        }
        for p in pages where Self.parent(p.path) == folder {
            out.append(.page(path: p.path, title: p.page.title + p.page.factDomainIndexTag, hook: p.page.hook, version: p.version))
        }
        return out
    }

    private func lines(_ folder: String) -> [String] {
        indexRows(folder).map { row in
            switch row {
            case .folder(let path, let name, let hook, let count):
                return "- [[\(path)/]] \(name)" + (hook.isEmpty ? "" : " — \(hook)") + "（\(count) 页）"
            case .page(let path, let title, let hook, _):
                return "- [[\(path)]] \(title)" + (hook.isEmpty ? "" : " — \(hook)")
            }
        }
    }

    /// 按真实文件算的这一层索引（形状同生成的 INDEX.md）
    public func index(_ folder: String) -> String {
        guard !folder.isEmpty else {
            var out = "# C 档案\n"
            for branch in WikiStore.branches where count(under: branch) > 0 {
                out += "\n## \(branch)" + (hooks[branch].map { " — \($0)" } ?? "") + "（\(count(under: branch)) 页）\n" + lines(branch).map { $0 + "\n" }.joined()
            }
            return out
        }
        return "# \(folder)\n\n" + lines(folder).map { $0 + "\n" }.joined()
    }

    public init(pages: [Page] = [], folders: [String] = [], hooks: [String: String] = [:], refused: String? = nil) {
        self.pages = pages
        self.folders = folders
        self.hooks = hooks
        self.refused = refused
    }
}
