import SwiftUI

/// 文件夹里露出的一张纸：文本 = 标题 + 开头几行；图片 = 缩略图
struct FileLibraryFolderSheet: Identifiable, Equatable {
    enum Face: Equatable {
        case text(title: String, lines: [String])
        case image(URL, modifiedAt: Date)
    }

    let id: String
    let face: Face
}

/// 后片：圆角 16 + 左上耳朵，一条路径画完（耳朵右侧用小内圆角接进顶边）
struct FileLibraryFolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.height / FileLibraryFolderCard.height
        let w = rect.width
        let h = rect.height
        let top = 16 * k
        let earTop = 7 * k
        let earWidth = 60 * k
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h / 2))
        p.addArc(tangent1End: CGPoint(x: 0, y: earTop), tangent2End: CGPoint(x: earWidth, y: earTop), radius: 9 * k)
        p.addArc(tangent1End: CGPoint(x: earWidth, y: earTop), tangent2End: CGPoint(x: earWidth, y: top), radius: 6 * k)
        p.addArc(tangent1End: CGPoint(x: earWidth, y: top), tangent2End: CGPoint(x: w, y: top), radius: 3 * k)
        p.addArc(tangent1End: CGPoint(x: w, y: top), tangent2End: CGPoint(x: w, y: h), radius: 16 * k)
        p.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: 0, y: h), radius: 16 * k)
        p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: earTop), radius: 16 * k)
        p.closeSubpath()
        return p
    }
}

/// 标记：SF Symbol / emoji / 首字（Georgia）
struct FileLibraryFolderMarkView: View {
    let mark: FileLibraryFolderLook.Mark
    let name: String
    let size: CGFloat
    let color: Color

    var body: some View {
        switch mark.kind {
        case .symbol:
            Image(systemName: mark.value ?? "folder")
                .font(.system(size: size * 0.9, weight: .regular))
                .foregroundColor(color)
        case .emoji:
            Text(mark.value ?? "")
                .font(.system(size: size))
        case .mono:
            Text(FileLibraryFolderLook.monogram(name))
                .font(.custom("Georgia", size: size * 1.08).weight(.semibold))
                .foregroundColor(color)
        case .none:
            EmptyView()
        }
    }
}

/// 卡片模式的磨砂文件夹：后片 + 最近 3 张纸 + 磨砂前片。`pose`：合上 / 按下（轻反馈）/ 张开（前片往前倒、纸扇形弹出、整只抬起），动画自带。
/// 后片 / 纸 / 前片拆成 static，开盒转场的飞行层用同一套画，交接那一帧逐像素一致。
struct FileLibraryFolderCard: View {
    enum Pose: Equatable {
        case closed, pressed, open
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let name: String
    let detail: String
    let look: FileLibraryFolderLook
    let sheets: [FileLibraryFolderSheet]
    let pose: Pose
    /// 开盒转场期间袋子（后片 + 纸 + 前片）交给飞行层画，这里藏起来；名字 / 详情照常
    var shellHidden = false

    static let height: CGFloat = 136
    static let frontHeight: CGFloat = 95
    /// 纸的大小、合上时纸顶离文件夹顶多远、合上时缩多少
    static let paperSize = CGSize(width: 92, height: 84)
    static let paperTop: CGFloat = 42
    static let closedScale: CGFloat = 0.86
    static let openTilt: Double = -26
    static let pressTilt: Double = -8
    static let u = FileLibraryUI.scale
    static let shadowInk = Color(hex: 0x3D3633)
    private static let pressCurve: Animation = .timingCurve(0.2, 1, 0.3, 1, duration: 0.18)

    /// 张开时每张纸的位置：s1 左、s2 中、s3 右；延迟让后面的先出
    static let fan: [(x: CGFloat, y: CGFloat, angle: Double, delay: Double)] = [
        (-30, -44, -11, 0.08),
        (0, -56, 0, 0.04),
        (30, -44, 11, 0)
    ]
    /// 按下时纸往上冒一点（仍是合上的 0.86）
    static let press: [(x: CGFloat, y: CGFloat, angle: Double)] = [
        (-4, -14, -3),
        (0, -16, 0),
        (4, -14, 3)
    ]

    private var open: Bool { pose == .open }

    private static func animation(_ pose: Pose, open: Animation) -> Animation {
        switch pose {
        case .open: open
        case .pressed: pressCurve
        case .closed: .easeIn(duration: 0.25)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            folder
                .opacity(shellHidden ? 0 : 1)
            Text(name)
                .font(FileLibraryUI.font(14, .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.top, 8)
            Text(detail)
                .font(FileLibraryUI.font(11.5))
                .monospacedDigit()
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var folder: some View {
        let u = Self.u
        let lifted = open && !reduceMotion
        let tilt: Double = reduceMotion ? 0 : pose == .open ? Self.openTilt : pose == .pressed ? Self.pressTilt : 0
        return ZStack(alignment: .top) {
            Self.back(look)
            ForEach(Array(sheets.prefix(3).enumerated()), id: \.element.id) { index, sheet in
                paper(sheet, slot: index)
            }
            Self.front(look: look, name: name, tilt: tilt)
                .animation(Self.animation(pose, open: .spring(response: 0.32, dampingFraction: 0.9)), value: pose)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Self.height * u)
        .scaleEffect(pose == .pressed ? 0.97 : 1)
        .offset(y: lifted ? -5 * u : 0)
        .animation(Self.animation(pose, open: .spring(response: 0.45, dampingFraction: 0.9)), value: pose)
    }

    private func paper(_ sheet: FileLibraryFolderSheet, slot: Int) -> some View {
        let u = Self.u
        let spot = Self.fan[slot]
        let fanned = open || reduceMotion
        let raised = pose == .pressed && !reduceMotion
        let lift = Self.press[slot]
        let animation = reduceMotion ? .easeInOut(duration: 0.2) : Self.animation(pose, open: .spring(response: 0.5, dampingFraction: 0.68).delay(spot.delay))
        let x: CGFloat = fanned ? spot.x : raised ? lift.x : 0
        let y: CGFloat = fanned ? spot.y : raised ? lift.y : 0
        let angle: Double = fanned ? spot.angle : raised ? lift.angle : 0
        return Self.sheet(sheet)
            .shadow(color: Self.shadowInk.opacity(0.12), radius: 2.5, y: 1)
            .scaleEffect(fanned ? 1 : Self.closedScale)
            .rotationEffect(.degrees(angle))
            .offset(x: x * u, y: Self.paperTop * u + y * u)
            .opacity(reduceMotion && !open ? 0 : 1)
            .animation(animation, value: pose)
    }

    static func back(_ look: FileLibraryFolderLook) -> some View {
        FileLibraryFolderBackShape()
            .fill(look.paint.backColor)
    }

    /// 一张纸（不含阴影）：92×84，圆角 9
    static func sheet(_ sheet: FileLibraryFolderSheet) -> some View {
        sheetFace(sheet)
            .frame(width: paperSize.width * u, height: paperSize.height * u)
            .background(Theme.mainBg)
            .clipShape(RoundedRectangle(cornerRadius: 9 * u, style: .continuous))
    }

    @ViewBuilder
    static func sheetFace(_ sheet: FileLibraryFolderSheet) -> some View {
        switch sheet.face {
        case .text(let title, let lines):
            VStack(alignment: .leading, spacing: 3 * u) {
                Text(title)
                    .font(.system(size: 8.5 * u, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 6.6 * u))
                        .lineSpacing(1.5 * u)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 9 * u)
            .padding(.top, 8 * u)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image(let url, let modifiedAt):
            Color.clear
                .overlay { FileThumbnailView(url: url, modifiedAt: modifiedAt) }
                .clipped()
        }
    }

    /// 磨砂前片：高 95，绕底边往前倒 `tilt` 度；阴影跟着倒的程度加深
    static func front(look: FileLibraryFolderLook, name: String, tilt: Double) -> some View {
        let paint = look.paint
        let shape = RoundedRectangle(cornerRadius: 15 * u, style: .continuous)
        let k = min(max(tilt / openTilt, 0), 1)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(paint.frontColor))
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom)))
            .overlay {
                if let pattern = look.pattern {
                    FileLibraryFolderPatternView(pattern: pattern, ink: paint.inkColor)
                }
            }
            .overlay(alignment: .bottomLeading) {
                FileLibraryFolderMarkView(mark: look.mark, name: name, size: 22 * u, color: paint.inkColor)
                    .shadow(color: Color.black.opacity(0.08), radius: 0.5, y: 1)
                    .padding(.leading, 12 * u)
                    .padding(.bottom, 10 * u)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.75), Color.white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2)), lineWidth: 1))
            .overlay(shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5))
            .shadow(color: shadowInk.opacity(0.10 + 0.06 * k), radius: 8 + 5 * k, y: 6 + 8 * k)
            .frame(height: frontHeight * u)
            .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
    }
}

/// 文件夹卡片的按钮外观：按住 = 轻反馈（ScrollView 里一滑会自动取消按下 → 弹回；松手没滑 = 点开）；mac 指针放上去 = 张开。卡片画在这里，label 只放 Color.clear。
struct FileLibraryFolderButtonStyle: ButtonStyle {
    let name: String
    let detail: String
    let look: FileLibraryFolderLook
    let sheets: [FileLibraryFolderSheet]
    var hovering = false
    var shellHidden = false

    func makeBody(configuration: Configuration) -> some View {
        FileLibraryFolderCard(
            name: name, detail: detail, look: look, sheets: sheets,
            pose: hovering ? .open : configuration.isPressed ? .pressed : .closed,
            shellHidden: shellHidden
        )
    }
}

/// 卡片模式的文件夹按钮：iOS 按住轻反馈，mac 指针放上去张开。`action` 的参数 = 点下时是不是已经张开（mac 指针在上面）
struct FileLibraryFolderButton: View {
    let name: String
    let detail: String
    let look: FileLibraryFolderLook
    let sheets: [FileLibraryFolderSheet]
    /// 开盒 / 返回转场里袋子交给飞行层画着时藏起来（只有被点的那只会因此刷新）
    var shellMark: FileLibraryFlightMark? = nil
    let action: (_ wasOpen: Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Button { action(hovering) } label: { Color.clear }
            .buttonStyle(FileLibraryFolderButtonStyle(name: name, detail: detail, look: look, sheets: sheets, hovering: hovering, shellHidden: shellMark?.hidden == true))
            #if os(macOS)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            #endif
            .accessibilityLabel(name)
            .accessibilityValue(detail)
    }
}
