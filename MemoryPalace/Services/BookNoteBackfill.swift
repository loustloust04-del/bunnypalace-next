import Foundation
import SwiftData

/// CR-1 T1：aiBubble 批注卡回填。
/// askXiaoke 写占位卡（「正在回答…」，messageId = user node id），本类在 assistant turn
/// 收口（.assistantTurnDidFinish）时把真实回答写回 notes.json。
/// 锚在 notes.json 里持久——杀 app / 隔天收口都能对上，无需 pending 状态。
enum BookNoteBackfill {

    /// 内容变化才写（更新语义：重新生成回答也跟进）；写后广播给开着的阅读器刷新。
    static func fill(nodeId: String, conversationId: String, context: ModelContext) {
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let assistant = (try? context.fetch(nodeDesc))?.first,
              let parentId = assistant.parentId,
              !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let userDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == parentId })
        guard let user = (try? context.fetch(userDesc))?.first,
              let bookRef = user.bookRef, !bookRef.isEmpty else { return }

        // bookRef 两段格式 `<safeName>#chapter<N>`（askXiaoke 写入）
        let parts = bookRef.split(separator: "#")
        guard parts.count >= 2, !parts[0].isEmpty else { return }
        let safeName = String(parts[0])

        var notes = BookStore.loadNotes(safeName: safeName, profileId: user.profileId)
        guard let idx = notes.firstIndex(where: { $0.kind == "aiBubble" && $0.messageId == user.id }),
              notes[idx].content != assistant.content else { return }

        notes[idx].content = assistant.content
        try? BookStore.saveNotes(notes, safeName: safeName, profileId: user.profileId)
        NotificationCenter.default.post(
            name: .bookNotesDidChange, object: nil,
            userInfo: ["safeName": safeName]
        )
    }
}
