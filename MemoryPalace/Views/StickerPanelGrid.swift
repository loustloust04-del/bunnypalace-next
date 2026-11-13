#if os(iOS)
import SwiftUI
import UIKit

/// ➕ 面板的贴纸网格（iOS）：UICollectionView。点 = 贴；长按拖动 = 排序；拖出网格 = 贴到落点（对话区的 onDrop 接）；
/// 长按菜单 = 置顶。格子内容仍是 SwiftUI 的 `PanelStickerCell`。
struct StickerPanelGrid: UIViewRepresentable {
    let assets: [StickerAsset]
    let profileId: String
    let pinTitle: (UUID) -> String
    let onTap: (StickerAsset) -> Void
    let onPinToggle: (StickerAsset) -> Void
    let onReorder: ([UUID]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(68)),
            repeatingSubitem: item, count: 4)
        group.interItemSpacing = .fixed(6)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = .init(top: 0, leading: 14, bottom: 14, trailing: 14)

        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.dragInteractionEnabled = true   // iPhone 默认关
        view.delegate = context.coordinator
        view.dragDelegate = context.coordinator
        view.dropDelegate = context.coordinator
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(assets.map(\.id), animated: true)
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        var parent: StickerPanelGrid
        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>?

        init(_ parent: StickerPanelGrid) { self.parent = parent }

        private func asset(_ id: UUID) -> StickerAsset? { parent.assets.first { $0.id == id } }

        func install(on view: UICollectionView) {
            let registration = UICollectionView.CellRegistration<UICollectionViewCell, UUID> { [weak self] cell, _, id in
                guard let self, let asset = self.asset(id) else { return }
                cell.contentConfiguration = UIHostingConfiguration {
                    PanelStickerCell(asset: asset, profileId: self.parent.profileId)
                }
                .margins(.all, 0)
                cell.backgroundConfiguration = .clear()
            }
            dataSource = UICollectionViewDiffableDataSource<Int, UUID>(collectionView: view) { view, indexPath, id in
                view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            apply(parent.assets.map(\.id), animated: false)
        }

        func apply(_ ids: [UUID], animated: Bool) {
            guard let dataSource, dataSource.snapshot().itemIdentifiers != ids else { return }
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            dataSource.apply(snapshot, animatingDifferences: animated)
        }

        // MARK: 点 / 长按菜单

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let id = dataSource?.itemIdentifier(for: indexPath), let asset = asset(id) else { return }
            parent.onTap(asset)
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard let indexPath = indexPaths.first, let id = dataSource?.itemIdentifier(for: indexPath), let asset = asset(id) else { return nil }
            let title = parent.pinTitle(id)
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: [UIAction(title: title, image: UIImage(systemName: "pin")) { _ in self?.parent.onPinToggle(asset) }])
            })
        }

        // MARK: 拖

        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return [] }
            let item = UIDragItem(itemProvider: NSItemProvider(object: id.uuidString as NSString))
            item.localObject = id
            return [item]
        }

        func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            return parameters
        }

        // MARK: 落回网格 = 排序

        func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
            session.localDragSession != nil && collectionView.hasActiveDrag
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }

        func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            guard let dataSource, let item = coordinator.items.first, let id = item.dragItem.localObject as? UUID else { return }
            var ids = dataSource.snapshot().itemIdentifiers
            guard let from = ids.firstIndex(of: id) else { return }
            ids.remove(at: from)
            let to = min(coordinator.destinationIndexPath?.item ?? ids.count, ids.count)
            ids.insert(id, at: to)
            apply(ids, animated: true)
            coordinator.drop(item.dragItem, toItemAt: IndexPath(item: to, section: 0))
            parent.onReorder(ids)
        }
    }
}
#endif
