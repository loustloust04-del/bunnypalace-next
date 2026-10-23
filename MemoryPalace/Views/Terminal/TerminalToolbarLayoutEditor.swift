#if os(iOS)
import UIKit
import SwiftUI

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 工具条布局编辑器（plan §C6，物料表 §7.1）。
///
/// `UICollectionView` inset-grouped list + diffable：长按 lift 跨区拖（主行 ↔ 各抽屉行 ↔ 已隐藏），
/// 左滑删除，长按 context menu 兜底（拖不动时还有一条路）。每次改动整份布局一次性写回 store。
///
/// **同一个键在编辑器里只出现一次** —— diffable 的 item 必须全局唯一，重复会直接崩。
/// rootshell 的 item ID 是 `builtin.<rawValue>` / `custom.<UUID>`，同样是这个约束。
final class TerminalToolbarLayoutEditor: UIViewController {

    private enum Section: Hashable {
        case main
        case drawer(Int)
        case hidden
    }

    private let store: TerminalToolbarStore
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, TerminalKeySlot>!

    init(store: TerminalToolbarStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.backgroundColor = UIColor(Theme.mainBg)
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = UIColor(Theme.mainBg)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dragInteractionEnabled = true    // 普通模式也能长按 lift 拖
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        // ⚠️ 别忘了这行：context menu 兜底（长按选「移到主行 / 移到抽屉 N / 移除」）走的是
        // UICollectionViewDelegate，只设 drag/drop delegate 的话那条路整个是死的。
        // 13:10 真机实测：漏了它 → 长按毫无反应，拖不动时用户就彻底没辙了。
        collectionView.delegate = self
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureDataSource()
        reload(animated: false)
    }

    // MARK: 数据源

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, TerminalKeySlot> {
            [weak self] cell, _, slot in
            var content = cell.defaultContentConfiguration()
            content.text = self?.title(for: slot) ?? "?"
            content.secondaryText = self?.detail(for: slot)
            content.textProperties.color = UIColor(Theme.textPrimary)
            content.secondaryTextProperties.color = UIColor(Theme.textMuted)
            content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.contentConfiguration = content
            cell.backgroundConfiguration = {
                var bg = UIBackgroundConfiguration.listGroupedCell()
                bg.backgroundColor = UIColor(Theme.sidebarBg)
                return bg
            }()
            cell.accessories = [.reorder(displayed: .always)]
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = view.defaultContentConfiguration()
            let section = self.section(at: indexPath.section)
            content.text = self.headerTitle(section)
            content.textProperties.color = self.headerIsOverCapacity(section)
                ? UIColor.systemOrange : UIColor(Theme.textMuted)
            view.contentConfiguration = content
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = view.defaultContentConfiguration()
            content.text = self.footerTitle(self.section(at: indexPath.section))
            content.textProperties.color = UIColor(Theme.textMuted)
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Section, TerminalKeySlot>(
            collectionView: collectionView
        ) { cv, indexPath, slot in
            cv.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: slot)
        }
        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? cv.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : cv.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        // Edit 模式的 reorder grip 走 diffable 自带的跨区重排
        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { [weak self] _ in self?.persist() }
    }

    private var sections: [Section] {
        [.main] + (0..<max(1, store.layout.drawerRows.count)).map { Section.drawer($0) } + [.hidden]
    }

    private func section(at index: Int) -> Section {
        let all = sections
        return all.indices.contains(index) ? all[index] : .hidden
    }

    private func reload(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, TerminalKeySlot>()
        snapshot.appendSections(sections)
        snapshot.appendItems(store.layout.mainRow, toSection: .main)
        for (i, row) in store.layout.drawerRows.enumerated() {
            snapshot.appendItems(row, toSection: .drawer(i))
        }
        snapshot.appendItems(hiddenSlots(), toSection: .hidden)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    /// 已隐藏 = 被显式 hide 的内建键 + 没放进任何行的自定义键（物料表 §7.1）
    private func hiddenSlots() -> [TerminalKeySlot] {
        let placedBuiltIn = store.layout.placedBuiltInIDs
        let placedCustom = store.layout.placedCustomIDs
        let builtIns = TerminalKeyID.allCases
            .filter { !placedBuiltIn.contains($0) }
            .map { TerminalKeySlot.builtIn($0) }
        let customs = store.customKeys
            .filter { !placedCustom.contains($0.id) }
            .map { TerminalKeySlot.custom($0.id) }
        return builtIns + customs
    }

    /// 从当前快照重建整份布局，一次性写回 store（物料表 §7.1：跨区拖放是一次整体布局写入）
    private func persist() {
        let snapshot = dataSource.snapshot()
        var mainRow: [TerminalKeySlot] = []
        var drawerRows: [[TerminalKeySlot]] = []
        var hidden: Set<TerminalKeyID> = []
        for section in snapshot.sectionIdentifiers {
            let items = snapshot.itemIdentifiers(inSection: section)
            switch section {
            case .main:
                mainRow = items
            case .drawer:
                drawerRows.append(items)
            case .hidden:
                // 内建键留在「已隐藏」= 显式隐藏；自定义键只是没放置，定义仍在 customKeys
                hidden = Set(items.compactMap { $0.builtInID })
            }
        }
        store.setLayout(TerminalToolbarLayout(
            mainRow: mainRow,
            drawerRows: drawerRows.isEmpty ? [[]] : drawerRows,
            hiddenKeys: hidden
        ))
        refreshHeaders()
    }

    /// 搬完键要把 header 重画一遍。
    ///
    /// diffable 的 `apply` **只管 item，不会重配已经在屏上的 supplementary view** ——
    /// 13:12 真机实测：把「终端设置」搬进抽屉后主行只剩 9 个键，header 却还写着「主行 10/12」。
    /// `reloadSections` 是唯一会让 supplementary 重新走一遍 provider 的路。
    private func refreshHeaders() {
        var snapshot = dataSource.snapshot()
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: 文案

    private func title(for slot: TerminalKeySlot) -> String {
        if let id = slot.builtInID { return id.settingsLabel }
        if let uuid = slot.customID, let key = store.customKey(uuid) { return key.label }
        return "?"
    }

    private func detail(for slot: TerminalKeySlot) -> String? {
        if let id = slot.builtInID {
            guard let bytes = TerminalByteComposer.bytes(forKey: id, modifiers: []) else { return nil }
            return Self.byteHint(bytes)
        }
        if let uuid = slot.customID, let key = store.customKey(uuid) {
            return key.sequence.count > 1 ? "宏 · \(key.sequence.count) 步" : "自定义"
        }
        return nil
    }

    /// 字节转可读提示，例：`[0x1b]` → `ESC`、`[0x03]` → `^C`
    static func byteHint(_ bytes: [UInt8]) -> String {
        if bytes.count == 1 {
            switch bytes[0] {
            case 0x1b: return "ESC"
            case 0x09: return "TAB"
            case 0x0d: return "↵"
            case 0x7f: return "DEL"
            case 0x20: return "SPC"
            case 0x00: return "NUL"
            case 0x01...0x1a: return "^\(Character(UnicodeScalar(bytes[0] + 0x40)))"
            default: return String(format: "0x%02x", bytes[0])
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private var mainRowCapacity: Int {
        let s = TerminalToolbarSizes.portrait
        let screenWidth = view.window?.windowScene?.screen.bounds.width ?? view.bounds.width
        let usable = screenWidth - s.pillInset * 2 - s.rowEdgePadding * 2
        return TerminalToolbarCapacity.capacity(availableWidth: usable, normalWidth: s.normalWidth)
    }

    private func headerIsOverCapacity(_ section: Section) -> Bool {
        section == .main && store.layout.mainRow.count > mainRowCapacity
    }

    private func headerTitle(_ section: Section) -> String {
        switch section {
        case .main: return "主行 \(store.layout.mainRow.count)/\(mainRowCapacity)"
        case .drawer(let i): return "抽屉 \(i + 1)"
        case .hidden: return "已隐藏"
        }
    }

    private func footerTitle(_ section: Section) -> String? {
        switch section {
        case .main:
            let over = store.layout.mainRow.count - mainRowCapacity
            return over > 0 ? "放不下的 \(over) 个键会挤到抽屉 1 的最前面" : nil
        case .hidden:
            return "长按选「移到主行 / 移到抽屉」放回去。自定义键即使不在布局里，定义也不会丢。"
        default:
            return nil
        }
    }

    // MARK: 左滑删除

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let slot = dataSource.itemIdentifier(for: indexPath),
              section(at: indexPath.section) != .hidden else { return nil }
        let action = UIContextualAction(style: .destructive, title: "移除") { [weak self] _, _, done in
            self?.moveToHidden(slot)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func moveToHidden(_ slot: TerminalKeySlot) {
        var snapshot = dataSource.snapshot()
        snapshot.deleteItems([slot])
        snapshot.appendItems([slot], toSection: .hidden)
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in self?.persist() }
    }

    private func move(_ slot: TerminalKeySlot, to target: Section) {
        var snapshot = dataSource.snapshot()
        snapshot.deleteItems([slot])
        // 主行是追加到末尾，抽屉是插到最前（物料表 §7.1 context menu 分支）
        if case .drawer = target, let first = snapshot.itemIdentifiers(inSection: target).first {
            snapshot.insertItems([slot], beforeItem: first)
        } else {
            snapshot.appendItems([slot], toSection: target)
        }
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in self?.persist() }
    }
}

// MARK: - 拖放

extension TerminalToolbarLayoutEditor: UICollectionViewDragDelegate, UICollectionViewDropDelegate {

    func collectionView(_ collectionView: UICollectionView,
                        itemsForBeginning session: any UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard let slot = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = slot
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView,
                        dropSessionDidUpdate session: any UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?)
    -> UICollectionViewDropProposal {
        // 只收 app 内的本地 session（物料表 §7.1）
        guard session.localDragSession != nil else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView,
                        performDropWith coordinator: any UICollectionViewDropCoordinator) {
        guard let item = coordinator.items.first,
              let slot = item.dragItem.localObject as? TerminalKeySlot else { return }

        var snapshot = dataSource.snapshot()
        // 目标为空时落到最后一个抽屉（物料表 §7.1）
        let destination = coordinator.destinationIndexPath
        let targetSection = destination.map { section(at: $0.section) }
            ?? sections.dropLast().last ?? .main

        snapshot.deleteItems([slot])
        let existing = snapshot.itemIdentifiers(inSection: targetSection)
        if let destination, destination.item < existing.count {
            snapshot.insertItems([slot], beforeItem: existing[destination.item])
        } else {
            snapshot.appendItems([slot], toSection: targetSection)
        }
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in self?.persist() }
        if let destination {
            coordinator.drop(item.dragItem, toItemAt: destination)
        }
    }
}

// MARK: - context menu 兜底

extension TerminalToolbarLayoutEditor: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let slot = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let current = section(at: indexPath.section)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu(children: []) }
            var actions: [UIAction] = []
            if current != .main {
                actions.append(UIAction(title: "移到主行") { _ in self.move(slot, to: .main) })
            }
            for i in 0..<max(1, self.store.layout.drawerRows.count) where current != .drawer(i) {
                actions.append(UIAction(title: "移到抽屉 \(i + 1)") { _ in
                    self.move(slot, to: .drawer(i))
                })
            }
            if current != .hidden {
                actions.append(UIAction(title: "移除", attributes: .destructive) { _ in
                    self.moveToHidden(slot)
                })
            }
            return UIMenu(children: actions)
        }
    }
}

// MARK: - SwiftUI 包装

struct TerminalToolbarLayoutEditorView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TerminalToolbarLayoutEditor {
        TerminalToolbarLayoutEditor()
    }

    func updateUIViewController(_ vc: TerminalToolbarLayoutEditor, context: Context) {}
}
#endif
