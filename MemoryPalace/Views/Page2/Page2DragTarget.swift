#if os(iOS)
import UIKit

struct Page2DragTarget {
    let id: UUID
    let frame: CGRect
    var snapshotRequired = true
    var previewFrame: CGRect? = nil
    var visibleFrame: CGRect { previewFrame ?? frame }
}

#endif
