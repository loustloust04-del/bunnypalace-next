#if os(iOS)
import SwiftUI
import UIKit

/// 群聊页的 UIKit 主体（plan-group-room-uikit）：消息列表 + 输入框 + 键盘。外皮（顶部浮层 / sheet / 背景）在 SwiftUI `AgoraRoomView`。
/// 根视图标 `KeyboardSelfManaging`：输入框自己贴 `keyboardLayoutGuide`，PagingViewController 见到第一响应者在这下面
/// 就不再对聊天页做键盘垫块（那套是给一对一 CardFlowView 的）。
final class GroupRoomRootView: UIView, KeyboardSelfManaging {}

final class AgoraRoomViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    private enum Item: Hashable {
        case loadOlder
        case date(String)
        case message(String)
        case typing(String)
        case empty
    }

    private enum Row: Equatable {
        case loadOlder(isLoading: Bool)
        case date(Date)
        case message(GroupMessageRowModel)
        case typing(AgoraTypingPresence, AgoraMember?, othersHex: String?)
        case empty(isLoading: Bool)
    }

    let viewModel: AgoraViewModel
    /// SwiftUI 顶部浮层（按钮行 + 状态药丸）的高度：列表内容从它下面开始，滚动时从它底下滚过去
    var topOverlayHeight: CGFloat = 0 {
        didSet { if topOverlayHeight != oldValue { view.setNeedsLayout() } }
    }
    /// 气泡颜色（外皮按「这个群 → 设置 → 默认」算好传进来）；变了整表重配
    var bubbleColors = GroupBubbleColors() {
        didSet { if bubbleColors != oldValue, isViewLoaded { renderList() } }
    }

    private let flowLayout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let listContainer = UIView()
    private let edgeBlur = ChatContentEdgeBlur.AttachmentView()
    private let composer = GroupRoomComposerView()

    private var items: [Item] = []
    private var rows: [Item: Row] = [:]
    private var layoutCache: [String: (model: GroupMessageRowModel, layout: GroupMessageLayout)] = [:]
    private var cacheWidth: CGFloat = 0
    private var cacheSettings = ""
    private var lastLayoutWidth: CGFloat = 0
    private var renderedRoomId: String?
    private var wasLoadingRoom = false
    /// 进房后已经滚到过底：这之后才允许滚到顶自动加载更早
    private var didInitialScroll = false
    /// 视图还没尺寸时先记着，布局好了再滚到底
    private var pendingScrollToBottom = false
    private var composerRendered = false

    init(viewModel: AgoraViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = GroupRoomRootView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.register(GroupMessageCell.self, forCellWithReuseIdentifier: GroupMessageCell.reuseID)
        collectionView.register(GroupDateCell.self, forCellWithReuseIdentifier: GroupDateCell.reuseID)
        collectionView.register(GroupTypingCell.self, forCellWithReuseIdentifier: GroupTypingCell.reuseID)
        collectionView.register(GroupLoadOlderCell.self, forCellWithReuseIdentifier: GroupLoadOlderCell.reuseID)
        collectionView.register(GroupEmptyCell.self, forCellWithReuseIdentifier: GroupEmptyCell.reuseID)
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            self?.cell(collectionView, indexPath: indexPath, item: item)
                ?? collectionView.dequeueReusableCell(withReuseIdentifier: GroupLoadOlderCell.reuseID, for: indexPath)
        }

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        // 顶部 / 底部模糊学 page1：ChatContentEdgeBlur 只给「消息层」加渐进模糊（顶部 130pt、输入框那段），
        // 它要求列表独占一个透明容器（容器只有这一个子视图），所以列表外面包一层
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(collectionView)
        edgeBlur.isUserInteractionEnabled = false
        collectionView.addSubview(edgeBlur)
        view.addSubview(listContainer)
        view.addSubview(composer)
        NSLayoutConstraint.activate([
            listContainer.topAnchor.constraint(equalTo: view.topAnchor),
            listContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            // 贴键盘上沿（没键盘时 = 底部安全区）留 6
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -6),
        ])

        composer.onTextChange = { [weak self] text in
            guard let self else { return }
            viewModel.composerText = text
            viewModel.composerChanged()
        }
        composer.onSend = { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.post() }
        }
        composer.onCancelEditing = { [weak self] in self?.viewModel.cancelEditing() }
        composer.onCancelReply = { [weak self] in self?.viewModel.cancelReply() }
        composer.onPickMention = { [weak self] handle in self?.insertMention(handle) }
        composer.onLayout = { [weak self] in
            self?.updateInsets()
            self?.updateEdgeBlur()
        }

        observeList()
        observeComposer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if collectionView.bounds.width != lastLayoutWidth {
            lastLayoutWidth = collectionView.bounds.width
            flowLayout.invalidateLayout()
        }
        updateInsets()
        updateEdgeBlur()
        if pendingScrollToBottom, collectionView.bounds.height > 0 {
            pendingScrollToBottom = false
            scrollToBottom(animated: false)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    // MARK: - 观察 view model

    private func observeList() {
        withObservationTracking { renderList() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeList() }
        }
    }

    private func observeComposer() {
        withObservationTracking { renderComposer() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeComposer() }
        }
    }

    private var room: AgoraRoomSummary? {
        viewModel.rooms.first { $0.id == viewModel.selectedRoomId }
    }

    private var enabledAgents: [AgoraMember] {
        viewModel.membersByActorId.values
            .filter { $0.isEnabled && $0.role == .member }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var mentionPrefix: String? {
        let text = viewModel.composerText
        guard let expression = try? NSRegularExpression(pattern: #"(?:^|\s)@([A-Za-z0-9_.-]*)$"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private var autocompleteMembers: [AgoraMember] {
        guard let prefix = mentionPrefix else { return [] }
        return enabledAgents.filter {
            prefix.isEmpty || $0.handle.lowercased().hasPrefix(prefix.lowercased())
        }
    }

    private var canPost: Bool {
        guard room?.isEnabled == true, !viewModel.isPosting else { return false }
        guard case .connected = viewModel.connectionState else { return false }
        return !viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var typingMembers: [AgoraTypingPresence] {
        viewModel.typingByActorId.values
            .filter(\.isTyping)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// 隔了 15 分钟以上 / 跨天 = 新的一段：插日期分隔，连发也从这里断开
    private static let runGap: TimeInterval = 15 * 60

    private static func startsNewBlock(_ messages: [AgoraMessage], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = messages[index - 1].createdAt, current = messages[index].createdAt
        return current.timeIntervalSince(previous) > runGap || !Calendar.current.isDate(previous, inSameDayAs: current)
    }

    private func renderComposer() {
        let text = viewModel.composerText
        // 程序改的字（开始编辑 / 取消 / 发出去清空 / 插入 @）也要通知一次，和原来 TextField onChange 一样
        let external = composerRendered && text != composer.textView.text
        composerRendered = true
        composer.apply(.init(
            text: text,
            isEditing: viewModel.editingMessageId != nil,
            reply: viewModel.replyingMessage.map {
                .init(name: viewModel.displayName(of: $0), snippet: AgoraViewModel.replySnippet($0.content, limit: 40))
            },
            isPosting: viewModel.isPosting,
            canPost: canPost,
            isEnabled: room?.isEnabled == true,
            suggestions: autocompleteMembers
        ))
        if external {
            Task { @MainActor [weak self] in self?.viewModel.composerChanged() }
        }
    }

    // MARK: - 列表

    private func renderList() {
        let messages = viewModel.messages
        let members = viewModel.membersByActorId
        let ownerActorId = room?.ownerActorId ?? ""
        let handles = Set(members.values.map(\.handle))
        let roomId = viewModel.selectedRoomId
        let isLoadingRoom = viewModel.isLoadingRoom

        var newItems: [Item] = []
        var newRows: [Item: Row] = [:]
        func add(_ item: Item, _ row: Row) {
            newItems.append(item)
            newRows[item] = row
        }
        if viewModel.hasMoreOlder { add(.loadOlder, .loadOlder(isLoading: viewModel.isLoadingOlder)) }
        if messages.isEmpty { add(.empty, .empty(isLoading: isLoadingRoom)) }
        for (index, message) in messages.enumerated() {
            let separated = Self.startsNewBlock(messages, at: index)
            if separated { add(.date(message.id), .date(message.createdAt)) }
            let member = members[message.actorId]
            let sameSpeaker = !separated && messages[index - 1].actorId == message.actorId
            let continuesRun = index + 1 < messages.count
                && messages[index + 1].actorId == message.actorId
                && !Self.startsNewBlock(messages, at: index + 1)
            add(.message(message.id), .message(GroupMessageRowModel(
                message: message,
                displayName: member?.displayName ?? "未知成员",
                handle: member?.handle,
                isOwner: member?.role == .owner || message.actorId == ownerActorId,
                showsName: !sameSpeaker,
                continuesRun: continuesRun,
                topGap: separated ? 0 : (sameSpeaker ? GroupRoomMetrics.runGap : GroupRoomMetrics.speakerGap),
                memberHandles: handles,
                reactions: viewModel.reactions(for: message),
                colors: bubbleColors
            )))
        }
        for presence in typingMembers {
            add(.typing(presence.actorId), .typing(presence, members[presence.actorId], othersHex: bubbleColors.othersHex))
        }

        let roomChanged = roomId != renderedRoomId
        let loadFinished = wasLoadingRoom && !isLoadingRoom
        let oldFirstMessage = items.first { if case .message = $0 { true } else { false } }
        let prepended = !roomChanged && oldFirstMessage != nil
            && newItems.first(where: { if case .message = $0 { true } else { false } }) != oldFirstMessage
            && newItems.contains(oldFirstMessage!)
        let grewAtEnd = newItems.last != items.last && !newItems.isEmpty
        let nearBottom = isNearBottom
        let changed = newItems.filter { rows[$0] != nil && rows[$0] != newRows[$0] }

        renderedRoomId = roomId
        wasLoadingRoom = isLoadingRoom
        items = newItems
        rows = newRows

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(newItems)
        snapshot.reconfigureItems(changed)

        if prepended {
            // 加载更早：插在顶上，保持当前看的位置不跳
            let oldHeight = collectionView.contentSize.height
            let oldOffset = collectionView.contentOffset.y
            dataSource.apply(snapshot, animatingDifferences: false)
            if !changed.isEmpty { flowLayout.invalidateLayout() }
            collectionView.layoutIfNeeded()
            collectionView.contentOffset.y = oldOffset + collectionView.contentSize.height - oldHeight
        } else if roomChanged || loadFinished || !didInitialScroll {
            // 进房 / 加载完：直接落在底部
            dataSource.apply(snapshot, animatingDifferences: false)
            if !changed.isEmpty { flowLayout.invalidateLayout() }
            if roomChanged { didInitialScroll = false }
            if !messages.isEmpty || roomChanged { requestScrollToBottom() }
            if !messages.isEmpty { didInitialScroll = true }
        } else {
            dataSource.apply(snapshot, animatingDifferences: true)
            if !changed.isEmpty { flowLayout.invalidateLayout() }
            // 有新消息 / 有人开始输入，且本来就在底部附近 → 跟到底；不在底部就不动
            if grewAtEnd && nearBottom { scrollToBottom(animated: true) }
        }
        maybeLoadOlder()
    }

    private func cell(_ collectionView: UICollectionView, indexPath: IndexPath, item: Item) -> UICollectionViewCell? {
        guard let row = rows[item] else { return nil }
        switch row {
        case .loadOlder(let isLoading):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GroupLoadOlderCell.reuseID, for: indexPath) as? GroupLoadOlderCell
            cell?.configure(isLoading: isLoading)
            return cell
        case .date(let date):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GroupDateCell.reuseID, for: indexPath) as? GroupDateCell
            cell?.configure(date: date)
            return cell
        case .message(let model):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GroupMessageCell.reuseID, for: indexPath) as? GroupMessageCell
            cell?.configure(model: model, layout: messageLayout(model, width: collectionView.bounds.width))
            cell?.onLongPress = { [weak self] message, bubble in self?.presentActions(for: message, bubble: bubble) }
            cell?.onToggleReaction = { [weak self] message, emoji in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.viewModel.toggleReaction(emoji, on: message)
            }
            return cell
        case .typing(let presence, let member, let othersHex):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GroupTypingCell.reuseID, for: indexPath) as? GroupTypingCell
            cell?.configure(presence: presence, member: member, othersHex: othersHex)
            return cell
        case .empty(let isLoading):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GroupEmptyCell.reuseID, for: indexPath) as? GroupEmptyCell
            cell?.configure(isLoading: isLoading)
            return cell
        }
    }

    private func messageLayout(_ model: GroupMessageRowModel, width: CGFloat) -> GroupMessageLayout {
        let settings = GroupRoomMetrics.settingsKey
        if width != cacheWidth || settings != cacheSettings {
            layoutCache.removeAll()
            cacheWidth = width
            cacheSettings = settings
        }
        if let hit = layoutCache[model.message.id], hit.model == model { return hit.layout }
        let layout = GroupMessageLayout(model: model, width: width)
        layoutCache[model.message.id] = (model, layout)
        return layout
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width
        guard width > 0, let item = dataSource.itemIdentifier(for: indexPath), let row = rows[item] else {
            return CGSize(width: max(width, 1), height: 1)
        }
        let height: CGFloat
        switch row {
        case .loadOlder: height = GroupLoadOlderCell.height
        case .date: height = GroupDateCell.height
        case .message(let model): height = messageLayout(model, width: width).height
        case .typing: height = GroupTypingCell.height
        case .empty:
            let inset = collectionView.contentInset
            height = max(200, collectionView.bounds.height - inset.top - inset.bottom - (viewModel.hasMoreOlder ? GroupLoadOlderCell.height : 0))
        }
        return CGSize(width: width, height: max(1, height))
    }

    /// page1 同款消息层边缘模糊：半径读外观设置 blurRadius（默认 1.3），底部那段跟着输入框 / 键盘走
    private func updateEdgeBlur() {
        edgeBlur.radius = UserDefaults.standard.object(forKey: "blurRadius") as? Double ?? 1.3
        edgeBlur.inputBarBottom = composer.frame.maxY
        edgeBlur.keyboardVisible = view.keyboardLayoutGuide.layoutFrame.height > view.safeAreaInsets.bottom + 1
        edgeBlur.enabled = !viewModel.messages.isEmpty
        edgeBlur.attach()
    }

    // MARK: - 长按浮层

    private func presentActions(for message: AgoraMessage, bubble: GroupBubbleView) {
        guard !message.isDeleted, let window = view.window else { return }
        bubble.textView.selectedTextRange = nil
        var items: [GroupMessageActionOverlay.MenuItem] = [
            .init(title: "回复", systemImage: "arrowshape.turn.up.left") { [weak self] in
                self?.viewModel.beginReply(message)
                self?.composer.focus()
            },
            .init(title: "复制", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.content
            },
            .init(title: "显示时间", systemImage: "clock",
                  revealedTitle: message.createdAt.formatted(.dateTime.year().month().day().hour().minute())),
        ]
        // 只有房主（你）自己的消息能编辑；编辑 / 删除是第二组（上面画组界）
        let canEdit = message.actorId == room?.ownerActorId
        if canEdit {
            items.append(.init(title: "编辑", systemImage: "pencil", dividerBefore: true) { [weak self] in
                self?.viewModel.beginEditing(message)
                self?.composer.focus()
            })
        }
        items.append(.init(title: "删除", systemImage: "trash", isDestructive: true, dividerBefore: !canEdit) { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.deleteMessage(message) }
        })
        let overlay = GroupMessageActionOverlay(source: bubble, selected: Set(viewModel.reactions(for: message)), items: items)
        overlay.onReact = { [weak self] emoji in self?.viewModel.toggleReaction(emoji, on: message) }
        // 键盘弹着时可见区到键盘上沿（没键盘时 = 底部安全区上沿）
        let keyboardTop = view.convert(view.keyboardLayoutGuide.layoutFrame, to: window).minY
        overlay.present(in: window, bottomLimit: keyboardTop)
    }

    // MARK: - @ 补全

    private func insertMention(_ handle: String) {
        let text = viewModel.composerText
        guard let expression = try? NSRegularExpression(pattern: #"@([A-Za-z0-9_.-]*)$"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return }
        viewModel.composerText.replaceSubrange(range, with: "@\(handle) ")
        composer.focus()
    }

    // MARK: - 滚动 / inset

    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.contentInset.bottom
        return collectionView.contentSize.height - visibleBottom < 80
    }

    private func requestScrollToBottom() {
        if collectionView.bounds.height > 0 {
            scrollToBottom(animated: false)
        } else {
            pendingScrollToBottom = true
        }
    }

    private func scrollToBottom(animated: Bool) {
        collectionView.layoutIfNeeded()
        let inset = collectionView.contentInset
        let y = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    /// 顶部 = 安全区 + SwiftUI 浮层；底部 = 输入框（跟着键盘走）以下全部。键盘动画里的布局也走这里，
    /// 本来在底部就一起跟上去（不在拖动中才跟，免得和手指抢）
    private func updateInsets() {
        guard isViewLoaded, view.bounds.height > 0 else { return }
        let top = view.safeAreaInsets.top + topOverlayHeight + 10
        let bottom = max(0, view.bounds.height - composer.frame.minY) + 10
        let current = collectionView.contentInset
        guard abs(current.top - top) > 0.5 || abs(current.bottom - bottom) > 0.5 else { return }
        let pinToBottom = isNearBottom && !collectionView.isTracking
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        collectionView.contentInset = insets
        collectionView.verticalScrollIndicatorInsets = insets
        if items.contains(.empty) { flowLayout.invalidateLayout() }
        if pinToBottom { scrollToBottom(animated: false) }
    }

    /// 滚到顶附近自动加载更早（进房滚到底之后才开始，内容不满一屏也会接着拉）
    private func maybeLoadOlder() {
        guard didInitialScroll, !pendingScrollToBottom, viewModel.hasMoreOlder, !viewModel.isLoadingOlder,
              collectionView.contentOffset.y + collectionView.contentInset.top < 300 else { return }
        Task { await viewModel.loadOlder() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        maybeLoadOlder()
    }
}
#endif
