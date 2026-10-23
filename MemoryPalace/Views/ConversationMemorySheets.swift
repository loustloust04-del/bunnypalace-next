import SwiftUI

/// 对话 ⋯ 菜单打开的记忆弹层是哪个对话的哪一样（点菜单那一刻记下，弹层开着时切对话也不串）
struct ConversationMemorySheetTarget: Identifiable, Equatable {
    enum Kind: String { case windowSummary, contextSummary }
    let kind: Kind
    let conversationId: String
    let profileId: String
    let title: String
    var id: String { "\(kind.rawValue)-\(conversationId)" }
}

/// 对话 ⋯ 菜单「窗口总结」「上下文摘要」的弹层宿主（plan-memory-app-three-views §5 / §5b）。菜单项一直显示，内容在弹层里后台读。
/// 单独一个 ViewModifier：ContentView.body 链太长，再往上挂修饰符会让编译器类型检查超时（同 CardLibraryReturnHooks）
struct ConversationMemorySheets: ViewModifier {
    @Binding var target: ConversationMemorySheetTarget?

    func body(content: Content) -> some View {
        content
            .sheet(item: $target) { t in
                switch t.kind {
                case .windowSummary:
                    // 不带「去这个窗口」：人已经在这个窗口里了
                    WindowSummarySheet(conversationId: t.conversationId, profileId: t.profileId, fallbackTitle: t.title)
                case .contextSummary:
                    ContextSummarySheet(conversationId: t.conversationId, profileId: t.profileId, fallbackTitle: t.title)
                }
            }
    }
}
