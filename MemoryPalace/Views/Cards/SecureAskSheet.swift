import SwiftUI
import SwiftStreamingMarkdown

/// 加密卡的输入单（docs/plan-secure-ask-sheet.md）：只管版式；字段由 AskCardView 给（复用表单行控件和它的草稿 @State），
/// 保存 / 取消也回 AskCardView（存钥匙串、失败回滚、关单清草稿都在那边）
struct SecureAskSheet<Fields: View>: View {
    let question: String
    let site: String?
    @Binding var thisConversationOnly: Bool
    let saveFailed: Bool
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let fields: () -> Fields
    #if os(iOS)
    /// 先半屏，点进输入框（键盘出来）再升全屏（粟粟 10-11）
    @State private var detent: PresentationDetent = .medium
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white)
                        .shadow(color: Theme.cardShadow, radius: Theme.cardShadowRadius, y: 1))
                    .accessibilityHidden(true)
                Text(question)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                Text("加密保存在这台设备，AI 看不到")
                    .font(.footnote)
                    .foregroundStyle(CodeBlockStyle.label)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
                if let site {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").foregroundStyle(CodeBlockStyle.label)
                        Text(site).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(groupShape.fill(Color.white))
                    .overlay(groupShape.strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
                    .padding(.bottom, 10)
                }
                VStack(alignment: .leading, spacing: 0) { fields() }
                    .padding(.horizontal, 14)
                    .background(groupShape.fill(Color.white))
                    .overlay(groupShape.strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
                Toggle("只在这个对话里用", isOn: $thisConversationOnly)
                    .toggleStyle(.switch)
                    .tint(Theme.branchIndicator)
                    .font(.subheadline)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 12)
                if saveFailed {
                    Text("没存进钥匙串，再试一次")
                        .font(.caption)
                        .foregroundStyle(CodeBlockStyle.label)
                        .padding(.bottom, 8)
                }
                Button(action: onSave) {
                    Text("保存")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.branchIndicator.opacity(canSave ? 1 : 0.45)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                Button(action: onCancel) {
                    Text("取消")
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(CodeBlockStyle.body)
        .environment(\.colorScheme, .light)   // 底是固定米白（同卡片），字 / 控件跟着固定浅色
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in detent = .large }
        .presentationDragIndicator(.visible)
        .presentationBackground(CodeBlockStyle.body)
        #else
        .frame(width: 420)
        .frame(minHeight: 480)   // mac sheet 里 ScrollView 不给高会塌
        #endif
    }

    private var groupShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
}

/// 字段组里两项之间的虚线（同小样）
struct SecureAskDashedRule: View {
    var body: some View {
        DashLine()
            .stroke(CodeBlockStyle.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct DashLine: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}
