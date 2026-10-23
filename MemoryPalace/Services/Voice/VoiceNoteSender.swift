import Foundation
import SwiftData
import Observation

/// 她发语音条的发送前半段（plan-voice-note M4）：临时录音存进文件库、转写、切走了就存进原对话的草稿附件。
/// 真正「发」在 ChatInputBar.sendVoiceNote，走打字发送同一条 sendMessage
enum VoiceNoteSender {
    /// 临时录音 → 文件库 `attachments/{对话目录}/voice-<时间戳>.m4a`，返回相对路径（= storedRef）。
    /// 临时文件无论成败都删掉（失败 = 这条丢弃，调用方提示）
    static func persist(tempFileURL: URL, conversationId: String, conversationTitle: String?,
                        profileId: String, now: Date = Date()) throws -> String {
        defer { try? FileManager.default.removeItem(at: tempFileURL) }
        let data = try Data(contentsOf: tempFileURL)
        return try AttachmentStore.save(
            fileName: "voice-\(fileStampFormatter.string(from: now)).m4a", data: data,
            conversationId: conversationId, conversationTitle: conversationTitle, profileId: profileId)
    }

    /// 文件库里的语音 → 转写（10 秒超时 / 失败 = nil，照发「没转出文字」）
    static func transcribe(path: String, profileId: String) async -> String? {
        guard let url = FileLibraryStore.absoluteURL(path, profileId: profileId) else { return nil }
        if #available(macOS 26.0, *) {
            return await VoiceNoteTranscriber.transcribe(fileURL: url)
        }
        return nil
    }

    /// 草稿附件（PendingChatAttachment 数组 JSON）末尾追加一条；旧数据解不开就只留这条，不丢新语音
    static func appendingToDraft(_ data: Data?, _ attachment: PendingChatAttachment) -> Data? {
        var atts = data.flatMap { try? JSONDecoder().decode([PendingChatAttachment].self, from: $0) } ?? []
        atts.append(attachment)
        return try? JSONEncoder().encode(atts)
    }

    @MainActor
    static func conversation(id: String, context: ModelContext) -> Conversation? {
        var d = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// 语音条转写的忙状态（sol P1-2）：挂在稳定单例上，不跟输入条走——输入条被撤掉重挂（+ 面板 / 多选 / 搜索）
/// 不丢、不被默认值覆盖。一次只转一条（转写期间不能再录），任务 id 管开始 / 完成，迟到的完成不清掉别人的
@MainActor
@Observable
final class VoiceNoteTranscribing {
    static let shared = VoiceNoteTranscribing()

    /// 正在转写那条语音开录时的对话 id；nil = 没在转
    private(set) var conversationId: String?
    @ObservationIgnored private var jobId: UUID?

    var isBusy: Bool { conversationId != nil }

    /// 开始一条；已有一条在转 = nil（不并发）
    func begin(conversationId: String) -> UUID? {
        guard jobId == nil else { return nil }
        let id = UUID()
        jobId = id
        self.conversationId = conversationId
        return id
    }

    func finish(_ id: UUID) {
        guard jobId == id else { return }
        jobId = nil
        conversationId = nil
    }
}
