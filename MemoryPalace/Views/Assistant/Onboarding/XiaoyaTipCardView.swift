import SwiftUI

// MARK: - Tip 卡 + 会动的示意插图（§11-1/4/6；小样 design-onboarding-xiaoya-v2.html A）
// 插图是 SwiftUI 形状拼的迷你手机，不用截图、不跟主题（颜色是花园固定配色）。
// 性能：只有看得见的那张在动——滚出视线 / 小芽 app 退到后台 / App 不在前台 / 减弱动态效果 → 停在一帧示意图上。
// 一张插图 = 一个 0…1 的循环进度 t，各层位置照小样 CSS 关键帧逐段插值（t 由 TimelineView 按时间算，§12-C）。

/// 插图种类：回桌面分竖条 / 弧线两版，其余跟 tip 一一对应
enum XiaoyaTipScene: Equatable {
    case strip, arc, toChat, toList, floors

    init(_ kind: XiaoyaTipKind, strip: Bool) {
        switch kind {
        case .toDesk: self = strip ? .strip : .arc
        case .toChat: self = .toChat
        case .toList: self = .toList
        case .floors: self = .floors
        }
    }

    var duration: Double {
        switch self {
        case .strip: 4.4
        case .arc: 4.8
        case .toChat, .toList: 3.9
        case .floors: 4.8
        }
    }

    /// 停住时画哪一刻（手势正在发生的那一帧）
    var restingT: Double {
        switch self {
        case .strip: 0.42
        case .arc: 0.45
        case .toChat, .toList: 0.6
        case .floors: 0.4
        }
    }
}

/// 读「切换应用」设置：竖条（默认）/ 弧线。mac 没有这个设置，按竖条讲
struct XiaoyaTipModeReader<Content: View>: View {
    #if os(iOS)
    @AppStorage(Page2Switcher.key) private var switcher = "strip"
    private var strip: Bool { switcher != "arc" }
    #else
    private let strip = true
    #endif
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(strip) }
}

// MARK: - 卡

struct XiaoyaTipCardView: View {
    let ref: XiaoyaTipRef
    /// 历史列表里不出「带我去桌面」
    var showsGo = true
    var answer: XiaoyaCardAnswer? = nil
    /// 卡底「懂了，下一条」「以后再看」：只给对话里最新那张没答过的（§12-B）
    var showsChips = false
    var onAnswer: (XiaoyaCardAnswer) -> Void = { _ in }
    @State private var replay = 0

    var body: some View {
        XiaoyaTipModeReader { strip in
            XiaoyaSkinReader { skin in
                let copy = XiaoyaScriptLines.tip(ref.kind, strip: strip)
                VStack(alignment: .leading, spacing: 8) {
                    herLine(copy, skin: skin)
                    illustrationCard(copy, scene: XiaoyaTipScene(ref.kind, strip: strip), skin: skin)
                    footer(skin)
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ skin: XiaoyaSkin) -> some View {
        if let answer {
            Text(answer.summary + (answer == .tipNext ? " ✓" : ""))
                .font(.system(size: XiaoyaCardFont.hint))
                .tracking(0.5)
                .foregroundStyle(skin.inkMuted)
                .padding(.leading, 2)
        } else if showsChips {
            let last = XiaoyaTipCatalog.next(after: ref) == nil
            HStack(spacing: 8) {
                XiaoyaChip(title: last ? XiaoyaScriptLines.tipDone : XiaoyaScriptLines.tipNext, on: true) { onAnswer(.tipNext) }
                if !last {
                    XiaoyaChip(title: XiaoyaScriptLines.tipLater, on: false) { onAnswer(.tipLater) }
                }
            }
            .padding(.leading, 2)
        }
    }

    /// 她说的那句：「Tip 1.1」金色纸签 + 标题，下面一句（墨线引出，同她平时的话；[[概念词]] 画马克笔）
    private func herLine(_ copy: XiaoyaTipCopy, skin: XiaoyaSkin) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                XiaoyaTipLabel(label: ref.label)
                Text(copy.title)
                    .font(.system(size: XiaoyaCardFont.body, weight: .semibold))
                    .foregroundStyle(skin.ink)
            }
            XiaoyaMarkedText(copy.text)
                .font(.system(size: XiaoyaCardFont.body))
                .foregroundStyle(skin.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
        .padding(.vertical, 1)
        .overlay(alignment: .leading) { Rectangle().fill(skin.ink).frame(width: 2) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 28)
    }

    private func illustrationCard(_ copy: XiaoyaTipCopy, scene: XiaoyaTipScene, skin: XiaoyaSkin) -> some View {
        HStack(alignment: .center, spacing: 14) {
            XiaoyaTipIllustration(scene: scene, replay: replay)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(gardenColor("#E7EEEC"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(copy.title)
                    .font(.system(size: XiaoyaCardFont.small + 0.5, weight: .semibold))
                    .foregroundStyle(skin.ink)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(copy.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1)")
                                .font(.system(size: 10.5, weight: .semibold, design: .serif))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(skin.ok, in: Circle())
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                            Text(step)
                                .font(.system(size: XiaoyaCardFont.hint))
                                .foregroundStyle(skin.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 6)
                #if os(iOS)
                if showsGo, ref.kind == .toDesk {
                    Button("带我去桌面") { XiaoyaApp.goDesktop() }
                        .buttonStyle(.xiaoya(.primary))
                        .padding(.top, 10)
                }
                #endif
                Text("点图重播 ↻")
                    .font(.system(size: 11.5))
                    .tracking(0.5)
                    .foregroundStyle(skin.inkMuted)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(skin.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(skin.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { replay += 1 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("重播插图"))
    }
}

// MARK: - 插图

/// 迷你手机：外框 112×228，屏幕 104×220。看得见才动（gate 说怎么判「看得见」）
struct XiaoyaTipIllustration: View {
    enum Gate {
        /// 在 ScrollView 里：onScrollVisibilityChange（小芽对话、历史列表）
        case scroll
        /// List 里（设置页）：跟着行出现 / 消失
        case appear
        /// 永远停在示意帧（设置页没选中的那张）
        case still
    }

    let scene: XiaoyaTipScene
    var replay = 0
    var gate: Gate = .scroll

    @State private var visibility = XiaoyaTipVisibility()
    /// 这一圈从哪一刻算起：开始播 / 点图重播时归零
    @State private var origin = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.page2AppActive) private var appActive
    /// 前后台听 UIKit 通知，不读环境 scenePhase：page2 子应用宿主拷的是环境快照，后台往返后停在 inactive，
    /// 插图一直停在示意帧（同 8ef0b21e6 终端 3D / 4214a8b33 桌面长按）
    @State private var foreground = UIApplication.shared.applicationState == .active
    #else
    private let appActive = true
    private let foreground = true
    #endif

    private var playing: Bool {
        visibility.visible(gate) && appActive && foreground && !reduceMotion
    }

    /// 帧 = 时间的纯函数，门控只决定 TimelineView 停不停（§12-C）：不再靠插拔 KeyframeAnimator，
    /// 播不播只看此刻的 playing，没有「错过某个回调就再也起不来」的状态
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
            XiaoyaTipScreen(scene: scene,
                            t: playing ? XiaoyaTipClock.progress(at: context.date, origin: origin, duration: scene.duration) : scene.restingT,
                            still: !playing)
        }
        .padding(4)
        .background(gardenColor("#1b1b1b"), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: gardenColor("#34403a").opacity(0.18), radius: 8, y: 6)
        .onScrollVisibilityChange(threshold: 0.3) { visibility.inViewport = $0 }
        .onAppear { visibility.onScreen = true }
        .onDisappear { visibility.onScreen = false }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in foreground = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in foreground = false }
        #endif
        .onChange(of: playing) { _, now in if now { origin = .now } }
        // 点得到 = 一定在屏上：顺手把两路信号对齐，万一哪个回调没来，点一下就能接着播（旧版这时点了也没反应）
        .onChange(of: replay) { _, _ in
            origin = .now
            visibility.onScreen = true
            visibility.inViewport = true
        }
        .accessibilityHidden(true)
    }
}

/// 插图「看得见」= 两路信号各管各的（§12-C）：
/// 旧写法只有一个 visible，三个回调抢着写：onDisappear 清成 false，.scroll 的 onAppear 不管，
/// 回来能不能再播全看 onScrollVisibilityChange 会不会再报一次 true——它是几何回调，只在可见比例跨阈值时报，
/// 哪次没报（iOS 26 LazyVStack 里几何回调只改布局、不滚动时不一定发），visible 就一直是 false，停在示意帧，点图重播也没用。
/// 现在 onAppear / onDisappear 只管 onScreen，滚动回调只管 inViewport，谁也不清对方的。
struct XiaoyaTipVisibility: Equatable {
    /// onAppear / onDisappear
    var onScreen = false
    /// onScrollVisibilityChange（.appear / .still 不看它）
    var inViewport = false

    func visible(_ gate: XiaoyaTipIllustration.Gate) -> Bool {
        switch gate {
        case .scroll: onScreen && inViewport
        case .appear: onScreen
        case .still: false
        }
    }
}

/// 循环进度：从 origin 起过了几秒，对一圈时长取余（同原来的 LinearKeyframe 0→1 重复）
enum XiaoyaTipClock {
    static func progress(at date: Date, origin: Date, duration: Double) -> Double {
        let elapsed = date.timeIntervalSince(origin)
        guard duration > 0, elapsed > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: duration) / duration
    }
}

/// 一帧画面：t ∈ 0…1
private struct XiaoyaTipScreen: View {
    let scene: XiaoyaTipScene
    let t: Double
    var still = false

    static let w: CGFloat = 104
    static let h: CGFloat = 220

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch scene {
            case .strip: stripScene
            case .arc: arcScene
            case .toChat: slideScene(left: AnyView(MiniChat(floor: MiniFloor.a)), right: AnyView(MiniDesk()), tag: "聊天")
            case .toList: slideScene(left: AnyView(MiniList(floor: MiniFloor.a)), right: AnyView(MiniChat(floor: MiniFloor.a)), tag: "对话列表")
            case .floors: floorsScene
            }
            // 灵动岛
            Capsule().fill(.black).frame(width: 30, height: 8).position(x: Self.w / 2, y: 8)
        }
        .frame(width: Self.w, height: Self.h, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: 回桌面 · 竖条（小样 sA / sS / sF / sR / sT）

    private var stripScene: some View {
        let appX = seg(t, [(0, 0), (0.08, 0), (0.32, -26), (0.93, -26), (1, 0)])
        let appScale = seg(t, [(0, 1), (0.08, 1), (0.32, 0.95), (0.52, 0.95), (0.64, 0.4), (0.93, 0.4), (1, 1)])
        let appOpacity = seg(t, [(0, 1), (0.52, 1), (0.64, 0), (0.93, 0), (1, 1)])
        let appRadius = seg(t, [(0, 0), (0.08, 0), (0.32, 14), (0.93, 14), (1, 0)])
        let stripX = seg(t, [(0, 26), (0.08, 26), (0.32, 0), (0.54, 0), (0.66, 26), (1, 26)])
        return ZStack(alignment: .topLeading) {
            MiniDesk()
            MiniStrip().offset(x: Self.w - 24 + stripX)
            MiniApp()
                .clipShape(RoundedRectangle(cornerRadius: appRadius, style: .continuous))
                .scaleEffect(appScale)
                .offset(x: appX)
                .opacity(appOpacity)
            ring(x: 82, y: 34, opacity: seg(t, [(0, 0), (0.48, 0), (0.5, 0.9), (0.6, 0), (1, 0)]),
                 scale: seg(t, [(0, 0.5), (0.48, 0.5), (0.5, 0.6), (0.6, 1.5), (1, 1.5)]))
            tag("⌂ 桌面", opacity: seg(t, [(0, 0), (0.62, 0), (0.68, 1), (0.92, 1), (0.97, 0), (1, 0)]))
            finger(x: seg(t, [(0, 78), (0.08, 78), (0.32, 26), (0.36, 26), (0.46, 85), (1, 85)]),
                   y: seg(t, [(0, 120), (0.36, 120), (0.46, 38), (1, 38)]),
                   opacity: still ? 1 : seg(t, [(0, 0), (0.08, 1), (0.53, 1), (0.6, 0), (1, 0)]),
                   scale: seg(t, [(0, 1), (0.46, 1), (0.49, 0.78), (0.53, 1), (1, 1)]))
            if still { arrow("arrow.left", x: 46, y: 104) }
        }
    }

    // MARK: 回桌面 · 弧线（小样 aD / aA / aF / aT）

    private var arcScene: some View {
        let x = seg(t, [(0, 0), (0.08, 0), (0.36, 8), (0.5, 8), (0.68, -33), (0.94, -33), (1, 0)])
        let y = seg(t, [(0, 0), (0.08, 0), (0.36, 14), (0.5, 14), (0.68, -43), (0.94, -43), (1, 0)])
        let s = seg(t, [(0, 1), (0.08, 1), (0.36, 0.56), (0.5, 0.56), (0.68, 0.16), (0.94, 0.16), (1, 1)])
        let r = seg(t, [(0, 0), (0.08, 0), (0.36, 18), (0.5, 18), (0.68, 30), (0.94, 30), (1, 0)])
        let o = seg(t, [(0, 1), (0.68, 0.85), (0.72, 0), (0.94, 0), (1, 1)])
        let deskDim = seg(t, [(0, 0), (0.08, 0), (0.2, 0.35), (0.52, 0.35), (0.7, 0), (1, 0)])
        let deskScale = seg(t, [(0, 1), (0.08, 1), (0.2, 1.05), (0.52, 1.05), (0.7, 1), (1, 1)])
        return ZStack(alignment: .topLeading) {
            MiniDesk()
                .overlay(Color.white.opacity(deskDim))
                .scaleEffect(deskScale)
            MiniApp()
                .overlay(alignment: .topLeading) { MiniArc().offset(x: 3, y: 3) }
                .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                .shadow(color: .black.opacity(s < 0.9 ? 0.25 : 0), radius: 9, y: 6)
                .scaleEffect(s)
                .offset(x: x, y: y)
                .opacity(o)
            tag("后台", opacity: seg(t, [(0, 0), (0.34, 0), (0.38, 1), (0.52, 1), (0.56, 0), (1, 0)]))
            tag("桌面", opacity: seg(t, [(0, 0), (0.7, 0), (0.75, 1), (0.92, 1), (0.97, 0), (1, 0)]))
            finger(x: seg(t, [(0, 4), (0.08, 4), (0.36, 38), (0.5, 38), (0.68, 62), (1, 62)]),
                   y: seg(t, [(0, 6), (0.08, 6), (0.36, 84), (0.5, 84), (0.68, 150), (1, 150)]),
                   opacity: still ? 1 : seg(t, [(0, 0), (0.08, 1), (0.68, 1), (0.76, 0), (1, 0)]))
            if still { arrow("arrow.down.right", x: 62, y: 116) }
        }
    }

    // MARK: 去聊天 / 看所有对话（小样 cT / cF / cG）：左右两页并排，手指往右划，整条往右挪一页

    private func slideScene(left: AnyView, right: AnyView, tag text: String) -> some View {
        let shift = seg(t, [(0, 0), (0.14, 0), (0.44, Self.w), (0.93, Self.w), (0.94, 0), (1, 0)])
        let fade = seg(t, [(0, 1), (0.88, 1), (0.93, 0), (0.94, 0), (1, 1)])
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                left.frame(width: Self.w, height: Self.h)
                right.frame(width: Self.w, height: Self.h)
            }
            .offset(x: -Self.w + shift)
            .opacity(fade)
            tag(text, opacity: seg(t, [(0, 0), (0.44, 0), (0.5, 1), (0.88, 1), (0.93, 0), (1, 0)]))
            finger(x: seg(t, [(0, 14), (0.1, 14), (0.44, 78), (1, 78)]), y: 120,
                   opacity: still ? 1 : seg(t, [(0, 0), (0.1, 1), (0.44, 1), (0.52, 0), (1, 0)]))
            if still { arrow("arrow.right", x: 46, y: 104) }
        }
    }

    // MARK: 楼层是什么（粟粟 10-16）：对话列表顶上点楼层 → 展开 → 换一层 → 翻到聊天，名字头像跟着变

    private var floorsScene: some View {
        let floor = t < 0.47 ? MiniFloor.a : MiniFloor.b
        let menu = seg(t, [(0, 0), (0.2, 0), (0.26, 1), (0.47, 1), (0.53, 0), (1, 0)])
        let shift = seg(t, [(0, 0), (0.6, 0), (0.72, -Self.w), (0.93, -Self.w), (0.94, 0), (1, 0)])
        let fade = seg(t, [(0, 1), (0.88, 1), (0.93, 0), (0.94, 0), (1, 1)])
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                MiniList(floor: floor).frame(width: Self.w, height: Self.h)
                MiniChat(floor: floor).frame(width: Self.w, height: Self.h)
            }
            .offset(x: shift)
            .opacity(fade)
            MiniFloorMenu(current: floor)
                .scaleEffect(x: 1, y: 0.6 + 0.4 * menu, anchor: .top)
                .opacity(menu)
                .offset(x: 8, y: 36)
            ring(x: 26, y: 13, opacity: seg(t, [(0, 0), (0.14, 0), (0.16, 0.9), (0.24, 0), (1, 0)]),
                 scale: seg(t, [(0, 0.5), (0.14, 0.5), (0.16, 0.6), (0.24, 1.5), (1, 1.5)]))
            ring(x: 26, y: 57, opacity: seg(t, [(0, 0), (0.42, 0), (0.44, 0.9), (0.52, 0), (1, 0)]),
                 scale: seg(t, [(0, 0.5), (0.42, 0.5), (0.44, 0.6), (0.52, 1.5), (1, 1.5)]))
            tag("Ta 跟着换了", opacity: seg(t, [(0, 0), (0.72, 0), (0.76, 1), (0.9, 1), (0.93, 0), (1, 0)]))
            finger(x: seg(t, [(0, 60), (0.06, 60), (0.13, 30), (1, 30)]),
                   y: seg(t, [(0, 110), (0.06, 110), (0.13, 17), (0.34, 17), (0.42, 61), (1, 61)]),
                   opacity: still ? 1 : seg(t, [(0, 0), (0.06, 1), (0.5, 1), (0.56, 0), (1, 0)]),
                   scale: seg(t, [(0, 1), (0.13, 1), (0.15, 0.8), (0.18, 1), (0.42, 1), (0.44, 0.8), (0.47, 1), (1, 1)]))
        }
    }

    // MARK: 零件

    /// 手指：半透明圆 + 白圈。x / y 是左上角（同小样 .fg 的 translate）
    private func finger(x: Double, y: Double, opacity: Double, scale: Double = 1) -> some View {
        Circle()
            .fill(gardenColor("#3D3533").opacity(0.32))
            .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .frame(width: 18, height: 18)
            .scaleEffect(scale)
            .offset(x: x, y: y)
            .opacity(opacity)
    }

    private func ring(x: Double, y: Double, opacity: Double, scale: Double) -> some View {
        Circle()
            .stroke(.white, lineWidth: 2)
            .frame(width: 26, height: 26)
            .scaleEffect(scale)
            .offset(x: x, y: y)
            .opacity(opacity)
    }

    private func tag(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(gardenColor("#3D3533").opacity(0.78), in: Capsule())
            .fixedSize()
            .frame(width: Self.w, alignment: .center)
            .offset(y: Self.h - 26)
            .opacity(opacity)
    }

    /// 停住时（减弱动态效果 / 看不见）补一个方向箭头
    private func arrow(_ symbol: String, x: Double, y: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(gardenColor("#3D3533").opacity(0.7), in: Circle())
            .offset(x: x, y: y)
    }

    /// 分段插值：stops 按时间排好，段内 smoothstep 缓动（近似小样的 cubic-bezier）
    private func seg(_ t: Double, _ stops: [(Double, Double)]) -> Double {
        guard let first = stops.first else { return 0 }
        if t <= first.0 { return first.1 }
        for (a, b) in zip(stops, stops.dropFirst()) where t <= b.0 {
            let span = b.0 - a.0
            guard span > 0 else { return b.1 }
            let u = (t - a.0) / span
            let e = u * u * (3 - 2 * u)
            return a.1 + (b.1 - a.1) * e
        }
        return stops.last?.1 ?? 0
    }
}

// MARK: - 迷你页面（小样 mDesk / mApp / mChat / mList / mStrip）

private enum MiniFloor {
    static let a = gardenColor("#C9A99A")
    static let b = gardenColor("#b3a2cc")
    static let c = gardenColor("#8EBD9F")
}

private struct MiniDesk: View {
    private static let iconColors = ["#F3E4E4", "#E7EEEC", "#ECE7F1", "#F4E8DC", "#FFFBF6", "#EFE6DA", "#E9EEE6", "#F1E6EC"]
    private static let day = Calendar.current.component(.day, from: Date())

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: gardenColor("#FFFBF6"), location: 0),
                                   .init(color: gardenColor("#EEF2EF"), location: 0.6),
                                   .init(color: gardenColor("#E7EEEC"), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Text("\(Self.day)")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(gardenColor("#3D3533"))
                .offset(x: 10, y: 14)
            ForEach(0..<16, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(gardenColor(Self.iconColors[i % 8]))
                    .overlay {
                        if i == 0 { Image("xiaoya-cameo").resizable().scaledToFit() }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(gardenColor("#3D3533").opacity(0.12), lineWidth: 0.5))
                    .frame(width: 17, height: 17)
                    .offset(x: 10 + CGFloat(i % 4) * 23, y: 58 + CGFloat(i / 4) * 28)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.55))
                .frame(width: 88, height: 28)
                .offset(x: 8, y: 184)
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(gardenColor(Self.iconColors[(i + 3) % 8]))
                    .frame(width: 14, height: 14)
                    .offset(x: 16 + CGFloat(i) * 20, y: 191)
            }
        }
        .frame(width: 104, height: 220, alignment: .topLeading)
    }
}

/// 小芽 app：剧场头 + 剪纸小芽 + 几行字
private struct MiniApp: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            gardenColor("#F3F3EF")
            gardenColor("#2F5D57").frame(width: 104, height: 78)
            Image(XiaoyaMood.smirk.assetName)
                .resizable().scaledToFit()
                .frame(height: 38)
                .offset(x: 10, y: 34)
            RoundedRectangle(cornerRadius: 2)
                .fill(gardenColor("#F2EEE4"))
                .frame(width: 36, height: 14)
                .rotationEffect(.degrees(-3))
                .offset(x: 52, y: 48)
            line(y: 96, width: 70, her: true)
            line(y: 106, width: 54, her: true)
            RoundedRectangle(cornerRadius: 7).fill(gardenColor("#FAFAF7"))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(gardenColor("#E2E2DA"), lineWidth: 0.5))
                .frame(width: 84, height: 30).offset(x: 10, y: 120)
            line(y: 160, width: 62, her: true)
            Capsule().fill(gardenColor("#DCE7DF")).frame(width: 40, height: 9).offset(x: 54, y: 176)
            Capsule().fill(.white).overlay(Capsule().stroke(gardenColor("#E2E2DA"), lineWidth: 0.5))
                .frame(width: 84, height: 10).offset(x: 10, y: 200)
        }
        .frame(width: 104, height: 220, alignment: .topLeading)
    }

    private func line(y: CGFloat, width: CGFloat, her: Bool) -> some View {
        HStack(spacing: 2) {
            if her { Rectangle().fill(gardenColor("#1E3D26")).frame(width: 2, height: 4) }
            Rectangle().fill(gardenColor("#c7cfc8")).frame(height: 4)
        }
        .frame(width: width, height: 4)
        .offset(x: 10, y: y)
    }
}

/// 聊天页：顶上是这一层 Ta 的头像 + 名字
private struct MiniChat: View {
    let floor: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            gardenColor("#FBFAF7")
            Circle().fill(floor).frame(width: 14, height: 14).offset(x: 45, y: 15)
            Capsule().fill(gardenColor("#cfc8bd")).frame(width: 22, height: 3).offset(x: 41, y: 31)
            Rectangle().fill(gardenColor("#E7E4DC")).frame(width: 104, height: 0.5).offset(y: 40)
            bubble(left: true, y: 52, width: 58)
            bubble(left: false, y: 72, width: 44)
            bubble(left: true, y: 92, width: 66, height: 22)
            bubble(left: false, y: 121, width: 52)
            bubble(left: true, y: 141, width: 40)
            Capsule().fill(.white).overlay(Capsule().stroke(gardenColor("#E0DCD2"), lineWidth: 0.5))
                .frame(width: 88, height: 16).offset(x: 8, y: 194)
        }
        .frame(width: 104, height: 220, alignment: .topLeading)
    }

    private func bubble(left: Bool, y: CGFloat, width: CGFloat, height: CGFloat = 13) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(left ? Color.white : gardenColor("#DCE7DF"))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(gardenColor("#E6E2D8"), lineWidth: left ? 0.5 : 0))
            .frame(width: width, height: height)
            .offset(x: left ? 8 : 104 - 8 - width, y: y)
    }
}

/// 对话列表：顶上是楼层（头像 + 名字 ▾），下面一排排对话
private struct MiniList: View {
    let floor: Color
    private static let colors = ["#C9A99A", "#b3a2cc", "#e3a9b0", "#8EBD9F", "#d9a07f", "#c7b27a"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            gardenColor("#FFFBF6")
            HStack(spacing: 4) {
                Circle().fill(floor).frame(width: 11, height: 11)
                Capsule().fill(gardenColor("#3D3533").opacity(0.7)).frame(width: 26, height: 3.5)
                Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold)).foregroundStyle(gardenColor("#3D3533"))
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(.white, in: Capsule())
            .overlay(Capsule().stroke(gardenColor("#E2DDD2"), lineWidth: 0.5))
            .offset(x: 8, y: 16)
            ForEach(0..<6, id: \.self) { i in
                ZStack(alignment: .topLeading) {
                    Circle().fill(gardenColor(Self.colors[(i + (floor == MiniFloor.a ? 0 : 2)) % 6])).frame(width: 15, height: 15).offset(y: 3)
                    Capsule().fill(gardenColor("#bdb5a8")).frame(width: CGFloat(30 + (i * 13) % 28), height: 3.5).offset(x: 21, y: 5)
                    Capsule().fill(gardenColor("#ddd7cc")).frame(width: CGFloat(44 + (i * 7) % 20), height: 3).offset(x: 21, y: 12)
                }
                .frame(width: 88, height: 22, alignment: .topLeading)
                .offset(x: 8, y: 44 + CGFloat(i) * 26)
            }
        }
        .frame(width: 104, height: 220, alignment: .topLeading)
    }
}

/// 展开的楼层切换器：三层，当前那层打勾
private struct MiniFloorMenu: View {
    let current: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([MiniFloor.a, MiniFloor.b, MiniFloor.c], id: \.self) { color in
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 12, height: 12)
                    Capsule().fill(gardenColor("#3D3533").opacity(0.55)).frame(width: 30, height: 3)
                    Spacer(minLength: 0)
                    if color == current {
                        Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(gardenColor("#5f8f74"))
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
            }
        }
        .frame(width: 76)
        .padding(.vertical, 3)
        .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
    }
}

/// 竖条：⌂ + 分隔 + 后台 app
private struct MiniStrip: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            gardenColor("#292623")
            RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.22))
                .overlay(Text("⌂").font(.system(size: 9)).foregroundStyle(.white))
                .frame(width: 16, height: 16).offset(x: 4, y: 40)
            Rectangle().fill(.white.opacity(0.25)).frame(width: 8, height: 1).offset(x: 8, y: 62)
            RoundedRectangle(cornerRadius: 5).fill(gardenColor("#F2EEE4"))
                .overlay(Image("xiaoya-cameo").resizable().scaledToFit().padding(1))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: 1.2))
                .frame(width: 16, height: 16).offset(x: 4, y: 70)
            RoundedRectangle(cornerRadius: 5).fill(gardenColor("#ECE7F1")).frame(width: 16, height: 16).offset(x: 4, y: 92)
            RoundedRectangle(cornerRadius: 5).fill(gardenColor("#F4E8DC")).frame(width: 16, height: 16).offset(x: 4, y: 114)
        }
        .frame(width: 24, height: 220, alignment: .topLeading)
    }
}

/// 左上角的回桌面弧线
private struct MiniArc: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 3, y: 20))
            p.addCurve(to: CGPoint(x: 20, y: 3), control1: CGPoint(x: 3, y: 10), control2: CGPoint(x: 10, y: 3))
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        .frame(width: 26, height: 26)
    }
}

// MARK: - 「Tip 1.1」纸签（小样 .tipno：金黄纸条、两头剪成燕尾、斜贴）

struct XiaoyaTipLabel: View {
    let label: String

    var body: some View {
        Text("Tip \(label)")
            .font(.system(size: 13, weight: .bold, design: .serif).italic())
            .tracking(0.5)
            .foregroundStyle(gardenColor("#5a4316"))
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .padding(.vertical, 1)
            .background(gardenColor("#F2D98E"), in: XiaoyaTipLabelShape())
            .compositingGroup()
            .shadow(color: .black.opacity(0.2), radius: 0, x: 1, y: 1.5)
            .rotationEffect(.degrees(-3))
    }
}

/// polygon(0 0, 100% 6%, 96% 50%, 100% 96%, 0 100%, 4% 50%)
private struct XiaoyaTipLabelShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addLines([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + r.height * 0.06),
                    CGPoint(x: r.minX + r.width * 0.96, y: r.midY), CGPoint(x: r.maxX, y: r.minY + r.height * 0.96),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + r.width * 0.04, y: r.midY)])
        p.closeSubpath()
        return p
    }
}

// MARK: - 灯泡点开：小芽的提示（§12「小样定稿」：干净的分组列表，不拟物；点一条打开原来那张 Tip 卡）

struct XiaoyaTipHistoryView: View {
    let script: XiaoyaScriptRunner
    let skin: XiaoyaSkin
    @Environment(\.dismiss) private var dismiss
    /// 词典里点了的词：弹释义 sheet（叠在这张列表 sheet 上）
    @State private var glossTerm: XiaoyaGlossary.Term?

    private var subtitle: String {
        let log = script.tips
        guard !log.isEmpty else { return "" }
        let unseen = log.unseenCount
        return "\(log.items.count) 条" + (unseen > 0 ? " · \(unseen) 条还没看" : "")
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(script.tips.sorted, id: \.number) { entry in
                    Section {
                        ForEach(XiaoyaTipCatalog.refs(for: entry.number), id: \.label) { ref in
                            NavigationLink {
                                tipPage(ref)
                            } label: {
                                tipRow(ref)
                            }
                            .listRowBackground(skin.card)
                        }
                    } header: {
                        Text("Tip \(entry.number) · \(XiaoyaTipCatalog.groupTitle(entry.number))")
                    }
                }
                Section {
                    ForEach(script.glossary.dictionary, id: \.term.word) { entry in
                        wordRow(entry)
                            .listRowBackground(skin.card)
                    }
                } header: {
                    Text("词典 · \(AssistantPrompts.assistantName)的词")
                } footer: {
                    Text("点一个词看释义；标「讲过」的是\(AssistantPrompts.assistantName)在聊天里讲过的")
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(skin.paper)
            .environment(\.xiaoyaSkin, skin)
            .navigationTitle("\(AssistantPrompts.assistantName)的提示")
            .navigationSubtitle(subtitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .sheet(item: $glossTerm) { term in
            XiaoyaGlossSheet(term: term)
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    private func tipRow(_ ref: XiaoyaTipRef) -> some View {
        XiaoyaTipModeReader { strip in
            let copy = XiaoyaScriptLines.tip(ref.kind, strip: strip)
            let seen = script.tips.isSeen(ref)
            HStack(spacing: 12) {
                Text(ref.label)
                    .font(.system(size: 16, weight: .semibold, design: .serif).italic())
                    .foregroundStyle(gardenColor("#b8954c"))
                    .frame(minWidth: 30, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.title)
                        .font(.system(size: XiaoyaCardFont.body, weight: .semibold))
                        .foregroundStyle(skin.ink)
                    Text(copy.summary)
                        .font(.system(size: XiaoyaCardFont.hint))
                        .foregroundStyle(skin.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(gardenColor("#D9483B"))
                    .frame(width: 8, height: 8)
                    .opacity(seen ? 0 : 1)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityValue(seen ? "" : "没看")
        }
    }

    private func tipPage(_ ref: XiaoyaTipRef) -> some View {
        ScrollView {
            XiaoyaTipCardView(ref: ref, showsGo: false)
                .padding(16)
        }
        .background(skin.paper)
        .environment(\.xiaoyaSkin, skin)
        .navigationTitle("Tip \(ref.label)")
        .onAppear { script.openTip(ref) }
    }

    private func wordRow(_ entry: XiaoyaGlossaryLog.DictionaryEntry) -> some View {
        let term = entry.term
        return Button { glossTerm = XiaoyaGlossary.term(term.word) } label: {
            HStack(spacing: 12) {
                Text("Aa")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(gardenColor("#b8954c"))
                    .frame(minWidth: 30, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        XiaoyaMarkedText("[[\(term.word)]]")
                            .font(.system(size: XiaoyaCardFont.body))
                            .foregroundStyle(skin.ink)
                        if entry.spoken {
                            Text("讲过")
                                .font(.system(size: XiaoyaCardFont.hint))
                                .foregroundStyle(gardenColor("#b8954c"))
                        }
                    }
                    Text(term.definition)
                        .font(.system(size: XiaoyaCardFont.hint))
                        .foregroundStyle(skin.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(skin.inkMuted)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
