import Foundation

/// 窗口总结 / 上下文摘要的读盘入口：界面只经这里拿「一个窗口」（plan-memory-migrate-3gen §六）。
/// 一个窗口 = A3 一段（windows/ 是一段从头压的才算；v4-1 抄本当「还没压」）+ A2（sessions/，没有就第一代当第 0 段）
public enum WindowSummaryReader {
    public struct Doc: Equatable {
        public var conversationId: String
        public var title: String
        public var a3: SessionSegment?
        /// A2：第 0 段 + 正式段 + 尾段，按时间
        public var a2: [SessionSegment]
        /// 老收尾段（v4，起点以前没搬的）：不注入、不进 A3，灰字放最下面
        public var oldCloseouts: [SessionSegment] = []
        /// windows/ 里认不成 A3 的旧窗口总结（v4-1 抄本，还没搬）：灰字一组，不算段数（astra #13）
        public var oldWindow: [SessionSegment] = []

        public var isEmpty: Bool { a3 == nil && a2.isEmpty && oldCloseouts.isEmpty && oldWindow.isEmpty }

        public init(conversationId: String, title: String, a3: SessionSegment? = nil, a2: [SessionSegment], oldCloseouts: [SessionSegment] = [], oldWindow: [SessionSegment] = []) {
            self.conversationId = conversationId
            self.title = title
            self.a3 = a3
            self.a2 = a2
            self.oldCloseouts = oldCloseouts
            self.oldWindow = oldWindow
        }
    }

    /// 纯函数：windows/ + sessions/ → 一个窗口
    public static func doc(conversationId: String, window w: SessionSummary?, context s: SessionSummary?) -> Doc {
        let segs = ordered(s?.segments ?? [])
        let title = [w?.title, s?.title].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let top = a3(w)
        return Doc(conversationId: conversationId, title: title, a3: top, a2: contextSegments(segs),
                   oldCloseouts: segs.filter { $0.kind == .closeout && !$0.isTail },
                   oldWindow: top == nil ? w?.segments ?? [] : [])
    }

    /// v5 的 A3：windows/ 只有一段、从头压的；v4-1 抄本（多段，或最后那段 from > 0）= 还没压
    public static func a3(_ w: SessionSummary?) -> SessionSegment? {
        guard let w, w.segments.count == 1, w.segments[0].from == 0 else { return nil }
        return w.segments[0]
    }

    /// 纯函数：改版前的累计摘要打头（它盖的是最前面那截），其余按开始时间先后；同一时间保持文件里的先后
    public static func ordered(_ segments: [SessionSegment]) -> [SessionSegment] {
        let legacy = segments.filter { $0.kind == .legacy }
        let rest = segments.enumerated()
            .filter { $0.element.kind != .legacy }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        return legacy + rest
    }

    /// 纯函数：A2 的段 = 第 0 段 + 正式段 + 尾段，不含老收尾段
    public static func contextSegments(_ segments: [SessionSegment]) -> [SessionSegment] {
        segments.filter { $0.kind != .window && ($0.kind != .closeout || $0.isTail) }
    }

    /// 段号现算：有改造前累计摘要它是第 0 段，没有从 1 数（同 `CatalogALineReader.numbered`）
    public static func number(_ index: Int, in a2: [SessionSegment]) -> Int {
        index + (a2.first?.kind == .legacy ? 0 : 1)
    }
}
