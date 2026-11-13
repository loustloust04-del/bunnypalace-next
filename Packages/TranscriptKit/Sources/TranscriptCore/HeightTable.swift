import CoreGraphics

/// 每行的高度，三档可信度。键 = 行 id + 内容版本 + 宽。
/// 内容或宽变了以后旧高度不删：在新高度量出来之前，它是比「估算」好得多的猜测，
/// 画面不会先塌成估算高度再弹回去。
public struct HeightTable: Sendable {
    public enum Tier: Int, Comparable, Sendable {
        /// 没量过，按种类猜的
        case estimated
        /// 后台预排版算的
        case prepared
        /// 界面上实际排出来的
        case measured

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Resolved: Equatable, Sendable {
        public var height: CGFloat
        public var tier: Tier
        /// 高度是按旧的内容版本或旧的宽量的
        public var stale: Bool
    }

    private struct Entry: Sendable {
        var version: Int
        var width: CGFloat
        var height: CGFloat
        var tier: Tier
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// 记一个高度。同一个键下，低档不覆盖高档；键变了就整条换掉。返回这一行解析出的高度有没有变。
    @discardableResult
    public mutating func store(_ height: CGFloat, tier: Tier, id: String, version: Int, width: CGFloat) -> Bool {
        guard height > 0.5 else { return false }
        if let old = entries[id], old.version == version, old.width == width {
            guard tier >= old.tier else { return false }
            entries[id] = Entry(version: version, width: width, height: height, tier: tier)
            return old.height != height
        }
        let previous = entries[id]?.height
        entries[id] = Entry(version: version, width: width, height: height, tier: tier)
        return previous != height
    }

    public func resolve(id: String, version: Int, width: CGFloat, estimate: CGFloat) -> Resolved {
        guard let entry = entries[id] else {
            return Resolved(height: estimate, tier: .estimated, stale: false)
        }
        if entry.version == version, entry.width == width {
            return Resolved(height: entry.height, tier: entry.tier, stale: false)
        }
        return Resolved(height: entry.height, tier: .estimated, stale: true)
    }

    public mutating func prune(retaining ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
