#if os(iOS)
import SwiftUI

// MARK: - 十字绣风像素点阵插画
//
// 网格字符串（'x'=有点，'.'/空格=空）→ 墨绿圆点，Canvas 绘制。
// 与 docs/未来愿景/onboarding-proto.html 的 PIX_MOTIFS 是同一组网格，改了一边记得同步另一边。
// 参考风格：十字绣 flash 图（奶油底 + 深绿小点组成的稀疏轮廓），不要用 emoji。

enum PixelMotif {
    case sprout     // 小芽（双叶苗）—— S0 欢迎 / 小白
    case key        // 钥匙 —— S2 Provider
    case spark      // 四芒星 —— S3 模型
    case blossom    // 开花 —— S4 教练 / S5
    case heart      // 心 —— S1.5 称呼 / 长期陪伴
    case ghostie    // 小幽灵 —— 保持神秘
    case gear       // 齿轮 —— 技术用户
    case card       // 卡片 —— 酒馆用户
    case quill      // 羽毛笔 —— S2「Ta叫什么名字」
    case fork       // 园艺叉 —— S1 身份 hero

    var grid: [String] {
        switch self {
        case .sprout:
            return [
                ".xxx....xxx..",
                "x...x..x...x.",
                "x....xx....x.",
                "x...x..x...x.",
                ".xxx....xxx..",
                "......x......",
                "......x......",
                "......x......",
                "..x...x...x..",
                "...x.xxx.x...",
                ".....xxx.....",
            ]
        case .key:
            // 复古钥匙 v3：学原版（宝冠 + 双椭圆环 + 旗形齿），左上/右下星芒点缀
            return [
                ".x.....x.......",
                "x.x...x.x......",
                ".x...x...x.....",
                "......x.x......",
                ".......x.......",
                "......x.x......",
                ".xxx...x...xxx.",
                "x...x.....x...x",
                "x...x.....x...x",
                "x...x.....x...x",
                ".xxx...x...xxx.",
                ".......x.......",
                "......xxx......",
                ".......x.......",
                ".......x.......",
                ".......x.......",
                ".......xxxxx...",
                ".......x...x...",
                ".......x...x...",
                ".......x...x...",
                ".......xxx.x...",
                ".......x....x..",
                "...........x.x.",
                "............x..",
            ]
        case .spark:
            return [
                ".....x.....",
                ".....x.....",
                "....x.x....",
                ".....x.....",
                "x..x...x..x",
                ".x..x.x..x.",
                "x..x...x..x",
                ".....x.....",
                "....x.x....",
                ".....x.....",
                ".....x.....",
            ]
        case .blossom:
            return [
                "....x.x.x....",
                ".....x.x.....",
                ".x.x.....x.x.",
                "..x..xxx..x..",
                "x....x.x....x",
                "..x..xxx..x..",
                ".x.x.....x.x.",
                ".....x.x.....",
                "....x.x.x....",
                "......x......",
                "..x...x...x..",
                "...x..x..x...",
                "....xxxxx....",
            ]
        case .heart:
            return [
                ".xxx...xxx.",
                "x...x.x...x",
                "x....x....x",
                "x.........x",
                ".x.......x.",
                "..x.....x..",
                "...x...x...",
                "....x.x....",
                ".....x.....",
            ]
        case .ghostie:
            return [
                "...xxxxxx...",
                "..x......x..",
                ".x........x.",
                ".x..x..x..x.",
                ".x........x.",
                ".x........x.",
                ".x........x.",
                ".x..x..x..x.",
                "..x.x..x.x..",
            ]
        case .gear:
            return [
                "..x.....x..",
                "...x...x...",
                ".x..xxx..x.",
                "..x.x.x.x..",
                "....xxx....",
                "..x.x.x.x..",
                ".x..xxx..x.",
                "...x...x...",
                "..x.....x..",
            ]
        case .card:
            return [
                ".xxxxxxxxxx.",
                ".x........x.",
                ".x..x..x..x.",
                ".x........x.",
                ".x...xx...x.",
                ".x...xx...x.",
                ".x........x.",
                ".x..x..x..x.",
                ".x........x.",
                ".xxxxxxxxxx.",
            ]
        case .quill:
            return [
                "......xxx..",
                ".....x..xx.",
                "....x....x.",
                "...x..x..x.",
                "..x..x..x..",
                "..x.x..x...",
                ".x.x..x....",
                ".x.x.x.....",
                "..xx.......",
                "..x........",
                ".x.........",
                "x..........",
            ]
        case .fork:
            return [
                ".x..x..x.",
                ".x..x..x.",
                ".x..x..x.",
                ".x..x..x.",
                "..x.x.x..",
                "...xxx...",
                "....x....",
                "....x....",
                "....x....",
            ]
        }
    }
}

/// 点阵画布：`scale` 是每格边长（pt），点是半径 0.27×scale 的圆（圆点比方块更像十字绣）。
struct PixelArtView: View {
    let motif: PixelMotif
    var scale: CGFloat = 5
    var color: Color = Color(hex: 0x2E5233)

    private var grid: [String] { motif.grid }
    private var cols: Int { grid.map(\.count).max() ?? 0 }
    private var rows: Int { grid.count }

    var body: some View {
        Canvas { ctx, _ in
            let r = scale * 0.27
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() where ch == "x" {
                    let cx = CGFloat(x) * scale + scale / 2
                    let cy = CGFloat(y) * scale + scale / 2
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(width: CGFloat(cols) * scale, height: CGFloat(rows) * scale)
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 20) {
        PixelArtView(motif: .sprout, scale: 8)
        HStack(spacing: 24) {
            PixelArtView(motif: .sprout, scale: 4)
            PixelArtView(motif: .spark, scale: 4)
            PixelArtView(motif: .blossom, scale: 4)
        }
    }
    .padding()
    .background(Color(hex: 0xFFFCF8))
}
#endif
