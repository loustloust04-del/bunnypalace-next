import SwiftUI

/// 图表卡 v2 的配色 / 字号（docs/plan-chart-cards-v2.md）。照 lieflat-charts 的 Mono 语法：
/// 墨 + 7 级灰阶，明度即数据（最重要的系列最黑）；一律实心，无阴影无渐变。
/// 焦点色只有一个：app 的薄荷，只给选中项。卡底是 ChatCardShell 固定的米白，所以这里都是浅色值。
enum ChartInk {
    static let ladder: [Color] = ([0x1C1C1A, 0x4A4944, 0x6A6963, 0x8F8E88, 0xB0AFA9, 0xC6C5BF, 0xD8D7D1] as [UInt]).map { Color(hex: $0) }
    static let ink = ladder[0]
    static let muted = Color(hex: 0x8F8E88)
    static let faint = Color(hex: 0xC6C5BF)
    static let grid = Color(hex: 0xDEDDD6)
    static var focus: Color { Theme.branchIndicator }

    /// 多系列按重要性沿灰阶取：第一条最黑，之后拉开间隔
    static func series(_ i: Int, of n: Int) -> Color {
        let steps: [[Int]] = [[0], [0, 4], [0, 3, 5], [0, 2, 4, 6]]
        let row = steps[max(0, min(n, 4) - 1)]
        return ladder[row[i % row.count]]
    }

    /// 环的各段：按值大小排名取深浅（最大的最黑），排第 6 往后都用最浅一级
    static func rank(_ r: Int) -> Color { ladder[[0, 2, 3, 4, 5, 6][min(r, 5)]] }

    // 字号（pt）：标题 / 说明 / 来源 / 图内数值 / 轴
    static let titleFont = Font.system(size: 16.5, weight: .semibold)
    static let subFont = Font.system(size: 11.5)
    static let sourceFont = Font.system(size: 9.5, weight: .medium)
    static func valueFont(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .heavy).monospacedDigit() }
    static let axisFont = Font.system(size: 9.5, weight: .semibold)
}
