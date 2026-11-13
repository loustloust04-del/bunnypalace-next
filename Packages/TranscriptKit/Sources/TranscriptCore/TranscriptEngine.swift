import CoreGraphics

/// 对话列表的「位置」只有这一个主人。
///
/// 所有会让画面动的事——行变了、某行量出了新高度、键盘垫块变了、列表尺寸变了、要跳到某条、用户在拖——
/// 都是交给 `apply` 的一张事务。它算出新的排版和新的滚动位置，返回界面要执行的指令。
/// 界面层不许在别处写 `contentOffset`。
///
/// 保位规则只有一条：变更前记住「哪一行不许动」，变更后把它放回原处。
/// - 贴着起点（最新消息）时：不许动的是起点。新内容把旧内容往上推，最新的一直在底。
/// - 离开起点在看历史时：不许动的是屏幕上最靠上的那一行的上沿。它下面的行长高、
///   屏幕外更新的消息在流式长高、键盘弹起，都不会让正在看的内容挪位置。
///
/// 坐标是 `TranscriptLayout` 的一维坐标：0 在起点，界面翻转后起点在屏幕底部。
public struct TranscriptEngine: Sendable {
    public struct Viewport: Equatable, Sendable {
        /// 列表可见高度
        public var height: CGFloat
        /// 起点一侧被盖住的高度（翻转后在屏幕底部：输入条）
        public var insetStart: CGFloat
        /// 另一侧被盖住的高度（屏幕顶部：顶栏）
        public var insetEnd: CGFloat

        public init(height: CGFloat, insetStart: CGFloat = 0, insetEnd: CGFloat = 0) {
            self.height = height
            self.insetStart = insetStart
            self.insetEnd = insetEnd
        }
    }

    public enum ScrollPhase: Equatable, Sendable {
        /// 手指按着拖
        case tracking
        /// 松手后的惯性
        case decelerating
        /// 程序发起的带动画滚动还没到位
        case animating
        case idle
    }

    public struct HeightReport: Equatable, Sendable {
        public var id: String
        public var version: Int
        public var height: CGFloat
        public var tier: HeightTable.Tier

        public init(id: String, version: Int, height: CGFloat, tier: HeightTable.Tier) {
            self.id = id
            self.version = version
            self.height = height
            self.tier = tier
        }
    }

    /// 键盘动画的时长和曲线，原样转交给界面，让列表和键盘同一条曲线走
    public struct KeyboardMotion: Equatable, Sendable {
        public var duration: Double
        public var curve: UInt

        public init(duration: Double, curve: UInt) {
            self.duration = duration
            self.curve = curve
        }
    }

    /// 垫块为什么变
    public enum PadReason: Equatable, Sendable {
        /// 键盘起落（含切输入法、候选栏出没）
        case keyboard(KeyboardMotion)
        /// 发送时顺手收键盘：不滑，一步到位
        case sendDismiss
        /// 其它（输入条自己长高等）：瞬变，按保位规则
        case layout
    }

    public enum ScrollAnimation: Equatable, Sendable {
        case none
        /// 系统默认的滚动动画
        case standard
        /// 跟键盘同曲线。做完后界面要回报 `.animationFinished(id)`
        case keyboard(KeyboardMotion, id: Int)
    }

    /// 跳到某一行时，把它放在可见区的哪里
    public enum Alignment: Equatable, Sendable {
        /// 贴着起点一侧（屏幕底部）
        case start
        case center
        /// 贴着另一侧（屏幕顶部）
        case end
    }

    public enum Transaction: Sendable {
        case setRows([TranscriptLayout.Row])
        case setHeights([HeightReport])
        case setLeadingPad(CGFloat, reason: PadReason)
        /// `.scroll(…, animation: .keyboard(_, id))` 做完了（被新动画顶掉的不用报）
        case animationFinished(id: Int)
        case setViewport(Viewport, width: CGFloat)
        /// 列表报告的当前位置。用户的手是位置的另一个来源，只能如实记下来
        case scrolled(to: CGFloat, phase: ScrollPhase)
        case scrollToStart(animated: Bool)
        case scrollToRow(id: String, alignment: Alignment, animated: Bool)
    }

    public enum Effect: Equatable, Sendable {
        /// 行集变了：按 `layout.rows` 应用快照，`reconfigure` 里的行内容变了要重配。
        /// `offsetAdjustment` 和排版失效在同一次排版里加到当前位置上
        case rowsChanged(reconfigure: Set<String>, offsetAdjustment: CGFloat)
        /// 行集没变，位置或高度变了
        case layoutChanged(offsetAdjustment: CGFloat)
        /// 程序滚动到绝对位置
        case scroll(to: CGFloat, animation: ScrollAnimation)
    }

    /// 用户拖离起点超过这么多，才算「不跟了」
    public static let leaveFollowDistance: CGFloat = 20
    /// 回到离起点这么近，才算「又跟上了」。两个阈值不同，停在中间不会来回翻
    public static let regainFollowDistance: CGFloat = 4

    // 键盘策略的四个数，照旧页（PagingViewController.handleChatKeyboardRise / keyboardWillHide、KeyboardInsetBridge）
    /// 离起点这么近，键盘起落时算「在底」
    public static let keyboardNearStartDistance: CGFloat = 200
    /// 垫块变化不超过这么多（切输入法、候选栏出没）：不滑，一步到位
    public static let keyboardSmallStep: CGFloat = 45
    /// 弹键盘时离起点不超过这么多屏：回到最新消息；更远：原地不动
    public static let keyboardReturnScreens: CGFloat = 1.0
    /// 发送时离起点不超过这么多屏：回到最新消息；更远：原地不动
    public static let sendReturnScreens: CGFloat = 1.5

    public private(set) var layout: TranscriptLayout
    public private(set) var viewport: Viewport
    public private(set) var offset: CGFloat
    public private(set) var isFollowing = true
    public private(set) var phase: ScrollPhase = .idle
    /// 收键盘的滑动在路上：垫块先留着（留着才有合法的位置可滑），滑完再塌成 `pad`
    public private(set) var pendingPadRelease: (id: Int, pad: CGFloat)?
    private var lastAnimationID = 0

    public init(width: CGFloat, viewport: Viewport) {
        layout = TranscriptLayout(width: width)
        self.viewport = viewport
        offset = -viewport.insetStart
    }

    /// 贴着起点时的位置
    public var minOffset: CGFloat { -viewport.insetStart }

    public var maxOffset: CGFloat {
        max(minOffset, layout.contentLength - viewport.height + viewport.insetEnd)
    }

    public var distanceFromStart: CGFloat { offset - minOffset }

    /// 「贴着起点」现在对应的位置。收键盘滑到一半时垫块还留着，所以比 `minOffset` 多出还没塌的那一截
    private var pinnedOffset: CGFloat {
        minOffset + (pendingPadRelease.map { layout.leadingPad - $0.pad } ?? 0)
    }

    /// 没被两头盖住的那段，在排版坐标里的范围
    public var visibleRange: (minY: CGFloat, maxY: CGFloat) {
        (offset + viewport.insetStart, offset + viewport.height - viewport.insetEnd)
    }

    // MARK: -

    public mutating func apply(_ transaction: Transaction) -> [Effect] {
        switch transaction {
        case .setRows(let rows):
            guard rows != layout.rows else { return [] }
            let before = Dictionary(uniqueKeysWithValues: layout.rows.map { ($0.id, $0.version) })
            let reconfigure = Set(rows.compactMap { row in
                before[row.id].flatMap { $0 != row.version ? row.id : nil }
            })
            let adjustment = keepingAnchor { $0.setRows(rows) }
            return [.rowsChanged(reconfigure: reconfigure, offsetAdjustment: adjustment)]

        case .setHeights(let reports):
            var changed = false
            let adjustment = keepingAnchor { layout in
                for report in reports {
                    if layout.setHeight(report.height, tier: report.tier, id: report.id, version: report.version) {
                        changed = true
                    }
                }
            }
            return changed || adjustment != 0 ? [.layoutChanged(offsetAdjustment: adjustment)] : []

        case .setLeadingPad(let pad, let reason):
            return setLeadingPad(max(0, pad), reason: reason)

        case .animationFinished(let id):
            guard let pending = pendingPadRelease, pending.id == id else { return [] }
            pendingPadRelease = nil
            let before = offset
            layout.setLeadingPad(pending.pad)
            offset = minOffset
            isFollowing = true
            return [.layoutChanged(offsetAdjustment: offset - before)]

        case .setViewport(let next, let width):
            guard next != viewport || width != layout.width else { return [] }
            let anchor = captureAnchor()
            viewport = next
            layout.setWidth(width)
            return [.layoutChanged(offsetAdjustment: restore(anchor))]

        case .scrolled(let position, let next):
            offset = position
            phase = next
            switch next {
            case .tracking, .decelerating:
                if distanceFromStart > Self.leaveFollowDistance {
                    isFollowing = false
                } else if distanceFromStart <= Self.regainFollowDistance {
                    isFollowing = true
                }
            case .idle:
                if distanceFromStart <= Self.regainFollowDistance { isFollowing = true }
            case .animating:
                break
            }
            return []

        case .scrollToStart(let animated):
            isFollowing = true
            guard offset != minOffset else { return [] }
            offset = minOffset
            return [.scroll(to: minOffset, animation: animated ? .standard : .none)]

        case .scrollToRow(let id, let alignment, let animated):
            guard let frame = layout.frame(of: id) else { return [] }
            let visible = viewport.height - viewport.insetStart - viewport.insetEnd
            let target: CGFloat
            switch alignment {
            case .start: target = frame.minY - viewport.insetStart
            case .center: target = frame.minY + frame.height / 2 - viewport.insetStart - visible / 2
            case .end: target = frame.maxY - (viewport.height - viewport.insetEnd)
            }
            let clamped = min(max(target, minOffset), maxOffset)
            isFollowing = clamped - minOffset <= Self.regainFollowDistance
            guard clamped != offset else { return [] }
            offset = clamped
            return [.scroll(to: clamped, animation: animated ? .standard : .none)]
        }
    }

    // MARK: 键盘垫块

    private mutating func setLeadingPad(_ pad: CGFloat, reason: PadReason) -> [Effect] {
        let interrupted = pendingPadRelease != nil
        pendingPadRelease = nil
        let delta = pad - layout.leadingPad
        let distance = distanceFromStart
        let nearStart = isFollowing || distance < Self.keyboardNearStartDistance

        guard delta != 0 else {
            // 垫块没变，但收起的滑动被新的弹起打断了：从半路接着滑回最新消息
            guard interrupted, case .keyboard(let motion) = reason else { return [] }
            isFollowing = true
            offset = minOffset
            return [.scroll(to: minOffset, animation: .keyboard(motion, id: nextAnimationID()))]
        }

        switch reason {
        case .layout:
            return [.layoutChanged(offsetAdjustment: keepingAnchor { $0.setLeadingPad(pad) })]

        case .sendDismiss:
            guard distance <= viewport.height * Self.sendReturnScreens else {
                return [.layoutChanged(offsetAdjustment: keepingAnchor { $0.setLeadingPad(pad) })]
            }
            return [.layoutChanged(offsetAdjustment: pinToStart { $0.setLeadingPad(pad) })]

        case .keyboard(let motion):
            if nearStart, abs(delta) <= Self.keyboardSmallStep {
                return [.layoutChanged(offsetAdjustment: pinToStart { $0.setLeadingPad(pad) })]
            }
            if delta > 0 {
                guard distance <= viewport.height * Self.keyboardReturnScreens else {
                    isFollowing = false
                    return [.layoutChanged(offsetAdjustment: keepingAnchor { $0.setLeadingPad(pad) })]
                }
                // 垫块长出来的同一帧把位置加上同样多：画面先不动；再按键盘的曲线滑回最新消息
                layout.setLeadingPad(pad)
                isFollowing = true
                offset = minOffset
                return [.layoutChanged(offsetAdjustment: delta),
                        .scroll(to: minOffset, animation: .keyboard(motion, id: nextAnimationID()))]
            }
            guard nearStart else {
                return [.layoutChanged(offsetAdjustment: keepingAnchor { $0.setLeadingPad(pad) })]
            }
            // 收键盘：垫块先留着，内容跟着键盘滑下去；滑完（animationFinished）再塌垫块、归位，同一帧
            let id = nextAnimationID()
            pendingPadRelease = (id, pad)
            isFollowing = true
            offset = pinnedOffset
            return [.scroll(to: offset, animation: .keyboard(motion, id: id))]
        }
    }

    private mutating func nextAnimationID() -> Int {
        lastAnimationID += 1
        return lastAnimationID
    }

    /// 改排版，然后钉回最新消息。返回位置要加多少
    private mutating func pinToStart(_ change: (inout TranscriptLayout) -> Void) -> CGFloat {
        let before = offset
        change(&layout)
        isFollowing = true
        offset = minOffset
        return offset - before
    }

    // MARK: 保位

    private enum Anchor {
        /// 贴着起点
        case start
        /// 这一行的 maxY（屏幕上的上沿）离当前位置这么远
        case row(id: String, distance: CGFloat)
        /// 屏幕上没有行：位置原样
        case none
    }

    private func captureAnchor() -> Anchor {
        if isFollowing { return .start }
        let visible = visibleRange
        guard let last = layout.indices(intersecting: visible.minY, visible.maxY).last else { return .none }
        return .row(id: layout.rows[last].id, distance: layout.frame(at: last).maxY - offset)
    }

    /// 把不许动的那一行放回原处，返回位置要加多少
    private mutating func restore(_ anchor: Anchor) -> CGFloat {
        var target = offset
        switch anchor {
        case .start:
            target = pinnedOffset
        case .row(let id, let distance):
            if let frame = layout.frame(of: id) { target = frame.maxY - distance }
        case .none:
            break
        }
        target = min(max(target, minOffset), maxOffset)
        let adjustment = target - offset
        offset = target
        return adjustment
    }

    private mutating func keepingAnchor(_ change: (inout TranscriptLayout) -> Void) -> CGFloat {
        let anchor = captureAnchor()
        change(&layout)
        return restore(anchor)
    }
}
