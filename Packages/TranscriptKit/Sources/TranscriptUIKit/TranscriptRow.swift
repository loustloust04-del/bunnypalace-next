#if canImport(UIKit)
import UIKit
import TranscriptCore

/// 一种行怎么量、怎么画。实现必须是不可变的值：`height(width:)` 会在后台线程被调。
public protocol TranscriptRowRenderer: Sendable {
    /// 同一种行共用同一批视图
    var reuseIdentifier: String { get }
    /// 给定宽度下的高度。高度只从这里来，cell 不自己量（Telegram 的 layout / apply 两段）
    func height(width: CGFloat) -> CGFloat
    @MainActor func makeView() -> UIView
    @MainActor func configure(_ view: UIView, width: CGFloat)
}

/// 对话页上的一行。一条消息通常是好几行（头、每个内容块、尾）
public struct TranscriptRow: Sendable {
    public var id: String
    /// 内容每变一次加一
    public var version: Int
    /// 和前一行（更新的那一行）之间的间距
    public var gapBefore: CGFloat
    /// 还没量出来时先占这么高
    public var estimatedHeight: CGFloat
    public var renderer: any TranscriptRowRenderer

    public init(id: String, version: Int = 0, gapBefore: CGFloat = 0, estimatedHeight: CGFloat = 44,
                renderer: any TranscriptRowRenderer) {
        self.id = id
        self.version = version
        self.gapBefore = gapBefore
        self.estimatedHeight = estimatedHeight
        self.renderer = renderer
    }

    var layoutRow: TranscriptLayout.Row {
        .init(id: id, version: version, gapBefore: gapBefore, estimatedHeight: estimatedHeight)
    }
}

extension CGAffineTransform {
    /// 上下翻转。必须写成「转 180° 再左右镜像」，不能写 scaleY(-1)：两者数学上相同，但前者的矩阵里留着 sin π 的
    /// 浮点余数，合成器按「非轴对齐」处理，圆角 / 抗锯齿边缘的取整不一样。旧页（SwiftUI rotationEffect + scaleEffect）
    /// 走的是这条路，11-12 像素对拍实测：换成 scaleY(-1) 每个圆角差 1 个色阶
    static let transcriptFlip = CGAffineTransform(rotationAngle: .pi).concatenating(CGAffineTransform(scaleX: -1, y: 1))
}

/// 列表整体上下翻过来显示（起点 = 最新 = 屏幕底部），每个 cell 的内容再翻回正
final class TranscriptCell: UICollectionViewCell {
    private(set) var hosted: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = .transcriptFlip
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 nib 建") }

    func host(_ row: TranscriptRow, width: CGFloat) {
        let view: UIView
        if let hosted {
            view = hosted
        } else {
            view = row.renderer.makeView()
            view.frame = contentView.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(view)
            hosted = view
        }
        row.renderer.configure(view, width: width)
    }
}
#endif
