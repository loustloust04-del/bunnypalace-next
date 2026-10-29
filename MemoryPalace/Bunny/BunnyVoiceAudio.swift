import Foundation

// MARK: - [Bunny patch BP-005] 语音条把录音本身一起交给 hub
//
// 上游语音条只发本地转写的文字；兔兔的 hub 收到 send 帧里的 audio:[{b64,ext}] 会走
// Gemini 语气 + Praat 韵律 +（影子模式）兔兔耳朵，结果并进正文给 Caelum。
// 这里在语音存进文件库后读一份字节暂存（最多 6 条、单条 ≤ 8 MB），组 send 帧时按 storedRef 取出。
// 只影响 CC（hub）通道；直连 API 不经过 sendFrame。

enum BunnyVoiceAudio {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated(unsafe) private static var ears: [String: [BunnyEarEvent]] = [:]   // 本地耳朵结果（同 storedRef）
    static let maxBytes = 8 * 1024 * 1024

    /// 语音条落进文件库后调用（在后台线程读文件）
    static func remember(path: String, profileId: String) async {
        let (data, events): (Data?, [BunnyEarEvent]) = await Task.detached(priority: .userInitiated) {
            guard let url = FileLibraryStore.absoluteURL(path, profileId: profileId) else { return (nil, []) }
            return (try? Data(contentsOf: url), BunnyLocalEars.analyze(url: url))   // 本地工位：苹果声音分类
        }.value
        guard let data, data.count <= maxBytes else { return }
        lock.lock(); defer { lock.unlock() }
        cache[path] = data
        ears[path] = events
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > 6 { let old = order.removeFirst(); cache.removeValue(forKey: old); ears.removeValue(forKey: old) }
    }

    /// 组 send 帧时调用：本条消息里的语音条 → [{b64, ext}]；没有就 nil
    static func payload(for attachments: [PendingChatAttachment]) -> [[String: Any]]? {
        lock.lock(); defer { lock.unlock() }
        let items: [[String: Any]] = attachments.compactMap { att in
            guard att.kind == .voice, let ref = att.storedRef, let data = cache[ref] else { return nil }
            let ext = (ref as NSString).pathExtension.lowercased()
            var item: [String: Any] = ["b64": data.base64EncodedString(), "ext": ext.isEmpty ? "m4a" : ext]
            if let ev = ears[ref] {
                item["local_ears"] = ev.map { ["label": $0.label, "id": $0.id, "score": $0.score, "times": $0.times, "style": $0.style] as [String: Any] }
                item["local_ears_engine"] = "apple-sound-v1"
            }
            return item
        }
        return items.isEmpty ? nil : items
    }
}
