import SwiftUI

// MARK: - 小芽 v2 · 剪纸舞台头（plan-小芽-v2 §3.3 + §3.6，粟粟 Q1 裁决 A + 09-26 剪纸舞台）
// 纸剧场布景 + 站在台口的剪纸小芽 + 斜贴的名字小票。它是盖在消息 ScrollView 上的浮层：
// 收放只改浮层自己的高度，不改列表的 viewport——避免「收起→可视区变高→离底距离变→又展开」的反馈环（astra B11）。

struct XiaoyaStageView: View {
    let state: XiaoyaStageState
    let name: String
    let englishName: String?
    let collapsed: Bool
    let theme: XiaoyaStageTheme
    let dark: Bool
    /// 本地大脑在答：小票上带片叶子
    var local = false
    /// 右上角「账本」钮
    var onLedger: (() -> Void)?
    /// 右上角齿轮：小芽设置（v3 §3）
    var onSettings: (() -> Void)?

    static var faceHeight: CGFloat {
        #if os(macOS)
        96
        #else
        118
        #endif
    }
    private static let collapsedFace: CGFloat = 40
    /// 展开时舞台（不含顶部安全区）的高度；消息列表顶部留同样的边距，最上面一条不会被盖住
    static var expandedHeight: CGFloat { faceHeight + 82 }
    private static let collapsedHeight: CGFloat = 70

    private var palette: XiaoyaStagePalette { theme.palette(dark: dark) }
    /// 这一翻从哪张到哪张。只在 onChange 里更新、同时当动画触发器——
    /// 画面只读它，不直接读 state.mood（onChange 比 body 晚一拍，直接读会闪一帧错脸）
    @State private var flip: FaceFlip?
    /// 出现时的脸：第一次翻之前 flip 还是空的，靠它顶住 onChange 之前那一帧
    @State private var restingMood: XiaoyaMood?
    @State private var lastLine: String?

    /// 纸片的一面：正面是某张表情；背面是那张剪纸的反面，写着一句话（粟粟 09-26「点一下小芽翻到背面」）
    private enum FaceSide: Equatable {
        case front(XiaoyaMood)
        case back(of: XiaoyaMood, line: String)
    }

    private struct FaceFlip: Equatable {
        var from: FaceSide
        var to: FaceSide
        var serial = 0
    }

    private var currentSide: FaceSide { flip?.to ?? .front(restingMood ?? state.mood) }

    private func turn(to side: FaceSide) {
        flip = FaceFlip(from: currentSide, to: side, serial: (flip?.serial ?? 0) + 1)
    }

    /// 点她：正面 → 翻到背面，3.5 秒后自己翻回来；在背面再点一下立刻翻回来
    private func tapFace() {
        XiaoyaProbe.log("tapFace collapsed=\(collapsed) side=\(currentSide)")
        guard !collapsed else { return }
        if case .back = currentSide {
            turn(to: .front(state.mood))
            return
        }
        let line = XiaoyaLines.random(excluding: lastLine)
        lastLine = line
        turn(to: .back(of: state.mood, line: line))
        let serial = flip?.serial
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            if flip?.serial == serial { turn(to: .front(state.mood)) }
        }
    }

    var body: some View {
        HStack(alignment: collapsed ? .center : .bottom, spacing: collapsed ? 10 : 6) {
            face
            ticket
                .padding(.bottom, collapsed ? 0 : 14)
            Spacer(minLength: 0)
        }
        .padding(.leading, collapsed ? 16 : 20)
        .padding(.trailing, 12)
        .padding(.top, collapsed ? 22 : 0)
        .padding(.bottom, collapsed ? XiaoyaStageBackdrop.edgeDepth : XiaoyaStageBackdrop.edgeDepth + 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: collapsed ? .leading : .bottomLeading)
        .frame(height: collapsed ? Self.collapsedHeight : Self.expandedHeight)
        .overlay(alignment: .topTrailing) { cornerButtons }
        .background(alignment: .bottom) {
            GeometryReader { geo in
                XiaoyaStageBackdrop(theme: theme, dark: dark, collapsed: collapsed, topInset: geo.safeAreaInsets.top)
            }
            .ignoresSafeArea(edges: .top)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: collapsed)
        .onChange(of: state.mood) { old, new in
            flip = FaceFlip(from: flip?.to ?? .front(old), to: .front(new), serial: (flip?.serial ?? 0) + 1)
            XiaoyaProbe.log("mood \(old)->\(new)")
        }
        .onChange(of: collapsed) { _, new in XiaoyaProbe.log("collapsed=\(new)") }
        .onAppear { if restingMood == nil { restingMood = state.mood } }
    }

    /// 换表情 = 纸片绕竖轴翻一下：0→90° 还是旧脸，90° 侧面那一刻换成新脸，再从 -90° 翻回正面。
    /// 用 KeyframeAnimator 由表情变化直接触发——不靠 transition + 动画事务（09-26 实测那条路从没动过）
    private var face: some View {
        let h = collapsed ? Self.collapsedFace : Self.faceHeight
        let from = flip?.from ?? .front(restingMood ?? state.mood)
        let to = flip?.to ?? .front(state.mood)
        // 还没翻过时停在 0 = 露 from；翻完停在 180 = 露 to。两种静止态露的都是「当前这张」
        return KeyframeAnimator(initialValue: 0.0, trigger: flip) { angle in
            let showNew = angle >= 90
            sideView(showNew ? to : from, height: h)
                // 先合成一层再投影：背面的字影子落在纸上被挡住，不会重影
                .compositingGroup()
                .shadow(color: .black.opacity(0.28), radius: 0, x: 2, y: 3)
                // 2D 翻片：横向压成 |cos| 宽，压成一条线那一刻换脸。不用 rotation3DEffect——
                // 透视在接近 90° 时把近侧边放得很大，离屏逐帧看到整张脸「扑」上来
                .scaleEffect(x: max(abs(cos(angle * .pi / 180)), 0.02), y: 1 + 0.04 * sin(angle * .pi / 180), anchor: .bottom)
                .frame(maxWidth: h * 1.35, maxHeight: h)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                CubicKeyframe(90, duration: 0.16)
                CubicKeyframe(180, duration: 0.24)
            }
        }
        // 固定槽位：九张表情宽窄不一，换脸时小票不跟着左右跳
        .frame(width: h * 1.35, height: h, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture(perform: tapFace)
        .accessibilityLabel(Text(state.status))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("翻到背面"))
    }

    @ViewBuilder
    private func sideView(_ side: FaceSide, height h: CGFloat) -> some View {
        switch side {
        case .front(let mood):
            Image(mood.assetName)
                .resizable()
                .scaledToFit()
        case .back(let mood, let line):
            // 剪纸反面：绕竖轴翻过来，剪影和透出的线稿都是左右镜像的；字正着写在中间
            ZStack {
                ZStack {
                    Image(mood.assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Self.paperBack)
                    Image(mood.assetName)
                        .resizable()
                        .scaledToFit()
                        .opacity(0.08)
                }
                .scaleEffect(x: -1)
                Text(line)
                    .font(.system(size: h * 0.12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineSpacing(1)
                    .foregroundStyle(Self.backInk)
                    .minimumScaleFactor(0.7)
                    .padding(h * 0.14)
            }
        }
    }

    private static let paperBack = Color(red: 0.925, green: 0.894, blue: 0.827)
    private static let backInk = Color(red: 0.118, green: 0.239, blue: 0.149)

    /// 奶白小票：名字 + 英文名 + 状态行，两头打孔，斜贴
    private var ticket: some View {
        VStack(alignment: .leading, spacing: collapsed ? 0 : 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: collapsed ? 15 : 20, weight: .bold))
                    .tracking(collapsed ? 0.5 : 2)
                if let englishName {
                    Text(englishName)
                        .font(.system(size: collapsed ? 11 : 13, design: .serif).italic())
                        .opacity(0.65)
                }
                if local {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: collapsed ? 9 : 10))
                        .opacity(0.6)
                        .accessibilityLabel("本地大脑")
                }
            }
            HStack(spacing: 5) {
                if state.isBusy {
                    XiaoyaBusyDots(color: palette.ticketInk.opacity(0.7))
                } else {
                    Circle().fill(palette.ticketInk.opacity(0.5)).frame(width: 4, height: 4)
                }
                Text(state.status)
                    .font(.system(size: collapsed ? 10.5 : 12))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .opacity(0.85)
        }
        .foregroundStyle(palette.ticketInk)
        .padding(.horizontal, collapsed ? 11 : 14)
        .padding(.vertical, collapsed ? 5 : 7)
        .background(palette.ticket, in: RoundedRectangle(cornerRadius: 3))
        .overlay(alignment: .leading) { Circle().fill(palette.backdrop).frame(width: 9, height: 9).offset(x: -4.5) }
        .overlay(alignment: .trailing) { Circle().fill(palette.backdrop).frame(width: 9, height: 9).offset(x: 4.5) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 0, x: 2, y: 3)
        .rotationEffect(.degrees(collapsed ? 0 : -2.5))
        .animation(.easeOut(duration: 0.2), value: state.status)
    }

    private var cornerButtons: some View {
        HStack(spacing: 8) {
            if let onSettings { cornerButton("gearshape", label: "小芽设置", action: onSettings) }
            if let onLedger { cornerButton("list.bullet.rectangle", label: "她改过的东西", action: onLedger) }
        }
        .padding(.trailing, 14)
        .padding(.top, collapsed ? 26 : 44)
    }

    private func cornerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ticketInk)
                .frame(width: 32, height: 32)
                .background(palette.ticket, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 0, x: 1, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 状态行的三个跳点（在想 / 在翻资料时）
struct XiaoyaBusyDots: View {
    let color: Color

    var body: some View {
        PhaseAnimator([0, 1, 2]) { phase in
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: 4, height: 4).opacity(i == phase ? 1 : 0.25)
                }
            }
        } animation: { _ in .easeInOut(duration: 0.35) }
    }
}
