#if canImport(UIKit)
import UIKit
import TranscriptCore

/// 对话列表。它只做两件事：把发生的事当成事务交给 `TranscriptEngine`，再执行引擎返回的指令。
/// **`contentOffset` 只经 `writeOffset(_:)` 写，而它只被「执行指令」那一段调用。** 别处要动位置，交事务。
@MainActor
public final class TranscriptViewController: UIViewController, UICollectionViewDelegate {
    public private(set) var engine = TranscriptEngine(width: 0, viewport: .init(height: 0))

    /// 用户拖动 / 程序滚动后位置变了（给回底钮、滚动条这类外面的东西用）
    public var onScroll: (() -> Void)?
    /// 列表的宽变了（首次有宽、转屏）。行的内容如果依赖宽度，在这里重新给行
    public var onLayoutWidthChange: (() -> Void)?

    private var rows: [String: TranscriptRow] = [:]
    private let layout = TranscriptCollectionLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    /// 只装列表这一个子视图的透明容器。要给「整页消息」加滤镜 / 蒙版的装饰（边缘模糊）挂在它的图层上，
    /// 不碰列表自己的图层，也不会连页面上别的东西一起罩进去
    private let contentContainer = UIView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
    private var registered = Set<String>()
    /// 正在执行引擎的指令：这期间列表报上来的位置变化是我们自己写的，不回报给引擎
    private var running = false
    /// 系统滚动动画在路上（`setContentOffset(animated:)`）
    private var systemAnimating = false
    private var keyboardAnimationID: Int?
    private var glideLink: CADisplayLink?
    private var glideLast: CFTimeInterval = 0
    private let measureQueue = DispatchQueue(label: "transcript.measure", qos: .userInitiated)
    private var measureGeneration = 0

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 nib 建") }

    // MARK: 对外

    /// 整份换成这些行（顺序：最新的在前）。增删由列表按 id 自己算
    /// 这一次 `setRows` 里换了种类的行（只在那一次调用期间有值）
    private var retyped: Set<String> = []

    /// `measured`：调用方已经在主线程量好的高度，和行集在同一轮里交给引擎（不等后台）。
    /// `streaming` = 这些高度属于正在流式输出的那条消息：跟随时长出来的部分滑上来，不限幅
    public func setRows(_ next: [TranscriptRow], measured: [TranscriptEngine.HeightReport] = [], streaming: Bool = false) {
        let previous = rows
        rows = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // 同一个 id 换了种类（流式里半截的块先是占位、下一拍变成列表）：cell 不能复用，得整个重建
        retyped = Set(next.compactMap { row in
            previous[row.id].flatMap { $0.renderer.reuseIdentifier != row.renderer.reuseIdentifier ? row.id : nil }
        })
        defer { retyped = [] }
        submit(.setRows(next.map(\.layoutRow)))
        if !measured.isEmpty { submit(.setHeights(measured, streaming: streaming)) }
        measureUnknownRows()
    }

    public func submit(_ transaction: TranscriptEngine.Transaction) {
        run(engine.apply(transaction))
    }

    /// 两头被盖住的高度：`start` 是屏幕底部（输入条），`end` 是屏幕顶部（顶栏）
    public func setInsets(start: CGFloat, end: CGFloat) {
        loadViewIfNeeded()
        collectionView.contentInset = UIEdgeInsets(top: start, left: 0, bottom: end, right: 0)
        collectionView.verticalScrollIndicatorInsets = collectionView.contentInset
        submitViewport()
    }

    public var scrollView: UIScrollView {
        loadViewIfNeeded()
        return collectionView
    }

    // MARK: 生命周期

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        contentContainer.backgroundColor = .clear
        contentContainer.frame = view.bounds
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.frame = contentContainer.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 翻转加在容器上，和旧页的结构一致（旧页的翻转也在挂滤镜的那一层，不在滚动视图上）。
        // 像素对拍的结果加在哪一层都一样，取结构一致的这种
        contentContainer.transform = .transcriptFlip
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.isPrefetchingEnabled = false
        collectionView.scrollsToTop = false
        collectionView.delegate = self
        layout.source = { [unowned self] in engine.layout }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [unowned self] view, indexPath, id in
            cell(in: view, at: indexPath, id: id)
        }
        contentContainer.addSubview(collectionView)
        view.addSubview(contentContainer)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopGlide()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        submitViewport()
    }

    private func submitViewport() {
        guard isViewLoaded else { return }
        let inset = collectionView.contentInset
        let widthBefore = engine.layout.width
        submit(.setViewport(.init(height: collectionView.bounds.height, insetStart: inset.top, insetEnd: inset.bottom),
                            width: collectionView.bounds.width))
        if engine.layout.width != widthBefore {
            measureUnknownRows()
            onLayoutWidthChange?()
        }
    }

    // MARK: 执行指令（唯一写 contentOffset 的地方）

    private func writeOffset(_ y: CGFloat) {
        let wasRunning = running
        running = true
        collectionView.contentOffset.y = y
        running = wasRunning
    }

    private func run(_ effects: [TranscriptEngine.Effect]) {
        guard isViewLoaded, !effects.isEmpty else { return }
        let wasRunning = running
        running = true
        defer { running = wasRunning }
        for effect in effects {
            switch effect {
            case .rowsChanged(let reconfigure, let adjustment):
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(engine.layout.rows.map(\.id))
                snapshot.reloadItems(Array(retyped))
                snapshot.reconfigureItems(Array(reconfigure.subtracting(retyped)))
                UIView.performWithoutAnimation {
                    dataSource?.apply(snapshot, animatingDifferences: false)
                    layout.invalidate(offsetAdjustment: adjustment)
                    collectionView.layoutIfNeeded()
                }

            case .layoutChanged(let adjustment):
                UIView.performWithoutAnimation {
                    layout.invalidate(offsetAdjustment: adjustment)
                    collectionView.layoutIfNeeded()
                }

            case .scroll(let target, let animation):
                if animation != .glide { stopGlide() }
                switch animation {
                case .none:
                    UIView.performWithoutAnimation { writeOffset(target) }
                case .glide:
                    startGlide()
                case .standard:
                    systemAnimating = true
                    collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                case .keyboard(let motion, let id):
                    keyboardAnimationID = id
                    let options = UIView.AnimationOptions(rawValue: motion.curve << 16)
                        .union([.beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve])
                    UIView.animate(withDuration: motion.duration, delay: 0, options: options) { [weak self] in
                        self?.writeOffset(target)
                    } completion: { [weak self] _ in
                        // 被更新的动画顶掉的不回报：引擎只认最新的那个 id
                        guard let self, self.keyboardAnimationID == id else { return }
                        self.keyboardAnimationID = nil
                        self.submit(.animationFinished(id: id))
                    }
                }
            }
        }
    }

    // MARK: 跟随滑入（`.glide` 的执行：逐帧按时间指数逼近引擎当前的位置；手指一碰、或引擎不再跟随，就停）

    private func startGlide() {
        guard glideLink == nil else { return }
        glideLast = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(glideTick(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
    }

    @objc private func glideTick(_ link: CADisplayLink) {
        if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating || !engine.isFollowing {
            stopGlide()
            return
        }
        let target = engine.offset
        let elapsed = max(0, link.timestamp - glideLast)
        glideLast = link.timestamp
        let remaining = collectionView.contentOffset.y - target
        guard remaining > 0.5 else {
            writeOffset(target)
            stopGlide()
            return
        }
        let step = max(1, remaining * (1 - exp(-elapsed / TranscriptEngine.glideResponse)))
        writeOffset(max(target, collectionView.contentOffset.y - step))
    }

    // MARK: 滚动回报

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !running else { return }
        let phase: TranscriptEngine.ScrollPhase
        if scrollView.isTracking {
            phase = .tracking
        } else if scrollView.isDecelerating {
            phase = .decelerating
        } else if systemAnimating {
            phase = .animating
        } else {
            phase = .idle
        }
        submit(.scrolled(to: scrollView.contentOffset.y, phase: phase))
        onScroll?()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        systemAnimating = false
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportIdle() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportIdle()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        systemAnimating = false
        reportIdle()
    }

    private func reportIdle() {
        submit(.scrolled(to: collectionView.contentOffset.y, phase: .idle))
        onScroll?()
    }

    // MARK: cell

    private func cell(in view: UICollectionView, at indexPath: IndexPath, id: String) -> UICollectionViewCell {
        guard let row = rows[id] else {
            return view.dequeueReusableCell(withReuseIdentifier: register("transcript.missing"), for: indexPath)
        }
        let cell = view.dequeueReusableCell(withReuseIdentifier: register(row.renderer.reuseIdentifier), for: indexPath)
        (cell as? TranscriptCell)?.host(row, width: engine.layout.width)
        return cell
    }

    private func register(_ identifier: String) -> String {
        if registered.insert(identifier).inserted {
            collectionView.register(TranscriptCell.self, forCellWithReuseIdentifier: identifier)
        }
        return identifier
    }

    // MARK: 量高度（后台算，主线程只收结果）

    private func measureUnknownRows() {
        let width = engine.layout.width
        guard width > 0 else { return }
        let pending = engine.layout.rows.indices.compactMap { index -> TranscriptRow? in
            let resolved = engine.layout.height(at: index)
            guard resolved.tier == .estimated else { return nil }
            return rows[engine.layout.rows[index].id]
        }
        guard !pending.isEmpty else { return }
        measureGeneration += 1
        let generation = measureGeneration
        measureQueue.async { [weak self] in
            guard self != nil else { return }
            // 分批回主线程：一万行的对话不会等全部量完才第一次更新
            for start in stride(from: 0, to: pending.count, by: 64) {
                let batch = pending[start..<min(start + 64, pending.count)].map { row in
                    TranscriptEngine.HeightReport(id: row.id, version: row.version,
                                                  height: row.renderer.height(width: width), tier: .prepared)
                }
                Task { @MainActor [weak self] in
                    guard let self, self.measureGeneration == generation, self.engine.layout.width == width else { return }
                    self.submit(.setHeights(batch))
                }
            }
        }
    }
}
#endif
