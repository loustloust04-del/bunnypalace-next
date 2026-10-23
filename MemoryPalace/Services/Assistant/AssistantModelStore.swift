import Foundation
import CryptoKit
import Observation

// MARK: - 小芽 v2 · P4 本地大脑的模型管理（plan-小芽-v2 §6.2 v1.1，astra B7）
// 清单钉死 revision + 每个文件的字节数（权重 / 分词器另核 sha256）；两个镜像拿到的一定是同一版。
// 先下到 <id>.partial/，全部核对通过才整体换名成 <id>/；Range 续传，200 / 206 / 416 分开处理；
// 默认只走 Wi-Fi；目录不进 iCloud 备份；1 GB 起步，不自动开下——粟粟点了才下。

struct AssistantLocalModel: Identifiable, Equatable {
    struct File: Equatable {
        var name: String
        var size: Int64
        var sha256: String?
    }

    var id: String
    var title: String
    var detail: String
    var repo: String
    var revision: String
    var files: [File]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static let light = AssistantLocalModel(
        id: "qwen3-1.7b-4bit", title: "轻巧款 · Qwen3 1.7B", detail: "快，偶尔犯迷糊",
        repo: "mlx-community/Qwen3-1.7B-4bit", revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
        files: sharedFiles(indexSize: 49731) + [
            File(name: "model.safetensors", size: 968_080_210, sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
        ])

    static let smart = AssistantLocalModel(
        id: "qwen3-4b-4bit", title: "聪明款 · Qwen3 4B", detail: "慢一些，更靠谱",
        repo: "mlx-community/Qwen3-4B-4bit", revision: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25",
        files: sharedFiles(indexSize: 63924) + [
            File(name: "model.safetensors", size: 2_263_022_529, sha256: "e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d"),
        ])

    static let catalog = [light, smart]

    private static func sharedFiles(indexSize: Int64) -> [File] {
        [
            File(name: "added_tokens.json", size: 707),
            File(name: "config.json", size: 937),
            File(name: "merges.txt", size: 1_671_853),
            File(name: "model.safetensors.index.json", size: indexSize),
            File(name: "special_tokens_map.json", size: 613),
            File(name: "tokenizer.json", size: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            File(name: "tokenizer_config.json", size: 9706),
            File(name: "vocab.json", size: 2_776_833),
        ]
    }
}

@Observable
@MainActor
final class AssistantModelStore {
    enum State: Equatable {
        case notInstalled
        case downloading(received: Int64, total: Int64)
        case paused(received: Int64, total: Int64)
        case installed
        case failed(String)
        /// 在用流量（或低数据模式），默认不下；她点「用流量下载」才下
        case waitingForWiFi(received: Int64, total: Int64)
    }

    static let shared = AssistantModelStore()

    nonisolated static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]

    private(set) var states: [String: State] = [:]

    @ObservationIgnored let root: URL
    @ObservationIgnored private let catalog: [AssistantLocalModel]
    @ObservationIgnored private let hosts: [String]
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeFetch: FileFetch?

    init(root: URL = AssistantModelStore.defaultRoot,
         catalog: [AssistantLocalModel] = AssistantLocalModel.catalog,
         hosts: [String] = AssistantModelStore.hosts,
         sessionConfiguration: URLSessionConfiguration = .default) {
        self.root = root
        self.catalog = catalog
        self.hosts = hosts
        self.sessionConfiguration = sessionConfiguration
        for model in catalog {
            states[model.id] = FileManager.default.fileExists(atPath: installedURL(model).path) ? .installed : .notInstalled
            if states[model.id] == .notInstalled, let received = partialBytes(model), received > 0 {
                states[model.id] = .paused(received: received, total: model.totalBytes)
            }
        }
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XiaoyaModels", isDirectory: true)
    }

    /// 装好了才返回目录（只看最终目录在不在：半截的 .partial 永远不算）。
    /// nonisolated：API 卡列表 / 路由在哪个线程都能问
    nonisolated static func installedDirectory(modelId: String) -> URL? {
        guard AssistantLocalModel.catalog.contains(where: { $0.id == modelId }) else { return nil }
        let url = defaultRoot.appendingPathComponent(modelId, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func state(_ model: AssistantLocalModel) -> State { states[model.id] ?? .notInstalled }

    func installedURL(_ model: AssistantLocalModel) -> URL { root.appendingPathComponent(model.id, isDirectory: true) }
    private func partialURL(_ model: AssistantLocalModel) -> URL { root.appendingPathComponent(model.id + ".partial", isDirectory: true) }

    private func partialBytes(_ model: AssistantLocalModel) -> Int64? {
        let dir = partialURL(model)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return model.files.reduce(Int64(0)) { sum, file in
            sum + ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.name).path)[.size] as? Int64) ?? 0)
        }
    }

    // MARK: 下载 / 暂停 / 删除

    func download(_ model: AssistantLocalModel, allowCellular: Bool = false) {
        guard downloadTasks[model.id] == nil, state(model) != .installed else { return }
        let received = partialBytes(model) ?? 0
        states[model.id] = .downloading(received: received, total: model.totalBytes)
        downloadTasks[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(model, allowCellular: allowCellular)
                self.states[model.id] = .installed
            } catch is CancellationError {
                let got = self.partialBytes(model) ?? 0
                self.states[model.id] = got > 0 ? .paused(received: got, total: model.totalBytes) : .notInstalled
            } catch AssistantModelError.expensiveNetwork {
                self.states[model.id] = .waitingForWiFi(received: self.partialBytes(model) ?? 0, total: model.totalBytes)
            } catch {
                self.states[model.id] = .failed(error.localizedDescription)
            }
            self.downloadTasks[model.id] = nil
        }
    }

    func pause(_ model: AssistantLocalModel) {
        activeFetch?.cancel()
        downloadTasks[model.id]?.cancel()
    }

    func delete(_ model: AssistantLocalModel) {
        pause(model)
        try? FileManager.default.removeItem(at: installedURL(model))
        try? FileManager.default.removeItem(at: partialURL(model))
        states[model.id] = .notInstalled
    }

    private func run(_ model: AssistantLocalModel, allowCellular: Bool) async throws {
        let partial = partialURL(model)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)

        let remaining = model.totalBytes - (partialBytes(model) ?? 0)
        if let free = Self.freeBytes(at: root), Double(free) < Double(remaining) * 1.2 {
            throw AssistantModelError.diskFull(needed: remaining)
        }

        for file in model.files {
            try Task.checkCancellation()
            let dest = partial.appendingPathComponent(file.name)
            try await fetchVerified(model, file, to: dest, allowCellular: allowCellular)
        }
        // 全部核对通过才整体换名：半截的 partial 永远不会被当成装好的
        let installed = installedURL(model)
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: partial, to: installed)
        Self.excludeFromBackup(installed)
    }

    /// 一个文件：先按大小判断要不要续传；两个镜像轮流试；下完核大小 + sha256，不对就删了报错
    private func fetchVerified(_ model: AssistantLocalModel, _ file: AssistantLocalModel.File, to dest: URL, allowCellular: Bool) async throws {
        if Self.size(of: dest) == file.size, try await Self.verify(dest, file) { return }
        if Self.size(of: dest) > file.size { try? FileManager.default.removeItem(at: dest) }

        var lastError: Error = AssistantModelError.badResponse(0)
        for host in hosts {
            let url = URL(string: "\(host)/\(model.repo)/resolve/\(model.revision)/\(file.name)")!
            do {
                let fetch = FileFetch(configuration: sessionConfiguration, allowCellular: allowCellular) { [weak self] delta in
                    Task { @MainActor in self?.addProgress(model, delta) }
                }
                activeFetch = fetch
                try await fetch.run(url: url, to: dest, expectedSize: file.size)
                activeFetch = nil
                guard try await Self.verify(dest, file) else {
                    try? FileManager.default.removeItem(at: dest)
                    throw AssistantModelError.checksumMismatch(file.name)
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch AssistantModelError.expensiveNetwork {
                throw AssistantModelError.expensiveNetwork
            } catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
            }
        }
        throw lastError
    }

    private func addProgress(_ model: AssistantLocalModel, _ delta: Int64) {
        if case .downloading(let received, let total) = states[model.id] {
            states[model.id] = .downloading(received: min(received + delta, total), total: total)
        }
    }

    // MARK: 帮手

    nonisolated static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    nonisolated static func verify(_ url: URL, _ file: AssistantLocalModel.File) async throws -> Bool {
        guard size(of: url) == file.size else { return false }
        guard let expected = file.sha256 else { return true }
        return try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected
        }.value
    }

    nonisolated static func freeBytes(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}

enum AssistantModelError: LocalizedError, Equatable {
    case badResponse(Int)
    case checksumMismatch(String)
    case diskFull(needed: Int64)
    case expensiveNetwork

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "下载失败（服务器返回 \(code)）"
        case .checksumMismatch(let name): "\(name) 校验没通过，已删掉，重试一次"
        case .diskFull(let needed): "空间不够，还需要大约 \(ByteCountFormatter.string(fromByteCount: needed * 12 / 10, countStyle: .file))"
        case .expensiveNetwork: "现在在用流量，默认只走 Wi-Fi"
        }
    }
}

// MARK: - 单文件下载：Range 续传，边下边写盘

final class FileFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let onBytes: @Sendable (Int64) -> Void
    private var session: URLSession?
    private var handle: FileHandle?
    private var offset: Int64 = 0
    private var expectedSize: Int64 = 0
    private var dest: URL?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private let lock = NSLock()

    init(configuration: URLSessionConfiguration, allowCellular: Bool, onBytes: @escaping @Sendable (Int64) -> Void) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.allowsExpensiveNetworkAccess = allowCellular
        config.allowsConstrainedNetworkAccess = allowCellular
        config.timeoutIntervalForRequest = 60
        self.configuration = config
        self.onBytes = onBytes
    }

    func run(url: URL, to dest: URL, expectedSize: Int64) async throws {
        self.dest = dest
        self.expectedSize = expectedSize
        offset = AssistantModelStore.size(of: dest)
        if !FileManager.default.fileExists(atPath: dest.path) {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
        }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); continuation = c; lock.unlock()
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        failure = CancellationError()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let dest else { return completionHandler(.cancel) }
        do {
            switch http.statusCode {
            case 206:
                // 核对服务器确实从我们要的位置接着给
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(offset)-") else { throw AssistantModelError.badResponse(206) }
                handle = try FileHandle(forWritingTo: dest)
                try handle?.seekToEnd()
            case 200:
                // 服务器没理 Range：从头写
                offset = 0
                try Data().write(to: dest)
                handle = try FileHandle(forWritingTo: dest)
            case 416:
                // 已经下满了：交给下一步核大小 / 校验
                failure = offset == expectedSize ? nil : AssistantModelError.badResponse(416)
                if offset != expectedSize { try? FileManager.default.removeItem(at: dest) }
                return completionHandler(.cancel)
            default:
                throw AssistantModelError.badResponse(http.statusCode)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            onBytes(Int64(data.count))
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        var result = failure
        if result == nil, let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { result = nil }
            else if (error as? URLError)?.networkUnavailableReason == .expensive
                        || (error as? URLError)?.networkUnavailableReason == .constrained {
                result = AssistantModelError.expensiveNetwork
            } else {
                result = error
            }
        }
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let result { c?.resume(throwing: result) } else { c?.resume() }
    }
}
