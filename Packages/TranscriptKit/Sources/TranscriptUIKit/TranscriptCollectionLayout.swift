#if canImport(UIKit)
import UIKit
import TranscriptCore

/// 自己不存任何高度和位置：每一行在哪、多高，都问引擎里那一份 `TranscriptLayout`。
final class TranscriptCollectionLayout: UICollectionViewLayout {
    var source: () -> TranscriptLayout = { TranscriptLayout(width: 0) }

    override var collectionViewContentSize: CGSize {
        let layout = source()
        return CGSize(width: layout.width, height: layout.contentLength)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let layout = source()
        return layout.indices(intersecting: rect.minY, rect.maxY).map { attributes(at: $0, in: layout) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let layout = source()
        guard indexPath.item < layout.rows.count else { return nil }
        return attributes(at: indexPath.item, in: layout)
    }

    /// 尺寸变化由控制器当成事务交给引擎，这里不自己失效
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }

    /// 排版失效，同一次排版里把位置加上 `offsetAdjustment`
    func invalidate(offsetAdjustment: CGFloat) {
        let context = UICollectionViewLayoutInvalidationContext()
        context.contentOffsetAdjustment = CGPoint(x: 0, y: offsetAdjustment)
        invalidateLayout(with: context)
    }

    private func attributes(at index: Int, in layout: TranscriptLayout) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        let frame = layout.frame(at: index)
        attributes.frame = CGRect(x: 0, y: frame.minY, width: layout.width, height: frame.height)
        return attributes
    }
}
#endif
