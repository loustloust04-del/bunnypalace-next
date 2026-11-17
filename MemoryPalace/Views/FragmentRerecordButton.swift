import MemoryCore
import SwiftUI

// MARK: - 对话 ⋯「重新记这个窗口」（C2：把这个窗口从起点到现在用现行写法记一遍，`FragmentRerecord`）

/// 只在总开关和碎片开关都开着、这个窗口参与记忆、用的是整段写法（不是本机模型 / 老写法）时出现。
/// 判断只读 UserDefaults 和已在内存里的对话，不读盘（菜单内容会被提前算）
struct RerecordFragmentsButton: View {
    let conversation: Conversation
    let viewModel: ConversationViewModel
    @AppStorage("mem_master") private var memMaster = true
    @AppStorage("mem_content_facts") private var memFacts = true
    @AppStorage(FragmentModelRoute.key) private var c2Model = ""

    var body: some View {
        if memMaster, memFacts, conversation.memoryEnabled,
           FragmentWatch.usesWhole(local: FragmentModelRoute.localModelId(choice: c2Model) != nil) {
            let running = FragmentRerecordStatus.shared.running[conversation.id]
            Button {
                Self.ask(conversation, viewModel: viewModel)
            } label: {
                Label(Self.title(running: running), systemImage: "arrow.counterclockwise")
            }
            .disabled(running != nil)
        }
    }

    private static func title(running: (batch: Int, of: Int)?) -> String {
        running.map { "正在重新记 · 第 \($0.batch) / \($0.of) 批" } ?? "重新记这个窗口"
    }

    /// 对话菜单（`ConversationMenu`「记忆 ▸」）用：条件和按钮一样，不出 = nil；只读 UserDefaults 和内存里的对话
    static func availability(_ conversation: Conversation) -> (title: String, running: Bool)? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "mem_master") as? Bool ?? true,
              defaults.object(forKey: "mem_content_facts") as? Bool ?? true,
              conversation.memoryEnabled,
              FragmentWatch.usesWhole(local: FragmentModelRoute.localModelId(choice: defaults.string(forKey: FragmentModelRoute.key) ?? "") != nil)
        else { return nil }
        let running = FragmentRerecordStatus.shared.running[conversation.id]
        return (title(running: running), running != nil)
    }

    /// 先弹确认（`RerecordFragmentsConfirm` 挂在 ContentView 上），她点「开始」才跑
    static func ask(_ conversation: Conversation, viewModel: ConversationViewModel) {
        viewModel.transientNotice = TransientNotice("📝 正在数这个窗口有多少要读…")
        FragmentRerecordStatus.shared.ask(conversationId: conversation.id, profileId: conversation.profileId)
    }
}

/// 确认框的宿主（菜单收起后还在的那一层）：她点「开始」才跑，跑完用对话页的小提示说结果
struct RerecordFragmentsConfirm: ViewModifier {
    let viewModel: ConversationViewModel

    func body(content: Content) -> some View {
        let status = FragmentRerecordStatus.shared
        content.alert("重新记这个窗口", isPresented: Binding(get: { status.prompt != nil }, set: { if !$0 { status.prompt = nil } }),
                      presenting: status.prompt) { prompt in
            if prompt.canRun {
                Button("取消", role: .cancel) { }
                Button("开始") {
                    viewModel.transientNotice = TransientNotice("📝 开始重新记，进度在对话 ⋯ 和记忆日志里")
                    status.start(prompt) { [weak viewModel] text in viewModel?.transientNotice = TransientNotice(text) }
                }
            } else {
                Button("好", role: .cancel) { }
            }
        } message: { prompt in
            Text(prompt.text)
        }
    }
}
