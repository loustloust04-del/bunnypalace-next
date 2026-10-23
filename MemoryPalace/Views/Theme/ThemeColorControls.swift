import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - 颜色行（颜色页 13 行共用）

/// 一行颜色：标题（+ 副标题）· hex · ↺（覆盖行）· 色块 / mac ColorPicker。
///
/// iOS 点色块 → 页级单一 `.sheet(item:)` 开 `ColorPickSheet`（系统取色器原样嵌在里面，上面加饱和度 / 明度两根条，D2 加不换）；
/// mac 行内 `ColorPicker` + v1 防回设结构（localColor + 双向 onChange 守卫），NSColorPanel 自带 HSB。
struct ThemeColorRow: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    var subtitle: String? = nil
    let value: ThemeColorValue
    /// nil → 显示 hex；覆盖行跟随态传「跟随主文字」
    var valueText: String? = nil
    /// 纯净背景开着时这行会被覆盖：标灰 + 「被覆盖」
    var covered: Bool = false
    var onReset: (() -> Void)? = nil
    let apply: (ThemeColorValue) -> Void
    let onOpenPicker: () -> Void
    @State private var localColor: Color

    init(
        title: String,
        subtitle: String? = nil,
        value: ThemeColorValue,
        valueText: String? = nil,
        covered: Bool = false,
        onReset: (() -> Void)? = nil,
        apply: @escaping (ThemeColorValue) -> Void,
        onOpenPicker: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.valueText = valueText
        self.covered = covered
        self.onReset = onReset
        self.apply = apply
        self.onOpenPicker = onOpenPicker
        self._localColor = State(initialValue: value.color)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(m.body)
                    .foregroundColor(covered ? Theme.textMuted : Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }

            Spacer(minLength: 8)

            if covered {
                Text("被覆盖")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent.opacity(0.6)))
            } else {
                Text(valueText ?? value.hexString)
                    .font(.system(size: Theme.F.caption, design: valueText == nil ? .monospaced : .default))
                    .foregroundColor(Theme.textMuted)
            }

            if let onReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: Theme.F.caption, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
                .help("还原")
                .accessibilityLabel("\(title) 还原")
            }

            #if os(iOS)
            // iOS 不挂任何 onChange 机器，唯一写入路径 = 取色 sheet 里的真实选色 / 拖条（B22）
            ThemeColorWell(value: value, onTap: onOpenPicker)
                .accessibilityLabel("\(title) 选颜色")
            #else
            ColorPicker("", selection: $localColor)
                .labelsHidden()
                .onChange(of: localColor) { _, picked in
                    if ThemeColorValue(color: picked) != value {
                        apply(ThemeColorValue(color: picked))
                    }
                }
                .onChange(of: value) { _, external in
                    if external != ThemeColorValue(color: localColor) {
                        localColor = external.color
                    }
                }
            #endif
        }
        .opacity(covered ? 0.55 : 1)
        .padding(.vertical, 2)
    }
}

// MARK: - 饱和度 / 明度两根渐变轨道（D2 加不换，住在取色 sheet 里）

/// 三根轨道画成「往哪拖会变成什么色」：色相 = 色环；饱和度 = 同明度的灰 → 纯色；明度 = 黑 → 当前色。
/// 色相独立存着，饱和度拖到 0（灰）再拖回来不丢色相。
struct ColorFineTunePanel: View {
    let value: ThemeColorValue
    let apply: (ThemeColorValue) -> Void
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double

    init(value: ThemeColorValue, apply: @escaping (ThemeColorValue) -> Void) {
        self.value = value
        self.apply = apply
        let hsb = value.hsb
        _hue = State(initialValue: hsb.hue)
        _saturation = State(initialValue: hsb.saturation)
        _brightness = State(initialValue: hsb.brightness)
    }

    var body: some View {
        VStack(spacing: 8) {
            GradientSliderRow(
                title: "色相",
                value: $hue,
                valueText: "\(Int((hue * 360).rounded()))°",
                gradient: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                onEditing: commit
            )
            GradientSliderRow(
                title: "饱和度",
                value: $saturation,
                valueText: "\(Int((saturation * 100).rounded()))%",
                gradient: [
                    Color(hue: hue, saturation: 0, brightness: brightness),
                    Color(hue: hue, saturation: 1, brightness: brightness)
                ],
                onEditing: commit
            )
            GradientSliderRow(
                title: "明度",
                value: $brightness,
                valueText: "\(Int((brightness * 100).rounded()))%",
                gradient: [
                    Color(hue: hue, saturation: saturation, brightness: 0),
                    Color(hue: hue, saturation: saturation, brightness: 1)
                ],
                onEditing: commit
            )
        }
        .onChange(of: value) { _, external in
            // 外部换色（下面的取色器 / ↺ / 撤销）→ 三个分量跟过去；自己写回的值 round trip 后会漂一点，差得小就不动
            let hsb = external.hsb
            if abs(hsb.saturation - saturation) > 0.02 { saturation = hsb.saturation }
            if abs(hsb.brightness - brightness) > 0.02 { brightness = hsb.brightness }
            // 灰色的色相无定义（读出来是 0），别把钉住的色相冲掉
            if hsb.saturation > 0.02, abs(hsb.hue - hue) > 0.02 { hue = hsb.hue }
        }
    }

    private func commit() {
        apply(ThemeColorValue(hue: hue, saturation: saturation, brightness: brightness, alpha: value.alpha))
    }
}

/// 一行：标题 · 渐变轨道 · 数值。紧凑单行——三根条要和 72pt 的大色块并排，还得给下面的系统取色器留够高度。
struct GradientSliderRow: View {
    let title: String
    @Binding var value: Double
    let valueText: String
    let gradient: [Color]
    let onEditing: () -> Void

    var body: some View {
        // 只住在取色 sheet 里，文字用系统语义色：编辑「主文字」时标签不能跟着变没
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(.primary)
                .frame(width: 40, alignment: .leading)
            GradientSlider(value: $value, gradient: gradient, onEditing: onEditing)
            Text(valueText)
                .font(.system(size: Theme.F.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// 轨道是渐变的滑杆。系统 `Slider` 的轨道换不了色，自画一根：胶囊渐变 + 白圆钮 + 横向拖。
struct GradientSlider: View {
    @Binding var value: Double
    let gradient: [Color]
    let onEditing: () -> Void
    private let knob: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: CGFloat(value) * usable)
            }
            // 显式尺寸，不用 maxHeight: .infinity——无障碍树里出现无穷大 frame 会让 idb 的 JSON 序列化直接崩（09-16 两次）
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        value = min(max(Double((g.location.x - knob / 2) / usable), 0), 1)
                        onEditing()
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
            onEditing()
        }
    }
}

// MARK: - 背景参数滑杆行（聊天背景页；M2 起带可选副标题）

struct ThemeAdjustmentSliderRow: View {
    let title: String
    var subtitle: String? = nil
    let range: ClosedRange<Double>
    @Binding var value: Double
    let leadingLabel: String
    let trailingLabel: String
    let valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Text(valueText)
                    .font(.system(size: Theme.F.caption, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }

            HStack(spacing: 10) {
                Text(leadingLabel)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)

                Slider(value: $value, in: range)
                    .tint(Theme.branchIndicator)

                Text(trailingLabel)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.vertical, 2)
    }
}

#if os(iOS)
// MARK: - iOS 取色：色块按钮 + 页级单一 sheet（B22 v6 结构原样，内容多了两根条）

/// 系统 color well 外观的色块按钮（纯按钮，sheet 由页级 .sheet(item:) 统一持有——
/// 之前 11 行各挂一个 .sheet 导致 presentation 仲裁打架：一次点击双 picker 实例 +
/// 下滑退不出去，B22 v6）。
struct ThemeColorWell: View {
    let value: ThemeColorValue
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(value.color)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 32, height: 32)
                )
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }
}

/// 页级取色目标：哪个色槽正在选色（驱动单一 .sheet(item:)）。
/// 持「初值 + 活值读取 + 写回闭包」而不是 keyPath（M1）——三格字色那两行是 optional token，要和非 optional 的表面 / 功能色共用同一个 sheet。
/// `read` 给 sheet 里的两根条读活值（网格选完色，条要跟过去）。`id` 用行的 key，不用标题：颜色页有两行都叫「文字」。
struct ColorPickingSlot: Identifiable {
    let id: String
    let label: String
    let initial: ThemeColorValue
    let read: () -> ThemeColorValue
    let apply: (Color) -> Void
}

/// 取色 sheet（D2 加不换，粟粟 09-16 三次裁决的最终版）：**系统取色器原样嵌在下面**，网格 / 光谱 / 滑块 / 不透明度都还在；
/// 上面加饱和度 / 明度两根渐变轨道。两边同步：网格选色 → 两根条跟过去；拖条 → 取色器的选色跟过去（`ColorPickerSheet` 的回声守卫吃掉自己推进去的色）。
struct ColorPickSheet: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.dismiss) private var dismiss
    let slot: ColorPickingSlot

    private var manager: ThemeManager { themeManager ?? ThemeManager.shared }

    var body: some View {
        let _ = manager.themeChangeID
        let current = slot.read()

        // 用 NavigationStack 包一层：嵌进来的 UIKit 取色器会让裸 VStack 铺到屏幕顶边压住状态栏，
        // 导航栏接管安全区，标题和「完成」也有了标准位置。
        NavigationStack {
            VStack(spacing: 0) {
                // 上面紧一点：系统取色器自己有 ~640pt 高，sheet 里多占一行它底下的常用色就被裁
                HStack(alignment: .center, spacing: 14) {
                    // 大圆角色块实时显示当前色（粟粟 09-16：「sheet 不要随时变，弄一个大圆角方块随时变」）
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(uiColor: .secondarySystemBackground))   // 半透明 token 露出灰底，别看成白
                            .overlay(RoundedRectangle(cornerRadius: 18).fill(current.color))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                            .frame(width: 72, height: 72)
                        Text(current.hexString)
                            .font(.system(size: Theme.F.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    ColorFineTunePanel(value: current) { slot.apply($0.color) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

                Divider()

                ColorPickerSheet(initial: slot.initial, current: current, onPick: slot.apply)
            }
            // sheet 底色固定用系统色，不跟主题 token 走——不然编辑「主背景」时整张 sheet 跟着变色
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(slot.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(.accentColor)
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct ColorPickerSheet: UIViewControllerRepresentable {
    let initial: ThemeColorValue
    /// 活值：上面两根条改了要推给取色器，让它的预览色块 / 滑块跟上
    let current: ThemeColorValue
    let onPick: (Color) -> Void

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let vc = UIColorPickerViewController()
        vc.selectedColor = initial.platformColor
        vc.supportsAlpha = true
        vc.delegate = context.coordinator
        return vc
    }

    /// 只在**外面**（两根条 / ↺）把色改到和取色器不一样时才程序化改 selectedColor，并记下来让守卫吃掉它推回来的回声。
    /// 取色器自己选的色走 didSelect → onPick → current 变 → 这里比出来相等，不会再写回去（B22 原则：不喂回声）。
    func updateUIViewController(_ vc: UIColorPickerViewController, context: Context) {
        let shown = ThemeColorValue(color: Color(uiColor: vc.selectedColor))
        guard !Coordinator.close(shown, current) else { return }
        context.coordinator.suppress = current
        vc.selectedColor = current.platformColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(initial: initial, onPick: onPick) }

    /// B22 守卫：本次取色会话内，等于初始色的 didSelect 一律吞掉——picker 在
    /// sheet 收尾/实例销毁时会把打开时刻的旧色伪装成选色事件推回（探针实录，
    /// docs/research-B22-背景变白.md），从值上与"用户精确选回原色"不可区分。
    /// 代价：同一次打开里精确选回初始色被忽略（视觉本就无变化，重开取色器即生效）。
    /// 09-16 加一层：程序化推进去的色（`suppress`）推回来也吞掉，否则两根条和取色器会互相喂。
    /// 比较用 RGB 各分量 ≤2/255 + alpha 容差（值经 Color↔UIColor round trip，raw Double 会漂）。
    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let initial: ThemeColorValue
        let onPick: (Color) -> Void
        var suppress: ThemeColorValue?

        init(initial: ThemeColorValue, onPick: @escaping (Color) -> Void) {
            self.initial = initial
            self.onPick = onPick
        }

        static func close(_ a: ThemeColorValue, _ b: ThemeColorValue) -> Bool {
            abs(a.red - b.red) <= 2.0 / 255 && abs(a.green - b.green) <= 2.0 / 255
                && abs(a.blue - b.blue) <= 2.0 / 255 && abs(a.alpha - b.alpha) < 0.004
        }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            let picked = ThemeColorValue(color: Color(uiColor: color))
            if Self.close(picked, initial) {
                return
            }
            if let suppress, Self.close(picked, suppress) {
                return
            }
            onPick(Color(uiColor: color))
        }
    }
}
#endif
