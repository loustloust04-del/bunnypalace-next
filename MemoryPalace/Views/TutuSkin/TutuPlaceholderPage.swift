#if PERSONAL_APPS
import SwiftUI

struct TutuPlaceholderPage: View {
    let page: Int
    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Theme.mainBg.ignoresSafeArea()
            Text("page\(page) · 兔兔")
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // page1 底部是输入条、顶上叠着聊天顶栏：齿轮放右上、让到顶栏下方；page0 / page2 放右下
        .overlay(alignment: page == 1 ? .topTrailing : .bottomTrailing) {
            if let onOpenSettings {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
                .padding(.trailing, 12)
                .padding(page == 1 ? .top : .bottom, page == 1 ? 104 : 24)
            }
        }
    }
}
#endif
