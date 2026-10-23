#if PERSONAL_APPS
#if DEBUG
import SwiftUI
import SwiftData

/// 有声书 tool 外壳。简单状态机：列表态 ↔ 播放态。
/// 不引 NavigationStack（右栏空间小，避免 chrome）。
struct AudiobookPanelView: View {
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    @Environment(\.modelContext) private var modelContext
    let profileId: String

    /// nil = 列表态，非 nil = 播放态
    @State private var selectedBookId: UUID?

    var body: some View {
        Group {
            if let bookId = selectedBookId {
                AudiobookPlayerView(bookId: bookId) { selectedBookId = nil }
            } else {
                AudiobookListView(profileId: profileId) { selectedBookId = $0 }
            }
        }
        // 学 BrowserView 的内嵌卡片观感：22pt continuous 圆角 + 上下 10pt 留白露 sidebarBg
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 10)
        .padding(.bottom, 10)
        .onAppear { consumeDesktopTarget() }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
    }
    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "audiobook" else { return }
        desktopNavigator?.pendingTarget = nil
        guard let id = UUID(uuidString: target.id) else { return }
        let pid = profileId
        var query = FetchDescriptor<AudiobookItem>(predicate: #Predicate { $0.id == id && $0.profileId == pid })
        query.fetchLimit = 1
        if (try? modelContext.fetch(query).first) != nil { selectedBookId = id }
    }
}
#endif
#endif
