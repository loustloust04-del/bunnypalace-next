#if canImport(UIKit)
import UIKit
import Combine

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 终端键盘工具条。**不是 `inputAccessoryView`** —— 它是终端页内的常驻 UIKit 层，
/// 底边直绑宿主视图的 `keyboardLayoutGuide`（聊天页输入条同款成熟路径，
/// `PagingViewController.swift:169` 在案）。
///
/// 为什么要脱离 accessory（plan §C0）：
/// 老实现 `TerminalAccessoryBar` 是 `tv.inputAccessoryView`，那条 52pt 收键盘后会赖在
/// `keyboardLayoutGuide` 里不回落到 34，把直绑 guide 的聊天页输入条顶高 18pt
/// （08-26 Bug1，探针实证 y 786 vs 804）。为此长出了「摘条必须在 resign 之前」的铁律
/// （`dismissTerminalKeyboard` / `restoreAccessoryBar` / `observeLeavingTerminalPage` 三件套），
/// 而摘条又是 08-26 递归闪退（040818.ips 六层栈爆）的老家。改成常驻层后 guide 里根本没有
/// accessory，**铁律整个消失**，翻离终端页只需 resign。
///
/// 显隐语义（粟粟 08-31 批注 §五-3）：**条跟软键盘一起起、一起藏**，没有「收了键盘条留底」
/// 这个中间态。dismiss ⌄ = 收键盘 + 条一起消失；点终端 = 键盘 + 条一起回来。
final class TerminalToolbarView: UIView {
    /// 已合成好的字节，发给终端
    var onSendBytes: (([UInt8]) -> Void)?
    /// 内部动作（dismiss / 窗口切换 / compose / 粘贴 / 设置），不发字节
    var onAction: ((TerminalKeyID) -> Void)?
    /// 条高变了（抽屉展开/收起）—— 终端要重算键盘避让
    var onHeightChange: ((CGFloat) -> Void)?

    private let store: TerminalToolbarStore
    private var cancellables: Set<AnyCancellable> = []

    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let vStack = UIStackView()
    private let drawerContainer = UIStackView()
    private let mainRow = UIStackView()

    private var sizes: TerminalToolbarSizes = .portrait
    /// 上次重建时的宽度。宽度变化超 10pt 才重建实际键集（物料表 §9.2）
    private var lastBuildWidth: CGFloat = 0
    private var drawerHeightConstraint: NSLayoutConstraint!
    // 竖/横两档尺寸切换要改的约束（物料表 §9.1/§9.5）
    private var pillLeading: NSLayoutConstraint!
    private var pillTrailing: NSLayoutConstraint!
    private var pillTop: NSLayoutConstraint!
    private var pillBottom: NSLayoutConstraint!
    private var rowLeading: NSLayoutConstraint!
    private var rowTrailing: NSLayoutConstraint!
    private var mainRowHeight: NSLayoutConstraint!

    /// 当前展开的抽屉行数
    private(set) var visibleDrawerRows = 0
    private var resolved = TerminalToolbarResolvedLayout(mainRow: [], drawerRows: [[]], capacity: 0)
    /// 状态机本体在 `TerminalDrawerState`（跨平台，好上单测）；这里只存当前值
    private var drawerState: TerminalDrawerState = .closed
    private weak var drawerToggleButton: TerminalKeyButton?
    /// 粘滞三态（物料表 §2）。同一个修饰键可以同时出现在主行和抽屉里，任一副本变了
    /// 要同步刷新所有副本的外观（§2.2），所以按钮统一收在这里。
    private var modifierState = TerminalModifierState()

    init(store: TerminalToolbarStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .clear
        // alpha 0 起步：没聚焦时不该露脸（真正的显隐由 setVisible 跟着键盘通知走）
        alpha = 0

        // iOS 26 Liquid Glass 药丸（floating，左右留边）。systemThinMaterial 在深色终端上发灰
        // 「看不见玻璃」，UIGlassEffect 才有真玻璃质感 —— 沿用老条已拍板的调性。
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        addSubview(glass)

        vStack.axis = .vertical
        vStack.spacing = 0
        vStack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(vStack)

        drawerContainer.axis = .vertical
        drawerContainer.spacing = 0
        drawerContainer.distribution = .fillEqually
        drawerContainer.isHidden = true

        mainRow.axis = .horizontal
        mainRow.spacing = 0
        mainRow.alignment = .center
        mainRow.distribution = .fillEqually   // 物料表 §9.3：主行等分可用宽

        vStack.addArrangedSubview(drawerContainer)
        vStack.addArrangedSubview(mainRow)

        drawerHeightConstraint = drawerContainer.heightAnchor.constraint(equalToConstant: 0)
        pillLeading = glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sizes.pillInset)
        pillTrailing = glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sizes.pillInset)
        pillTop = glass.topAnchor.constraint(equalTo: topAnchor, constant: sizes.pillPadding)
        pillBottom = glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -sizes.pillPadding)
        rowLeading = vStack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor,
                                                     constant: sizes.rowEdgePadding)
        rowTrailing = vStack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor,
                                                       constant: -sizes.rowEdgePadding)
        mainRowHeight = mainRow.heightAnchor.constraint(equalToConstant: sizes.rowHeight)
        NSLayoutConstraint.activate([
            pillLeading, pillTrailing, pillTop, pillBottom,
            rowLeading, rowTrailing,
            vStack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            vStack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            mainRowHeight,
            drawerHeightConstraint,
        ])
        glass.layer.cornerRadius = sizes.pillCorner

        store.$layout.sink { [weak self] _ in self?.setNeedsRebuild() }.store(in: &cancellables)
        store.$customKeys.sink { [weak self] _ in self?.setNeedsRebuild() }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 布局

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: sizes.totalHeight(drawerRows: visibleDrawerRows))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        guard w > 0 else { return }
        // 竖/横切档：trait 的 verticalSizeClass 优先，拿不到看屏幕长宽比（物料表 §9.2）
        let screen = window?.windowScene?.screen.bounds.size ?? bounds.size
        let next = TerminalToolbarSizes.resolve(for: traitCollection, screenSize: screen)
        if next != sizes {
            sizes = next
            applySizeConstraints()
            lastBuildWidth = w
            rebuild()          // 键宽/键高变了，按钮要按新档重建
            return
        }
        // 旋转后宽度变了会改主行容量和溢出，超 10pt 才重建（物料表 §9.2/§10.2）
        if abs(w - lastBuildWidth) > 10 {
            lastBuildWidth = w
            rebuild()
        }
    }

    private func applySizeConstraints() {
        pillLeading.constant = sizes.pillInset
        pillTrailing.constant = -sizes.pillInset
        pillTop.constant = sizes.pillPadding
        pillBottom.constant = -sizes.pillPadding
        rowLeading.constant = sizes.rowEdgePadding
        rowTrailing.constant = -sizes.rowEdgePadding
        mainRowHeight.constant = sizes.rowHeight
        glass.layer.cornerRadius = sizes.pillCorner
    }

    private var needsRebuild = false

    private func setNeedsRebuild() {
        guard !needsRebuild else { return }
        needsRebuild = true
        DispatchQueue.main.async { [weak self] in
            self?.needsRebuild = false
            self?.rebuild()
        }
    }

    /// 主行可用宽 = 药丸内宽 − 行内左右边距（物料表 §9.3 末条）
    private var availableWidth: CGFloat {
        max(0, lastBuildWidth - sizes.pillInset * 2 - sizes.rowEdgePadding * 2)
    }

    private func rebuild() {
        guard lastBuildWidth > 0 else { return }
        resolved = TerminalToolbarCapacity.resolve(layout: store.layout,
                                                   availableWidth: availableWidth,
                                                   normalWidth: sizes.normalWidth)
        mainRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        drawerToggleButton = nil
        for slot in resolved.mainRow {
            let button = makeButton(slot)
            if slot.builtInID == .drawerToggle { drawerToggleButton = button as? TerminalKeyButton }
            mainRow.addArrangedSubview(button)
        }
        // 宽度变了会重建，已开的抽屉 count/index 得夹回当前行数（物料表 §6.1）
        clampDrawerState()
        rebuildDrawer()
        applyHeight()
    }

    // MARK: 抽屉

    private var drawerRowCount: Int { max(1, resolved.drawerRows.count) }

    private func clampDrawerState() {
        drawerState = drawerState.clamped(rowCount: drawerRowCount)
    }

    private func advanceDrawer() {
        drawerState = drawerState.advanced(mode: store.drawerToggleMode, rowCount: drawerRowCount)
        rebuildDrawer()
        applyHeight()
    }

    private func rebuildDrawer() {
        drawerContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let indices = drawerState.visibleRowIndices(rowCount: drawerRowCount)
        for i in indices where resolved.drawerRows.indices.contains(i) {
            drawerContainer.addArrangedSubview(makeDrawerRow(resolved.drawerRows[i]))
        }
        drawerContainer.isHidden = indices.isEmpty
        visibleDrawerRows = indices.count
        drawerHeightConstraint.constant = sizes.rowHeight * CGFloat(indices.count)
        // 「…」开着时上 active 背景，0.1s（物料表 §6.4 —— 这是 toggle 高亮，不是抽屉高度动画）
        UIView.animate(withDuration: 0.1) {
            self.drawerToggleButton?.stickyBackgroundColor =
                indices.isEmpty ? nil : UIColor.label.withAlphaComponent(0.12)
        }
    }

    /// 一行抽屉：横滚 + 按 intrinsic 宽排（物料表 §6.3/§9.4），行底 0.5pt 50% 分隔线。
    /// **展开/收起不自造动画** —— 高度变化交给布局系统（plan §C3 末条）。
    private func makeDrawerRow(_ slots: [TerminalKeySlot]) -> UIView {
        let host = UIView()
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scroll)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 0
        row.alignment = .center
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        for slot in TerminalToolbarCapacity.drawerRenderable(slots) {
            row.addArrangedSubview(makeButton(slot))
        }
        scroll.addSubview(row)

        let separator = UIView()
        separator.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
        separator.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(separator)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            separator.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        return host
    }

    private var lastReportedHeight: CGFloat = 0

    private func applyHeight() {
        invalidateIntrinsicContentSize()
        let height = sizes.totalHeight(drawerRows: visibleDrawerRows)
        // 只在真变了才通知 —— 这条链尽头是终端的 transform 动画，每次 layout 都放一次会抖
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onHeightChange?(height)
    }

    private func makeButton(_ slot: TerminalKeySlot) -> UIView {
        let b: TerminalKeyButton
        if slot.builtInID == .arrowJoystick {
            let joystick = TerminalArrowJoystickButton(slot: slot, sizes: sizes)
            joystick.onDirection = { [weak self] direction in self?.joystickMoved(direction) }
            b = joystick
        } else if let id = slot.builtInID, let mod = TerminalKeyModifiers(keyID: id) {
            b = TerminalModifierButton(slot: slot, sizes: sizes, modifier: mod)
        } else {
            b = TerminalKeyButton(slot: slot, sizes: sizes)
        }
        if let id = slot.builtInID {
            if let ch = id.symbolCharacter {
                b.setTitle(String(ch))
            } else if let icon = id.iconName {
                b.setIcon(icon)
            } else {
                b.setTitle(id.settingsLabel)
            }
            // Tab 和方向键长按连发（物料表 §1.2 第 7 行 / §3.3）
            b.repeatsOnHold = (id == .tab || id.kind == .navigation)
        } else if let uuid = slot.customID, let key = store.customKey(uuid) {
            if let icon = key.iconName { b.setIcon(icon) } else { b.setTitle(key.displayText) }
        } else {
            b.setTitle("?")
        }
        b.onPress = { [weak self] s in self?.keyPressed(s) }
        // 三态外观最后套 —— 它会把 Shift 的图标换成 shift.fill，得排在上面的 setIcon 之后
        if let mb = b as? TerminalModifierButton { mb.phase = modifierState.phase(mb.modifier) }
        return b
    }

    // MARK: 派发

    private func keyPressed(_ slot: TerminalKeySlot) {
        if let id = slot.builtInID {
            switch id.kind {
            case .action:
                // 内部 action 直接 return，**不消耗 oneShot 修饰键**（物料表 §2.2 边界）
                onAction?(id)
                return
            case .toggle:
                // 抽屉 / joystick 是条自己的事，不外抛。**也不消耗 oneShot 修饰键**
                //（物料表 §2.2 边界：点了 Ctrl 再开抽屉，Ctrl 还留给下一个真键）
                if id == .drawerToggle { advanceDrawer() }
                return
            case .modifier:
                guard let mod = TerminalKeyModifiers(keyID: id) else { return }
                modifierState.tap(mod, at: Date.timeIntervalSinceReferenceDate)
                refreshModifierButtons()
                return
            default:
                break
            }
            // 真键：套上活跃修饰位合成字节，发完清 oneShot（locked 保留）
            if let bytes = TerminalByteComposer.bytes(forKey: id, modifiers: modifierState.active) {
                onSendBytes?(bytes)
                consumeOneShots()
            }
        } else if let uuid = slot.customID, let key = store.customKey(uuid) {
            sendCustomKey(key)
        }
    }

    /// 摇杆拖出一个方向。粘滞修饰照样参与合成（Ctrl+joystick 有效，物料表 §3.2），
    /// 首发用掉 oneShot 之后的连发就是纯方向键。
    private func joystickMoved(_ direction: TerminalKeyCombo.SpecialKey) {
        onSendBytes?(TerminalByteComposer.bytes(forSpecial: direction, modifiers: modifierState.active))
        consumeOneShots()
    }

    /// 软键盘打的字也要过修饰状态机（plan §C4：合成点插在 `Coordinator.send` 前）。
    /// 返回合成后的字节；没有活跃修饰位就原样返回。
    func applyModifiers(to bytes: [UInt8]) -> [UInt8] {
        let mods = modifierState.active
        guard !mods.isEmpty else { return bytes }
        defer { consumeOneShots() }
        // 只对单个 ASCII 字符合成。多字节（中文、粘贴、IME 上屏一整串）套修饰没有意义；
        // ≥ 0x80 的单字节也不行 —— 那是 Latin-1 标量，重新 UTF-8 编码会变成两个字节。
        guard bytes.count == 1, bytes[0] < 0x80 else { return bytes }
        return TerminalByteComposer.bytes(forCharacter: Character(UnicodeScalar(bytes[0])),
                                          modifiers: mods)
    }

    private func consumeOneShots() {
        modifierState.consumeOneShots()
        refreshModifierButtons()
    }

    /// 同一修饰键的所有副本（主行 + 各抽屉行）一起刷新（物料表 §2.2）。
    /// 直接走视图树，不自己维护一份按钮清单 —— 抽屉每次开合都在增删按钮，
    /// 清单同步不上就会刷到已经拆掉的旧按钮。
    private func refreshModifierButtons() {
        for b in Self.modifierButtons(in: self) { b.phase = modifierState.phase(b.modifier) }
    }

    private static func modifierButtons(in view: UIView) -> [TerminalModifierButton] {
        view.subviews.flatMap { sub -> [TerminalModifierButton] in
            (sub as? TerminalModifierButton).map { [$0] } ?? modifierButtons(in: sub)
        }
    }

    private func sendCustomKey(_ key: TerminalCustomKey) {
        // 单个字符、没有 baked 修饰的自定义键走正常的 modifier-aware 路径（物料表 §10.3 末条）
        if key.sequence.count == 1, case .text(let t) = key.sequence[0], t.count == 1,
           let ch = t.first {
            onSendBytes?(TerminalByteComposer.bytes(forCharacter: ch, modifiers: modifierState.active))
            consumeOneShots()
            return
        }
        // 多步宏不套 toolbar 的活跃修饰，但按完仍清 oneShot（物料表 §2.2）
        sendSteps(key.sequence, from: 0)
        consumeOneShots()
    }

    /// 逐 step 发。**某一步最后一个字节是 ESC 且后面还有 step 时强制等 50ms** ——
    /// 否则终端会把 `ESC + 下一个字符` 合并成 Alt+key（物料表 §10.3）。
    private func sendSteps(_ steps: [TerminalSequenceStep], from index: Int) {
        guard index < steps.count else { return }
        let bytes: [UInt8]
        switch steps[index] {
        case .text(let t): bytes = Array(t.utf8)
        case .keyCombo(let combo): bytes = TerminalByteComposer.bytes(forCombo: combo)
        }
        onSendBytes?(bytes)
        let next = index + 1
        guard next < steps.count else { return }
        let delay: TimeInterval = bytes.last == 0x1B ? 0.05 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendSteps(steps, from: next)
        }
    }

    // MARK: 显隐

    /// 条随键盘显隐。曲线取键盘通知的 duration，跟键盘同步淡入淡出。
    ///
    /// 注意：这里只改 alpha，**不碰 first responder、不调 reloadInputViews** ——
    /// 它由键盘通知 handler 调用，那两件事是 08-26 递归闪退禁区
    /// （`docs/handoffs/handoff-keyboard-follow-2026-08-26.md` §三）。
    func setVisible(_ visible: Bool, duration: TimeInterval) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(alpha - target) > 0.01 else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) {
            self.alpha = target
        }
    }

    /// 没连上电脑时整条变灰（审计 T08）。只动里面那层按键的透明度——条自己的 alpha 归 `setVisible` 管；
    /// 键照样能按，按了由终端那边浮「没连上，打的字不会发出去」。
    func setDimmed(_ dimmed: Bool) {
        vStack.alpha = dimmed ? 0.35 : 1
    }
}
#endif
