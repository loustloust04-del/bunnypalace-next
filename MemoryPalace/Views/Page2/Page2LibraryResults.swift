#if os(iOS)
import SwiftUI
import UIKit

struct Page2LibraryResults: UIViewControllerRepresentable {
    let tools: [RightPanelTool]
    let showIndex: Bool
    let margin: CGFloat
    let date: Date
    let scheme: ColorScheme
    var onOpen: (RightPanelTool) -> Void
    var onAdd: (RightPanelTool) -> Void
    var onBeginDrag: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        updateUIViewController(controller, context: context)
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(tools: tools, showIndex: showIndex, margin: margin, date: date, scheme: scheme,
                             onOpen: onOpen, onAdd: onAdd, onBeginDrag: onBeginDrag)
    }

    final class Controller: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate {
        private let table = UITableView(frame: .zero, style: .plain)
        private var tools: [RightPanelTool] = []
        private var sections: [[RightPanelTool]] = Array(repeating: [], count: Page2LibraryNameKey.letters.count)
        private var showIndex = true
        private var margin: CGFloat = 31
        private var date = Date.distantPast
        private var scheme = ColorScheme.dark
        private var onOpen: ((RightPanelTool) -> Void)?
        private var onAdd: ((RightPanelTool) -> Void)?
        private var onBeginDrag: (() -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            table.backgroundColor = .clear
            table.rowHeight = 72
            table.sectionHeaderTopPadding = 0
            table.sectionHeaderHeight = 0
            table.sectionFooterHeight = 0
            table.contentInsetAdjustmentBehavior = .never
            table.keyboardDismissMode = .interactive
            table.showsVerticalScrollIndicator = false
            table.sectionIndexMinimumDisplayRowCount = 0
            table.sectionIndexColor = .label
            table.sectionIndexBackgroundColor = .clear
            table.sectionIndexTrackingBackgroundColor = .clear
            table.tableFooterView = UIView(frame: .zero)
            table.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
            table.dataSource = self; table.delegate = self; table.dragDelegate = self
            table.dragInteractionEnabled = true
            table.accessibilityIdentifier = "page2.library-results"
            table.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(table)
            NSLayoutConstraint.activate([
                table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                table.topAnchor.constraint(equalTo: view.topAnchor),
                table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
            ])
        }

        func configure(tools: [RightPanelTool], showIndex: Bool, margin: CGFloat, date: Date, scheme: ColorScheme,
                       onOpen: @escaping (RightPanelTool) -> Void, onAdd: @escaping (RightPanelTool) -> Void,
                       onBeginDrag: @escaping () -> Void) {
            loadViewIfNeeded()
            let changed = self.tools != tools || self.showIndex != showIndex || self.margin != margin || self.date != date || self.scheme != scheme
            self.tools = tools; self.showIndex = showIndex; self.margin = margin; self.date = date; self.scheme = scheme
            self.onOpen = onOpen; self.onAdd = onAdd; self.onBeginDrag = onBeginDrag
            view.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            table.separatorInset = UIEdgeInsets(top: 0, left: margin + 64, bottom: 0, right: margin)
            if changed {
                let grouped = Dictionary(grouping: tools) { Page2LibraryNameKey($0.name).section }
                sections = Page2LibraryNameKey.letters.map { grouped[$0] ?? [] }
                table.reloadData()
            }
        }
        func numberOfSections(in tableView: UITableView) -> Int { sections.count }
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }
        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { .leastNonzeroMagnitude }
        func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNonzeroMagnitude }
        func sectionIndexTitles(for tableView: UITableView) -> [String]? { showIndex ? Page2LibraryNameKey.letters.map(String.init) : nil }
        func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
            sections.indices.dropFirst(index).first { !sections[$0].isEmpty } ?? sections.indices.last { !sections[$0].isEmpty } ?? 0
        }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let tool = sections[indexPath.section][indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "tool", for: indexPath)
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            cell.isAccessibilityElement = true
            cell.accessibilityIdentifier = "page2.app.\(tool.id)"
            cell.accessibilityLabel = tool.name
            cell.accessibilityTraits = .button
            let margin = margin, date = date, scheme = scheme
            cell.contentConfiguration = UIHostingConfiguration {
                HStack(spacing: 16) {
                    Page2AppIcon(tool: tool, side: 48, label: false, followsIconSize: false, interactive: false, decorative: true)
                    Text(tool.name).font(.system(size: 17)).lineLimit(1).modifier(Page2DesktopLabel())
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, margin)
                .environment(\.page2Date, date)
                .environment(\.colorScheme, scheme)
            }.margins(.all, 0)
            return cell
        }
        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { onOpen?(sections[indexPath.section][indexPath.row]) }
        func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            let tool = sections[indexPath.section][indexPath.row]
            return UIContextMenuConfiguration(identifier: tool.id as NSString, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [UIAction(title: "添加到主屏", image: UIImage(systemName: "plus.app")) { [weak self] _ in self?.onAdd?(tool) }])
            }
        }
        func tableView(_ tableView: UITableView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? { iconPreview(configuration) }
        func tableView(_ tableView: UITableView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? { iconPreview(configuration) }
        private func iconPreview(_ configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            guard let id = configuration.identifier as? String,
                  let section = sections.firstIndex(where: { $0.contains(where: { $0.id == id }) }),
                  let row = sections[section].firstIndex(where: { $0.id == id }),
                  let cell = table.cellForRow(at: IndexPath(row: row, section: section)) else { return nil }
            let rect = CGRect(x: margin, y: 12, width: 48, height: 48)
            guard let snapshot = cell.contentView.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
            snapshot.frame = CGRect(origin: .zero, size: rect.size)
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: 12.5)
            return UITargetedPreview(view: snapshot, parameters: parameters,
                                     target: UIPreviewTarget(container: cell.contentView, center: CGPoint(x: rect.midX, y: rect.midY)))
        }
        func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            let tool = sections[indexPath.section][indexPath.row]
            return [UIDragItem(itemProvider: NSItemProvider(object: "library:\(tool.id)" as NSString))]
        }
        func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) { onBeginDrag?() }
        func tableView(_ tableView: UITableView, dragPreviewParametersForRowAt indexPath: IndexPath) -> UIDragPreviewParameters? {
            let parameters = UIDragPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: CGRect(x: margin, y: 12, width: 48, height: 48), cornerRadius: 12.5)
            return parameters
        }
    }
}
#endif
