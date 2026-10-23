import CryptoKit
import Foundation
import LinkPresentation
import Network
import UniformTypeIdentifiers

/// 外链卡元数据（research-chat-cards §7.1 / §7.4）
struct LinkPreview: Codable, Equatable {
    var title: String?
    var host: String
    var imageFile: String?
    var iconFile: String?
    var fetchedAt: Date
    var failed: Bool
}

struct LinkPreviewFetchResult {
    var title: String?
    var imageData: Data?
    var iconData: Data?
}

@MainActor
protocol LinkMetadataFetching {
    func fetch(_ url: URL) async -> LinkPreviewFetchResult?
}

/// 同网址单飞、全局并发上限、落盘缓存、失败 1 天；本地模式 / 非公网不抓；迟到结果在本地模式下丢弃。
@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/link-previews", isDirectory: true),
        fetcher: SystemLinkMetadataFetcher(),
        isOffline: { LocalMode.isOn },
        now: Date.init,
        maxConcurrent: 3)

    static let failureTTL: TimeInterval = 86_400
    static let maxImageBytes = 3 * 1024 * 1024

    private let directory: URL
    private let fetcher: LinkMetadataFetching
    private let isOffline: () -> Bool
    private let now: () -> Date
    private let maxConcurrent: Int
    private var memory: [String: LinkPreview] = [:]
    private var inFlight: [String: Task<LinkPreview, Never>] = [:]
    private var running = 0
    /// 排队的抓取：后来的先抓（快速滑过时，屏幕上的是最后请求的那张）；没人要了的直接放走（TASK page1-卡片-05）
    private var waiters: [(key: String, resume: CheckedContinuation<Bool, Never>)] = []
    /// 每个网址还有几张卡在等结果
    private var interest: [String: Int] = [:]

    init(directory: URL, fetcher: LinkMetadataFetching, isOffline: @escaping () -> Bool,
         now: @escaping () -> Date, maxConcurrent: Int) {
        self.directory = directory
        self.fetcher = fetcher
        self.isOffline = isOffline
        self.now = now
        self.maxConcurrent = maxConcurrent
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 自动抓取只对公网目标：排除 localhost / .local / 私网回环链路本地 IP 字面量 / 带账号密码
    /// TASK page1-卡片-05：少见写法也拦——非点分 IPv4（127.1、整数、十六进制、八进制，系统解析和 inet_aton 一样宽）、
    /// IPv4 映射 IPv6、组播、不带点的单段主机名、.lan / .internal / .home.arpa 等内网后缀、末尾带点
    nonisolated static func isPublicTarget(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let v6 = IPv6Address(bare) {
            let b = [UInt8](v6.rawValue)
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {   // ::ffff:a.b.c.d
                return isPublicIPv4(Array(b[12..<16]))
            }
            return !(v6.isLoopback || v6.isLinkLocal || v6.isUniqueLocal || v6 == .any || v6.isMulticast)
        }
        if let v4 = looseIPv4(bare) { return isPublicIPv4(v4) }
        if !bare.contains(".") { return false }                                        // 单段主机名：内网
        let privateSuffixes = ["localhost", "local", "lan", "internal", "home.arpa", "localdomain", "intranet", "corp"]
        return !privateSuffixes.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    /// 按 inet_aton 的宽松规则解析（1–4 段，每段十进制 / 0x 十六进制 / 0 开头八进制）；不是 IPv4 写法 → nil
    nonisolated static func looseIPv4(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }),
              host.withCString({ inet_aton($0, &addr) }) != 0 else { return nil }
        let n = UInt32(bigEndian: addr.s_addr)
        return [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    }

    nonisolated private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        !(b[0] == 10 || b[0] == 127 || b[0] == 0 || (b[0] == 169 && b[1] == 254)
          || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
          || (b[0] == 100 && (64...127).contains(b[1])) || b[0] >= 224)
    }

    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func metaURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }
    func imageURL(_ file: String) -> URL { directory.appendingPathComponent(file) }

    private func simple(_ url: URL) -> LinkPreview {
        LinkPreview(title: nil, host: url.host ?? url.absoluteString, imageFile: nil, iconFile: nil, fetchedAt: now(), failed: true)
    }

    /// 已有且未过期的结果（不发请求）
    func cached(_ url: URL) -> LinkPreview? {
        let k = key(url)
        guard let preview = memory[k]
                ?? (try? Data(contentsOf: metaURL(k))).flatMap({ try? JSONDecoder().decode(LinkPreview.self, from: $0) }) else { return nil }
        memory[k] = preview
        if preview.failed, now().timeIntervalSince(preview.fetchedAt) > Self.failureTTL { return nil }
        return preview
    }

    /// 不用等网络就能给出的结果：有缓存给缓存；本地模式 / 非公网给简版；否则 nil（要抓，才显示骨架）（终审 I4）
    func immediate(_ url: URL) -> LinkPreview? {
        if let hit = cached(url) { return hit }
        if isOffline() || !Self.isPublicTarget(url) { return simple(url) }
        return nil
    }

    func preview(for url: URL) async -> LinkPreview {
        if let hit = cached(url) { return hit }
        guard !isOffline(), Self.isPublicTarget(url) else { return simple(url) }
        let k = key(url)
        interest[k, default: 0] += 1
        if let task = inFlight[k] { return await awaitResult(task, key: k) }
        let task = Task { () -> LinkPreview in
            guard await acquire(k) else { return simple(url) }          // 排队时卡片都滑走了：不抓、不记失败
            defer { release() }
            guard !isOffline() else { return simple(url) }
            let result = await fetcher.fetch(url)
            guard !isOffline() else { return simple(url) }              // 抓取中切到本地模式：迟到结果丢弃
            var preview = LinkPreview(title: result?.title, host: url.host ?? url.absoluteString,
                                      imageFile: nil, iconFile: nil, fetchedAt: now(), failed: result == nil)
            if let data = result?.imageData, data.count <= Self.maxImageBytes,
               (try? data.write(to: imageURL("\(k)-image"), options: .atomic)) != nil {
                preview.imageFile = "\(k)-image"
            }
            if let data = result?.iconData, data.count <= Self.maxImageBytes,
               (try? data.write(to: imageURL("\(k)-icon"), options: .atomic)) != nil {
                preview.iconFile = "\(k)-icon"
            }
            if let data = try? JSONEncoder().encode(preview) { try? data.write(to: metaURL(k), options: .atomic) }
            memory[k] = preview
            return preview
        }
        inFlight[k] = task
        let preview = await awaitResult(task, key: k)
        if inFlight[k] == task { inFlight[k] = nil }
        return preview
    }

    /// 等结果；调用方被取消（卡片离屏）就少一个「有人要」
    private func awaitResult(_ task: Task<LinkPreview, Never>, key k: String) async -> LinkPreview {
        await withTaskCancellationHandler {
            let preview = await task.value
            if !Task.isCancelled {                                       // 取消的那份已在 abandon 里减过
                interest[k, default: 1] -= 1
                if interest[k] ?? 0 <= 0 { interest[k] = nil }
            }
            return preview
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(k) }
        }
    }

    private func abandon(_ k: String) {
        guard let count = interest[k] else { return }
        interest[k] = count > 1 ? count - 1 : nil
        guard interest[k] == nil, let i = waiters.firstIndex(where: { $0.key == k }) else { return }
        waiters.remove(at: i).resume.resume(returning: false)
        inFlight[k] = nil
    }

    /// true = 轮到了去抓；false = 排队时没人要了
    private func acquire(_ k: String) async -> Bool {
        if running < maxConcurrent {
            running += 1
            return true
        }
        return await withCheckedContinuation { waiters.append((k, $0)) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeLast().resume.resume(returning: true)          // 后来的先抓
        }
    }
}

/// 系统 LinkPresentation（元数据 10 秒超时；图片各自另限 10 秒）
@MainActor
struct SystemLinkMetadataFetcher: LinkMetadataFetching {
    func fetch(_ url: URL) async -> LinkPreviewFetchResult? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let image = await Self.loadImageData(metadata.imageProvider)
        let icon = await Self.loadImageData(metadata.iconProvider)
        return LinkPreviewFetchResult(title: metadata.title, imageData: image, iconData: icon)
    }

    /// 图片加载与 10 秒计时赛跑，先到者结算（只结算一次）
    private static func loadImageData(_ provider: NSItemProvider?) async -> Data? {
        guard let provider else { return nil }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            _ = provider.loadDataRepresentation(for: .image) { data, _ in once.resume(data) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { once.resume(nil) }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

    func resume(_ value: Data?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
