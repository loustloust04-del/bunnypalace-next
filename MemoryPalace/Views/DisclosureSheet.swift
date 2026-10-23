import SwiftUI

/// 折叠行弹出面板的壳（原 ThinkingSheet 的 chrome 抽出来）：把手 + 左上关闭圆钮 + 居中标题 + 正文滚动。
/// 思考过程 / 想起来了 / 工具调用 三家共用；标题走英文微标签例外（粟粟拍）。
struct DisclosureSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 44)
                HStack {
                    #if os(iOS)
                    GlassBackButton(systemImage: "xmark") { dismiss() }
                    #else
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.accent.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    #endif
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                content()
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
        }
        .background(Theme.mainBg)
        #if os(iOS)
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 480, minHeight: 420)
        #endif
        // S1-5：mac 的 sheet 不自带 Esc。改这一处同时盖住 ThinkingSheet / RecallCardView /
        // MessageSegmentsView 那两个（都套这个壳）
        .macEscapeToDismiss { dismiss() }
    }
}
