import SwiftUI

/// 设置页只露一个开关（粟粟 08-25：用户不需要调参数，浪费版面）。
struct LiquidMetalRingToggle: View {
    let fontSize: CGFloat
    @AppStorage(LiquidMetalTuning.enabledKey) private var enabled = true

    var body: some View {
        Toggle("输入框彩虹描边", isOn: $enabled)
            .font(.system(size: fontSize))
            .tint(Theme.branchIndicator)
        if enabled {
            LiquidMetalRingPreview()
        }
    }
}

/// 奶白 / 深色两块底上的活预览
struct LiquidMetalRingPreview: View {
    var body: some View {
        HStack(spacing: 10) {
            pill(dark: false)
            pill(dark: true)
        }
        .frame(height: 60)
    }

    private func pill(dark: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(dark ? Color(white: 0.07) : Color(red: 1.0, green: 0.988, blue: 0.9725))
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(dark ? Color(white: 0.16) : Color.white)
                LiquidMetalRing(cornerRadius: 20, forceDark: dark)
            }
            .frame(height: 40)
            .padding(.horizontal, 12)
        }
    }
}

/// 调参仪表盘——预设 + 滑块 + 实时预览（奶白/深色两块底）。08-25 定稿后从设置页摘下来，没挂在任何地方；
/// 要再调参把它挂回 AppearanceSettingsTab 即可（默认值在 LiquidMetalTuning.defaults）。
struct LiquidMetalTunerView: View {
    let fontSize: CGFloat
    @AppStorage(LiquidMetalTuning.enabledKey) private var enabled = true
    @AppStorage(LiquidMetalTuning.presetKey) private var presetRaw = "auto"
    @AppStorage(LiquidMetalTuning.lineWidthKey) private var lineWidth = 0.8
    @AppStorage(LiquidMetalTuning.featherKey) private var feather = 0.5
    @AppStorage(LiquidMetalTuning.blurKey) private var blur = 1.5
    @AppStorage(LiquidMetalTuning.scaleKey) private var scale = 0.7
    @AppStorage(LiquidMetalTuning.complexityKey) private var complexity = 0.45
    @AppStorage(LiquidMetalTuning.speedKey) private var speed = 1.0
    @AppStorage(LiquidMetalTuning.haloKey) private var halo = true
    @AppStorage(LiquidMetalTuning.haloStrengthKey) private var haloStrength = 0.65
    @AppStorage(LiquidMetalTuning.haloLapKey) private var haloLap = 7.0

    var body: some View {
        Toggle("彩虹描边", isOn: $enabled)
            .font(.system(size: fontSize))
            .tint(Theme.branchIndicator)
        if enabled {
            preview
            Picker("", selection: $presetRaw) {
                ForEach(LiquidMetalTuning.presetOptions, id: \.raw) { Text($0.name).tag($0.raw) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.textSecondary)
            row("线宽", $lineWidth, 0.8...5, 0.1) { String(format: "%.1fpt", $0) }
            row("外沿羽化", $feather, 0...6, 0.5) { String(format: "%.1fpt", $0) }
            row("羽化模糊", $blur, 0...1.5, 0.1) { String(format: "×%.1f", $0) }
            row("密度", $scale, 0.3...2.5, 0.1) { String(format: "%.1f", $0) }
            row("复杂度", $complexity, 0...1, 0.05) { String(format: "%.2f", $0) }
            row("流速", $speed, 0.2...3, 0.1) { String(format: "×%.1f", $0) }
            Toggle("高光 halo", isOn: $halo)
                .font(.system(size: fontSize))
                .tint(Theme.branchIndicator)
            if halo {
                row("高光强度", $haloStrength, 0...1, 0.05) { String(format: "%.2f", $0) }
                row("绕一圈秒数", $haloLap, 2...30, 1) { String(format: "%.0fs", $0) }
            }
            Button("恢复默认") { LiquidMetalTuning.reset() }
                .font(.system(size: fontSize))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var preview: some View { LiquidMetalRingPreview() }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, fmt: @escaping (Double) -> String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: fontSize)).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: step).tint(Theme.branchIndicator)
            Text(fmt(value.wrappedValue)).font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundColor(Theme.textMuted).frame(width: 52, alignment: .trailing)
        }
    }
}
