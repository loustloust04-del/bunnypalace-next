#if os(iOS)
import SceneKit
import SwiftUI
import UIKit

/// 场景里能点的东西，‹ › 按这个顺序切（没有的跳过）：手机 → 电脑 1 → 它的 Agent → 电脑 2 → 它的 Agent → … → 再接一台。
/// 电脑和吉祥物带 hub id（plan-multi-hub B4.1）
enum TerminalSceneItem: Hashable, Identifiable {
    case local, ghost
    case remote(String), claude(String), codex(String)

    var id: Self { self }
}

/// 场景里的一台电脑（主电脑第一，其余按添加顺序站后排）
struct TerminalSceneHost: Equatable {
    var id: String
    var primary: Bool
    /// hub 名（D1，≥2 台时底部条第一行）
    var name: String
    var link: TerminalLinkState
    var device: TerminalDeviceClass
    /// hub 报来的型号名（「MacBook Air (15-inch, M5)」）；nil = 不知道，叫「我的电脑」
    var modelName: String?
    var hostName: String?
    /// nil = 那台电脑上没有这个引擎，不放；.normal / .happy = 连着时的脸（没连上一律 x.x）
    var claude: TerminalMascotFace?
    var codex: TerminalMascotFace?
    var screenTitle: String
    var screenRows: [TerminalCRTScreen.Row]
    /// 断了时那台最后还在的时间（「连不上 · 3 分钟前还在」）；连着 / 不知道 = nil
    var lastSeen: Date? = nil
    /// 待配对（≥2 台时跟首页那行一样说「要重新配对」，不说断了）
    var needsPairing = false
}

/// 首页算好交给场景的：变了才推进去改节点属性，场景本身只在电脑增删 / 换机型时重建
struct TerminalSceneInput: Equatable {
    var local: TerminalDeviceClass
    var localName: String
    var hosts: [TerminalSceneHost]

    var multi: Bool { hosts.count >= 2 }
    /// 主电脑的连接（「接上我的电脑」大按钮 / 无障碍说明跟它）
    var link: TerminalLinkState { hosts.first?.link ?? .unplugged }
}

/// 首页上半：3D 小场景 + 盖在上面的说明行 / 「接上我的电脑」/ 点设备后的底部条
struct TerminalHomeScene: View {
    let input: TerminalSceneInput
    /// 聚焦哪个：首页下面点电脑行的名字也会拉过来
    @Binding var focus: TerminalSceneItem?
    let onAction: (TerminalSceneItem) -> Void
    /// 底部条「管理这台」（≥2 台才出）
    let onManage: (String) -> Void

    @Environment(\.page2AppActive) private var appActive
    /// 前后台听 UIKit 通知，不读环境 scenePhase：page2 子应用宿主拷的是环境快照，后台往返后停在 inactive，
    /// 看得见却一直停帧、点设备镜头不动（11-05 Air；同 4214a8b33 桌面长按）
    @State private var foreground = UIApplication.shared.applicationState == .active
    /// 整页滚走、场景不在视口里也算看不见，停帧
    @State private var onScreen = true

    private var items: [TerminalSceneItem] {
        [.local] + input.hosts.flatMap { host -> [TerminalSceneItem] in
            [.remote(host.id)] + (host.claude != nil ? [.claude(host.id)] : []) + (host.codex != nil ? [.codex(host.id)] : [])
        } + [.ghost]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RadialGradient(
                    colors: [Color(red: 0.165, green: 0.145, blue: 0.133),
                             Color(red: 0.102, green: 0.090, blue: 0.082),
                             Color(red: 0.075, green: 0.067, blue: 0.063)],
                    center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 260))
            TerminalScene3D(input: input, focus: $focus, active: appActive && foreground && onScreen)
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in foreground = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in foreground = false }
        .onChange(of: items) { old, items in
            // 停在「再接一台」时加上了一台：虚线往后挪了，镜头改对着新加的那台（不然怼在新电脑屏幕上）
            if focus == .ghost, let added = items.first(where: { if case .remote = $0 { !old.contains($0) } else { false } }) {
                focus = added
            } else if let focus, !items.contains(focus) {
                self.focus = nil
            }
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
            Button { onAction(.remote(CCHubRegistry.primaryId)) } label: {
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
        if input.multi {
            // 只说断了 / 要重新配对的那几台，别的照常
            let broken = input.hosts.filter { $0.link == .broken && !$0.needsPairing }.map(\.name)
            let pairing = input.hosts.filter(\.needsPairing).map(\.name)
            if !broken.isEmpty || !pairing.isEmpty {
                let fine = input.hosts.filter { $0.link == .connected }.map(\.name)
                return [broken.isEmpty ? nil : broken.joined(separator: "、") + "断了",
                        pairing.isEmpty ? nil : pairing.joined(separator: "、") + "要重新配对",
                        fine.isEmpty ? nil : fine.joined(separator: "、") + "照常"]
                    .compactMap { $0 }.joined(separator: " · ")
            }
        }
        switch input.link {
        case .unplugged: return "手机里的小电脑已经能用了 · 再接一台电脑试试"
        case .broken: return "线断了 · \(remoteTitle)现在连不上"
        case .connected: return nil
        }
    }

    private var remoteTitle: String { input.hosts.first.map(Self.title) ?? "我的电脑" }

    private static func title(_ host: TerminalSceneHost) -> String { host.hostName ?? host.modelName ?? "我的电脑" }

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
                    HStack(spacing: 5) {
                        Text(label.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(TerminalChrome.ink)
                        if label.primaryBadge {
                            Text("主电脑")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Self.ink)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.mint))
                        }
                    }
                    // 断线那台的「N 分钟前还在」按分钟走（describe 每次取当前时间）
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(describe(item).detail)
                            .font(.system(size: 11.5))
                            .foregroundColor(TerminalChrome.dim)
                    }
                    HStack(spacing: 6) {
                        Button { onAction(item) } label: {
                            Text(label.action)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Self.ink)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.mint))
                        }
                        .buttonStyle(.plain)
                        if let hub = label.manage {
                            Button { onManage(hub) } label: {
                                Text("管理这台")
                                    .font(.system(size: 12))
                                    .foregroundColor(Self.paper)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
        /// ≥2 台时主电脑名字后面那个「主电脑」小标
        var primaryBadge = false
        /// ≥2 台时电脑的条给「管理这台」（值 = hub id）
        var manage: String?
    }

    private func describe(_ item: TerminalSceneItem) -> BarText {
        switch item {
        case .local:
            return BarText(name: input.localName, detail: "手机里的小电脑 · 自带 Linux（Alpine）", action: "打开终端 ›")
        case .remote(let id):
            guard let host = host(id) else { return ghostText }
            guard input.multi else { return singleRemoteText(host) }
            let status: String
            let action: String
            switch host.link {
            case _ where host.needsPairing: status = "要重新配对"; action = "重新扫码 ›"
            case .unplugged: status = "还没接上"; action = "接上我的电脑 ›"
            case .broken: status = TerminalLastSeen.broken(host.lastSeen); action = "重新连接 ›"
            case .connected: status = "已接上"; action = "新 shell ›"
            }
            let model = host.modelName ?? host.hostName ?? "型号报不上来"
            return BarText(name: host.name, detail: "\(model) · \(status)", action: action, primaryBadge: host.primary, manage: host.id)
        case .claude(let id):
            guard let host = host(id) else { return ghostText }
            return agentText(host, label: "Claude Code", face: host.claude)
        case .codex(let id):
            guard let host = host(id) else { return ghostText }
            return agentText(host, label: "Codex", face: host.codex)
        case .ghost:
            return ghostText
        }
    }

    private func host(_ id: String) -> TerminalSceneHost? { input.hosts.first { $0.id == id } }

    private var ghostText: BarText {
        input.multi
            ? BarText(name: "再接一台", detail: "扫码或手填，加一台新电脑", action: "去配对 ›")
            : BarText(name: "再接一台", detail: "以后可以接好几台电脑", action: "去配对 ›")
    }

    /// 只接 1 台：原来那套字
    private func singleRemoteText(_ host: TerminalSceneHost) -> BarText {
        let status: String
        let action: String
        switch host.link {
        case .unplugged: status = "还没接上"; action = "接上我的电脑 ›"
        case .broken: status = TerminalLastSeen.broken(host.lastSeen); action = "重新连接 ›"
        case .connected: status = "已接上"; action = "新 shell ›"
        }
        let detail = [host.modelName == nil ? nil : "我的电脑", host.hostName, status].compactMap { $0 }.joined(separator: " · ")
        return BarText(name: host.modelName ?? "我的电脑", detail: detail, action: action)
    }

    /// Agent 设置只主 hub（B5）：附加那台的吉祥物主动作 =「在<名字>开新 …」
    private func agentText(_ host: TerminalSceneHost, label: String, face: TerminalMascotFace?) -> BarText {
        let connected = host.link == .connected
        guard input.multi else {
            let detail = connected ? "住在\(Self.title(host))上 · " + (face == .happy ? "有事找你" : "连着") : "电脑没连上 · x.x"
            return BarText(name: label, detail: detail, action: "\(label) 设置 ›")
        }
        let detail = connected ? "住在 \(host.name) 上 · " + (face == .happy ? "有事找你" : "连着") : "\(host.name) 没连上 · x.x"
        let action = host.primary ? "\(label) 设置 ›" : connected ? "在\(host.name)开新 \(label) ›" : "重新连接 ›"
        return BarText(name: label, detail: detail, action: action)
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
/// 多台电脑（B4.1）：每台一组节点（电脑 + 吉祥物 + 珠串），各自三态 / 各自接线；电脑增删 / 换机型才重建
@MainActor
final class TerminalSceneController: NSObject, SCNSceneRendererDelegate {
    var onPick: ((TerminalSceneItem?) -> Void)?

    /// 一台电脑建好的那组节点
    private struct BuiltHost {
        let id: String
        /// 0 = 主电脑原位，其余站后排
        let slot: Int
        let remote: TerminalSceneRemote
        let crt: TerminalCRTScreen
        let crab: TerminalMascotNode
        let cloud: TerminalMascotNode
    }

    private final class Built {
        let parts: TerminalSceneParts
        let hosts: [BuiltHost]
        let local: TerminalDeviceClass

        init(parts: TerminalSceneParts, hosts: [BuiltHost], local: TerminalDeviceClass) {
            self.parts = parts
            self.hosts = hosts
            self.local = local
        }
    }

    /// 一台电脑的状态，和 `Built.hosts` 一一对应
    private struct LiveHost {
        var link: TerminalLinkState = .unplugged
        var connectStart: TimeInterval?
        var claude: TerminalMascotFace?
        var codex: TerminalMascotFace?
        var screen: (title: String, rows: [TerminalCRTScreen.Row])?
    }

    /// 主线程写、渲染线程读，都过 `lock`
    private struct Live {
        var built: Built?
        var hosts: [LiveHost] = []
        var focus: TerminalSceneItem?
        /// 慢慢晃的东西（珠子流光、吉祥物浮动、屏幕光标 / 亮带、镜头摆）动到这时候
        var ambientUntil: TimeInterval = 0
        /// 状态变了要出几帧把新样子画上
        var awakeUntil: TimeInterval = 0
        var lowPower = false
        var settled = false
        var stopRequested = false
        var resetCamera = true
        /// 停了：每帧回调一律不写场景图（写了就算脏，SCNView 会自己续帧）。wake 清
        var halted = false
        /// 有新样子还没画上（重建 / 输入变了）：停着时 SCNView 自己补画（换场景、上屏、尺寸变）的那一帧照样画一次静态的，画完清。
        /// 不然停着建好的场景上屏时镜头停在原点（11-05 Air 满屏大珠子）
        var dirty = false
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
    /// 多了后排的电脑：镜头看的点往后挪、拉远一点（design-multi-hub）
    nonisolated private static let multiTarget: SIMD3<Float> = [0, 1.0, -1.5]
    nonisolated private static let multiDistance: Float = 13.6
    nonisolated private static let multiPitch: Float = 0.52

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
        let rebuild = old == nil || old?.local != new.local
            || old?.hosts.map(\.id) != new.hosts.map(\.id) || old?.hosts.map(\.device) != new.hosts.map(\.device)
        let built = rebuild ? build(new) : nil
        let now = CACurrentMediaTime()
        let changed = old != new
        let oldHosts = Dictionary(uniqueKeysWithValues: (old?.hosts ?? []).map { ($0.id, $0) })
        var connecting = false
        let focusChanged = withLive { live -> Bool in
            if let built {
                live.built = built
                live.resetCamera = true
            }
            let previous = Dictionary(uniqueKeysWithValues: zip(old?.hosts.map(\.id) ?? [], live.hosts).map { ($0, $1) })
            live.hosts = new.hosts.map { host in
                var state = previous[host.id] ?? LiveHost()
                let was = oldHosts[host.id]
                // 刚接上（含刚加上的那台）播一次接线；第一次进来不播
                if old != nil, was?.link != .connected, host.link == .connected {
                    state.connectStart = now
                    connecting = true
                }
                if host.link != .connected { state.connectStart = nil }
                state.link = host.link
                state.claude = host.claude
                state.codex = host.codex
                if built != nil || was?.screenTitle != host.screenTitle || was?.screenRows != host.screenRows {
                    state.screen = (host.screenTitle, host.screenRows)
                }
                return state
            }
            let moved = live.focus != focus
            live.focus = focus
            if built != nil || changed || moved { live.dirty = true }
            return moved
        }
        if let built {
            view?.scene = built.parts.scene
            view?.pointOfView = built.parts.camera
        }
        let wasActive = active
        active = newActive
        guard newActive else {
            stop()
            return
        }
        // 看不见的时候接上的：回到可见再从头补播
        if !wasActive {
            withLive { live in
                for i in live.hosts.indices where live.hosts[i].connectStart != nil { live.hosts[i].connectStart = now }
            }
        }
        if built != nil || focusChanged || connecting || !wasActive {
            wake(ambient: true)
        } else if changed {
            wake(ambient: false)
        }
    }

    private func build(_ input: TerminalSceneInput) -> Built {
        let crts = input.hosts.map { TerminalCRTScreen(tall: $0.device != .laptop && $0.device != .desktop) }
        let parts = TerminalSceneBuilder().build(local: input.local, remotes: zip(input.hosts, crts).map { ($0.device, $1.material) })
        let hosts = zip(parts.remotes, crts).enumerated().map { slot, pair in
            let (remote, crt) = pair
            let crab = TerminalMascotNode.clawd(height: 0.4)
            remote.claudeSeat.addChildNode(crab.root)
            let cloud = TerminalMascotNode.codex(height: 0.66)
            remote.codexSeat.addChildNode(cloud.root)
            return BuiltHost(id: input.hosts[slot].id, slot: slot, remote: remote, crt: crt, crab: crab, cloud: cloud)
        }
        return Built(parts: parts, hosts: hosts, local: input.local)
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
            live.halted = false
        }
        guard active, let view else { return }
        view.scene?.isPaused = false
        view.rendersContinuously = true
        view.isPlaying = true
    }

    private func stop() {
        withLive { $0.halted = true }
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

    var isHaltedForTesting: Bool { withLive { $0.halted } }
    var partsForTesting: TerminalSceneParts? { withLive { $0.built?.parts } }

    nonisolated private static func isIdle(_ live: Live, now: TimeInterval) -> Bool {
        now >= live.awakeUntil && now >= live.ambientUntil && live.hosts.allSatisfy { $0.connectStart == nil } && live.settled
    }

    // MARK: 手势

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view, let built = withLive({ $0.built }) else { return }
        let hits = view.hitTest(recognizer.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        let parts = built.parts
        // 吉祥物坐在电脑上，先认它们
        var roots: [(TerminalSceneItem, SCNNode)] = []
        for host in built.hosts {
            roots.append((.claude(host.id), host.crab.root))
            roots.append((.codex(host.id), host.cloud.root))
        }
        roots.append((.local, parts.local))
        for host in built.hosts { roots.append((.remote(host.id), host.remote.node)) }
        roots.append((.ghost, parts.ghost))
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
        let current = withLive { live -> Live? in
            guard !live.halted || live.dirty else { return nil }
            for i in live.hosts.indices {
                if let start = live.hosts[i].connectStart, now - start > 3.6 { live.hosts[i].connectStart = nil }
            }
            let snapshot = live
            for i in live.hosts.indices { live.hosts[i].screen = nil }
            live.resetCamera = false
            live.dirty = false
            return snapshot
        }
        guard let s = current, let built = s.built else { return }
        // 停着补画的那帧：不晃、镜头直接落位、接线按播完画、不判停
        let still = s.halted
        let parts = built.parts
        let dt = Float(lastTime == 0 ? 1.0 / 30 : min(0.05, now - lastTime))
        lastTime = now
        // 慢慢晃的东西在 8 秒的最后 0.6 秒淡掉，停下来不跳
        let w = s.lowPower || still ? 0 : Float(min(1, max(0, (s.ambientUntil - now) / 0.6)))
        for (host, state) in zip(built.hosts, s.hosts) {
            if let screen = state.screen { host.crt.setContent(title: screen.title, rows: screen.rows) }
        }

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
            let multi = built.hosts.count >= 2
            let target = multi ? Self.multiTarget : Self.target
            let distance = multi ? Self.multiDistance : Self.distance
            let pitch = multi ? Self.multiPitch : Self.pitch
            let yaw = Self.yaw + Float(sin(now / 4.2)) * 0.06 * w
            wantPos = target + distance * SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
            wantLook = target
        }
        if s.resetCamera || still {
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

        // 每台各自的三种状态 + 接线
        var wave: Float = 0
        for (host, state) in zip(built.hosts, s.hosts) {
            let remote = host.remote
            let n = remote.beads.count
            var shown = n, glowHead = -1, power: Float = 1, alive = true, dim: Float = 1, gap = false
            let start = state.link == .connected && !still ? state.connectStart : nil
            let connecting = start != nil
            if let start {
                let t = Float(now - start)
                shown = max(6, Int((6 + Float(n - 6) * Self.ease(t / 1.6)).rounded()))
                glowHead = shown - 1
                let boot = t - 1.7
                power = boot < 0 ? 0 : boot < 0.12 ? 1 : boot < 0.22 ? 0 : boot < 0.32 ? 0.8 : boot < 0.42 ? 0.1 : min(1, boot)
                alive = boot >= 0.42   // 屏幕稳稳亮起的那一下，吉祥物活过来
                if t > 2.3 && t < 3.4 { wave = sin((t - 2.3) * 14) }
            } else if state.link == .unplugged {
                shown = 6; power = 0; alive = false; dim = 0.55
            } else if state.link == .broken {
                power = 0; alive = false; dim = 0.5; gap = true
            }
            let flowing = state.link == .connected && !connecting
            let head = Float((now / 0.07).truncatingRemainder(dividingBy: Double(n + 12))) - 6
            for (i, bead) in remote.beads.enumerated() {
                bead.isHidden = !(i < shown && !(gap && (15...19).contains(i)))
                guard let m = bead.geometry?.firstMaterial else { continue }
                var e: Float = 0
                if flowing { e = max(0, 1 - abs(Float(i) - head) / 3) * 1.3 * w }
                if glowHead >= 0 { e = max(0, 1 - Float(glowHead - i) / 5) * 1.8 }
                m.diffuse.contents = Self.beadColor(dim)
                if state.link == .broken && !connecting && (i == 14 || i == 20) {
                    m.emission.contents = Self.berry
                    e = 0.6 + 0.4 * Float(sin(now / 0.2)) * w
                } else {
                    m.emission.contents = Self.mint
                }
                m.emission.intensity = CGFloat(e)
            }
            remote.threadMaterial.transparency = state.link == .connected ? 1 : 0.35
            let triangles = remote.threadElement.primitiveCount
            remote.threadElement.primitiveRange = NSRange(location: 0, length: triangles * shown / n / 16 * 16)
            host.crt.update(power: power, time: w > 0 ? now : nil)
            remote.led?.diffuse.contents = power > 0.5 ? Self.mint : state.link == .broken ? Self.berry : Self.ledOff

            // 吉祥物
            for (mascot, mood, phase) in [(host.crab, state.claude, 0.0), (host.cloud, state.codex, 1.7)] {
                mascot.root.isHidden = mood == nil
                mascot.setFace(alive ? mood ?? .normal : .dead)
                mascot.root.simdPosition.y = alive ? Float(abs(sin(now / 0.52 + phase + Double(host.slot) * 0.9))) * 0.035 * w : 0
            }
        }
        // 企鹅
        parts.penguin.eulerAngles.z = Float(sin(now / 0.76)) * 0.04 * w
        parts.flipper.eulerAngles.z = 0.32 + max(0, wave) * 0.6

        let idle = !still && withLive { live -> Bool in
            live.settled = settled
            guard !live.stopRequested, Self.isIdle(live, now: now) else { return false }
            live.stopRequested = true
            live.halted = true
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

    /// 后排那几台小一号，镜头距离照 design-multi-hub 收一点
    nonisolated private static func anchor(_ item: TerminalSceneItem, _ built: Built) -> Anchor? {
        let parts = built.parts
        func host(_ id: String) -> BuiltHost? { built.hosts.first { $0.id == id } }
        switch item {
        case .local:
            return Anchor(node: parts.localScreen, distance: built.local == .tablet ? 6.0 : 5.6, lift: 0)
        case .remote(let id):
            guard let host = host(id) else { return nil }
            return host.slot == 0 ? Anchor(node: host.remote.screen, distance: 6.8, lift: 0.35)
                : Anchor(node: host.remote.screen, distance: 7.0, lift: 0.25)
        case .claude(let id):
            guard let host = host(id), !host.crab.root.isHidden else { return nil }
            return Anchor(node: host.crab.root, distance: host.slot == 0 ? 3.4 : 3.1, lift: host.slot == 0 ? 0.3 : 0.28)
        case .codex(let id):
            guard let host = host(id), !host.cloud.root.isHidden else { return nil }
            return Anchor(node: host.cloud.root, distance: host.slot == 0 ? 3.4 : 3.1, lift: host.slot == 0 ? 0.4 : 0.36)
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
