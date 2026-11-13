import Foundation

public enum WikiProposalSources {
    /// 路径里任何一段以 private_ 开头（大小写不论）的一律不碰
    public static func isPrivate(_ path: String) -> Bool {
        path.split(separator: "/").contains { CCMemorySync.isExcluded(name: String($0)) }
    }

    /// 文字里带 `[[私人页]]` 的那几行剥掉（历史 INDEX 回执 / 页里的连线）
    public static func strippingPrivateLinks(_ text: String) -> String {
        guard text.range(of: "private_", options: .caseInsensitive) != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        return lines.filter { !linksPrivate($0) }.joined(separator: "\n")
    }

    private static func linksPrivate(_ line: String) -> Bool {
        var rest = line[...]
        while let open = rest.range(of: "[[") {
            guard let close = rest[open.upperBound...].range(of: "]]") else { return false }
            if isPrivate(String(rest[open.upperBound..<close.lowerBound])) { return true }
            rest = rest[close.upperBound...]
        }
        return false
    }
}
