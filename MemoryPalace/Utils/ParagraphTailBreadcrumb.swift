#if DEBUG
import SwiftUI
import SwiftStreamingMarkdown

/// 段尾丢字探针 B（粟粟 10-31）：fork 段落视图排完版发现有字没排进视图高度 → 记一条面包屑。
/// 只带节点 id 前 8 位、泡序号、块序号、字数和尺寸，不带任何正文和标题。整个文件只进 Debug。
enum ParagraphTailBreadcrumb {
    /// 同一段同一尺寸只记一次（滚动回收、重排会反复报）
    nonisolated(unsafe) private static var logged = Set<String>()

    static func install() {
        ParagraphLayoutProbe.onTruncation = { report in
            let text = message(report)
            guard logged.insert(text).inserted else { return }
            if logged.count > 500 { logged.removeAll() }
            BreadcrumbLog.shared.add("✂️", text)
        }
    }

    /// 节点 id 前 8 位 + 气泡模式的泡序号；没有节点 = nil
    static func tag(nodeId: String?, bubble: Int?) -> String? {
        guard let nodeId else { return nil }
        return String(nodeId.prefix(8)) + (bubble.map { " 泡\($0)" } ?? "")
    }

    static func message(_ r: ParagraphLayoutProbe.Report) -> String {
        "段尾没排进来：\(r.tag ?? "无节点") 第\(r.block.map(String.init) ?? "?")块，少 \(r.missing) 字（共 \(r.length)）· 宽 \(pt(r.width)) 高 \(pt(r.height)) 需 \(pt(r.needed))"
    }

    private static func pt(_ v: CGFloat) -> String { String(format: "%.2f", v) }
}

extension EnvironmentValues {
    /// 气泡模式第几个泡（BubbleModeRow → ChatMarkdownView → 段落探针标记）
    @Entry var chatProbeBubbleIndex: Int? = nil
}
#endif
