import Foundation

/// 一个输入框的链接直读状态：草稿变了就对一遍链接，读好的发送时变附件（plan-link-direct-read 4.1 / 4.2）
@MainActor
final class LinkReadSession: ObservableObject {
    enum State: Equatable {
        case ask
        case loading
        case done(LinkRead.Result)
        case failed(String)

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    struct Item: Identifiable, Equatable {
        let url: URL
        var state: State
        var id: String { url.absoluteString }
    }

    static let sendWait: TimeInterval = 6

    @Published private(set) var items: [Item] = []
    /// 点过 × 的：这一条草稿里不再出现
    private var dismissed = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var syncTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var bypassWait = false
    private let reader: @MainActor (URL) async throws -> LinkRead.Result
    /// (链接, 是不是 CC, 楼层 id) → 读 / 问 / 不读
    private let decide: @MainActor (URL, Bool, String?) -> LinkRead.Decision

    init(reader: @escaping @MainActor (URL) async throws -> LinkRead.Result = { try await LinkRead.read($0) },
         decide: @escaping @MainActor (URL, Bool, String?) -> LinkRead.Decision = { LinkRead.decide($0, isCC: $1, profileId: $2) }) {
        self.reader = reader
        self.decide = decide
    }

    var hasLoading: Bool { items.contains { $0.state == .loading } }

    /// 草稿变化（防抖 400ms）
    func draftChanged(_ text: String, isCC: Bool, profileId: String?) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.sync(text, isCC: isCC, profileId: profileId)
        }
    }

    func sync(_ text: String, isCC: Bool, profileId: String?) {
        let urls = LinkRead.links(in: text)
        let keep = Set(urls.map(\.absoluteString))
        for item in items where !keep.contains(item.id) {
            tasks.removeValue(forKey: item.id)?.cancel()
        }
        var next: [Item] = []
        for url in urls where !dismissed.contains(url.absoluteString) {
            if let existing = items.first(where: { $0.id == url.absoluteString }) {
                next.append(existing)
                continue
            }
            switch decide(url, isCC, profileId) {
            case .skip: continue
            case .ask: next.append(Item(url: url, state: .ask))
            case .read: next.append(Item(url: url, state: .loading))
            }
        }
        items = next
        for item in items where item.state == .loading && tasks[item.id] == nil { start(item.url) }
    }

    /// 问 → 读；读不到 → 回到问（她去浏览器里登录完再点一次）
    func approve(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].state {
        case .ask:
            items[i].state = .loading
            start(items[i].url)
        case .failed:
            items[i].state = .ask
        default:
            break
        }
    }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        tasks.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
    }

    private func start(_ url: URL) {
        let id = url.absoluteString
        tasks[id] = Task { [weak self, reader] in
            let state: State
            do {
                state = .done(try await reader(url))
            } catch {
                state = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled, let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[i].state = state
            self.tasks[id] = nil
        }
    }

    /// 发送时还有在读的：先拦下，等读完或 6 秒到再 `resend`；等的时候再点发送 = 不等了
    func holdSend(then resend: @escaping @MainActor () -> Void) -> Bool {
        if bypassWait { return false }
        if let waitTask {
            waitTask.cancel()
            self.waitTask = nil
            return false
        }
        guard hasLoading else { return false }
        waitTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.sendWait)
            while let self, self.hasLoading, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.waitTask = nil
            self.bypassWait = true
            resend()
            self.bypassWait = false
        }
        return true
    }

    /// 读好了、链接还在正文里的 → 附件
    func attachments(for text: String) -> [PendingChatAttachment] {
        let present = Set(LinkRead.links(in: text).map(\.absoluteString))
        return items.flatMap { item -> [PendingChatAttachment] in
            guard present.contains(item.id), case .done(let result) = item.state else { return [] }
            return LinkRead.attachments(for: result)
        }
    }

    /// 发出去了：清空，下一条重新开始
    func reset() {
        syncTask?.cancel()
        waitTask?.cancel()
        waitTask = nil
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        items = []
        dismissed = []
    }
}
