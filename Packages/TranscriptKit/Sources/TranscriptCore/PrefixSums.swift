import CoreGraphics

/// 树状数组上的一列非负长度：改一项、求前 n 项之和、按累计长度找是第几项，都是 O(log n)。
/// 一万行的对话里某一行长高了，不用把后面所有行的位置重算一遍。
struct PrefixSums: Sendable {
    private var tree: [CGFloat]          // 1 起始
    private(set) var values: [CGFloat]

    init(_ values: [CGFloat] = []) {
        self.values = values
        tree = [0] + values
        for i in 1..<tree.count {
            let parent = i + (i & -i)
            if parent < tree.count { tree[parent] += tree[i] }
        }
    }

    var count: Int { values.count }

    var total: CGFloat { sum(upTo: count) }

    mutating func set(_ index: Int, _ value: CGFloat) {
        let delta = value - values[index]
        guard delta != 0 else { return }
        values[index] = value
        var i = index + 1
        while i < tree.count {
            tree[i] += delta
            i += i & -i
        }
    }

    /// `values[0..<index]` 之和
    func sum(upTo index: Int) -> CGFloat {
        var result: CGFloat = 0
        var i = index
        while i > 0 {
            result += tree[i]
            i -= i & -i
        }
        return result
    }

    /// 累计长度 `offset` 落在第几项里：最小的 i 使 `sum(upTo: i + 1) > offset`。
    /// `offset` 在全部之后返回 `count`；负数返回 0。
    func index(containing offset: CGFloat) -> Int {
        guard offset >= 0 else { return 0 }
        var position = 0
        var remaining = offset
        var step = 1
        while step << 1 < tree.count { step <<= 1 }
        while step > 0 {
            let next = position + step
            if next < tree.count, tree[next] <= remaining {
                position = next
                remaining -= tree[next]
            }
            step >>= 1
        }
        return position
    }
}
