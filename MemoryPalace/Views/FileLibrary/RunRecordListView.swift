import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// 整理记录（`.runs/`）只读预览的原生列表 + 代码块卡 + 全文 sheet（粟粟 10-22：「为啥不 uikit」「折叠全用弹 sheet，跟 page1 的工具调用一样」）。
// 只有这里用。行高按当前宽度和字号直接算（标题 / 叙述量字，卡按字号定高），不估高：锚点 = 那一轮标题行，一次滚准。

/// 字号：接旧预览那套（`fontScale`，正文 13.5×、标题 20 / 17 / 15×、代码 0.88×正文），iOS 再乘系统动态字体。
/// 它是测量缓存的键之一：变了就重量行高
struct RunRecordTypography: Equatable {
    /// `fontScale` × 动态字体倍数
    let scale: CGFloat

    static func current(fontScale: Double) -> RunRecordTypography {
        #if os(iOS)
        let dynamic = UIFontMetrics(forTextStyle: .body).scaledValue(for: 100) / 100
        #else
        let dynamic: CGFloat = 1
        #endif
        return RunRecordTypography(scale: CGFloat(fontScale) * dynamic)
    }

    var prose: CGFloat { 13.5 * scale }
    func heading(_ level: Int) -> CGFloat { (level <= 1 ? 20 : level == 2 ? 17 : 15) * scale }
    var code: CGFloat { 13.5 * scale * 0.88 }
    /// 卡照 page1 卡的 12 / 10pt，按旧默认 1.2 归一后跟着放大
    var cardName: CGFloat { 12 * scale / 1.2 }
    var cardMeta: CGFloat { 10 * scale / 1.2 }
    var cardHeight: CGFloat { ceil(40 * scale / 1.2) }

    static let horizontal: CGFloat = 16

    func padding(_ row: RunRecordDocument.Row, first: Bool) -> (top: CGFloat, bottom: CGFloat) {
        switch row {
        case .heading(_, let level): return (first ? 8 : (level <= 2 ? 18 : 10), 4)
        case .prose: return (first ? 8 : 3, 3)
        case .block: return (3, 3)
        }
    }

    /// 代码块里没有换行（LF / CR 都不算有）才可能原地显示；排不排得下一行由各端按实际字体量
    static func isSingleLine(_ block: RunRecordDocument.Block) -> Bool {
        !block.alwaysCard && !block.text.utf8.contains(0x0A) && !block.text.utf8.contains(0x0D)
    }

    func text(_ row: RunRecordDocument.Row) -> (value: String, bold: Bool, size: CGFloat)? {
        switch row {
        case .heading(let text, let level): return (text, true, heading(level))
        case .prose(let text): return (text, false, prose)
        case .block: return nil
        }
    }
}

/// 代码块折叠卡：样子照 page1 工具调用卡（MessageSegmentsView 折叠行）——图标、名字、「· 共 N 字」、首行摘要单行截断、右侧 chevron
struct RunRecordBlockCard: View {
    let block: RunRecordDocument.Block
    let typography: RunRecordTypography

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: block.icon)
                .font(.system(size: typography.cardMeta, weight: .medium))
                .foregroundColor(Theme.textMuted)
                .frame(width: 14 * typography.scale / 1.2)
            Text(block.name)
                .font(.system(size: typography.cardName, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Text("· 共 \(block.count) 字")
                .font(.system(size: typography.cardMeta))
                .foregroundColor(Theme.textMuted.opacity(0.7))
                .lineLimit(1)
                .fixedSize()
            if !block.summary.isEmpty {
                Text("· \(block.summary)")
                    .font(.system(size: typography.cardMeta))
                    .foregroundColor(Theme.textMuted.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: typography.cardMeta))
                .foregroundColor(Theme.textMuted)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.55)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 点卡弹出的全文：同一个 DisclosureSheet 壳，里面是原生只读文本视图（TextKit 2，等宽，可选中，不高亮、不切段、不折叠）
struct RunRecordBlockSheet: View {
    let block: RunRecordDocument.Block
    let typography: RunRecordTypography
    @State private var copied = false

    var body: some View {
        DisclosureSheet(title: block.name, scrolls: false) {
            VStack(alignment: .leading, spacing: 8) {
                if let note = block.note {
                    Text(note)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.danger)
                }
                HStack(spacing: 8) {
                    Text("共 \(block.count) 字" + (block.language.isEmpty ? "" : " · \(block.language)"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                    Spacer(minLength: 0)
                    Button {
                        Self.copy(block)
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制")
                }
                RunRecordTextView(text: block.text, fontSize: typography.code)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(block.id)
            }
            .padding(.bottom, 12)
        }
    }
}

extension RunRecordBlockSheet {
    /// 「复制」= 整块原文（不是屏幕上看到的哪一段）
    static func copy(_ block: RunRecordDocument.Block) { RunRecordClipboard.copy(block.text) }
}

enum RunRecordClipboard {
    /// 测试用：接管复制，不碰系统剪贴板
    nonisolated(unsafe) static var override: ((String) -> Void)?

    static func copy(_ text: String) {
        if let override { return override(text) }
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - iOS：UICollectionView（flow layout，行高按宽度 + 字号算准）

#if os(iOS)
struct RunRecordListView: UIViewRepresentable {
    let document: RunRecordDocument
    let typography: RunRecordTypography
    let onOpen: (RunRecordDocument.Block) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RunRecordCollectionView {
        let view = RunRecordCollectionView(frame: .zero, collectionViewLayout: RunRecordFlowLayout())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.register(RunRecordTextCell.self, forCellWithReuseIdentifier: RunRecordTextCell.reuse)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "card")
        view.register(RunRecordCodeLineCell.self, forCellWithReuseIdentifier: RunRecordCodeLineCell.reuse)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.widthChanged(view)
        }
        context.coordinator.apply(document, typography: typography, onOpen: onOpen, to: view)
        return view
    }

    func updateUIView(_ view: RunRecordCollectionView, context: Context) {
        context.coordinator.apply(document, typography: typography, onOpen: onOpen, to: view)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        private var document: RunRecordDocument?
        private var typography = RunRecordTypography(scale: 1.2)
        private var onOpen: (RunRecordDocument.Block) -> Void = { _ in }
        private var heights: [CGFloat] = []
        /// 代码块是否原地显示（没换行、这个宽度和字号下一行排得下）；和行高同一个缓存键
        private var inline: [Bool] = []
        /// 测量缓存的键：宽度 + 字号
        private var heightKey: (width: CGFloat, typography: RunRecordTypography)?

        func apply(_ document: RunRecordDocument, typography: RunRecordTypography, onOpen: @escaping (RunRecordDocument.Block) -> Void,
                   to view: RunRecordCollectionView) {
            self.onOpen = onOpen
            if self.document?.id != document.id {
                self.document = document
                self.typography = typography
                resetHeights()
                view.reloadData()
                view.pendingTarget = document.targetRow.map { IndexPath(item: $0, section: 0) }
                view.setNeedsLayout()
            } else if self.typography != typography {
                // 字号变了：行高重量、卡重画、原地 / 折卡重判，停在原来最上面那行
                self.typography = typography
                resetHeights()
                view.keepTopRowThroughRelayout()
                view.reloadData()
            }
        }

        /// 宽度变了：清缓存（行高、原地 / 折卡都按新宽度重判）；cell 类型可能变，排完那一轮再换 cell
        func widthChanged(_ view: RunRecordCollectionView) {
            resetHeights()
            view.needsCellReload = true
        }

        func resetHeights() {
            heightKey = nil
        }

        private func ensure(width: CGFloat) {
            guard let rows = document?.rows, heightKey?.width != width || heightKey?.typography != typography else { return }
            heightKey = (width, typography)
            inline = rows.map { Self.fitsInline($0, width: width, typography: typography) }
            heights = rows.indices.map { Self.measure(rows[$0], first: $0 == 0, inline: inline[$0], width: width, typography: typography) }
        }

        private func height(at index: Int, width: CGFloat) -> CGFloat {
            ensure(width: width)
            return heights.indices.contains(index) ? heights[index] : 1
        }

        private func isInline(_ index: Int, in view: UICollectionView) -> Bool {
            ensure(width: max(1, view.bounds.width - 2 * RunRecordTypography.horizontal))
            return inline.indices.contains(index) && inline[index]
        }

        static func codeFont(_ typography: RunRecordTypography) -> UIFont {
            .monospacedSystemFont(ofSize: typography.code, weight: .regular)
        }

        /// 短单行：没换行，并且按当前宽度和代码字号实际量出来一行排得下
        static func fitsInline(_ row: RunRecordDocument.Row, width: CGFloat, typography: RunRecordTypography) -> Bool {
            guard case .block(let block) = row, RunRecordTypography.isSingleLine(block) else { return false }
            return ceil((block.text as NSString).size(withAttributes: [.font: codeFont(typography)]).width) <= width
        }

        static func measure(_ row: RunRecordDocument.Row, first: Bool, inline: Bool, width: CGFloat, typography: RunRecordTypography) -> CGFloat {
            let pad = typography.padding(row, first: first)
            if inline { return ceil(codeFont(typography).lineHeight) + pad.top + pad.bottom + 2 }
            guard let t = typography.text(row) else { return typography.cardHeight }
            let font = UIFont.systemFont(ofSize: t.size, weight: t.bold ? .semibold : .regular)
            let rect = (t.value as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                      attributes: [.font: font], context: nil)
            return ceil(rect.height) + pad.top + pad.bottom + 1
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            document?.rows.count ?? 0
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = max(1, collectionView.bounds.width - 2 * RunRecordTypography.horizontal)
            return CGSize(width: width, height: height(at: indexPath.item, width: width))
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let rows = document?.rows else { return UICollectionViewCell() }
            let row = rows[indexPath.item]
            let typography = typography
            if case .block(let block) = row, isInline(indexPath.item, in: collectionView) {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RunRecordCodeLineCell.reuse, for: indexPath) as! RunRecordCodeLineCell
                cell.show(block.text, font: Self.codeFont(typography), padding: typography.padding(row, first: indexPath.item == 0))
                return cell
            }
            if case .block(let block) = row {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath)
                cell.contentConfiguration = UIHostingConfiguration { RunRecordBlockCard(block: block, typography: typography) }
                    .margins(.horizontal, 0)
                    .margins(.vertical, 3)
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RunRecordTextCell.reuse, for: indexPath) as! RunRecordTextCell
            cell.show(row, first: indexPath.item == 0, typography: typography)
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            if let rows = document?.rows, case .block(let block) = rows[indexPath.item], !isInline(indexPath.item, in: collectionView) { onOpen(block) }
        }

        /// 只有卡能点开；原地显示的短值是可选中的文字
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            guard let rows = document?.rows else { return false }
            if case .block = rows[indexPath.item] { return !isInline(indexPath.item, in: collectionView) }
            return false
        }
    }
}

final class RunRecordFlowLayout: UICollectionViewFlowLayout {
    override init() {
        super.init()
        minimumLineSpacing = 0
        minimumInteritemSpacing = 0
        sectionInset = UIEdgeInsets(top: 0, left: RunRecordTypography.horizontal, bottom: 32, right: RunRecordTypography.horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    /// 宽度变了不光重排位置，还要重新问 delegate 每行多大（不然沿用旧宽高：卡宽不对、叙述被裁、后面全错位）；
    /// 自己的高度缓存一起清，并记下最上面那行，排完停回去（astra 审 97d41cbab P1）
    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if let view = collectionView as? RunRecordCollectionView, newBounds.width != view.bounds.width,
           let flow = context as? UICollectionViewFlowLayoutInvalidationContext {
            flow.invalidateFlowLayoutDelegateMetrics = true
            view.keepTopRowThroughRelayout()
            view.onWidthChange?()
        }
        return context
    }
}

/// 锚点：第一次有宽度、数据就位时把那一轮标题行滚到顶（行高是算出来的，不估，一次即准）。
/// 之后宽度 / 字号变了，停回变之前最上面那一行（同样的露出量）
final class RunRecordCollectionView: UICollectionView {
    var pendingTarget: IndexPath?
    var onWidthChange: (() -> Void)?
    /// 宽度变了以后，原地显示 / 折卡可能互换，排完这一轮换一次 cell
    var needsCellReload = false
    private var keepTop: (item: IndexPath, offset: CGFloat)?

    func keepTopRowThroughRelayout() {
        guard pendingTarget == nil, keepTop == nil, let first = indexPathsForVisibleItems.min(),
              let frame = layoutAttributesForItem(at: first)?.frame else { return }
        keepTop = (first, contentOffset.y + adjustedContentInset.top - frame.minY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsCellReload {
            needsCellReload = false
            reloadData()
        }
        guard bounds.width > 0, numberOfSections > 0 else { return }
        if let target = pendingTarget, target.item < numberOfItems(inSection: 0) {
            pendingTarget = nil
            scrollToItem(at: target, at: .top, animated: false)
        } else if let keep = keepTop, keep.item.item < numberOfItems(inSection: 0),
                  let frame = collectionViewLayout.layoutAttributesForItem(at: keep.item)?.frame {
            keepTop = nil
            let maxY = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
            contentOffset.y = min(max(-adjustedContentInset.top, frame.minY + keep.offset - adjustedContentInset.top), maxY)
        }
    }
}

final class RunRecordTextCell: UICollectionViewCell {
    static let reuse = "text"
    private let label = UILabel()
    private var insets = UIEdgeInsets.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ row: RunRecordDocument.Row, first: Bool, typography: RunRecordTypography) {
        let pad = typography.padding(row, first: first)
        insets = UIEdgeInsets(top: pad.top, left: 0, bottom: pad.bottom, right: 0)
        guard let t = typography.text(row) else { return }
        label.font = UIFont.systemFont(ofSize: t.size, weight: t.bold ? .semibold : .regular)
        label.textColor = UIColor(t.bold ? Theme.textPrimary : Theme.textSecondary)
        label.text = t.value
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.inset(by: insets)
    }
}

/// 短单行代码原地显示：等宽、只读、可选中（UITextView，不滚、一行）
final class RunRecordCodeLineCell: UICollectionViewCell {
    static let reuse = "codeLine"
    private let textView = UITextView(usingTextLayoutManager: true)
    private var insets = UIEdgeInsets.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.dataDetectorTypes = []
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 1
        textView.textColor = UIColor(Theme.textPrimary)
        contentView.addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, font: UIFont, padding: (top: CGFloat, bottom: CGFloat)) {
        insets = UIEdgeInsets(top: padding.top, left: 0, bottom: padding.bottom, right: 0)
        textView.font = font
        textView.text = text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = contentView.bounds.inset(by: insets)
    }
}

/// sheet 里的全文：UITextView TextKit 2，只读可选中，自己滚
struct RunRecordTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = UIColor(Theme.textPrimary)
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 24, right: 0)
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.font?.pointSize != fontSize { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
}

// MARK: - mac：NSTableView（行高按宽度 + 字号算准）

#else
struct RunRecordListView: NSViewRepresentable {
    let document: RunRecordDocument
    let typography: RunRecordTypography
    let onOpen: (RunRecordDocument.Block) -> Void

    func makeNSView(context: Context) -> RunRecordScrollView {
        let view = RunRecordScrollView()
        view.onOpen = onOpen
        view.apply(document, typography: typography)
        return view
    }

    func updateNSView(_ view: RunRecordScrollView, context: Context) {
        view.onOpen = onOpen
        view.apply(document, typography: typography)
    }
}

final class RunRecordScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var onOpen: (RunRecordDocument.Block) -> Void = { _ in }
    private(set) var document: RunRecordDocument?
    private(set) var typography = RunRecordTypography(scale: 1.2)
    private var heights: [CGFloat] = []
    private var inline: [Bool] = []
    /// 测量缓存的键：宽度 + 字号
    private var heightKey: (width: CGFloat, typography: RunRecordTypography)?
    private var pendingTarget: Int?
    private let measurer = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        documentView = table
        hasVerticalScroller = true
        // 浮层滚动条：传统滚动条出现 / 消失会改内容宽度，行高全表重量、落点跟着挪
        scrollerStyle = .overlay
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ document: RunRecordDocument, typography: RunRecordTypography) {
        if self.document?.id != document.id {
            self.document = document
            self.typography = typography
            heightKey = nil
            table.reloadData()
            pendingTarget = document.targetRow
            needsLayout = true
        } else if self.typography != typography {
            self.typography = typography
            relayoutKeepingTopRow { table.reloadData() }
        }
    }

    /// 点卡 = 打开那一块（鼠标点击和测试共用）；原地显示的短值不是卡，不弹
    func open(row: Int) {
        guard let rows = document?.rows, rows.indices.contains(row), case .block(let block) = rows[row], !isInline(row) else { return }
        onOpen(block)
    }

    /// 这个代码块现在是不是原地显示（没换行、当前宽度和字号下一行排得下）；和行高同一个缓存键
    func isInline(_ row: Int) -> Bool {
        ensureHeights(contentView.bounds.width)
        return inline.indices.contains(row) && inline[row]
    }

    @objc private func clicked() { open(row: table.clickedRow) }

    override func tile() {
        super.tile()
        let width = contentView.bounds.width
        if width > 0, heightKey != nil, heightKey?.width != width, let count = document?.rows.count, count > 0 {
            // 行高重量；原地显示 / 折卡也按新宽度重判，cell 可能要换，整表重载
            relayoutKeepingTopRow {
                ensureHeights(width)
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<count))
                table.reloadData()
            }
        }
    }

    /// 宽度 / 字号变了：重量行高，再停回变之前最上面那一行（同样的露出量）
    private func relayoutKeepingTopRow(_ change: () -> Void) {
        let top = contentView.bounds.minY
        let row = table.row(at: NSPoint(x: 0, y: top))
        let offset = row >= 0 ? top - table.rect(ofRow: row).minY : 0
        heightKey = nil
        change()
        if ensureHeights(contentView.bounds.width) { noteAllHeights() }
        guard pendingTarget == nil, row >= 0, row < table.numberOfRows else { return }
        table.layoutSubtreeIfNeeded()
        scroll(toY: table.rect(ofRow: row).minY + offset)
    }

    override func layout() {
        super.layout()
        scrollToPendingTarget()
    }

    private func scrollToPendingTarget() {
        guard let target = pendingTarget, contentView.bounds.width > 0, target < table.numberOfRows else { return }
        pendingTarget = nil
        if ensureHeights(contentView.bounds.width) { noteAllHeights() }
        table.layoutSubtreeIfNeeded()
        scroll(toY: table.rect(ofRow: target).minY)
    }

    private func scroll(toY y: CGFloat) {
        let maxY = max(0, table.bounds.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        reflectScrolledClipView(contentView)
    }

    private var codeFont: NSFont { .monospacedSystemFont(ofSize: typography.code, weight: .regular) }

    /// 短单行：没换行，并且用原地显示那个标签、按当前宽度和代码字号实际量出来一行排得下
    func fitsInline(_ index: Int, width: CGFloat) -> Bool {
        guard let rows = document?.rows, case .block(let block) = rows[index], RunRecordTypography.isSingleLine(block) else { return false }
        measurer.font = codeFont
        measurer.stringValue = block.text
        let oneLine = measurer.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
        return ceil(oneLine.width) <= max(1, width - 2 * RunRecordTypography.horizontal)
    }

    /// 某行在某宽度下多高（测试也用它对答案）
    func measuredHeight(_ index: Int, width: CGFloat) -> CGFloat {
        guard let rows = document?.rows else { return 0 }
        let row = rows[index]
        let pad = typography.padding(row, first: index == 0)
        if fitsInline(index, width: width) {
            let oneLine = measurer.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
            return ceil(oneLine.height) + pad.top + pad.bottom + 1
        }
        guard let t = typography.text(row) else { return typography.cardHeight }
        measurer.font = .systemFont(ofSize: t.size, weight: t.bold ? .semibold : .regular)
        measurer.stringValue = t.value
        let textWidth = max(1, width - 2 * RunRecordTypography.horizontal)
        let cell = measurer.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)) ?? .zero
        return ceil(cell.height) + pad.top + pad.bottom + 1
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document?.rows.count ?? 0 }

    /// 宽度 / 字号和缓存的不一样就整表重量（每行量一次，几百行几毫秒）
    @discardableResult
    private func ensureHeights(_ width: CGFloat) -> Bool {
        guard width > 0, heightKey?.width != width || heightKey?.typography != typography else { return false }
        heightKey = (width, typography)
        let indices = (document?.rows ?? []).indices
        inline = indices.map { fitsInline($0, width: width) }
        heights = indices.map { measuredHeight($0, width: width) }
        return true
    }

    private func noteAllHeights() {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        ensureHeights(contentView.bounds.width)
        return heights.indices.contains(row) ? max(1, heights[row]) : typography.cardHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let rows = document?.rows else { return nil }
        let id = NSUserInterfaceItemIdentifier("runRecordRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? RunRecordRowCell) ?? RunRecordRowCell()
        cell.identifier = id
        cell.show(rows[row], first: row == 0, typography: typography, inline: isInline(row))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// 一行：标题 / 叙述是可选中的原生标签，卡是 SwiftUI（同 page1 卡样）
final class RunRecordRowCell: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var card: NSHostingView<RunRecordBlockCard>?
    private var pad: (top: CGFloat, bottom: CGFloat) = (0, 0)

    override var isFlipped: Bool { true }

    /// 测试 / 无障碍读这一行的字
    private(set) var text = ""

    func show(_ row: RunRecordDocument.Row, first: Bool, typography: RunRecordTypography, inline: Bool) {
        pad = typography.padding(row, first: first)
        if case .block(let block) = row, inline {
            // 短单行原地显示：等宽、可选中
            text = block.text
            showLabel(block.text, font: .monospacedSystemFont(ofSize: typography.code, weight: .regular), color: NSColor(Theme.textPrimary))
        } else if case .block(let block) = row {
            text = block.name
            label.isHidden = true
            if let card {
                card.rootView = RunRecordBlockCard(block: block, typography: typography)
                card.isHidden = false
            } else {
                let host = NSHostingView(rootView: RunRecordBlockCard(block: block, typography: typography))
                host.sizingOptions = []
                addSubview(host)
                card = host
            }
        } else if let t = typography.text(row) {
            text = t.value
            showLabel(t.value, font: .systemFont(ofSize: t.size, weight: t.bold ? .semibold : .regular),
                      color: NSColor(t.bold ? Theme.textPrimary : Theme.textSecondary))
        }
        needsLayout = true
    }

    private func showLabel(_ value: String, font: NSFont, color: NSColor) {
        card?.isHidden = true
        if label.superview == nil {
            label.isSelectable = true
            addSubview(label)
        }
        label.isHidden = false
        label.font = font
        label.textColor = color
        label.stringValue = value
    }

    /// 卡这一行的点击交给表格（NSHostingView 会吞 mouseDown，表格就收不到 action）
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let card, !card.isHidden else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        let frame = NSRect(x: RunRecordTypography.horizontal, y: pad.top,
                           width: max(1, bounds.width - 2 * RunRecordTypography.horizontal),
                           height: max(1, bounds.height - pad.top - pad.bottom))
        label.frame = frame
        card?.frame = frame
    }
}

/// sheet 里的全文：NSTextView TextKit 2，只读可选中，自己滚
struct RunRecordTextView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        // 系统工厂建的就是 TextKit 2；离屏实测上屏 12ms，自己拼的那套 50ms
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.textColor = NSColor(Theme.textPrimary)
            textView.textContainerInset = NSSize(width: 0, height: 4)
            textView.string = text
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let textView = view.documentView as? NSTextView, textView.font?.pointSize != fontSize else { return }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
#endif
