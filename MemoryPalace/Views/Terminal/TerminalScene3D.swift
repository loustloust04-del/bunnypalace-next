#if os(iOS)
import SceneKit
import SwiftUI
import UIKit

/// 场景里能点的东西，‹ › 按这个顺序切（没有的跳过）
enum TerminalSceneItem: Hashable, Identifiable {
    case local, remote, claude, codex, ghost

    var id: Self { self }
}

/// 首页算好交给场景的：变了才推进去改节点属性，场景本身只建一次
struct TerminalSceneInput: Equatable {
    var link: TerminalLinkState
    var local: TerminalDeviceClass
    var localName: String
    var remote: TerminalDeviceClass
    /// hub 报来的型号名（「MacBook Air (15-inch, M5)」）；nil = 不知道，叫「我的电脑」
    var remoteName: String?
    var hostName: String?
    /// nil = 那台电脑上没有这个引擎，不放；.normal / .happy = 连着时的脸（没连上一律 x.x）
    var claude: TerminalMascotFace?
    var codex: TerminalMascotFace?
    var screenTitle: String
    var screenRows: [TerminalCRTScreen.Row]
}

/// 首页上半：3D 小场景 + 盖在上面的说明行 / 「接上我的电脑」/ 点设备后的底部条
struct TerminalHomeScene: View {
    let input: TerminalSceneInput
    let onAction: (TerminalSceneItem) -> Void

    @Environment(\.page2AppActive) private var appActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var focus: TerminalSceneItem?
    /// 整页滚走、场景不在视口里也算看不见，停帧
    @State private var onScreen = true

    private var items: [TerminalSceneItem] {
        [.local, .remote] + (input.claude != nil ? [.claude] : []) + (input.codex != nil ? [.codex] : []) + [.ghost]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RadialGradient(
                    colors: [Color(red: 0.165, green: 0.145, blue: 0.133),
                             Color(red: 0.102, green: 0.090, blue: 0.082),
                             Color(red: 0.075, green: 0.067, blue: 0.063)],
                    center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 260))
            TerminalScene3D(input: input, focus: $focus, active: appActive && scenePhase == .active && onScreen)
                .accessibilityLabel(input.link == .connected ? "手机和我的电脑已接上" : "我的电脑没接上")
            Text("TERMINAL")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .kerning(2)
                .foregroundColor(Palette.mint)
                .shadow(color: Palette.mint.opacity(0.7), radius: 3)
                .padding(.leading, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
            if let focus {
                focusBar(focus)
            } else {
                overview
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .onChange(of: items) { _, items in
            if let focus, !items.contains(focus) { self.focus = nil }
        }
    }

    // MARK: 全景

    @ViewBuilder
    private var overview: some View {
        if let caption {
            Text(caption)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(red: 0.725, green: 0.698, blue: 0.671))
                .shadow(color: .black.opacity(0.8), radius: 2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
        if input.link == .unplugged {
            Button { onAction(.remote) } label: {
                Text("接上我的电脑")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Self.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.mint))
                    .shadow(color: Palette.mint.opacity(0.45), radius: 9)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var caption: String? {
        switch input.link {
        case .unplugged: return "手机里的小电脑已经能用了 · 再接一台电脑试试"
        case .broken: return "线断了 · \(remoteTitle)现在连不上"
        case .connected: return nil
        }
    }

    private var remoteTitle: String { input.hostName ?? input.remoteName ?? "我的电脑" }

    // MARK: 聚焦条

    private func focusBar(_ item: TerminalSceneItem) -> some View {
        let label = describe(item)
        let index = items.firstIndex(of: item) ?? 0
        return ZStack {
            Button { self.focus = nil } label: {
                Text("完成")
                    .font(.system(size: 12))
                    .foregroundColor(Self.paper)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Self.glass(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            HStack(spacing: 6) {
                arrow("‹") { step(-1) }
                VStack(spacing: 0) {
                    Text(label.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(TerminalChrome.ink)
                    Text(label.detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(TerminalChrome.dim)
                    Button { onAction(item) } label: {
                        Text(label.action)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Self.ink)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.mint))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 3)
                    HStack(spacing: 4) {
                        ForEach(items) { dot in
                            Circle()
                                .fill(dot == item ? Palette.mint : Color.white.opacity(0.22))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.top, 4)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                arrow("›") { step(1) }
            }
            .padding(6)
            .background(Self.glass(cornerRadius: 16))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("第 \(index + 1) 个，共 \(items.count) 个")
        }
    }

    private func arrow(_ glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 26))
                .foregroundColor(Self.paper)
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func step(_ delta: Int) {
        guard let focus, let index = items.firstIndex(of: focus) else { return }
        self.focus = items[(index + delta + items.count) % items.count]
    }

    private struct BarText {
        let name: String
        let detail: String
        let action: String
    }

    private func describe(_ item: TerminalSceneItem) -> BarText {
        let connected = input.link == .connected
        switch item {
        case .local:
            return BarText(name: input.localName, detail: "手机里的小电脑 · 自带 Linux（Alpine）", action: "打开终端 ›")
        case .remote:
            let status: String
            let action: String
            switch input.link {
            case .unplugged: status = "还没接上"; action = "接上我的电脑 ›"
            case .broken: status = "连不上"; action = "重新连接 ›"
            case .connected: status = "已接上"; action = "新 shell ›"
            }
            let detail = [input.remoteName == nil ? nil : "我的电脑", input.hostName, status].compactMap { $0 }.joined(separator: " · ")
            return BarText(name: input.remoteName ?? "我的电脑", detail: detail, action: action)
        case .claude:
            return BarText(name: "Claude Code", detail: mascotDetail(input.claude, connected: connected), action: "Claude Code 设置 ›")
        case .codex:
            return BarText(name: "Codex", detail: mascotDetail(input.codex, connected: connected), action: "Codex 设置 ›")
        case .ghost:
            return BarText(name: "再接一台", detail: "以后可以接好几台电脑", action: "去配对 ›")
        }
    }

    private func mascotDetail(_ face: TerminalMascotFace?, connected: Bool) -> String {
        guard connected else { return "电脑没连上 · x.x" }
        return "住在\(remoteTitle)上 · " + (face == .happy ? "有事找你" : "连着")
    }

    private static let ink = Color(red: 0.122, green: 0.110, blue: 0.102)
    private static let paper = Color(red: 0.91, green: 0.886, blue: 0.855)

    private static func glass(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(red: 0.122, green: 0.110, blue: 0.102).opacity(0.82))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// `SCNView` 包一层（不用 SwiftUI `SceneView`，好控制停帧）
private struct TerminalScene3D: UIViewRepresentable {
    let input: TerminalSceneInput
    @Binding var focus: TerminalSceneItem?
    let active: Bool

    func makeCoordinator() -> TerminalSceneController { TerminalSceneController() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: nil)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.isPlaying = false
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let binding = $focus
        context.coordinator.onPick = { binding.wrappedValue = $0 }
        context.coordinator.apply(input, focus: focus, active: active)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: TerminalSceneController) {
        coordinator.detach()
    }
}

/// 场景的一切状态和动画。节点只在 SceneKit 渲染线程的 update 回调里改；主线程只写 `Live`（加锁）再叫醒渲染。
/// D5：进首页 / 接线 / 摸一下 动 8 秒左右，然后 `isPlaying = false` + `rendersContinuously = false`，一帧都不出；
/// 低电量只播接线那一次；看不见（换 tab / 离开终端 / 后台）立刻停。
@MainActor
final class TerminalSceneController: NSObject, SCNSceneRendererDelegate {
    var onPick: ((TerminalSceneItem?) -> Void)?

    private final class Built {
        let parts: TerminalSceneParts
        let crt: TerminalCRTScreen
        let crab: TerminalMascotNode
        let cloud: TerminalMascotNode
        let local: TerminalDeviceClass
        let remote: TerminalDeviceClass

        init(parts: TerminalSceneParts, crt: TerminalCRTScreen, crab: TerminalMascotNode, cloud: TerminalMascotNode,
             local: TerminalDeviceClass, remote: TerminalDeviceClass) {
            self.parts = parts
            self.crt = crt
            self.crab = crab
            self.cloud = cloud
            self.local = local
            self.remote = remote
        }
    }

    /// 主线程写、渲染线程读，都过 `lock`
    private struct Live {
        var built: Built?
        var link: TerminalLinkState = .unplugged
        var connectStart: TimeInterval?
        var claude: TerminalMascotFace?
        var codex: TerminalMascotFace?
        var focus: TerminalSceneItem?
        /// 慢慢晃的东西（珠子流光、吉祥物浮动、屏幕光标 / 亮带、镜头摆）动到这时候
        var ambientUntil: TimeInterval = 0
        /// 状态变了要出几帧把新样子画上
        var awakeUntil: TimeInterval = 0
        var lowPower = false
        var screen: (title: String, rows: [TerminalCRTScreen.Row])?
        var settled = false
        var stopRequested = false
        var resetCamera = true
    }

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var live = Live()
    nonisolated(unsafe) private var camPos: SIMD3<Float> = .zero
    nonisolated(unsafe) private var camLook: SIMD3<Float> = .zero
    nonisolated(unsafe) private var lastTime: TimeInterval = 0

    private weak var view: SCNView?
    private var active = false
    private var input: TerminalSceneInput?
    private var powerObserver: NSObjectProtocol?

    private static let ambientSeconds: TimeInterval = 8
    nonisolated private static let target: SIMD3<Float> = [0.05, 1.1, 0]
    nonisolated private static let distance: Float = 11.8
    nonisolated private static let yaw: Float = -0.1
    nonisolated private static let pitch: Float = 0.5

    nonisolated private func withLive<T>(_ body: (inout Live) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&live)
    }

    func attach(_ view: SCNView) {
        self.view = view
        view.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.withLive { live in
                live.lowPower = low
                if low { live.ambientUntil = 0 }
            }
        }
    }

    func detach() {
        stop()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        powerObserver = nil
        view?.scene = nil
        view?.delegate = nil
    }

    func apply(_ new: TerminalSceneInput, focus: TerminalSceneItem?, active newActive: Bool) {
        let old = input
        input = new
        var ambient = false
        if old == nil || old?.local != new.local || old?.remote != new.remote {
            build(new)
            ambient = true
        }
        let now = CACurrentMediaTime()
        let changed = old != new
        let focusChanged = withLive { live -> Bool in
            if let old, old.link != .connected, new.link == .connected { live.connectStart = now }
            if new.link != .connected { live.connectStart = nil }
            live.link = new.link
            live.claude = new.claude
            live.codex = new.codex
            if old?.screenTitle != new.screenTitle || old?.screenRows != new.screenRows {
                live.screen = (new.screenTitle, new.screenRows)
            }
            let moved = live.focus != focus
            live.focus = focus
            return moved
        }
        let wasActive = active
        active = newActive
        guard newActive else {
            stop()
            return
        }
        // 看不见的时候接上的：回到可见再从头补播
        if !wasActive { withLive { live in if live.connectStart != nil { live.connectStart = now } } }
        let connecting = old.map { $0.link != .connected && new.link == .connected } ?? false
        if ambient || focusChanged || connecting || !wasActive {
            wake(ambient: true)
        } else if changed {
            wake(ambient: false)
        }
    }

    private func build(_ input: TerminalSceneInput) {
        let crt = TerminalCRTScreen(tall: input.remote != .laptop && input.remote != .desktop)
        let parts = TerminalSceneBuilder().build(local: input.local, remote: input.remote, remoteScreen: crt.material)
        let crab = TerminalMascotNode.clawd(height: 0.4)
        parts.claudeSeat.addChildNode(crab.root)
        let cloud = TerminalMascotNode.codex(height: 0.66)
        parts.codexSeat.addChildNode(cloud.root)
        let built = Built(parts: parts, crt: crt, crab: crab, cloud: cloud, local: input.local, remote: input.remote)
        withLive { live in
            live.built = built
            live.resetCamera = true
            live.screen = (input.screenTitle, input.screenRows)
        }
        view?.scene = parts.scene
        view?.pointOfView = parts.camera
    }

    // MARK: 出帧 / 停帧

    private func wake(ambient: Bool) {
        let now = CACurrentMediaTime()
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        withLive { live in
            live.lowPower = low
            if ambient && !low { live.ambientUntil = max(live.ambientUntil, now + Self.ambientSeconds) }
            live.awakeUntil = max(live.awakeUntil, now + (low ? 0 : 0.3))
            // 镜头要不要滑由下一帧重算；不清掉的话，排在后面的 stopIfIdle 会拿上一帧的「已落定」把滑动掐掉
            live.settled = false
        }
        guard active, let view else { return }
        view.scene?.isPaused = false
        view.rendersContinuously = true
        view.isPlaying = true
    }

    private func stop() {
        guard let view else { return }
        view.isPlaying = false
        view.rendersContinuously = false
        view.scene?.isPaused = true
    }

    private func stopIfIdle() {
        let now = CACurrentMediaTime()
        let idle = withLive { live -> Bool in
            live.stopRequested = false
            return Self.isIdle(live, now: now)
        }
        if idle { stop() }
    }

    nonisolated private static func isIdle(_ live: Live, now: TimeInterval) -> Bool {
        now >= live.awakeUntil && now >= live.ambientUntil && live.connectStart == nil && live.settled
    }

    // MARK: 手势

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view, let built = withLive({ $0.built }) else { return }
        let hits = view.hitTest(recognizer.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        let parts = built.parts
        // 吉祥物坐在电脑上，先认它们
        let roots: [(TerminalSceneItem, SCNNode)] = [(.claude, built.crab.root), (.codex, built.cloud.root),
                                                     (.local, parts.local), (.remote, parts.remote), (.ghost, parts.ghost)]
        let picked = roots.first { _, root in
            !root.isHidden && hits.contains { Self.node($0.node, isInside: root) }
        }?.0
        wake(ambient: true)
        onPick?(picked)
    }

    nonisolated private static func node(_ node: SCNNode, isInside root: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let n = current {
            if n === root { return true }
            current = n.parent
        }
        return false
    }

    // MARK: 每帧（渲染线程）

    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime _: TimeInterval) {
        let now = CACurrentMediaTime()
        let s = withLive { live -> Live in
            if let start = live.connectStart, now - start > 3.6 { live.connectStart = nil }
            let snapshot = live
            live.screen = nil
            live.resetCamera = false
            return snapshot
        }
        guard let built = s.built else { return }
        let parts = built.parts
        let dt = Float(lastTime == 0 ? 1.0 / 30 : min(0.05, now - lastTime))
        lastTime = now
        // 慢慢晃的东西在 8 秒的最后 0.6 秒淡掉，停下来不跳
        let w = s.lowPower ? 0 : Float(min(1, max(0, (s.ambientUntil - now) / 0.6)))
        if let screen = s.screen { built.crt.setContent(title: screen.title, rows: screen.rows) }

        // 镜头
        var wantPos: SIMD3<Float>, wantLook: SIMD3<Float>
        if let focus = s.focus, let anchor = Self.anchor(focus, built) {
            wantLook = anchor.node.simdWorldPosition
            wantLook.y += anchor.lift
            var n = anchor.node.simdConvertVector([0, 0, 1], to: nil)
            n.y *= 0.4   // 正对屏幕，但别从地板往上看
            n = simd_normalize(n)
            wantPos = wantLook + n * anchor.distance
            let drop = 0.06 * anchor.distance   // 整体下移：设备落在底部条上方
            wantLook.y -= drop
            wantPos.y -= drop
        } else {
            // 不接拖动转场景（住在 page2 横向翻页里，抢手势会翻不了页），只留慢慢摆
            let yaw = Self.yaw + Float(sin(now / 4.2)) * 0.06 * w
            wantPos = Self.target + Self.distance * SIMD3(sin(yaw) * cos(Self.pitch), sin(Self.pitch), cos(yaw) * cos(Self.pitch))
            wantLook = Self.target
        }
        if s.resetCamera {
            camPos = wantPos
            camLook = wantLook
        }
        // 低电量也滑过去（不滑像跳帧）；落定就停，慢慢晃的东西照旧不动
        let k = 1 - exp(-dt * 5)
        camPos += (wantPos - camPos) * k
        camLook += (wantLook - camLook) * k
        parts.camera.simdPosition = camPos
        // 显式给世界 up：缺省 up 取节点自己的 worldUp，镜头一摆就累积侧滚，地面看着是歪的
        parts.camera.simdLook(at: camLook, up: [0, 1, 0], localFront: [0, 0, -1])
        let settled = simd_distance(camPos, wantPos) < 0.003 && simd_distance(camLook, wantLook) < 0.003

        // 三种状态 + 接线
        let n = parts.beads.count
        var shown = n, glowHead = -1, power: Float = 1, alive = true, dim: Float = 1, gap = false, wave: Float = 0
        let start = s.link == .connected ? s.connectStart : nil
        let connecting = start != nil
        if let start {
            let t = Float(now - start)
            shown = max(6, Int((6 + Float(n - 6) * Self.ease(t / 1.6)).rounded()))
            glowHead = shown - 1
            let boot = t - 1.7
            power = boot < 0 ? 0 : boot < 0.12 ? 1 : boot < 0.22 ? 0 : boot < 0.32 ? 0.8 : boot < 0.42 ? 0.1 : min(1, boot)
            alive = boot >= 0.42   // 屏幕稳稳亮起的那一下，吉祥物活过来
            wave = t > 2.3 && t < 3.4 ? sin((t - 2.3) * 14) : 0
        } else if s.link == .unplugged {
            shown = 6; power = 0; alive = false; dim = 0.55
        } else if s.link == .broken {
            power = 0; alive = false; dim = 0.5; gap = true
        }
        let flowing = s.link == .connected && !connecting
        let head = Float((now / 0.07).truncatingRemainder(dividingBy: Double(n + 12))) - 6
        for (i, bead) in parts.beads.enumerated() {
            bead.isHidden = !(i < shown && !(gap && (15...19).contains(i)))
            guard let m = bead.geometry?.firstMaterial else { continue }
            var e: Float = 0
            if flowing { e = max(0, 1 - abs(Float(i) - head) / 3) * 1.3 * w }
            if glowHead >= 0 { e = max(0, 1 - Float(glowHead - i) / 5) * 1.8 }
            m.diffuse.contents = Self.beadColor(dim)
            if s.link == .broken && !connecting && (i == 14 || i == 20) {
                m.emission.contents = Self.berry
                e = 0.6 + 0.4 * Float(sin(now / 0.2)) * w
            } else {
                m.emission.contents = Self.mint
            }
            m.emission.intensity = CGFloat(e)
        }
        parts.threadMaterial.transparency = s.link == .connected ? 1 : 0.35
        let triangles = parts.threadElement.primitiveCount
        parts.threadElement.primitiveRange = NSRange(location: 0, length: triangles * shown / n / 16 * 16)
        built.crt.update(power: power, time: w > 0 ? now : nil)
        parts.led?.diffuse.contents = power > 0.5 ? Self.mint : s.link == .broken ? Self.berry : Self.ledOff

        // 吉祥物 + 企鹅
        for (mascot, mood, phase) in [(built.crab, s.claude, 0.0), (built.cloud, s.codex, 1.7)] {
            mascot.root.isHidden = mood == nil
            mascot.setFace(alive ? mood ?? .normal : .dead)
            mascot.root.simdPosition.y = alive ? Float(abs(sin(now / 0.52 + phase))) * 0.035 * w : 0
        }
        parts.penguin.eulerAngles.z = Float(sin(now / 0.76)) * 0.04 * w
        parts.flipper.eulerAngles.z = 0.32 + max(0, wave) * 0.6

        let idle = withLive { live -> Bool in
            live.settled = settled
            guard !live.stopRequested, Self.isIdle(live, now: now) else { return false }
            live.stopRequested = true
            return true
        }
        if idle {
            Task { @MainActor [weak self] in self?.stopIfIdle() }
        }
    }

    private struct Anchor {
        let node: SCNNode
        let distance: Float
        let lift: Float
    }

    nonisolated private static func anchor(_ item: TerminalSceneItem, _ built: Built) -> Anchor? {
        let parts = built.parts
        switch item {
        case .local: return Anchor(node: parts.localScreen, distance: built.local == .tablet ? 6.0 : 5.6, lift: 0)
        case .remote: return Anchor(node: parts.remoteScreen, distance: 6.8, lift: 0.35)
        case .claude: return built.crab.root.isHidden ? nil : Anchor(node: built.crab.root, distance: 3.4, lift: 0.3)
        case .codex: return built.cloud.root.isHidden ? nil : Anchor(node: built.cloud.root, distance: 3.4, lift: 0.4)
        case .ghost: return Anchor(node: parts.ghost, distance: 6.4, lift: 0.95)
        }
    }

    nonisolated private static func ease(_ t: Float) -> Float {
        t < 0 ? 0 : t > 1 ? 1 : 1 - pow(1 - t, 3)
    }

    nonisolated private static let mint = TerminalSceneBuilder.color(TerminalSceneBuilder.C.mint)
    nonisolated private static let berry = TerminalSceneBuilder.color(TerminalSceneBuilder.C.berry)
    nonisolated private static let ledOff = TerminalSceneBuilder.color(0x3a3633)
    nonisolated private static let beadColors: [Float: UIColor] = {
        let base = TerminalSceneBuilder.color(TerminalSceneBuilder.C.bead)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Dictionary(uniqueKeysWithValues: [Float(1), 0.55, 0.5].map { dim in
            (dim, UIColor(red: r * CGFloat(dim), green: g * CGFloat(dim), blue: b * CGFloat(dim), alpha: 1))
        })
    }()

    nonisolated private static func beadColor(_ dim: Float) -> UIColor {
        beadColors[dim] ?? .white
    }
}
#endif
