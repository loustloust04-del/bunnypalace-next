#if DEBUG && os(iOS)
import SwiftUI
import UIKit
import SwiftStreamingMarkdown
import TranscriptUIKit

// 重构 R3（docs/plan-重构.md「拆行方案」）：文章模式下一条消息拆出来的行。
// 尺寸和间距照旧页 `BubbleView.articleModeBody`；对不对由 TranscriptParityTests 的新旧对拍判定。

/// 文章模式的几个固定尺寸（旧页的出处写在每项后面）
enum ArticleMetrics {
    /// 列表左右留白（ChatMetrics.listInsetH，iOS）
    static let listInsetH: CGFloat = 16
    /// 署名和气泡之间、气泡和它下面的东西之间（articleModeBody 的 VStack spacing）
    static let partSpacing: CGFloat = 8
    /// 正文块与块之间（渲染包 BlockView 的 VStack spacing）
    static let blockSpacing = RenderableDocument.blockSpacing
    /// 你的消息卡最宽（articleModeBody `.frame(maxWidth: 500)`）
    static let userBubbleMaxWidth: CGFloat = 500
}

/// 署名：caption2 medium、textMuted；整行水平内缩 4，名字再朝正文一侧内缩 6
struct ArticleNameRow: TranscriptRowRenderer {
    let name: String
    let isUser: Bool
    let color: UIColor
    let displayScale: CGFloat

    let reuseIdentifier = "article.name"

    private static var font: UIFont {
        .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
    }

    /// SwiftUI 的 Text 把行高向上取到整像素（不是整点）：11pt 字在 3x 屏上是 13.33，不是 14
    func height(width: CGFloat) -> CGFloat { (Self.font.lineHeight * displayScale).rounded(.up) / displayScale }

    @MainActor func makeView() -> UIView { ArticleNameView() }

    @MainActor func configure(_ view: UIView, width: CGFloat) {
        guard let view = view as? ArticleNameView else { return }
        view.label.font = Self.font
        view.label.textColor = color
        view.label.text = name
        // 同 SwiftUI 的 Text：标签正好包住字（宽向上取到整像素），字从标签左边起排。
        // 整行右对齐的话字的起点落在小数像素上，抗锯齿和旧页差一截
        let textWidth = ((name as NSString).size(withAttributes: [.font: Self.font]).width * displayScale).rounded(.up) / displayScale
        let inset = ArticleMetrics.listInsetH + 4 + 6
        view.label.frame = CGRect(x: isUser ? width - inset - textWidth : inset, y: 0,
                                  width: textWidth, height: height(width: width))
    }
}

final class ArticleNameView: UIView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        label.backgroundColor = .clear
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 nib 建") }
}

/// 气泡里的一个正文块。气泡底按行切片：这一行只画属于自己的那一段，上下相邻的行接起来就是整张气泡
struct ArticleBlockRow: TranscriptRowRenderer, @unchecked Sendable {
    /// 这一块排好的样子（主线程排的）
    let layout: MarkdownBlockLayout
    let config: MarkdownRenderConfig
    /// 这条消息整张气泡的宽（= 最宽的一块 + 两侧内边距）
    let bubbleWidth: CGFloat
    let isUser: Bool
    let isFirst: Bool
    let isLast: Bool
    let fill: UIColor
    let cornerRadius: CGFloat
    let paddingH: CGFloat
    let paddingV: CGFloat

    let reuseIdentifier = "article.block"

    private var topInset: CGFloat { isFirst ? paddingV : ArticleMetrics.blockSpacing }
    private var bottomInset: CGFloat { isLast ? paddingV : 0 }

    func height(width: CGFloat) -> CGFloat { topInset + layout.size.height + bottomInset }

    @MainActor func makeView() -> UIView { ArticleBubbleSliceView() }

    @MainActor func configure(_ view: UIView, width: CGFloat) {
        guard let slice = view as? ArticleBubbleSliceView else { return }
        let bubbleX = isUser ? width - ArticleMetrics.listInsetH - bubbleWidth : ArticleMetrics.listInsetH
        slice.apply(bubbleFrame: CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: height(width: width)),
                    fill: fill, cornerRadius: cornerRadius, roundsTop: isFirst, roundsBottom: isLast)
        slice.block.frame = CGRect(origin: CGPoint(x: bubbleX + paddingH, y: topInset), size: layout.size)
        slice.block.apply(layout, config: config)
    }
}

final class ArticleBubbleSliceView: UIView {
    let block = MarkdownBlockView(frame: .zero)
    private let background = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true        // 卡底图层会故意画出这一行（见 apply），多出来的裁掉
        layer.addSublayer(background)
        addSubview(block)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 nib 建") }

    func apply(bubbleFrame: CGRect, fill: UIColor, cornerRadius: CGFloat, roundsTop: Bool, roundsBottom: Bool) {
        // 同 SwiftUI 画 RoundedRectangle 的办法（11-12 看旧页图层树）：一个带底色的普通图层，连续曲率圆角
        var corners: CACornerMask = []
        if roundsTop { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if roundsBottom { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 默认主题下助手的卡底是全透明的：不画
        background.isHidden = fill.cgColor.alpha == 0
        // 连续曲率的圆角要占掉约 1.53 倍半径的边长；这一行如果比它矮，系统会把圆角压扁，和整张卡的圆角不一样。
        // 所以只圆一头的切片朝没圆角的那头多画一截（被 clipsToBounds 裁掉），让圆角按整张卡的形状算
        var frame = bubbleFrame
        let spill = cornerRadius * 4
        if roundsTop, !roundsBottom { frame.size.height += spill }
        if roundsBottom, !roundsTop { frame.origin.y -= spill; frame.size.height += spill }
        background.frame = frame
        background.backgroundColor = fill.cgColor
        background.cornerRadius = cornerRadius
        background.cornerCurve = .continuous
        background.contentsScale = traitCollection.displayScale
        background.allowsEdgeAntialiasing = true
        background.maskedCorners = corners
        CATransaction.commit()
    }
}

/// 还没有原生实现的块：占个位，把高度和「是什么」画出来，对拍时一眼能看到缺哪种
struct ArticlePendingBlockRow: TranscriptRowRenderer {
    let label: String
    let reuseIdentifier = "article.pending"

    func height(width: CGFloat) -> CGFloat { 44 }

    @MainActor func makeView() -> UIView {
        let label = UILabel()
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabel
        label.backgroundColor = UIColor.systemGray.withAlphaComponent(0.12)
        return label
    }

    @MainActor func configure(_ view: UIView, width: CGFloat) {
        (view as? UILabel)?.text = label
    }
}
#endif
