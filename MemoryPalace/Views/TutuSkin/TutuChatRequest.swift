#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import CryptoKit

struct TutuChatRequest: Hashable {
    var message: TutuChatMessageSnapshot
    var path: ArraySlice<TutuChatMessageSnapshot>
    var width: CGFloat
    var scale: CGFloat
    var mode: String
    var streaming: Bool

    init(message: TutuChatMessageSnapshot, path: [TutuChatMessageSnapshot], width: CGFloat,
         scale: CGFloat, mode: String, streaming: Bool) {
        self.message = message
        if let index = path.firstIndex(where: { $0.id == message.id }) {
            self.path = path[...index]
        } else {
            self.path = path[...]
            self.path.append(message)
        }
        self.width = width; self.scale = scale; self.mode = mode; self.streaming = streaming
    }

    var cacheKey: String? {
        guard !streaming else { return nil }
        let prefix = path.map { "\($0.id.utf8.count):\($0.id)|\($0.text.utf8.count):\($0.text)|\($0.isUser)|\($0.isRich)|\($0.hasRecall)|\($0.hasDate)|\($0.dateLabel)|\($0.recallLabel)|\($0.nativeHeight)" }.joined(separator: ";")
        let value = "chat-v11-noto-serif-cormorant-500-r1|\(message.id)|\(message.text)|\(message.isUser)|\(message.isRich)|\(width)|\(scale)|\(mode)|\(message.nativeHeight)|\(prefix)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
#endif
