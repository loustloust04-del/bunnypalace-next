#if PERSONAL_APPS
import Foundation
import SwiftStreamingMarkdown

/// 聊天正文 `$NVDA` → `[$NVDA](ticker://open/NVDA)`（markdown link 化，自动薄荷绿可点）。
/// 纯函数可测。只认大写 1-5 位（拍板，美股正股）；跳过 fenced code block、行内 `code`、
/// 已有 markdown link 内部；`$100`/`US$` 不命中。
/// scheme 走 `ticker://open/<sym>` 路径形式（host 会被 Foundation 小写化，vocabnote 同款绕法）。
enum TickerLinkifier {

    /// 前面不能是字母/数字/$（防 US$、A$X），后面不能是字母/数字（防 $NVDAx）。
    private static let tickerPattern = try! NSRegularExpression(
        pattern: #"(?<![\w$])\$([A-Z]{1,5})(?![A-Za-z0-9])"#)
    /// 行内占用区：行内代码 `...` 与已有 link [..](..)——里面的 $ 不动。
    private static let occupiedPattern = try! NSRegularExpression(
        pattern: #"`[^`\n]*`|\[[^\]\n]*\]\([^)\n]*\)"#)

    static func linkify(_ md: String) -> String {
        guard md.contains("$") else { return md }
        let md = MarkdownFenceNormalizer.normalize(md)   // 同长度嵌套围栏先推断改写
        var out: [String] = []
        var fence = MarkdownFenceTracker()
        var changed = false
        for lineSub in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            if fence.consume(line) || !line.contains("$") {
                out.append(line)
                continue
            }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            // 行内公式 `$E = mc^2$` 也是占用区：不然 `$E` 会被当成股票代码
            let occupied = occupiedPattern.matches(in: line, range: full).map(\.range)
                + InlineDollarMath.spans(in: line).map { NSRange($0, in: line) }
            var result = line
            for m in tickerPattern.matches(in: line, range: full).reversed() {
                if occupied.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                let sym = ns.substring(with: m.range(at: 1))
                result = (result as NSString).replacingCharacters(
                    in: m.range, with: "[$\(sym)](ticker://open/\(sym))")
                changed = true
            }
            out.append(result)
        }
        return changed ? out.joined(separator: "\n") : md
    }

    // MARK: - 缓存（聊天渲染热路径 13× 放大教训：按 node.id 缓存，命中先比源串防流式增长脏读）

    private final class Box {
        let source: String
        let output: String
        init(source: String, output: String) { self.source = source; self.output = output }
    }
    private static let cache = NSCache<NSString, Box>()

    /// cacheKey = node.id；nil（流式尾巴/无节点语境）直接算不缓存。
    static func linkifyCached(_ md: String, cacheKey: String?) -> String {
        guard let key = cacheKey else { return linkify(md) }
        if let hit = cache.object(forKey: key as NSString), hit.source == md {
            return hit.output
        }
        let out = linkify(md)
        cache.setObject(Box(source: md, output: out), forKey: key as NSString)
        return out
    }
}
#endif
