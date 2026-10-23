import CoreGraphics

/// 一列里几个组怎么分尺寸（plan-panel-ps §3.2）。纯函数：列容器只管把结果画出来。
///
/// 纵列（左 / 右）分高，底列分宽，同一套：
/// 1. 折叠组 = `collapsedSize`（纵列 = tab 栏高）
/// 2. 展开组按 weight 分剩下的，每组 ≥ `bar + minBody`
/// 3. 放不下 → 展开组按比例压正文，最低压到只剩 tab 栏（正文 0，内容保活，同折叠）
/// 4. 全部折叠 → 多出的给 `remainder`（列尾空白）
/// 恒等：`Σsizes + seam × (n − 1) + remainder == total`，全部 ≥ 0
enum PanelColumnLayout {
    struct Item: Equatable {
        var weight: CGFloat
        var collapsed: Bool
    }

    struct Result: Equatable {
        var sizes: [CGFloat]
        /// 实际用的缝（总量连缝都放不下时按比例缩）
        var seam: CGFloat
        var remainder: CGFloat
    }

    /// 一列的权重：没记过的（新组）按这一列已记权重的均值算，全没记过 = 1。存档里的旧点数权重也照样按比例用
    static func weights(_ stored: [CGFloat?]) -> [CGFloat] {
        let known = stored.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        let fallback = known.isEmpty ? 1 : known.reduce(0, +) / CGFloat(known.count)
        return stored.map { w in
            guard let w, w.isFinite, w > 0 else { return fallback }
            return w
        }
    }

    static func extents(total: CGFloat, items: [Item], bar: CGFloat, seam: CGFloat, minBody: CGFloat,
                        collapsedSize: CGFloat? = nil) -> Result {
        let n = items.count
        guard n > 0 else { return Result(sizes: [], seam: 0, remainder: max(0, total)) }
        guard total > 0, total.isFinite else { return Result(sizes: Array(repeating: 0, count: n), seam: 0, remainder: 0) }
        let gaps = CGFloat(n - 1)
        let s = gaps > 0 ? min(seam, total / (gaps * 2)) : 0
        let avail = total - s * gaps
        let c = collapsedSize ?? bar
        let expanded = items.indices.filter { !items[$0].collapsed }
        let collapsedCount = CGFloat(n - expanded.count)

        // 连「折叠组 + 每个展开组一条 tab 栏」都放不下：平均分，谁也不多拿
        if collapsedCount * c + CGFloat(expanded.count) * bar > avail {
            return Result(sizes: Array(repeating: avail / CGFloat(n), count: n), seam: s, remainder: 0)
        }
        var sizes = items.map { $0.collapsed ? c : 0 }
        if expanded.isEmpty {
            return Result(sizes: sizes, seam: s, remainder: avail - collapsedCount * c)
        }
        let space = avail - collapsedCount * c
        let weights = expanded.map { i -> CGFloat in
            let w = items[i].weight
            return w.isFinite && w > 0 ? w : 1
        }
        let floor = bar + minBody
        if space >= CGFloat(expanded.count) * floor {
            // 注水：按比例分，不够下限的钉在下限，剩下的在其余里再按比例分
            var pinned = Set<Int>()
            while true {
                let freeSpace = space - CGFloat(pinned.count) * floor
                let freeWeight = expanded.indices.filter { !pinned.contains($0) }.reduce(0) { $0 + weights[$1] }
                var changed = false
                for k in expanded.indices where !pinned.contains(k) {
                    if freeSpace * weights[k] / freeWeight < floor { pinned.insert(k); changed = true }
                }
                if !changed {
                    for k in expanded.indices {
                        sizes[expanded[k]] = pinned.contains(k) ? floor : freeSpace * weights[k] / freeWeight
                    }
                    break
                }
            }
        } else {
            let body = space - CGFloat(expanded.count) * bar
            let totalWeight = weights.reduce(0, +)
            for k in expanded.indices { sizes[expanded[k]] = bar + body * weights[k] / totalWeight }
        }
        return Result(sizes: sizes, seam: s, remainder: 0)
    }

    /// 拖两个相邻展开组之间的缝：上（左）一个长 `delta`、下（右）一个短 `delta`，各自守住 `floor`。
    /// 返回新尺寸——列容器把它们原样写成 weight（weight 只看比例，用点数当 weight 最直观）
    static func dragSeam(sizes: [CGFloat], at seam: Int, delta: CGFloat, floor: CGFloat) -> [CGFloat] {
        guard sizes.indices.contains(seam), sizes.indices.contains(seam + 1) else { return sizes }
        var out = sizes
        let pair = sizes[seam] + sizes[seam + 1]
        guard pair >= 2 * floor else { return sizes }
        let upper = min(max(floor, sizes[seam] + delta), pair - floor)
        out[seam] = upper
        out[seam + 1] = pair - upper
        return out
    }
}

/// 组正文上的落点分三带（plan-panel-ps §4）：上 25% = 在这个组前面新开一组，下 25% = 后面新开一组，中间 = 并进来。
/// `position` / `extent` 是**正文**本地坐标（不含 tab 栏）；恰在 25% / 75% 归并入；正文高 0（折叠）只能并入
enum GroupBodyDrop {
    enum Zone: Equatable { case before, merge, after }

    static func resolve(position: CGFloat, extent: CGFloat) -> Zone {
        guard extent > 0, position.isFinite else { return .merge }
        if position < extent * 0.25 { return .before }
        if position > extent * 0.75 { return .after }
        return .merge
    }
}

/// 正文卡槽上的落点：贴左 / 右沿 = 停到那一列（列尾新开一组），贴底沿 = 底列，其余 = 浮出。角上底沿优先
enum CardDropZone {
    enum Zone: Equatable { case left, right, bottom, float }

    static let edgeBand: CGFloat = 48
    static let bottomBand: CGFloat = 60

    static func resolve(_ point: CGPoint, in size: CGSize, bottomEnabled: Bool) -> Zone {
        guard size.width > 0, size.height > 0 else { return .float }
        if bottomEnabled, point.y > size.height - bottomBand { return .bottom }
        if point.x < edgeBand { return .left }
        if point.x > size.width - edgeBand { return .right }
        return .float
    }
}
