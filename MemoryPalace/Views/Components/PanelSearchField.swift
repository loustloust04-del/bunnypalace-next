import SwiftUI

/// 右栏面板里就地过滤用的搜索框（样式同文件库面板的搜索框）
struct PanelSearchField: View {
    let prompt: String
    @Binding var text: String
    /// 外面要收键盘时传（iOS 记忆页：切格 / 跳过来时收起）
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted.opacity(0.65))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .modifier(OptionalFocus(focus: focus))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted.opacity(0.65))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.mainBg.opacity(0.72))
        )
    }
}

private struct OptionalFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus)
        } else {
            content
        }
    }
}

/// 面板搜索词为空 / 只剩空白时不过滤
extension String {
    var panelSearchKeyword: String? {
        let kw = trimmingCharacters(in: .whitespacesAndNewlines)
        return kw.isEmpty ? nil : kw
    }
}

/// 有搜索词但一条都没命中时的空态
struct PanelNoMatchView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundColor(Theme.textMuted.opacity(0.4))
            Text("没有匹配")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
