import UserNotifications

/// APNs 到达时 iOS 系统 spawn 这个进程，30 秒内必须 contentHandler 回去。
/// 我们的工作：按 chat_id 反查楼层 → 改 title + 把头像作为 attachment（缩略图）挂上去。
///
/// 前提：hub 端 APNs payload 带 `mutable-content: 1`（否则 iOS 根本不叫醒 NSE）。
///
/// 注：本来想走 Communication Notifications（INSendMessageIntent + content.updating(from:)）
/// 让锁屏显示电报式 sender 圆头像，但该 API 需要 com.apple.developer.usernotifications.communication
/// entitlement，Apple 把它从 Xcode + Capability 列表移除（受限能力，需 Apple 人工审批）。
/// 改走 UNNotificationAttachment 路径：折叠时右上角缩略图、展开时大图——不依赖任何受限能力。
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        self.bestAttempt = mutable

        guard let chatId = mutable.userInfo["chat_id"] as? String,
              let lookup = SharedIdentityStore.lookup(chatId: chatId) else {
            // 陈年 chat / App Group 没就绪 → fallback：直接放行 hub 默认 title
            contentHandler(mutable); return
        }

        mutable.title = lookup.assistantName

        if let avatarData = lookup.avatarData,
           let attachment = makeAvatarAttachment(data: avatarData, chatId: chatId) {
            mutable.attachments = [attachment]
        }

        contentHandler(mutable)
    }

    /// 把头像 JPEG 数据落到 NSE 临时目录 + 包成 UNNotificationAttachment。
    /// iOS 通过验证后会把文件 move 到自己 attachment data store，NSE 临时区会被清理。
    private func makeAvatarAttachment(data: Data, chatId: String) -> UNNotificationAttachment? {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("avatar-\(chatId.prefix(8)).jpg")
        try? FileManager.default.removeItem(at: fileURL)
        do {
            try data.write(to: fileURL, options: .atomic)
            let options: [String: Any] = [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
            return try UNNotificationAttachment(identifier: "avatar", url: fileURL, options: options)
        } catch {
            return nil
        }
    }

    /// 系统 30s 临到 → 兜底把当前最好版本回去
    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let best = bestAttempt {
            handler(best)
        }
    }
}
