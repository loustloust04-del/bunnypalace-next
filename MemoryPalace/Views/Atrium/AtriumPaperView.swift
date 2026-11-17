#if os(iOS)
import SwiftUI

/// atrium 背景：粟粟 11-14 给的「花园撕贴纸」。同日二改：贴纸缩小、不能撕、挪到底部安全区，
/// 所以不再跑 WebGL，只是两张静态图（`Resources/Atrium/`）：整屏的纸 + 底部一小条景
enum AtriumPaper {
    private static func image(_ name: String, _ ext: String) -> UIImage? {
        Bundle.main.path(forResource: name, ofType: ext).flatMap(UIImage.init(contentsOfFile:))
    }

    static let paper = image("atrium-paper", "jpg")
    static let scene = image("atrium-scene", "png")

    /// 整屏的纸
    struct Background: View {
        var body: some View {
            if let paper = AtriumPaper.paper {
                Image(uiImage: paper).resizable().scaledToFill()
            } else {
                Color(red: 250 / 255, green: 247 / 255, blue: 244 / 255)
            }
        }
    }

    /// 底部那条景（树、猫、郁金香、两棵蓝花草、月亮、云，按原画位置等比缩小）：单独占一行，列表不会压上去
    struct Scene: View {
        var body: some View {
            if let scene = AtriumPaper.scene {
                Image(uiImage: scene).resizable().scaledToFit()
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
#endif
