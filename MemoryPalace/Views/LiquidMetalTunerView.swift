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
