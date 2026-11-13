import Foundation
import MemoryCore
import os

/// 所有接口的状态都收在一个 actor 里：连接各跑各的任务，路由 / 索引 / 跑批都从这里过（不共享裸可变状态）。
actor MemorydService {
    /// 挂载脚本在副本根留的标记（没标记就拒绝启动：真楼层只读）
    static let mountMarkerName = ".memoryd-mount"

    struct Config: Sendable {
        var floor: URL
        var profileId: String
        /// 测试 / 夹具直接用拷出来的目录时置 true，跳过 `.memoryd-mount` 标记检查
        var allowUnmounted: Bool = false
        /// 接了模型（`--model` + 环境里的 key）才跑得了要模型的写手；nil = 只跑离线的
        var model: MemorydModel? = nil
        /// 给碎片打分的裁判（`--judge-model` + `MEMORYD_JUDGE_KEY`）
        var judge: MemorydModel? = nil
    }

    /// 请求里临时加的一版提示词：以这个写手的「现行」配方为底，只换 system（和 user，给了的话）
    struct TrialRecipe: Equatable, Sendable {
        var name: String
        var system: String
        var user: String?
    }

    /// 楼层快照（`exports/floor-snapshot-*.json`）的识别结果；`conversationSnapshot` 状态接口用
    struct SnapshotInfo: Sendable {
        var file: String
        var windows: Int
        var nodes: Int
        var exportedAt: Date?
        var schema: Int?
        /// 快照顶层写的导出楼层（旧快照没有 = nil）；与 `--profile-id` 不一致时状态里说一句
        var exportedProfileId: String?
        /// 快照里有没有 `--profile-id` 这个楼层的窗口（false = 导出时的 profileId 与启动参数不一致）
        var readable: Bool
    }

    enum BenchError: LocalizedError {
        case noSet(String)
        case badBody

        var errorDescription: String? {
            switch self {
            case .noSet(let id): return "没有这个题集：\(id)"
            case .badBody: return "请求体要 {\"setId\": \"…\"}"
            }
        }
    }

    let config: Config
    private let webRoot: URL?
    private let benchStore: MemoryBenchStore
    private var index: CatalogRecallIndexStore?
    /// 副本 `exports/` 里有楼层快照就是它（E2-6：只识别 + 状态，bench 接线在 E2-5b）
    let conversations: (any ConversationSource)?
    private let snapshotInfo: SnapshotInfo?
    private let log = Logger(subsystem: "com.susu.memoryd", category: "service")
    /// `HTTPServer.start()` 拿到实际端口后注入（`--port 0` 时事先不知道），Host / Origin 校验要用
    private let bound = BoundPort()
    /// 实验台：正在跑 / 这次启动以来跑过的（跑完的同时落盘在 `bench-runs/experiments/`）
    private var experiments: [String: MemorydExperiment] = [:]

    init(config: Config, webRoot: URL?) throws {
        self.config = config
        self.webRoot = webRoot
        // memoryd 对副本只写自己的 bench-runs/
        self.benchStore = MemoryBenchStore(root: config.floor.appendingPathComponent("bench-runs", isDirectory: true))
        guard config.allowUnmounted
                || FileManager.default.fileExists(atPath: config.floor.appendingPathComponent(Self.mountMarkerName).path) else {
            throw MemorydError.notMounted(config.floor.path)
        }
        let snapshot = Self.loadSnapshot(floor: config.floor, profileId: config.profileId)
        self.conversations = snapshot?.source
        self.snapshotInfo = snapshot?.info
    }

    /// `exports/` 里最新的 `floor-snapshot-*.json`（文件名带秒级 UTC 时间戳 + `Z`，字典序 = 时间序）。
    /// 只认严格时间戳名、普通文件、非符号链接、≤ 256 MB 的候选；不合格的记 log 跳过。
    /// 解不开记 log 当没有：坏快照不影响 wiki 那半边。最新那份坏了不回退上一份（导出只留 2 份，重导即可）。
    private static func loadSnapshot(floor: URL, profileId: String)
        -> (source: SnapshotConversationSource, info: SnapshotInfo)? {
        let dir = floor.appendingPathComponent(FloorSnapshotExportFolder.name, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let maxBytes = 256 * 1024 * 1024
        let files = names
            .filter(FloorSnapshotExportFolder.isSnapshotFileName)
            .compactMap { name -> (name: String, url: URL)? in
                let url = dir.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= maxBytes else {
                    Logger(subsystem: "com.susu.memoryd", category: "snapshot")
                        .error("跳过不合格快照 \(name, privacy: .public)")
                    return nil
                }
                return (name, url)
            }
            .sorted { $0.name < $1.name }
        guard let latest = files.last else { return nil }
        let url = latest.url
        let decoder = JSONDecoder()
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try decoder.decode(FloorSnapshot.self, from: data)
            let source = SnapshotConversationSource(floor: snapshot, profileId: profileId)
            let readable = try !source.windows(profileId: profileId, updatedSince: nil, includeTrashed: true).isEmpty
            return (source, SnapshotInfo(
                file: FloorSnapshotExportFolder.name + "/" + latest.name,
                windows: snapshot.windows.count,
                nodes: snapshot.windows.reduce(0) { $0 + $1.nodes.count },
                exportedAt: snapshot.exportedAt, schema: snapshot.schema,
                exportedProfileId: snapshot.profileId, readable: readable))
        } catch {
            Logger(subsystem: "com.susu.memoryd", category: "snapshot")
                .error("楼层快照读不了 \(latest.name, privacy: .public)：\(String(describing: error), privacy: .public)")
            return nil
        }
    }


    nonisolated func bind(port: UInt16) {
        bound.set(port)
    }

    // MARK: - 路由

    func respond(_ request: HTTPRequest) async -> HTTPResponse {
        if let refusal = guardOrigin(request) { return refusal }
        guard let path = RoutePath.normalized(request.target) else {
            return .error(400, "路径不合法")
        }
        let segments = RoutePath.segments(path)
        if segments.isEmpty {
            guard request.method == "GET" else { return .error(405, "只支持 GET") }
            return staticFile("index.html", type: "text/html; charset=utf-8")
        }
        switch segments[0] {
        case "app.js":
            guard request.method == "GET" else { return .error(405, "只支持 GET") }
            return staticFile("app.js", type: "application/javascript; charset=utf-8")
        case "api":
            do {
                return try await api(request, segments: Array(segments.dropFirst()))
            } catch {
                log.error("接口出错：\(String(describing: error), privacy: .public)")
                return .error(500, error.localizedDescription)
            }
        default:
            return .error(404, "没有这个路径")
        }
    }

    /// 只认本机回环来的请求：挡 DNS 重绑定（Host 是恶意域名）和跨站简单请求（Origin 不是本机页面 / 非 JSON POST）
    private func guardOrigin(_ request: HTTPRequest) -> HTTPResponse? {
        guard let port = bound.port else { return .error(500, "服务还没绑定端口") }
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        let host = (request.headers["host"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard hosts.contains(host) else { return .error(403, "Host 不是本机回环地址") }
        if let raw = request.headers["origin"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let origin = raw.lowercased()
            guard hosts.map({ "http://" + $0 }).contains(origin) else {
                return .error(403, "Origin 不是本机页面")
            }
        }
        if request.method == "POST" {
            let type = (request.headers["content-type"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            // application/json 的 POST 浏览器必须先预检（OPTIONS 我们回 405），跨站发不出来
            guard type.hasPrefix("application/json") else { return .error(415, "POST 要 application/json") }
        }
        return nil
    }

    private func staticFile(_ name: String, type: String) -> HTTPResponse {
        guard let webRoot,
              let data = try? Data(contentsOf: webRoot.appendingPathComponent(name)) else {
            return .error(404, "静态文件缺失")
        }
        return HTTPResponse(headers: ["Content-Type": type], body: data)
    }

    private func api(_ request: HTTPRequest, segments: [String]) async throws -> HTTPResponse {
        let method = request.method
        if segments == ["status"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return status()
        }
        if segments == ["c2", "score"] {
            guard method == "POST" else { return .error(405, "只支持 POST") }
            return try await scoreFragments(request)
        }
        if segments == ["c2", "agent"] {
            guard method == "POST" else { return .error(405, "只支持 POST") }
            return try await runOrganizeAgent(request)
        }
        if segments == ["c2", "write-agent"] {
            guard method == "POST" else { return .error(405, "只支持 POST") }
            return try await runWriteAgent(request)
        }
        if segments == ["c2", "results"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return reviewResults()
        }
        if segments.count == 3, segments[0] == "c2", segments[1] == "review" {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return reviewPage(segments[2])
        }
        if segments == ["c2", "review"] {
            if method == "GET" { return reviewPage(nil) }
            guard method == "POST" else { return .error(405, "只支持 GET / POST") }
            return try reviewMark(request)
        }
        if segments == ["c2", "merge"] {
            guard method == "POST" else { return .error(405, "只支持 POST") }
            return try await mergeFragments(request)
        }
        if segments == ["c2", "organize"] {
            guard method == "POST" else { return .error(405, "只支持 POST") }
            return try await organizeFragments(request)
        }
        if segments == ["conversations"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return try conversationList()
        }
        if segments == ["experiments"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return experimentList()
        }
        if segments == ["experiments", "run"] {
            guard method == "POST" else { return .error(405, "只支持 POST") }
            return try experimentStart(request)
        }
        if segments.count == 2, segments[0] == "experiments" {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return experimentDetail(segments[1])
        }
        if segments == ["bench", "sets"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return benchSets()
        }
        if segments.count == 3, segments[0] == "bench", segments[1] == "sets" {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return try benchSet(segments[2])
        }
        if segments == ["bench", "run"] {
            guard method == "POST" else { return .error(405, "只支持 POST") }
            return try await benchRun(request)
        }
        if segments == ["bench", "runs"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return benchRuns()
        }
        if segments.count == 3, segments[0] == "bench", segments[1] == "runs" {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return benchRunDetail(segments[2])
        }
        if segments == ["wiki", "index"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return wikiIndex()
        }
        if segments == ["wiki", "group"] {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            return wikiGroup("")
        }
        if segments.count >= 3, segments[0] == "wiki" {
            guard method == "GET" else { return .error(405, "只支持 GET") }
            let rest = segments.dropFirst(2).joined(separator: "/")
            switch segments[1] {
            case "group": return wikiGroup(rest)
            case "page": return wikiPage(rest)
            case "entry": return wikiEntry(rest)
            default: return .error(404, "没有这个接口")
            }
        }
        if segments == ["wiki", "page"] { return .error(404, "缺页路径") }
        if segments == ["wiki", "entry"] { return .error(404, "缺条目键") }
        return .error(404, "没有这个接口")
    }

    // MARK: - 状态

    /// `GET /api/status`：服务挂在哪层、有没有认出对话快照。
    /// 没快照 = 只能跑 wiki 题（recall / c2 写手仍「不可测」）；有快照但楼层对不上单独说一句
    private func status() -> HTTPResponse {
        var object: [String: Any] = [
            "floor": config.floor.path,
            "profileId": config.profileId,
        ]
        object["model"] = config.model?.modelId ?? NSNull()
        var notes: [String] = []
        if let snapshotInfo {
            var snapshot: [String: Any] = [
                "file": snapshotInfo.file,
                "windows": snapshotInfo.windows,
                "nodes": snapshotInfo.nodes,
                "schema": snapshotInfo.schema as Any,
            ]
            if let date = snapshotInfo.exportedAt {
                let ms = date.timeIntervalSince1970 * 1000
                if ms.isFinite, abs(ms) < 9.0e15 {
                    snapshot["exportedAt"] = Int64(ms.rounded())
                } else {
                    snapshot["exportedAt"] = NSNull()
                    notes.append("exportedAt 越界")
                }
            } else {
                snapshot["exportedAt"] = NSNull()
            }
            object["conversationSnapshot"] = snapshot
            if !snapshotInfo.readable {
                notes.append("快照里没有本楼层的窗口：--profile-id（\(config.profileId)）与导出时的不一致")
            }
            if let exported = snapshotInfo.exportedProfileId, exported != config.profileId {
                notes.append("快照顶层 profileId（\(exported)）与 --profile-id（\(config.profileId)）不一致")
            }
        } else {
            object["conversationSnapshot"] = NSNull()
            notes.append("无对话快照：bench 只能跑 wiki 题")
        }
        if !notes.isEmpty { object["note"] = notes.joined(separator: "；") }
        return .json(object)
    }

    // MARK: - 实验台（挑一个对话跑写入侧）

    private var experimentsDir: URL {
        config.floor.appendingPathComponent("bench-runs", isDirectory: true).appendingPathComponent("experiments", isDirectory: true)
    }

    private static let experimentEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let experimentDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// 快照里这层楼没进回收站的对话，新的在前；条数 = 主线上有正文的消息数（写手看到的那些）
    private func conversationList() throws -> HTTPResponse {
        guard let conversations else { return .error(404, "副本里没有楼层快照（exports/floor-snapshot-*.json）") }
        let windows = try conversations.windows(profileId: config.profileId, updatedSince: nil, includeTrashed: false)
            .sorted { $0.updateTime > $1.updateTime }
        let rows = try windows.map { window -> [String: Any] in
            [
                "id": window.id,
                "title": window.title,
                "messages": try MemorydExperimentRunner.messages(window: window, source: conversations).count,
                "updatedAt": Int64(window.updateTime.timeIntervalSince1970 * 1000),
                "memoryEnabled": window.memoryEnabled,
                "isCC": window.isCC,
            ]
        }
        return .json(["conversations": rows, "model": (config.model?.modelId as Any?) ?? NSNull()])
    }

    private func experimentStart(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let model = config.model else {
            return .error(400, "没接模型：环境里设 \(MemorydModel.keyVariable)，启动加 --model <模型 id>")
        }
        guard let conversations else { return .error(404, "副本里没有楼层快照") }
        guard let raw = try? Self.experimentDecoder.decode(MemorydExperiment.Options.self, from: request.body) else {
            return .error(400, "请求体要 {\"conversationId\": \"…\"}")
        }
        let options = MemorydExperimentRunner.normalized(raw)
        guard let window = try conversations.window(profileId: config.profileId, idOrPrefix: options.conversationId) else {
            return .error(404, "快照里没有这个对话")
        }
        if experiments.values.contains(where: { $0.status == "running" }) {
            return .error(409, "有一个实验还在跑，等它跑完")
        }
        let all = try MemorydExperimentRunner.messages(window: window, source: conversations)
        guard options.from < all.count else { return .error(400, "这个对话主线只有 \(all.count) 条") }
        let ran = min(options.limit, all.count - options.from)
        let start = MemorydExperiment(id: UUID().uuidString, at: Date(), status: "running", options: options,
                                      windowTitle: window.title, model: model.modelId, totalMessages: all.count, ranMessages: ran,
                                      progress: "排队")
        experiments[start.id] = start
        let floor = config.floor
        Task { [weak self] in
            let done = await MemorydExperimentRunner.run(start, all: all, model: model, floor: floor) { update in
                await self?.experimentUpdate(update)
            }
            await self?.experimentUpdate(done)
        }
        return .json(["id": start.id, "totalMessages": all.count, "ranMessages": ran])
    }

    private func experimentUpdate(_ experiment: MemorydExperiment) {
        experiments[experiment.id] = experiment
        guard experiment.status != "running" else { return }
        do {
            try FileManager.default.createDirectory(at: experimentsDir, withIntermediateDirectories: true)
            try Self.experimentEncoder.encode(experiment)
                .write(to: experimentsDir.appendingPathComponent(experiment.id + ".json"), options: .atomic)
        } catch {
            log.error("实验结果存不下：\(String(describing: error), privacy: .public)")
        }
    }

    private func storedExperiments() -> [MemorydExperiment] {
        let files = (try? FileManager.default.contentsOfDirectory(at: experimentsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? Self.experimentDecoder.decode(MemorydExperiment.self, from: $0) }
        }
    }

    private func experiment(_ id: String) -> MemorydExperiment? {
        experiments[id] ?? storedExperiments().first { $0.id == id }
    }

    private func experimentList() -> HTTPResponse {
        var all = Dictionary(storedExperiments().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, experiment) in experiments { all[id] = experiment }
        let rows = all.values.sorted { $0.at > $1.at }.map { e -> [String: Any] in
            [
                "id": e.id, "at": Int64(e.at.timeIntervalSince1970 * 1000), "status": e.status,
                "conversationId": e.options.conversationId, "windowTitle": e.windowTitle, "model": e.model,
                "ranMessages": e.ranMessages, "segments": e.segments.count,
                "cards": e.fragments.reduce(0) { $0 + $1.cards.count }, "progress": e.progress,
            ]
        }
        return .json(["experiments": rows])
    }

    private func experimentDetail(_ id: String) -> HTTPResponse {
        guard let found = experiment(id), let data = try? Self.experimentEncoder.encode(found) else {
            return .error(404, "没有这次实验：\(id)")
        }
        return .jsonRaw(data)
    }

    // MARK: - 给现有的 C2 卡打分（plan-c2-write-shape P0）

    /// 副本 `exports/fragments.json`（`store-to-floor-snapshot.py` 导的活着的 C2 卡）
    struct ExportedFragment: Decodable, Sendable {
        let i: Int
        let content: String
        let category: String
        let subject: String?
        let speaker: String?
        let conversationId: String?
        let sourceNodeId: String?
        let model: String?
        var day: String? = nil
    }

    struct FragmentScore: Codable, Sendable {
        var at: Date
        var judge: String
        var cards: Int
        var tally: FragmentJudge.Tally
        var byModel: [String: FragmentJudge.Tally]
        var judgments: [FragmentJudge.Judgment]
        var failedBatches: [String]
        var calls: Int
        var inputTokens: Int
        var outputTokens: Int
    }

    /// 一张卡的出处：它引用的那条消息连同主线上前两条
    private func sourceExcerpts(_ cards: [ExportedFragment], source: any ConversationSource,
                                names: MemoryExtractor.Names) throws -> [Int: String] {
        var paths: [String: [SessionSegmentWriter.Message]] = [:]
        var out: [Int: String] = [:]
        for card in cards {
            guard let cid = card.conversationId, let node = card.sourceNodeId else { continue }
            if paths[cid] == nil {
                paths[cid] = try source.window(profileId: config.profileId, idOrPrefix: cid).map {
                    try MemorydExperimentRunner.messages(window: $0, source: source)
                } ?? []
            }
            guard let path = paths[cid], let index = path.firstIndex(where: { $0.id == node }) else { continue }
            out[card.i] = path[max(0, index - 2)...index].map { m in
                let who = m.role == "user" ? names.user : names.char
                let text = m.content.count > 800 ? String(m.content.prefix(800)) + "…" : m.content
                return "\(who)：\(text)"
            }.joined(separator: "\n")
        }
        return out
    }

    private func scoreFragments(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let judge = config.judge else {
            return .error(400, "没接裁判：环境里设 \(MemorydModel.Variables.judge.key)，启动加 --judge-model <模型 id>")
        }
        guard let conversations else { return .error(404, "副本里没有楼层快照") }
        let file = config.floor.appendingPathComponent(FloorSnapshotExportFolder.name).appendingPathComponent("fragments.json")
        guard let data = try? Data(contentsOf: file),
              let cards = try? JSONDecoder().decode([ExportedFragment].self, from: data), !cards.isEmpty else {
            return .error(404, "副本里没有 exports/fragments.json（用 store-to-floor-snapshot.py 重新导一次）")
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let names = MemoryExtractor.Names(userName: body["userName"] as? String ?? "", assistantName: body["assistantName"] as? String ?? "")
        let limit = (body["limit"] as? Int).map { max(1, min($0, cards.count)) } ?? cards.count
        var chosen = Array(cards.prefix(limit))
        var excerpts = try sourceExcerpts(chosen, source: conversations, names: names)
        // 判「并完之后的那一套」：卡换成合并结果，出处 = 它吸收的那几张的出处拼起来
        if let name = body["merge"] as? String {
            // 程序的一次「整理 + 并」，或者自由 agent 的一套产出（agent-<run>）
            let rows: [(i: Int, content: String, from: [Int])]
            if let run = loadMergeRun(name) {
                rows = run.result.map { ($0.i, $0.content, $0.from) }
            } else if let found = agentRun(name) {
                rows = found.archive.enumerated().map { ($0.offset + 1, $0.element.content, $0.element.from) }
            } else {
                return .error(404, "没有这套结果：\(name)")
            }
            let original = try sourceExcerpts(cards, source: conversations, names: names)
            chosen = rows.map {
                ExportedFragment(i: $0.i, content: $0.content, category: "", subject: nil, speaker: nil,
                                 conversationId: nil, sourceNodeId: nil, model: $0.from.count > 1 ? "并出来的" : "没动的")
            }
            excerpts = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row.i, row.from.compactMap { original[$0] }.prefix(8).joined(separator: "\n…\n"))
            })
        }

        let meter = ScoreMeter()
        let caller: SessionSegmentWriter.Caller = { system, user in
            let reply = try await judge.complete(system: system, user: user)
            meter.add(reply.usage)
            return reply.text
        }
        let starts = Array(stride(from: 0, to: chosen.count, by: FragmentJudge.batchSize))
        var judgments: [FragmentJudge.Judgment] = []
        var failed: [String] = []
        await withTaskGroup(of: (Int, Result<[FragmentJudge.Judgment], Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < starts.count else { return }
                let offset = starts[next]
                next += 1
                let slice = chosen[offset..<min(offset + FragmentJudge.batchSize, chosen.count)]
                let batch = slice.map {
                    FragmentJudge.Card(id: String($0.i), content: $0.content, subject: $0.subject, speaker: $0.speaker,
                                       category: $0.category, source: excerpts[$0.i] ?? "")
                }
                let prior = chosen[..<offset].map { FragmentJudge.Prior(id: String($0.i), content: $0.content) }
                group.addTask {
                    do { return (offset, .success(try await FragmentJudge.judge(batch: batch, prior: prior, names: names, caller: caller))) }
                    catch { return (offset, .failure(error)) }
                }
            }
            for _ in 0..<min(3, starts.count) { addNext() }
            while let (offset, result) = await group.next() {
                switch result {
                case .success(let rows): judgments += rows
                case .failure(let error): failed.append("第 \(offset + 1) 张起那一批：\(error.localizedDescription)")
                }
                addNext()
            }
        }
        judgments.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        let modelOf = Dictionary(chosen.map { (String($0.i), $0.model ?? "?") }, uniquingKeysWith: { a, _ in a })
        var byModel: [String: FragmentJudge.Tally] = [:]
        for (model, rows) in Dictionary(grouping: judgments, by: { modelOf[$0.id] ?? "?" }) {
            byModel[model] = FragmentJudge.tally(rows)
        }
        let totals = meter.totals
        let score = FragmentScore(at: Date(), judge: judge.modelId, cards: chosen.count, tally: FragmentJudge.tally(judgments),
                                  byModel: byModel, judgments: judgments, failedBatches: failed,
                                  calls: totals.calls, inputTokens: totals.input, outputTokens: totals.output)
        let dir = config.floor.appendingPathComponent("bench-runs", isDirectory: true).appendingPathComponent("c2-scores", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoded = try Self.experimentEncoder.encode(score)
        try encoded.write(to: dir.appendingPathComponent("score-\(Int(score.at.timeIntervalSince1970)).json"), options: .atomic)
        return .jsonRaw(encoded)
    }

    // MARK: - C2 整理的「并」单独一步（plan-c2-write-shape §1.2 之后）

    struct FragmentMergeRun: Codable, Sendable {
        struct Row: Codable, Sendable {
            /// 并完之后重新编的号
            var i: Int
            var content: String
            /// 它来自原来的哪几张（原编号）
            var from: [Int]
        }

        var at: Date
        var model: String
        var organize: String
        /// 进来几张（整理后的留 / 改 / 并）、并完剩几张
        var before: Int
        var after: Int
        var groups: Int
        var failedGroups: Int
        var result: [Row]
        var calls: Int
        var inputTokens: Int
        var outputTokens: Int
    }

    private var mergeDir: URL {
        config.floor.appendingPathComponent("bench-runs", isDirectory: true).appendingPathComponent("c2-merge", isDirectory: true)
    }

    private func loadMergeRun(_ name: String) -> FragmentMergeRun? {
        guard !name.contains("/"), !name.contains("..") else { return nil }
        return (try? Data(contentsOf: mergeDir.appendingPathComponent(name)))
            .flatMap { try? Self.experimentDecoder.decode(FragmentMergeRun.self, from: $0) }
    }

    /// 拿一次整理的结果，把留下来的卡（留 / 改 / 并；删和拿不准的不进）分组合并
    private func mergeFragments(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let model = config.model else {
            return .error(400, "没接模型：环境里设 \(MemorydModel.keyVariable)，启动加 --model <模型 id>")
        }
        guard let conversations else { return .error(404, "副本里没有楼层快照") }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        guard let name = body["organize"] as? String, !name.contains("/"), !name.contains("..") else {
            return .error(400, "请求体要 {\"organize\": \"<c2-organize 里的文件名>\"}")
        }
        let organizeFile = config.floor.appendingPathComponent("bench-runs").appendingPathComponent("c2-organize").appendingPathComponent(name)
        guard let organized = (try? Data(contentsOf: organizeFile))
            .flatMap({ try? Self.experimentDecoder.decode(FragmentOrganizeRun.self, from: $0) }) else {
            return .error(404, "没有这次整理结果：\(name)")
        }
        let file = config.floor.appendingPathComponent(FloorSnapshotExportFolder.name).appendingPathComponent("fragments.json")
        guard let data = try? Data(contentsOf: file), let cards = try? JSONDecoder().decode([ExportedFragment].self, from: data) else {
            return .error(404, "副本里没有 exports/fragments.json")
        }
        let names = MemoryExtractor.Names(userName: body["userName"] as? String ?? "", assistantName: body["assistantName"] as? String ?? "")
        let excerpts = try sourceExcerpts(cards, source: conversations, names: names)
        let original = Dictionary(cards.map { ($0.i, $0.content) }, uniquingKeysWith: { a, _ in a })
        // 留 / 并：原文；改：改好的那句
        let survivors: [FragmentMerger.Card] = organized.decisions.compactMap { decision in
            guard let i = Int(decision.id), let content = original[i] else { return nil }
            switch decision.action {
            case .keep, .merge: return FragmentMerger.Card(id: decision.id, content: content, source: excerpts[i] ?? "")
            case .fix: return FragmentMerger.Card(id: decision.id, content: decision.content ?? content, source: excerpts[i] ?? "")
            case .drop, .unsure: return nil
            }
        }
        let meter = ScoreMeter()
        let caller: SessionSegmentWriter.Caller = { system, user in
            let reply = try await model.complete(system: system, user: user)
            meter.add(reply.usage)
            return reply.text
        }
        let outcome = try await FragmentMerger.run(survivors, names: names, caller: caller)
        let absorbed = Set(outcome.merged.flatMap(\.from))
        var rows: [(order: Int, content: String, from: [Int])] = []
        for card in survivors where !absorbed.contains(card.id) {
            if let i = Int(card.id) { rows.append((i, card.content, [i])) }
        }
        for merged in outcome.merged {
            let from = merged.from.compactMap(Int.init).sorted()
            if let first = from.first { rows.append((first, merged.content, from)) }
        }
        rows.sort { $0.order < $1.order }
        let totals = meter.totals
        let run = FragmentMergeRun(at: Date(), model: model.modelId, organize: name, before: survivors.count, after: rows.count,
                                   groups: outcome.groups.count, failedGroups: outcome.failedGroups.count,
                                   result: rows.enumerated().map { .init(i: $0.offset + 1, content: $0.element.content, from: $0.element.from) },
                                   calls: totals.calls, inputTokens: totals.input, outputTokens: totals.output)
        try FileManager.default.createDirectory(at: mergeDir, withIntermediateDirectories: true)
        let encoded = try Self.experimentEncoder.encode(run)
        let outName = "merge-\(model.modelId)-\(Int(run.at.timeIntervalSince1970)).json"
        try encoded.write(to: mergeDir.appendingPathComponent(outName), options: .atomic)
        return .json(["file": outName, "before": run.before, "after": run.after, "groups": run.groups,
                      "failedGroups": run.failedGroups, "merged": outcome.merged.count,
                      "calls": run.calls, "inputTokens": run.inputTokens, "outputTokens": run.outputTokens])
    }

    // MARK: - 整理结果给她审（她的留 / 删才是最后的标准）

    private var reviewDir: URL {
        config.floor.appendingPathComponent("bench-runs", isDirectory: true).appendingPathComponent("c2-review", isDirectory: true)
    }

    /// 给她审的是哪一次：`c2-merge/.pinned` 里写了文件名就用它（别的对照实验再跑也不会把她正在看的换掉），否则最新的
    private func latestMergeFile() -> String? {
        if let pinned = (try? String(contentsOf: mergeDir.appendingPathComponent(".pinned"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pinned.isEmpty, loadMergeRun(pinned) != nil {
            return pinned
        }
        return ((try? FileManager.default.contentsOfDirectory(atPath: mergeDir.path)) ?? [])
            .filter { $0.hasPrefix("merge-") && $0.hasSuffix(".json") }
            .max { (Int($0.split(separator: "-").last?.dropLast(5) ?? "") ?? 0) < (Int($1.split(separator: "-").last?.dropLast(5) ?? "") ?? 0) }
    }

    private func verdicts(for file: String) -> [String: String] {
        (try? Data(contentsOf: reviewDir.appendingPathComponent(file)))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// 最近一次「整理 + 并」的结果：整理后的卡（带它吸收的原卡）、被删的、拿不准的、她已经点过的
    // 对照实验里自由 agent 的产出：副本 `gold/organize/<run>/archive.json` + `dropped.json`
    private struct AgentArchiveRow: Decodable {
        let content: String
        let from: [Int]
        let confidence: Double?
    }

    private struct AgentDroppedRow: Decodable {
        let i: Int
        let why: String?
    }

    private static let agentPrefix = "agent-"

    private var agentRunsDir: URL {
        config.floor.appendingPathComponent("gold", isDirectory: true).appendingPathComponent("organize", isDirectory: true)
    }

    /// 包里的整理 agent 跑同一批卡（plan-organize-agent O3）。结果写进 `gold/organize/<run>/`，和自由 agent 的产出同形，
    /// 审核页和比对脚本直接认。同步跑完才回（几分钟到十几分钟）
    private func runOrganizeAgent(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let model = config.model else {
            return .error(400, "没接模型：环境里设 \(MemorydModel.keyVariable)，启动加 --model <模型 id>")
        }
        guard let conversations else { return .error(404, "副本里没有楼层快照") }
        let file = config.floor.appendingPathComponent(FloorSnapshotExportFolder.name).appendingPathComponent("fragments.json")
        guard let data = try? Data(contentsOf: file),
              let cards = try? JSONDecoder().decode([ExportedFragment].self, from: data), !cards.isEmpty else {
            return .error(404, "副本里没有 exports/fragments.json")
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        guard let run = body["run"] as? String, !run.isEmpty, !run.contains("/"), !run.contains("..") else {
            return .error(400, "请求体要 {\"run\": \"<这次的名字，如 runP_Opus>\"}")
        }
        let names = MemoryExtractor.Names(userName: body["userName"] as? String ?? "", assistantName: body["assistantName"] as? String ?? "")
        let limit = (body["limit"] as? Int).map { max(1, min($0, cards.count)) } ?? cards.count
        let rounds = (body["rounds"] as? Int).map { max(5, min($0, 200)) } ?? OrganizeAgent.Limits().rounds
        let source = try SnapshotOrganizeSource(cards: Array(cards.prefix(limit)), conversations: conversations,
                                                profileId: config.profileId, names: names)
        let started = Date()
        let outcome = await OrganizeAgent.run(source: source, caller: model, names: names,
                                              ownerWords: body["ownerWords"] as? String ?? OrganizeAgent.defaultOwnerWords,
                                              limits: .init(rounds: rounds),
                                              options: .init(neighbors: body["neighbors"] as? Bool ?? true,
                                                             allowKeep: body["allowKeep"] as? Bool ?? false,
                                                             piles: body["piles"] as? Bool ?? true))
        let dir = agentRunsDir.appendingPathComponent(run, isDirectory: true)
        try MemorydOrganizeOutput.write(outcome, cards: source.all, model: model.modelId, to: dir, startedAt: started)
        let trace = (try? Data(contentsOf: dir.appendingPathComponent("trace.json"))) ?? Data("{}".utf8)
        return .jsonRaw(trace)
    }

    private func agentRun(_ name: String) -> (archive: [AgentArchiveRow], dropped: [AgentDroppedRow])? {
        guard name.hasPrefix(Self.agentPrefix) else { return nil }
        let run = String(name.dropFirst(Self.agentPrefix.count))
        guard !run.isEmpty, !run.contains("/"), !run.contains("..") else { return nil }
        let dir = agentRunsDir.appendingPathComponent(run, isDirectory: true)
        guard let archive = (try? Data(contentsOf: dir.appendingPathComponent("archive.json")))
            .flatMap({ try? JSONDecoder().decode([AgentArchiveRow].self, from: $0) }) else { return nil }
        let dropped = (try? Data(contentsOf: dir.appendingPathComponent("dropped.json")))
            .flatMap { try? JSONDecoder().decode([AgentDroppedRow].self, from: $0) } ?? []
        return (archive, dropped)
    }

    /// 自由 agent 没有这个文件；包里的整理 agent 把「拿不准」单列在 `unsure.json`
    private func agentUnsure(_ name: String) -> [AgentDroppedRow] {
        guard name.hasPrefix(Self.agentPrefix) else { return [] }
        let dir = agentRunsDir.appendingPathComponent(String(name.dropFirst(Self.agentPrefix.count)), isDirectory: true)
        return (try? Data(contentsOf: dir.appendingPathComponent("unsure.json")))
            .flatMap { try? JSONDecoder().decode([AgentDroppedRow].self, from: $0) } ?? []
    }

    // 写入对照实验的产出：`gold/write/<材料>/<run>/archive.json`（直接从原文写的条目，带出处消息编号），
    // 同一段里现有的卡在 `gold/write/<材料>-existing/existing-cards.json`。名字 `write-<材料>~<run 或 existing>`
    private struct WriteRow: Decodable {
        let content: String
        let msgs: [Int]?
        let msg: Int?
        let since: String?
        let confidence: Double?
        let subject: String?
        let type: String?
        let origin: String?
        let volatile: Bool?
        let target: String?
    }

    private struct WriteNoteRow: Decodable {
        let title: String
        let content: String
        let page: String?
        let cards: [String]
    }

    private static let writePrefix = "write-"

    private var writeRunsDir: URL {
        config.floor.appendingPathComponent("gold", isDirectory: true).appendingPathComponent("write", isDirectory: true)
    }

    /// 包里的写入 agent 跑副本里一个窗口的一段（plan-write-agent W2）。结果写进 `gold/write/<material>/<run>/`，
    /// 和手写实验里自由 agent 的产出同形。同步跑完才回
    private func runWriteAgent(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let model = config.model else {
            return .error(400, "没接模型：环境里设 \(MemorydModel.keyVariable)，启动加 --model <模型 id>")
        }
        guard let conversations else { return .error(404, "副本里没有楼层快照") }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        func plain(_ key: String) -> String? {
            guard let value = body[key] as? String, !value.isEmpty, !value.contains("/"), !value.contains("..") else { return nil }
            return value
        }
        guard let run = plain("run"), run.hasPrefix("run"), let material = plain("material"),
              !material.hasSuffix("-existing"), !material.hasSuffix("-judge") else {
            return .error(400, "请求体要 {run: \"run…\", material: \"<材料名>\", conversation: \"<窗口 id 或前缀>\" 或 title: \"<窗口名里的一段>\"}")
        }
        let window: ConversationWindow?
        if let id = body["conversation"] as? String, !id.isEmpty {
            window = try conversations.window(profileId: config.profileId, idOrPrefix: id)
        } else if let title = body["title"] as? String, !title.isEmpty {
            let hits = try conversations.windows(profileId: config.profileId, updatedSince: nil, includeTrashed: false).filter { $0.title.contains(title) }
            guard hits.count <= 1 else { return .error(400, "窗口名里含这段字的有 \(hits.count) 个，给 conversation id") }
            window = hits.first
        } else {
            window = nil
        }
        guard let window else { return .error(404, "没找到这个窗口") }
        let path = try MemorydExperimentRunner.messages(window: window, source: conversations)
        let to = min(max(body["to"] as? Int ?? path.count, 0), path.count)
        let from = (body["last"] as? Int).map { max(to - max($0, 1), 0) } ?? min(max((body["from"] as? Int ?? 1) - 1, 0), to)
        guard from < to else { return .error(400, "这一段是空的（主线 \(path.count) 条）") }
        var existing: [WriteKnownCard] = []
        let existingName = body["existing"] as? String
        if let existingName {
            let parts = existingName.dropFirst(Self.writePrefix.count).split(separator: "~", maxSplits: 1).map(String.init)
            guard writeRun(existingName) != nil, parts.count == 2, parts[1] != "existing",
                  let cards = MemorydWriteOutput.known(from: writeRunsDir.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent("archive.json")) else {
                return .error(404, "existing 要是一次写入的名字（write-<材料>~<run>）")
            }
            existing = cards
        }
        let names = MemoryExtractor.Names(userName: body["userName"] as? String ?? "", assistantName: body["assistantName"] as? String ?? "")
        let source = SnapshotWriteSource(window: window, path: path, range: from..<to, existing: existing, names: names, conversations: conversations)
        let materialDir = writeRunsDir.appendingPathComponent(material, isDirectory: true)
        try FileManager.default.createDirectory(at: materialDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let transcript = materialDir.appendingPathComponent("transcript.txt")
        if !FileManager.default.fileExists(atPath: transcript.path) {
            try Data(source.transcript().utf8).write(to: transcript, options: .atomic)
        }
        let rounds = (body["rounds"] as? Int).map { max(5, min($0, 200)) } ?? 40
        let started = Date()
        let outcome = await WriteAgent.run(source: source, caller: model, names: names,
                                           limits: .init(rounds: rounds, contextChars: 120_000, resultChars: 24_000))
        let dir = materialDir.appendingPathComponent(run, isDirectory: true)
        try MemorydWriteOutput.write(outcome, model: model.modelId, existing: existingName, spanCount: to - from, to: dir, startedAt: started)
        return .jsonRaw((try? Data(contentsOf: dir.appendingPathComponent("trace.json"))) ?? Data("{}".utf8))
    }

    private func writeRun(_ name: String) -> (material: String, rows: [WriteRow])? {
        guard name.hasPrefix(Self.writePrefix), !name.contains("/"), !name.contains("..") else { return nil }
        let parts = name.dropFirst(Self.writePrefix.count).split(separator: "~", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let file = parts[1] == "existing"
            ? writeRunsDir.appendingPathComponent(parts[0] + "-existing").appendingPathComponent("existing-cards.json")
            : writeRunsDir.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent("archive.json")
        guard let rows = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode([WriteRow].self, from: $0) }) else { return nil }
        return (parts[0], rows)
    }

    private func writeNames() -> [(name: String, label: String)] {
        let materials = ((try? FileManager.default.contentsOfDirectory(atPath: writeRunsDir.path)) ?? [])
            .filter { !$0.hasSuffix("-existing") && !$0.hasSuffix("-judge") && !$0.hasPrefix(".") }.sorted()
        return materials.flatMap { material -> [(name: String, label: String)] in
            let runs = ((try? FileManager.default.contentsOfDirectory(atPath: writeRunsDir.appendingPathComponent(material).path)) ?? [])
                .filter { $0.hasPrefix("run") }
                .sorted { a, b in
                    // 第一轮（run 后面没数字）排在第二、三轮前，包里的 agent（runW）排最后
                    func rank(_ run: String) -> String {
                        let rest = run.dropFirst(3)
                        return rest.hasPrefix("W") ? "9" + rest : (rest.first?.isNumber == true ? String(rest) : "1" + rest)
                    }
                    return rank(a) < rank(b)
                }
            return (["existing"] + runs).map { run in
                (Self.writePrefix + material + "~" + run, run == "existing" ? "写入 · 现有的卡" : "写入 · 自由 agent · \(run)")
            }
        }
    }

    private func writePage(_ name: String, material: String, rows: [WriteRow]) -> HTTPResponse {
        let transcript = (try? String(contentsOf: writeRunsDir.appendingPathComponent(material).appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        func excerpt(_ numbers: [Int]) -> String {
            var wanted = Set<Int>()
            for number in numbers.prefix(8) { wanted.insert(number - 1); wanted.insert(number) }
            return wanted.sorted().compactMap { $0 >= 1 && $0 <= lines.count ? String(lines[$0 - 1].prefix(900)) : nil }.joined(separator: "\n")
        }
        let kept: [[String: Any]] = rows.enumerated().map { index, row in
            let numbers = row.msgs ?? row.msg.map { [$0] } ?? []
            var out: [String: Any] = ["key": "w\(index + 1)", "content": row.content, "source": excerpt(numbers)]
            if let confidence = row.confidence { out["confidence"] = confidence }
            if let since = row.since, !since.isEmpty { out["since"] = since }
            if let subject = row.subject, !subject.isEmpty { out["subject"] = subject }
            let marks = [row.type, row.origin, row.volatile == true ? "volatile" : nil, row.target.map { "改已有的 " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }
            if !marks.isEmpty { out["marks"] = marks }
            return out
        }
        // 给 wiki 的段落（包里的写入 agent 才有）：排在卡后面，点开看撑着它的卡
        var all = kept
        let parts = name.dropFirst(Self.writePrefix.count).split(separator: "~", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1] != "existing",
           let notes = (try? Data(contentsOf: writeRunsDir.appendingPathComponent(material).appendingPathComponent(parts[1]).appendingPathComponent("notes.json")))
            .flatMap({ try? JSONDecoder().decode([WriteNoteRow].self, from: $0) }) {
            let byId = Dictionary(rows.enumerated().map { ("n\($0.offset + 1)", $0.element.content) }, uniquingKeysWith: { a, _ in a })
            all += notes.enumerated().map { index, note in
                ["key": "p\(index + 1)", "subject": note.title, "content": note.content, "marks": ["给 wiki", note.page ?? "新页"],
                 "source": note.cards.map { "[\($0)] \(byId[$0] ?? "（档案里已有的卡）")" }.joined(separator: "\n")]
            }
        }
        return .json(["file": name, "model": "write", "total": lines.count, "kept": all,
                      "dropped": [[String: Any]](), "unsure": [[String: Any]](), "verdicts": verdicts(for: name)])
    }

    private func isReviewable(_ name: String) -> Bool {
        !name.contains("/") && !name.contains("..") && (loadMergeRun(name) != nil || agentRun(name) != nil || writeRun(name) != nil)
    }

    /// 能看的几套结果：自由 agent 的 + 程序各次「整理 + 并」的
    private func reviewResults() -> HTTPResponse {
        var rows: [[String: Any]] = []
        for entry in writeNames() {
            guard let found = writeRun(entry.name) else { continue }
            let run = String(entry.name.split(separator: "~", maxSplits: 1).last ?? "")
            let row: String
            if run == "existing" { row = "现在的写法（每 20 条填表）" }
            else if run.hasPrefix("runW") { row = "包里的写入 agent" }
            else if run.hasPrefix("run3") { row = "自由 agent · 第三轮（长，一件事一条）" }
            else if run.hasPrefix("run2") { row = "自由 agent · 第二轮（短，一个事实一条）" }
            else { row = "自由 agent · 第一轮" }
            let short = run == "existing" ? "DeepSeek" : run.replacingOccurrences(of: "runW2_", with: "按事交 · ").replacingOccurrences(of: "runW_", with: "")
                .replacingOccurrences(of: "run2", with: "").replacingOccurrences(of: "run3", with: "").replacingOccurrences(of: "run", with: "")
                .replacingOccurrences(of: "DS", with: "DeepSeek")
            rows.append(["name": entry.name, "label": entry.label, "group": "写入：从原文直接写（同一段 \(found.material)）", "row": row,
                         "short": short, "kept": found.rows.count, "dropped": 0, "unsure": 0, "marked": verdicts(for: entry.name).count])
        }
        let runs = ((try? FileManager.default.contentsOfDirectory(atPath: agentRunsDir.path)) ?? []).sorted()
        for run in runs {
            let name = Self.agentPrefix + run
            guard let found = agentRun(name) else { continue }
            let ours = FileManager.default.fileExists(atPath: agentRunsDir.appendingPathComponent(run).appendingPathComponent("trace.json").path)
            rows.append(["name": name, "label": "\(ours ? "整理 agent" : "自由 agent") · \(run)",
                         "group": "整理：收拾原来那批卡", "row": ours ? "包里的整理 agent" : "自由 agent", "short": run.replacingOccurrences(of: "run", with: ""),
                         "kept": found.archive.count,
                         "dropped": found.dropped.count, "unsure": agentUnsure(name).count, "marked": verdicts(for: name).count])
        }
        let merges = ((try? FileManager.default.contentsOfDirectory(atPath: mergeDir.path)) ?? [])
            .filter { $0.hasPrefix("merge-") && $0.hasSuffix(".json") }.sorted()
        for file in merges {
            guard let run = loadMergeRun(file) else { continue }
            let organizeFile = config.floor.appendingPathComponent("bench-runs").appendingPathComponent("c2-organize").appendingPathComponent(run.organize)
            let tally = (try? Data(contentsOf: organizeFile))
                .flatMap { try? Self.experimentDecoder.decode(FragmentOrganizeRun.self, from: $0) }?.tally
            rows.append(["name": file, "label": "程序 · \(run.model)", "group": "整理：收拾原来那批卡", "row": "程序（一次调用不带工具）", "short": run.model,
                         "kept": run.after, "dropped": tally?.count(.drop) ?? 0,
                         "unsure": tally?.count(.unsure) ?? 0, "marked": verdicts(for: file).count])
        }
        return .json(["results": rows, "default": latestMergeFile() ?? ""])
    }

    private func reviewPage(_ requested: String?) -> HTTPResponse {
        let cardsFile0 = config.floor.appendingPathComponent(FloorSnapshotExportFolder.name).appendingPathComponent("fragments.json")
        if let name = requested, let found = writeRun(name) { return writePage(name, material: found.material, rows: found.rows) }
        if let name = requested, let found = agentRun(name) {
            let cards = (try? Data(contentsOf: cardsFile0)).flatMap { try? JSONDecoder().decode([ExportedFragment].self, from: $0) } ?? []
            let original = Dictionary(cards.map { ($0.i, $0.content) }, uniquingKeysWith: { a, _ in a })
            let sources = conversations.flatMap {
                try? sourceExcerpts(cards, source: $0, names: MemoryExtractor.Names(userName: "她", assistantName: "AI"))
            } ?? [:]
            let kept: [[String: Any]] = found.archive.enumerated().map { index, row in
                var out: [String: Any] = ["key": "g\(index + 1)", "content": row.content,
                                          "from": row.from.map { ["i": $0, "content": original[$0] ?? "", "source": sources[$0] ?? ""] as [String: Any] }]
                if let confidence = row.confidence { out["confidence"] = confidence }
                return out
            }
            let dropped: [[String: Any]] = found.dropped.map {
                ["key": "o\($0.i)", "i": $0.i, "content": original[$0.i] ?? "", "why": $0.why ?? "", "source": sources[$0.i] ?? ""]
            }
            let unsure: [[String: Any]] = agentUnsure(name).map {
                ["key": "o\($0.i)", "i": $0.i, "content": original[$0.i] ?? "", "why": $0.why ?? "", "source": sources[$0.i] ?? ""]
            }
            return .json(["file": name, "model": "agent", "total": cards.count, "kept": kept,
                          "dropped": dropped, "unsure": unsure, "verdicts": verdicts(for: name)])
        }
        guard let file = requested ?? latestMergeFile(), let run = loadMergeRun(file) else { return .error(404, "还没有整理结果") }
        let cardsFile = config.floor.appendingPathComponent(FloorSnapshotExportFolder.name).appendingPathComponent("fragments.json")
        let cards = (try? Data(contentsOf: cardsFile)).flatMap { try? JSONDecoder().decode([ExportedFragment].self, from: $0) } ?? []
        let original = Dictionary(cards.map { ($0.i, $0.content) }, uniquingKeysWith: { a, _ in a })
        // 每张原卡的出处原文（它引用的那条消息连同前两条），页面上点开看
        let sources = conversations.flatMap {
            try? sourceExcerpts(cards, source: $0, names: MemoryExtractor.Names(userName: "她", assistantName: "AI"))
        } ?? [:]
        let organizeFile = config.floor.appendingPathComponent("bench-runs").appendingPathComponent("c2-organize").appendingPathComponent(run.organize)
        let decisions = (try? Data(contentsOf: organizeFile))
            .flatMap { try? Self.experimentDecoder.decode(FragmentOrganizeRun.self, from: $0) }?.decisions ?? []
        func rows(_ action: FragmentOrganizer.Action) -> [[String: Any]] {
            decisions.filter { $0.action == action }.compactMap { d in
                guard let i = Int(d.id) else { return nil }
                return ["key": "o\(i)", "i": i, "content": original[i] ?? "", "why": d.why ?? "", "source": sources[i] ?? ""]
            }
        }
        let kept: [[String: Any]] = run.result.map { row in
            ["key": "m\(row.i)", "content": row.content,
             "from": row.from.map { ["i": $0, "content": original[$0] ?? "", "source": sources[$0] ?? ""] as [String: Any] }]
        }
        return .json(["file": file, "model": run.model, "total": cards.count, "kept": kept,
                      "dropped": rows(.drop), "unsure": rows(.unsure), "verdicts": verdicts(for: file)])
    }

    /// 她点一下：{file, key, verdict: "keep" | "drop" | ""}（空 = 撤回）
    private func reviewMark(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let file = body["file"] as? String, isReviewable(file),
              let key = body["key"] as? String, let verdict = body["verdict"] as? String,
              ["keep", "drop", ""].contains(verdict) else {
            return .error(400, "请求体要 {file, key, verdict: keep | drop | 空}")
        }
        var all = verdicts(for: file)
        if verdict.isEmpty { all[key] = nil } else { all[key] = verdict }
        try FileManager.default.createDirectory(at: reviewDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]).write(to: reviewDir.appendingPathComponent(file), options: .atomic)
        return .json(["marked": all.count])
    }

    // MARK: - C2 整理（做梦）：给现有的卡下结论（plan-c2-write-shape P1-整理，只出结论不落库）

    struct FragmentOrganizeRun: Codable, Sendable {
        var at: Date
        var model: String
        var variant: String
        var cards: Int
        var tally: FragmentOrganizer.Tally
        var decisions: [FragmentOrganizer.Decision]
        var failedBatches: [String]
        var calls: Int
        var inputTokens: Int
        var outputTokens: Int
    }

    /// 一批一批按先后来，每批的「档案里已有的」= 这一批之前的全部卡（实验口径：不随前面批次的结论变）
    private func organizeFragments(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let model = config.model else {
            return .error(400, "没接模型：环境里设 \(MemorydModel.keyVariable)，启动加 --model <模型 id>")
        }
        guard let conversations else { return .error(404, "副本里没有楼层快照") }
        let file = config.floor.appendingPathComponent(FloorSnapshotExportFolder.name).appendingPathComponent("fragments.json")
        guard let data = try? Data(contentsOf: file),
              let cards = try? JSONDecoder().decode([ExportedFragment].self, from: data), !cards.isEmpty else {
            return .error(404, "副本里没有 exports/fragments.json（用 store-to-floor-snapshot.py 重新导一次）")
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let names = MemoryExtractor.Names(userName: body["userName"] as? String ?? "", assistantName: body["assistantName"] as? String ?? "")
        let limit = (body["limit"] as? Int).map { max(1, min($0, cards.count)) } ?? cards.count
        let chosen = Array(cards.prefix(limit))
        let excerpts = try sourceExcerpts(chosen, source: conversations, names: names)
        let variant = (body["variant"] as? String).flatMap(FragmentOrganizer.Variant.init(rawValue:)) ?? .purpose

        let meter = ScoreMeter()
        let caller: SessionSegmentWriter.Caller = { system, user in
            let reply = try await model.complete(system: system, user: user)
            meter.add(reply.usage)
            return reply.text
        }
        let starts = Array(stride(from: 0, to: chosen.count, by: FragmentOrganizer.batchSize))
        var decisions: [FragmentOrganizer.Decision] = []
        var failed: [String] = []
        await withTaskGroup(of: (Int, Result<[FragmentOrganizer.Decision], Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < starts.count else { return }
                let offset = starts[next]
                next += 1
                let slice = chosen[offset..<min(offset + FragmentOrganizer.batchSize, chosen.count)]
                let batch = slice.map {
                    FragmentOrganizer.Card(id: String($0.i), content: $0.content, subject: $0.subject, source: excerpts[$0.i] ?? "")
                }
                let known = chosen[..<offset].map { FragmentOrganizer.Known(id: String($0.i), content: $0.content) }
                group.addTask {
                    do { return (offset, .success(try await FragmentOrganizer.organize(batch: batch, known: known, names: names, variant: variant, caller: caller))) }
                    catch { return (offset, .failure(error)) }
                }
            }
            for _ in 0..<min(3, starts.count) { addNext() }
            while let (offset, result) = await group.next() {
                switch result {
                case .success(let rows): decisions += rows
                case .failure(let error): failed.append("第 \(offset + 1) 张起那一批：\(error.localizedDescription)")
                }
                addNext()
            }
        }
        decisions.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        let totals = meter.totals
        let run = FragmentOrganizeRun(at: Date(), model: model.modelId, variant: variant.rawValue, cards: chosen.count, tally: FragmentOrganizer.tally(decisions),
                                      decisions: decisions, failedBatches: failed,
                                      calls: totals.calls, inputTokens: totals.input, outputTokens: totals.output)
        let dir = config.floor.appendingPathComponent("bench-runs", isDirectory: true).appendingPathComponent("c2-organize", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoded = try Self.experimentEncoder.encode(run)
        let outName = "organize-\(model.modelId)-\(variant.rawValue)-\(Int(run.at.timeIntervalSince1970)).json"
        try encoded.write(to: dir.appendingPathComponent(outName), options: .atomic)
        return HTTPResponse(headers: ["Content-Type": "application/json; charset=utf-8", "X-Memoryd-File": outName], body: encoded)
    }

    // MARK: - 题集 / 跑批

    /// memoryd 自己的资源 bundle 里全部 `*.json` + 副本 `bench-runs/sets/`
    private func allSets() -> [MemoryBenchSet] {
        builtInSets() + benchStore.floorSets()
    }

    private func builtInSets() -> [MemoryBenchSet] {
        let (sets, skipped) = loadBuiltInSets()
        for detail in skipped {
            log.error("跳过不是题集的资源 \(detail, privacy: .public)")
        }
        return sets
    }

    /// 题集文件 = `memory-bench-` 开头，但楼层 JSON（`memory-bench-recall-floor-*`）不是题集，显式排除。
    /// 解不开的进 `skipped`（调用方记 error）；测试直接断言 `skipped` 为空 = 不记 error。
    func loadBuiltInSets() -> (sets: [MemoryBenchSet], skipped: [String]) {
        guard let dir = MemorydResources.benchDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return ([], []) }
        var sets: [MemoryBenchSet] = []
        var skipped: [String] = []
        for url in urls.filter({
            $0.pathExtension == "json"
                && $0.lastPathComponent.hasPrefix("memory-bench-")
                && !$0.lastPathComponent.hasPrefix("memory-bench-recall-floor-")
        }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: url)
                sets.append(try MemoryBench.decoder.decode(MemoryBenchSet.self, from: data))
            } catch {
                skipped.append("\(url.lastPathComponent)：\(String(describing: error))")
            }
        }
        return (sets, skipped)
    }

    private func benchSets() -> HTTPResponse {
        let sets = allSets().map { set -> [String: Any] in
            var object: [String: Any] = [
                "id": set.id,
                "name": set.name,
                "writer": set.writer,
                "source": set.source.rawValue,
                "caseCount": set.cases.count,
                "runnable": set.writer == OfflineWikiBenchWriter.id || set.writer == OfflineRecallBench.writerId
                    || (config.model != nil && Self.modelWriter(set.writer) != nil),
                "needsModel": Self.modelWriter(set.writer) != nil,
            ]
            if set.writer == OfflineRecallBench.writerId {
                let runnable = set.cases.filter { OfflineRecallBench.isRunnable($0) }.count
                object["partial"] = "\(runnable)/\(set.cases.count)"
            }
            return object
        }
        return .json(["sets": sets])
    }

    private func benchSet(_ id: String) throws -> HTTPResponse {
        guard let set = allSets().first(where: { $0.id == id }) else {
            return .error(404, "没有这个题集：\(id)")
        }
        return .jsonRaw(try MemoryBench.encoder.encode(set))
    }

    private func benchRuns() -> HTTPResponse {
        let runs = benchStore.runs().map { run -> [String: Any] in
            [
                "id": run.id,
                "at": Int64(run.at.timeIntervalSince1970 * 1000),
                "status": run.status.rawValue,
                "writer": run.writer,
                "set": ["id": run.set.id, "name": run.set.name],
                "cells": run.cells.count,
                "scores": run.scores.map { ["recipeId": $0.recipeId, "modelId": $0.modelId,
                                            "main": $0.main as Any, "mainName": $0.mainName] },
                "note": run.note as Any,
            ]
        }
        return .json(["runs": runs])
    }

    private func benchRunDetail(_ id: String) -> HTTPResponse {
        guard let run = benchStore.run(id: id) else { return .error(404, "没有这次跑：\(id)") }
        guard let data = try? MemoryBench.encoder.encode(run) else { return .error(500, "这次跑写不成 JSON") }
        return .jsonRaw(data)
    }

    private func benchRun(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let setId = object["setId"] as? String, !setId.isEmpty else {
            return .error(400, BenchError.badBody.localizedDescription)
        }
        guard let set = allSets().first(where: { $0.id == setId }) else {
            return .error(404, BenchError.noSet(setId).localizedDescription)
        }
        var trial: [TrialRecipe] = []
        for item in object["recipes"] as? [[String: Any]] ?? [] {
            guard let system = item["system"] as? String, !system.isEmpty else {
                return .error(400, "recipes 里每一版都要有 system")
            }
            trial.append(TrialRecipe(name: (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "试 \(trial.count + 1)",
                                     system: system, user: item["user"] as? String))
        }
        do {
            let run = try await runBench(set, trial: trial)
            return .json(["runId": run.id, "status": run.status.rawValue, "cells": run.cells.count,
                          "measurable": run.cells.count, "note": run.note as Any])
        } catch let error as MemoryBenchRunError {
            // 题数超限 / 空跑 / 重复身份都是请求本身的问题，不算服务错
            return .error(400, error.localizedDescription)
        }
    }

    /// 要调模型的写手（包里现成的那份，和 app 同一份代码）
    static func modelWriter(_ id: String) -> (any MemoryBenchWriter)? {
        switch id {
        case MemoryWriterID.c2.rawValue: return MemoryBenchC2Writer()
        case MemoryWriterID.a2.rawValue: return MemoryBenchA2Writer()
        default: return nil
        }
    }

    func runBench(_ set: MemoryBenchSet, trial: [TrialRecipe] = []) async throws -> MemoryBenchRun {
        if set.writer == OfflineRecallBench.writerId {
            return try await runRecallBench(set)
        }
        if let writer = Self.modelWriter(set.writer) {
            guard let model = config.model else {
                return try saveUnmeasurableRun(set, reason: "没接模型：环境里设 \(MemorydModel.keyVariable)，启动加 --model <模型 id>")
            }
            return try await runModelBench(set, writer: writer, model: model, trial: trial)
        }
        let writer = OfflineWikiBenchWriter()
        guard set.writer == writer.id else {
            return try saveUnmeasurableRun(set, reason: "memoryd v1 不调模型、不读对话树（\(set.writer) 写手）")
        }
        let runnable = set.cases.filter { OfflineWikiBenchWriter.isRunnable($0) }
        let skipped = set.cases.count - runnable.count
        guard !runnable.isEmpty else {
            return try saveUnmeasurableRun(set, reason: "没有 query 形状的用例")
        }
        let recipes = writer.builtInRecipes(defaults: MemoryReadEnvironment.defaults)
        let models = [MemoryBenchModelRef(credentialId: "", modelId: "offline", name: "离线", local: true)]
        let floor = config.floor
        var run = try await MemoryBenchRunner.run(
            writer: writer, set: set, caseIds: runnable.map(\.id), recipes: recipes, models: models,
            store: benchStore, profileId: config.profileId, memoryRoot: { floor },
            local: { [weak self] testCase, _ in
                guard let self else { throw CancellationError() }
                return try await self.execute(testCase)
            },
            caller: { _, _ in throw MemorydError.noModelCall },
            runId: UUID().uuidString
        )
        // 出错的格子（items 为空）自动配出来的判断照着标签就成立，会把主分抬高：整格剔除后重算
        let broken = Set(run.cells.filter { $0.error != nil }.map(\.id))
        if !broken.isEmpty {
            run.judgments.removeAll { broken.contains($0.cellId) }
            run.scores = run.scored(with: writer.scorers)
        }
        var notes: [String] = []
        if !broken.isEmpty { notes.append("\(broken.count) 格出错未计分") }
        if skipped > 0 { notes.append("不可测 \(skipped) 题（需要对话树 / 模型）") }
        if !notes.isEmpty {
            run.note = [run.note, notes.joined(separator: "；")].compactMap { $0 }.joined(separator: "；")
            try benchStore.saveRun(run)
        }
        return run
    }

    /// 真调模型跑一次：配方 = 现行（和正式写手逐字相同）+ 副本里存过的版本 + 这次请求临时加的几版
    private func runModelBench(_ set: MemoryBenchSet, writer: any MemoryBenchWriter, model: MemorydModel,
                               trial: [TrialRecipe]) async throws -> MemoryBenchRun {
        var recipes = writer.builtInRecipes(defaults: MemoryReadEnvironment.defaults)
        recipes += try benchStore.recipeBook(writer: writer.id).versions
        if let base = recipes.first {
            for (offset, item) in trial.enumerated() {
                var recipe = base
                recipe.id = "trial-\(offset + 1)"
                recipe.name = item.name
                recipe.parent = base.id
                recipe.system = item.system
                if let user = item.user, !user.isEmpty { recipe.user = user }
                recipe.builtIn = false
                recipes.append(recipe)
            }
        }
        let floor = config.floor
        return try await MemoryBenchRunner.run(
            writer: writer, set: set, recipes: recipes, models: [model.ref],
            store: benchStore, profileId: config.profileId, memoryRoot: { floor },
            local: { _, _ in throw MemorydError.noModelCall },
            caller: model.caller,
            runId: UUID().uuidString
        )
    }

    /// recall 写手：Y 半边 13 题（每轮都有 ops）；11 题纯 X 留给刀 3。宿主时区不符整份不可测
    private func runRecallBench(_ set: MemoryBenchSet) async throws -> MemoryBenchRun {
        let expected = OfflineRecallBench.timeZone(of: set)
        let host = Calendar.current.timeZone.identifier
        if let expected, expected != host {
            return try saveUnmeasurableRun(set, reason: "宿主时区 \(host) ≠ 题集 \(expected)：请 TZ=\(expected) 启动 memoryd")
        }
        guard let floorURL = MemorydResources.recallFloorURL else {
            throw MemorydError.noRecallFloor
        }
        let runnable = set.cases.filter { OfflineRecallBench.isRunnable($0) }
        let skipped = set.cases.count - runnable.count
        guard !runnable.isEmpty else {
            return try saveUnmeasurableRun(set, reason: "没有每轮都带 ops 的用例")
        }
        let writer = OfflineRecallBench.writer(floorURL: floorURL)
        let recipes = [try OfflineRecallBench.recipe(tuning: RecallTuning.defaults)]
        let models = [MemoryBenchModelRef(credentialId: "", modelId: "offline", name: "离线", local: true)]
        let floor = config.floor
        var run = try await MemoryBenchRunner.run(
            writer: writer, set: set, caseIds: runnable.map(\.id), recipes: recipes, models: models,
            store: benchStore, profileId: config.profileId, memoryRoot: { floor },
            local: { testCase, recipe in
                try await OfflineRecallBench.execute(testCase: testCase, recipe: recipe, floorURL: floorURL)
            },
            caller: { _, _ in throw MemorydError.noModelCall },
            runId: UUID().uuidString
        )
        let broken = Set(run.cells.filter { $0.error != nil }.map(\.id))
        if !broken.isEmpty {
            run.judgments.removeAll { broken.contains($0.cellId) }
            run.scores = run.scored(with: writer.scorers)
        }
        var notes: [String] = []
        if !broken.isEmpty { notes.append("\(broken.count) 格出错未计分") }
        if skipped > 0 { notes.append("主分不可测（X 侧 \(skipped) 题等刀 3）") }
        if !notes.isEmpty {
            run.note = [run.note, notes.joined(separator: "；")].compactMap { $0 }.joined(separator: "；")
            try benchStore.saveRun(run)
        }
        return run
    }

    private func saveUnmeasurableRun(_ set: MemoryBenchSet, reason: String) throws -> MemoryBenchRun {
        let now = MemoryBench.stamp(Date())
        let run = MemoryBenchRun(
            id: UUID().uuidString, writer: set.writer, at: now, finishedAt: now, status: .done,
            set: .init(id: set.id, name: set.name, revision: set.revision),
            recipes: [], models: [], caseIds: set.cases.map(\.id),
            cells: [], judgments: [], scores: [], pinned: false,
            note: "不可测 \(set.cases.count) 题：\(reason)"
        )
        try benchStore.saveRun(run)
        return run
    }

    // MARK: - 离线执行（wiki 索引这一段）

    /// 和 app 同一条 X2 全文管线：`RecallFullText.terms → queryWeights → query → search → ranked → verified`，
    /// 只把最后一步的命中列出来（不拼提示词、不调模型）。这些函数本身一行没改。
    private func execute(_ testCase: MemoryBenchCase) async throws -> String {
        let query = try OfflineWikiBenchWriter.query(of: testCase)
        let tuning = RecallTuning.defaults
        // 和 app 一样把 wiki 根的「不触发的词」传进 terms / ranked；search 不限 kinds，页和要点卡同排
        let stop = wiki.stopWords()
        let terms = RecallFullText.terms(query, excluding: stop, tuning: tuning)
        var words: [String] = []
        var verified: [CatalogRecallIndexStore.Hit] = []
        if !terms.isEmpty {
            let store = try recallIndex()
            let weights = try store.queryWeights(terms: terms, profileId: config.profileId)
            words = RecallFullText.query(terms, weights: weights, tuning: tuning)
            let status = try store.status(profileId: config.profileId)
            let indexed = try store.search(terms: words, profileId: config.profileId)
            let batch = RecallFullTextCandidates(profileId: config.profileId, text: query, terms: words,
                                                 weights: weights, status: status, hits: indexed)
            let ranked = RecallFullText.ranked(batch, text: query, profileId: config.profileId,
                                               excluding: stop, tuning: tuning)
            verified = store.verified(ranked, maximumCount: tuning.maximumPages)
        }
        let output = OfflineWikiBenchOutput(query: query, terms: terms, words: words, hits: verified.map {
            OfflineWikiBenchOutput.Hit(kind: $0.kind.rawValue, path: $0.path, version: $0.version)
        })
        return String(decoding: try MemoryBench.lineEncoder.encode(output), as: UTF8.self)
    }

    private func recallIndex() throws -> CatalogRecallIndexStore {
        if let index { return index }
        let wiki = WikiStore(root: config.floor.appendingPathComponent("wiki", isDirectory: true))
        guard FileManager.default.fileExists(atPath: wiki.root.path) else {
            throw MemorydError.noWiki
        }
        let store = try CatalogRecallIndexStore.open(profileId: config.profileId, wiki: wiki)
        if try store.status(profileId: config.profileId).state != .ready {
            try store.rebuild()
        }
        index = store
        return store
    }

    // MARK: - wiki 四层

    private var wiki: WikiStore {
        WikiStore(root: config.floor.appendingPathComponent("wiki", isDirectory: true))
    }

    private func safeWiki() -> SafeWiki {
        SafeWiki.scan(wiki, memoryRoot: config.floor)
    }

    private func wikiIndex() -> HTTPResponse {
        let safe = safeWiki()
        guard safe.refused == nil else { return .error(500, safe.refused ?? "wiki 根不可信") }
        let groups = WikiStore.branches.map { branch -> [String: Any] in
            [
                "path": branch,
                "title": branch == WikiStore.userBranch ? "本人" : branch,
                "count": safe.count(under: branch),
            ]
        }
        return .json(["groups": groups])
    }

    /// 只读 SafeWiki 快照：不跟链接（`.group.md` 链接也读不到）、`private_*` 页和文件夹不进、只装 private 页的文件夹不列
    private func wikiGroup(_ path: String) -> HTTPResponse {
        guard path.isEmpty || WikiStore.isValidFolderPath(path) else { return .error(404, "分组路径不合法") }
        let safe = safeWiki()
        guard safe.refused == nil else { return .error(500, safe.refused ?? "wiki 根不可信") }
        guard path.isEmpty || safe.folders.contains(path) else { return .error(404, "没有这个分组") }
        var entries: [[String: Any]] = []
        for row in safe.indexRows(path) {
            switch row {
            case .folder(let folder, let name, let hook, let count):
                entries.append(["path": folder, "type": "folder", "title": name, "hook": hook, "count": count])
            case .page(let page, let title, let hook, _):
                entries.append(["path": page, "type": "page", "title": title, "hook": hook, "count": 0])
            }
        }
        return .json(["path": path, "entries": entries])
    }

    private func wikiPage(_ path: String) -> HTTPResponse {
        guard WikiStore.isValidPagePath(path) else { return .error(404, "页路径不合法") }
        let safe = safeWiki()
        guard let page = safe.pages.first(where: { $0.path == path }) else { return .error(404, "没有这一页") }
        let parsed = page.page
        var object: [String: Any] = [
            "path": parsed.path,
            "title": parsed.title,
            "hook": parsed.hook,
            "now": parsed.now,
            "records": parsed.records,
            "links": parsed.links.map { ["target": $0.target, "relation": $0.relation.rawValue, "why": $0.why] },
            "entries": parsed.entries ?? [],
            "markdown": page.text,
            "layer": "wiki页",
        ]
        if let kind = parsed.kind { object["kind"] = kind.rawValue }
        if let validUntil = parsed.validUntil { object["validUntil"] = validUntil }
        if let extra = parsed.extra {
            object["extra"] = [
                "meta": extra.meta,
                "linkLines": extra.linkLines,
                "sections": extra.sections.map { ["heading": $0.heading, "body": $0.body] },
                "preamble": extra.preamble as Any,
            ]
        }
        return .json(object)
    }

    /// `GET /api/wiki/entry/<页段数>/<页路径>/<卡路径>|<版本>`：卡原文支（碎片支在真实楼层没有来源，`FloorSnapshot` 无 fragments）。
    /// 版本放在同一段里：`RoutePath` 丢 query，放 query 会被吞。页段数写在前缀（十进制），按段数取页、剩下的全是卡路径，
    /// 页 / 卡两边含 `memory` 段也不歧义。
    private func wikiEntry(_ rest: String) -> HTTPResponse {
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let pageCount = parts.first.flatMap(Int.init), pageCount >= 2 else {
            return .error(400, "条目路径要以页段数开头（十进制 ≥ 2）")
        }
        guard parts.count > pageCount + 1 else { return .error(400, "条目路径不完整") }
        let pagePath = parts[1...pageCount].joined(separator: "/")
        guard WikiStore.isValidPagePath(pagePath) else { return .error(400, "页路径不合法") }
        let cardKey = parts[(pageCount + 1)...].joined(separator: "/")
        guard cardKey.hasPrefix("memory/") else {
            // 成功切分只看段数；`memory/` 只用来分错误：页段数写错时卡一半可能还留着 `memory/`，
            // 完全没有 `memory/` 段则不是卡引用（保持旧文案）。
            if cardKey.contains("memory/") { return .error(400, "页段数与卡路径不匹配") }
            return .error(404, "原文层暂不支持这种条目（缺 memory/ 卡路径）")
        }
        guard let ref = CatalogRecallIndexStore.reference(cardKey) else { return .error(400, "条目键要 <卡路径>|<版本>") }
        let safe = safeWiki()
        guard safe.refused == nil else { return .error(500, safe.refused ?? "wiki 根不可信") }
        guard let page = safe.pages.first(where: { $0.path == pagePath }) else { return .error(404, "没有这一页") }
        let target = RecallWikiCardTarget(
            page: RecallWikiPageTarget(profileId: config.profileId, path: pagePath, version: page.version),
            path: ref.path, version: ref.version)
        let reader = RecallWikiReader(profileId: config.profileId, memoryRoot: config.floor, userName: "", resolveCurrent: nil)
        switch reader.original(wiki: wiki, target: target) {
        case .value(let original):
            var object: [String: Any] = [
                "target": [
                    "page": ["profileId": target.page.profileId, "path": target.page.path, "version": target.page.version as Any],
                    "path": target.path,
                    "version": target.version,
                ],
            ]
            if let current = original.currentVersion { object["currentVersion"] = current }
            if let missing = original.missingOriginal { object["missing"] = String(describing: missing) } else { object["missing"] = NSNull() }
            if let text = original.text {
                object["text"] = text.text
                object["offset"] = text.offset
                object["complete"] = text.complete
            }
            // 一期只返回首 3000 字（`RecallWikiReader` 的翻页游标不接续读入口）：`complete == false` 时由 web 标注未完
            return .json(object)
        case .stale:
            return .error(409, "页已改版，请从该页重新定位")
        case .unavailable:
            return .error(404, "页或该条目不可用")
        case .invalidTarget:
            return .error(400, "目标不合法")
        }
    }
}

/// memoryd 的通用错误
enum MemorydError: LocalizedError {
    case noWiki
    case noModelCall
    case noRecallFloor
    case notMounted(String)

    var errorDescription: String? {
        switch self {
        case .noWiki: return "副本里没有 wiki/"
        case .noModelCall: return "memoryd v1 不调模型"
        case .noRecallFloor: return "memoryd 资源里缺 memory-bench-recall-floor-xingyan.json"
        case .notMounted(let path):
            return "\(path) 不是 memoryd-mount.sh 做的副本（缺 \(MemorydService.mountMarkerName)）；不碰真楼层，先用 scripts/memoryd-mount.sh 拷一份"
        }
    }
}

/// 一次打分里所有裁判调用的记账
final class ScoreMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var input = 0
    private var output = 0

    func add(_ usage: MemoryBenchUsage?) {
        lock.withLock {
            calls += 1
            input += usage?.input ?? 0
            output += usage?.output ?? 0
        }
    }

    var totals: (calls: Int, input: Int, output: Int) { lock.withLock { (calls, input, output) } }
}

/// 监听端口存这里：`start()` 是同步的，要在同一时刻把端口给到 actor 里的 `respond`
final class BoundPort: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?

    func set(_ port: UInt16) {
        lock.withLock { value = port }
    }

    var port: UInt16? {
        lock.withLock { value }
    }
}

extension MemorydService: HTTPResponder {}
