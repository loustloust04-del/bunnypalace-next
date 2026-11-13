import Foundation

public enum MemoryEvent: Sendable, Equatable {
    case memoryDidChange
    case fileLibraryDidChange
    /// WikiStore 写了影响注入的文件（INDEX / 不触发的词 / 页，内容真变了）或挪了东西：app 作废注入缓存；page 非 nil = 一页 md，再通知全文索引
    case wikiInjectionDidChange(page: URL?)
}

public final class MemoryEvents: @unchecked Sendable {
    public static let shared = MemoryEvents()
    private let lock = NSLock()
    private var streams: [UUID: AsyncStream<MemoryEvent>.Continuation] = [:]
    private var relay: (@Sendable (MemoryEvent) -> Void)?

    public init() {}

    public func stream() -> AsyncStream<MemoryEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.streams[id] = nil }
            }
            lock.withLock { streams[id] = continuation }
        }
    }

    /// The app relay runs on the emitting thread, like NotificationCenter.post.
    public func setRelay(_ relay: @escaping @Sendable (MemoryEvent) -> Void) {
        lock.withLock { self.relay = relay }
    }

    public func emit(_ event: MemoryEvent) {
        let (relay, streams) = lock.withLock { (self.relay, Array(self.streams.values)) }
        relay?(event)
        for stream in streams { stream.yield(event) }
    }
}
