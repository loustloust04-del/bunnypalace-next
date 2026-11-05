import Foundation
import SwiftData

/// 只把输入框相对上次同步的变化写回；取消发送恢复到模型的草稿不属于旧输入框。
struct InputBarDraftPersistence {
    private var text = ""
    private var attachments: [PendingChatAttachment] = []
    private var quotePreview: String?
    private var quoteReplyTo: String?

    mutating func load(text: String, attachments: [PendingChatAttachment],
                       quotePreview: String?, quoteReplyTo: String?) {
        self.text = text
        self.attachments = attachments
        self.quotePreview = quotePreview
        self.quoteReplyTo = quoteReplyTo
    }

    mutating func persistText(_ value: String, to conversation: Conversation, context: ModelContext) {
        guard !conversation.isTrashed, value != text else { return }
        updateText(value, in: conversation)
        try? context.save()
    }

    mutating func persistAttachments(_ value: [PendingChatAttachment], to conversation: Conversation,
                                     context: ModelContext) {
        guard !conversation.isTrashed, value != attachments else { return }
        updateAttachments(value, in: conversation)
        try? context.save()
    }

    mutating func flush(to conversation: Conversation, text: String, attachments: [PendingChatAttachment],
                        quotePreview: String?, quoteReplyTo: String?, context: ModelContext) {
        guard !conversation.isTrashed else { return }
        updateText(text, in: conversation)
        updateAttachments(attachments, in: conversation)
        if quotePreview != self.quotePreview {
            conversation.draftQuotePreview = quotePreview ?? ""
            self.quotePreview = quotePreview
        }
        if quoteReplyTo != self.quoteReplyTo {
            conversation.draftQuoteReplyTo = quoteReplyTo ?? ""
            self.quoteReplyTo = quoteReplyTo
        }
        try? context.save()
    }

    private mutating func updateText(_ value: String, in conversation: Conversation) {
        guard value != text else { return }
        let stored = conversation.draftText
        if stored == text || stored.isEmpty {
            conversation.draftText = value
        } else {
            // restoreToDraft 追加的尾巴留在模型里；实时键入和后台 liveText 只替换旧 UI 那一段。
            let recovered: String
            if !text.isEmpty, stored.hasPrefix(text + "\n") {
                recovered = String(stored.dropFirst(text.count + 1))
            } else {
                recovered = stored
            }
            conversation.draftText = value.isEmpty ? recovered : value + "\n" + recovered
        }
        text = value
    }

    private mutating func updateAttachments(_ value: [PendingChatAttachment], in conversation: Conversation) {
        guard value != attachments else { return }
        var stored = conversation.draftAttachmentsData.flatMap {
            try? JSONDecoder().decode([PendingChatAttachment].self, from: $0)
        } ?? []
        let previousIDs = Set(attachments.map(\.id))
        let currentIDs = Set(value.map(\.id))
        stored.removeAll { previousIDs.contains($0.id) && !currentIDs.contains($0.id) }
        for attachment in value {
            if let index = stored.firstIndex(where: { $0.id == attachment.id }) {
                stored[index] = attachment
            } else if !previousIDs.contains(attachment.id) {
                stored.append(attachment)
            }
        }
        conversation.draftAttachmentsData = stored.isEmpty ? nil : try? JSONEncoder().encode(stored)
        attachments = value
    }
}
