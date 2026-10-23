#if os(iOS)
import SwiftUI
import UIKit

struct Page2StackEditorCards: UIViewControllerRepresentable {
    let items: [Page2Item]
    let layout: Page2Layout
    let cardSize: CGSize
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onReorder: (Page2Layout, [UUID]) -> Void
    let onRemove: (UUID) -> Void
    let onExternalDrag: (UIGestureRecognizer.State, Page2Item, CGPoint, CGRect) -> Bool
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> Controller {
        Controller(items: items, layout: layout, cardSize: cardSize, selectedID: selectedID, environment: environment,
                   onSelect: onSelect, onReorder: onReorder, onRemove: onRemove, onExternal: onExternalDrag)
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(items: items, layout: layout, cardSize: cardSize, selectedID: selectedID, environment: environment)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }

    final class Controller: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
        private var items: [Page2Item]
        private var snapshot: Page2Layout
        private var cardSize: CGSize
        private var inherited: EnvironmentValues
        private var selectedID: UUID?
        private let onSelect: (UUID) -> Void
        private let onReorder: (Page2Layout, [UUID]) -> Void
        private let onRemove: (UUID) -> Void
        private let onExternal: (UIGestureRecognizer.State, Page2Item, CGPoint, CGRect) -> Bool
        private let flow = CardLayout()
        private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
        private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(handleReorder(_:)))
        private var baseline: Page2Layout?
        private var originalItems: [Page2Item]?
        private var dragged: Page2Item?
        private var outside = false
        private var originalFrame: CGRect = .zero
        private var originalTouch = CGPoint.zero
        private var laidOut = false

        init(items: [Page2Item], layout: Page2Layout, cardSize: CGSize, selectedID: UUID?, environment: EnvironmentValues,
             onSelect: @escaping (UUID) -> Void, onReorder: @escaping (Page2Layout, [UUID]) -> Void,
             onRemove: @escaping (UUID) -> Void, onExternal: @escaping (UIGestureRecognizer.State, Page2Item, CGPoint, CGRect) -> Bool) {
            self.items = items; snapshot = layout; self.cardSize = cardSize; self.selectedID = selectedID; inherited = environment
            self.onSelect = onSelect; self.onReorder = onReorder; self.onRemove = onRemove; self.onExternal = onExternal
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            overrideUserInterfaceStyle = inherited.colorScheme == .dark ? .dark : .light
            collection.backgroundColor = .clear
            collection.contentInsetAdjustmentBehavior = .never
            collection.showsVerticalScrollIndicator = false
            collection.decelerationRate = .fast
            collection.clipsToBounds = true
            collection.layer.cornerRadius = 42
            collection.dataSource = self; collection.delegate = self
            collection.accessibilityIdentifier = "page2.stack-editor-cards"
            collection.accessibilityValue = items.map { Page2WidgetCatalog.name($0.widgetKind ?? "") }.joined(separator: "、")
            collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "widget")
            hold.minimumPressDuration = 0.3
            collection.addGestureRecognizer(hold)
            view.addSubview(collection)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            collection.frame = view.bounds
            if flow.itemSize != cardSize {
                flow.itemSize = cardSize
                flow.minimumLineSpacing = -cardSize.height * 0.135
                flow.invalidateLayout()
            }
            if !laidOut, !items.isEmpty, view.bounds.height > 0 {
                laidOut = true
                collection.layoutIfNeeded()
                let index = items.firstIndex { $0.id == selectedID } ?? 0
                collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
            }
        }
        func configure(items: [Page2Item], layout: Page2Layout, cardSize: CGSize, selectedID: UUID?, environment: EnvironmentValues) {
            if let baseline, baseline != layout { cancelMove() }
            inherited = environment; snapshot = layout
            overrideUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
            collection.accessibilityValue = items.map { Page2WidgetCatalog.name($0.widgetKind ?? "") }.joined(separator: "、")
            guard baseline == nil else { return }
            if self.items != items || self.cardSize != cardSize || self.selectedID != selectedID {
                self.items = items; self.cardSize = cardSize; self.selectedID = selectedID; laidOut = false
                if isViewLoaded { collection.reloadData(); view.setNeedsLayout() }
            }
        }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "widget", for: indexPath)
            let item = items[indexPath.item]
            cell.backgroundColor = .clear
            cell.backgroundConfiguration = .clear()
            let size = cardSize, environment = inherited, remove = onRemove
            cell.contentConfiguration = UIHostingConfiguration {
                Page2HostedContent(content: Card(item: item, size: size, onRemove: { remove(item.id) }), environment: environment)
            }.margins(.all, 0).background { Color.clear }
            return cell
        }
        func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { true }
        func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
            guard baseline != nil, !outside, items.indices.contains(sourceIndexPath.item), items.indices.contains(destinationIndexPath.item) else { return }
            let moved = items.remove(at: sourceIndexPath.item)
            items.insert(moved, at: destinationIndexPath.item)
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { selectCentered() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { selectCentered() } }
        private func selectCentered() {
            guard baseline == nil, !items.isEmpty else { return }
            let middle = collection.contentOffset.y + collection.bounds.height / 2
            let pitch = max(1, cardSize.height + flow.minimumLineSpacing)
            let index = min(items.count - 1, max(0, Int(((middle - cardSize.height / 2) / pitch).rounded())))
            if selectedID != items[index].id { selectedID = items[index].id; onSelect(items[index].id) }
        }
        @objc private func handleReorder(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: collection)
            switch gesture.state {
            case .began:
                guard let index = collection.indexPathForItem(at: point), items.indices.contains(index.item),
                      collection.beginInteractiveMovementForItem(at: index) else { return }
                baseline = snapshot; originalItems = items; dragged = items[index.item]
                if let cell = collection.cellForItem(at: index), let window = view.window {
                    originalFrame = cell.convert(cell.bounds, to: window)
                    originalTouch = gesture.location(in: window)
                }
            case .changed:
                guard let dragged, let window = view.window else { return }
                if outside {
                    if !onExternal(.changed, dragged, gesture.location(in: window), movedFrame(at: gesture.location(in: window))) { cancelMove() }
                }
                else if !collection.bounds.insetBy(dx: -36, dy: -36).contains(point) {
                    collection.cancelInteractiveMovement()
                    outside = onExternal(.began, dragged, gesture.location(in: window), movedFrame(at: gesture.location(in: window)))
                    if !outside { cancelMove() }
                } else { collection.updateInteractiveMovementTargetPosition(point) }
            case .ended:
                if outside, let dragged, let window = view.window {
                    self.dragged = nil; baseline = nil; originalItems = nil; outside = false
                    _ = onExternal(.ended, dragged, gesture.location(in: window), movedFrame(at: gesture.location(in: window)))
                } else if let baseline {
                    collection.endInteractiveMovement()
                    self.baseline = nil; originalItems = nil; dragged = nil
                    onReorder(baseline, items.map(\.id))
                }
            case .cancelled, .failed: cancelMove()
            default: break
            }
        }
        private func movedFrame(at point: CGPoint) -> CGRect {
            originalFrame.offsetBy(dx: point.x - originalTouch.x, dy: point.y - originalTouch.y)
        }
        private func cancelMove() {
            if outside, let dragged, let window = view.window { _ = onExternal(.cancelled, dragged, hold.location(in: window), movedFrame(at: hold.location(in: window))) }
            collection.cancelInteractiveMovement()
            if let originalItems { items = originalItems; collection.reloadData() }
            originalItems = nil; dragged = nil; outside = false; baseline = nil
        }
        func stop() { if baseline != nil { cancelMove() }; collection.dataSource = nil; collection.delegate = nil }
    }

    final class CardLayout: UICollectionViewFlowLayout {
        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }
        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            guard let collectionView else { return super.layoutAttributesForElements(in: rect) }
            let middle = collectionView.bounds.midY
            return super.layoutAttributesForElements(in: rect)?.compactMap { original in
                guard let value = original.copy() as? UICollectionViewLayoutAttributes else { return nil }
                let distance = min(1, abs(value.center.y - middle) / max(1, itemSize.height + minimumLineSpacing))
                value.transform = CGAffineTransform(scaleX: 1 - distance * 0.08, y: 1 - distance * 0.08)
                value.zIndex = Int((1 - distance) * 100)
                return value
            }
        }
        override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint, withScrollingVelocity velocity: CGPoint) -> CGPoint {
            guard let collectionView else { return proposedContentOffset }
            let pitch = max(1, itemSize.height + minimumLineSpacing)
            let index = ((proposedContentOffset.y + collectionView.bounds.height / 2 - itemSize.height / 2) / pitch).rounded()
            return CGPoint(x: 0, y: max(0, index * pitch + itemSize.height / 2 - collectionView.bounds.height / 2))
        }
    }
    struct Card: View {
        let item: Page2Item
        let size: CGSize
        let onRemove: () -> Void
        var body: some View {
            VStack(spacing: 8) {
                Page2WidgetHost(item: item, onOpen: { _ in })
                    .frame(width: max(1, size.width - 32), height: max(1, size.height - 50))
                    .allowsHitTesting(false)
                Text(Page2WidgetCatalog.name(item.widgetKind ?? "")).font(.system(size: 12)).foregroundStyle(.white)
            }
            .frame(width: size.width, height: size.height)
            .background { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 42)) }
            .overlay(alignment: .topLeading) {
                Page2RemoveBadge(label: "从叠放移除\(Page2WidgetCatalog.name(item.widgetKind ?? ""))", editing: true, action: onRemove)
                    .offset(x: 8, y: 8)
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("page2.stack-card.\(item.widgetKind ?? item.id.uuidString)")
        }
    }
}
#endif
