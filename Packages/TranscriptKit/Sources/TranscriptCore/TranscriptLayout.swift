import CoreGraphics

/// 对话页的一维排版：行从「起点」开始一行接一行往后排。
///
/// 起点 = 最新的消息。界面把整张列表上下翻过来显示（和旧页、Telegram 同法），所以起点在屏幕底部；
/// 这里只管一维坐标，不知道翻转这回事。
///
/// `leadingPad` 是起点之前的一段空白：键盘和输入条长高时把最新的消息顶上去的那块「垫块」。
public struct TranscriptLayout: Sendable {
    public struct Row: Equatable, Sendable {
        public var id: String
        /// 内容每变一次加一；高度按它失效
        public var version: Int
        /// 和前一行（更靠起点的那一行）之间的间距。第一行的不算
        public var gapBefore: CGFloat
        /// 没量过时按种类猜的高度
        public var estimatedHeight: CGFloat

        public init(id: String, version: Int = 0, gapBefore: CGFloat = 0, estimatedHeight: CGFloat) {
            self.id = id
            self.version = version
            self.gapBefore = gapBefore
            self.estimatedHeight = estimatedHeight
        }
    }

    public struct Frame: Equatable, Sendable {
        public var minY: CGFloat
        public var height: CGFloat
        public var maxY: CGFloat { minY + height }
    }

    public private(set) var rows: [Row] = []
    public private(set) var width: CGFloat
    public private(set) var leadingPad: CGFloat = 0
    public private(set) var heights = HeightTable()

    private var indexByID: [String: Int] = [:]
    /// 每行占的长度 = 行前间距 + 行高
    private var extents = PrefixSums()

    public init(width: CGFloat) {
        self.width = width
    }

    public var contentLength: CGFloat { leadingPad + extents.total }

    public func index(of id: String) -> Int? { indexByID[id] }

    // MARK: 改

    public mutating func setRows(_ next: [Row]) {
        rows = next
        indexByID = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($1.id, $0) })
        rebuild()
    }

    public mutating func setWidth(_ next: CGFloat) {
        guard next != width else { return }
        width = next
        rebuild()
    }

    public mutating func setLeadingPad(_ next: CGFloat) {
        leadingPad = max(0, next)
    }

    /// 记下一行的高度。返回排版有没有变。行不在当前列表里也会记（滚回来、切回分支时直接用）。
    @discardableResult
    public mutating func setHeight(_ height: CGFloat, tier: HeightTable.Tier, id: String, version: Int) -> Bool {
        guard heights.store(height, tier: tier, id: id, version: version, width: width),
              let index = indexByID[id] else { return false }
        let before = extents.values[index]
        extents.set(index, extent(at: index))
        return extents.values[index] != before
    }

    /// 高度表只留这些行的（换对话时调）
    public mutating func pruneHeights(retaining ids: Set<String>) {
        heights.prune(retaining: ids)
    }

    // MARK: 查

    public func height(at index: Int) -> HeightTable.Resolved {
        let row = rows[index]
        return heights.resolve(id: row.id, version: row.version, width: width, estimate: row.estimatedHeight)
    }

    public func frame(at index: Int) -> Frame {
        let height = height(at: index).height
        let end = leadingPad + extents.sum(upTo: index + 1)
        return Frame(minY: end - height, height: height)
    }

    public func frame(of id: String) -> Frame? {
        indexByID[id].map(frame(at:))
    }

    /// 和 `[minY, maxY]` 有交集的行。行间距里的空白不算任何一行。
    public func indices(intersecting minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        guard !rows.isEmpty, maxY >= minY else { return 0..<0 }
        var first = min(extents.index(containing: minY - leadingPad), rows.count)
        // 落在某一行的行前间距里：这一行其实还没开始，但它是从这里往后的第一行
        if first < rows.count, frame(at: first).maxY <= minY { first += 1 }
        var last = min(extents.index(containing: maxY - leadingPad), rows.count - 1)
        if last >= first, frame(at: last).minY >= maxY { last -= 1 }
        return last >= first ? first..<(last + 1) : first..<first
    }

    // MARK: -

    private func extent(at index: Int) -> CGFloat {
        (index == 0 ? 0 : rows[index].gapBefore) + height(at: index).height
    }

    private mutating func rebuild() {
        extents = PrefixSums(rows.indices.map(extent(at:)))
    }
}
