#if os(macOS)
import Foundation

/// 会话正文里的链接（Wake `markdown_links.rs`）：路径归属来自会话，不能从本机同名文件推断。外链交系统；本机会话的文件路径按原字面 →
/// 百分号解码一次 → 去掉 `:行号` 再试（相对路径按项目目录、`~` 按 HOME），存在就在 Finder 里选中；远程会话的路径一律不碰本机
enum CodingLinkResolver {
    enum Target: Equatable {
        case external
        case file(URL)
        /// 远程会话的文件路径：rsync 只镜像会话数据，远端路径在本机没有意义
        case remote
        case unavailable
        case ignore
    }

    /// - Parameter home: 只在需要展开 `~` 时才取（远程与外链不得碰本机 HOME）
    static func resolve(_ href: String, remote: Bool, projectPath: String, home: () -> URL?) -> Target {
        if href.isEmpty || href.hasPrefix("#") { return .ignore }
        // 盘符须先于 scheme 识别，否则 C:/... 会被交给 URL 打开器
        let windows = windowsPath(href)
        var scheme = windows ? nil : urlScheme(href)
        // 裸文件名 + 行号（main.rs:11）也符合 scheme 语法：带点的 scheme 后面只跟行号时按文件处理
        if let found = scheme, found.contains("."), withoutLineNumber(href) == found { scheme = nil }
        if let found = scheme, found.lowercased() != "file" { return .external }
        if remote { return .remote }
        if windows || hasControl(href) { return .unavailable }
        if scheme != nil {
            guard let path = fileURIPath(href) else { return .unavailable }
            if exists(path) { return .file(path) }
            if let bare = withoutLineNumber(href), let path = fileURIPath(bare), isFile(path) { return .file(path) }
            return .unavailable
        }
        let homeURL = home()
        if let path = existingLocalPath(href, projectPath: projectPath, home: homeURL) { return .file(path) }
        if let bare = withoutLineNumber(href), let path = existingLocalPath(bare, projectPath: projectPath, home: homeURL), isFile(path) {
            return .file(path)
        }
        return .unavailable
    }

    private static func existingLocalPath(_ href: String, projectPath: String, home: URL?) -> URL? {
        // 裸路径先按原字面找，保留真实文件名里的 % # ? 等字符；Markdown href 也可能编码了空格 / 中文，只解码一次
        if let path = localPath(href, projectPath: projectPath, home: home), exists(path) { return path }
        if href.contains("%"), let decoded = href.removingPercentEncoding,
           let path = localPath(decoded, projectPath: projectPath, home: home), exists(path) {
            return path
        }
        return nil
    }

    /// 完整文件名不存在时才试 `:行号`（先于百分号解码，免得把文件名里的 %3A 当定位符）；Finder 只选中文件，不跳到行
    private static func withoutLineNumber(_ href: String) -> String? {
        guard let colon = href.lastIndex(of: ":") else { return nil }
        let path = href[..<colon]
        let line = href[href.index(after: colon)...]
        guard !path.isEmpty, !line.isEmpty, line.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(line), number > 0 else { return nil }
        return String(path)
    }

    private static func urlScheme(_ href: String) -> String? {
        guard let colon = href.firstIndex(of: ":") else { return nil }
        let scheme = href[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        return String(scheme)
    }

    private static func windowsPath(_ path: String) -> Bool {
        let b = Array(path.utf8)
        let slash = UInt8(ascii: "/"), backslash = UInt8(ascii: "\\")
        if path.hasPrefix("\\\\") { return true }
        guard b.count >= 2, (b[0] >= 65 && b[0] <= 90) || (b[0] >= 97 && b[0] <= 122), b[1] == UInt8(ascii: ":") else { return false }
        return b.count == 2 || b[2] == backslash || (b[2] == slash && (b.count < 4 || b[3] != slash))
    }

    private static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// `file:` URI → 本机绝对路径。file:relative 与反斜杠不猜；只认空 host 或 localhost；带 query / fragment 的不认
    private static func fileURIPath(_ href: String) -> URL? {
        guard let colon = href.firstIndex(of: ":"), href[href.index(after: colon)...].hasPrefix("/"), !href.contains("\\"),
              let url = URL(string: href) else { return nil }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
        guard url.query == nil, url.fragment == nil else { return nil }
        let path = url.path
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !windowsPath(String(path.drop { $0 == "/" })) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func localPath(_ href: String, projectPath: String, home: URL?) -> URL? {
        if href.isEmpty || href.hasPrefix("#") || href.hasPrefix("?") || href.hasPrefix("//") || windowsPath(href) || hasControl(href) {
            return nil
        }
        if href == "~" { return home }
        if href.hasPrefix("~/") { return home?.appendingPathComponent(String(href.dropFirst(2).drop { $0 == "/" })) }
        if href.hasPrefix("~") { return nil }
        if href.hasPrefix("/") { return URL(fileURLWithPath: href) }
        var isDir: ObjCBool = false
        guard projectPath.hasPrefix("/"), FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(href)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }
}
#endif
