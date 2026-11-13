import SwiftUI

/// 人页「设定」/ 「我」里还没按人存的那几行：行尾灰字「目前所有人共用」，点行照常进老页（plan-atrium P2）。
/// P3 每把一项改成按人存，就把那一行的 badge 去掉
struct SharedByAllBadge: View {
    var text = "目前所有人共用"

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: Theme.F.caption))
        }
        .foregroundColor(Theme.textMuted)
        .fixedSize()
    }
}
