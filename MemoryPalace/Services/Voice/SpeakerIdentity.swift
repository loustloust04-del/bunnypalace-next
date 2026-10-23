import Foundation
import CryptoKit
import SherpaOnnx
import SherpaOnnxC

enum SpeakerRole: String, Codable, Sendable { case owner, familiar }
struct SpeakerIdentity: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: SpeakerRole
    var vectors: [[Float]] = []
    var sampleHashes: [String] = []
    var ready: Bool { vectors.count >= 10 }
}
struct SpeakerMatch: Equatable, Sendable {
    enum Status: String, Sendable { case matched, likely, unknown, ambiguous, unavailable }
    let status: Status
    var name: String?
    var generation: Int?
    var cue: String? {
        switch status {
        case .matched: name.map { "[说话人线索·本机声纹估计] 声音接近已录入的「\($0)」。仅作关系线索，不是身份认证。" }
        case .likely: name.map { "[说话人线索·不确定] 可能接近「\($0)」，不要据此更换身份或读取其他人的私密记忆。" }
        case .ambiguous: "[说话人线索] 与多份已录入档案相近，无法确定是谁，不要猜名字。"
        case .unknown: "[说话人线索] 没有匹配到已录入档案，不要据此猜名字。"
        case .unavailable: nil
        }
    }
}

enum SpeakerMatcher {
    static func normalized(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty, v.count <= 1024, v.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(v.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0.000001 else { return nil }
        return v.map { Float(Double($0) / norm) }
    }
    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in sum.indices { sum[i] += v[i] / Float(vectors.count) } }
        return normalized(sum)
    }
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        return zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
    static func threshold(_ vectors: [[Float]]) -> Float {
        let scores = vectors.indices.compactMap { i -> Float? in
            guard let mean = centroid(vectors.enumerated().filter { $0.offset != i }.map(\.element)) else { return nil }
            return similarity(vectors[i], mean)
        }.sorted()
        guard !scores.isEmpty else { return 1 }
        return min(0.92, max(0.55, scores[max(0, scores.count / 10 - 1)] - 0.05))
    }
    static func match(_ vector: [Float], identities: [SpeakerIdentity]) -> SpeakerMatch {
        guard let v = normalized(vector) else { return SpeakerMatch(status: .unavailable) }
        let scores = identities.filter(\.ready).compactMap { p -> (SpeakerIdentity, Float, Float)? in
            guard let c = centroid(p.vectors), c.count == v.count else { return nil }
            return (p, similarity(v, c), threshold(p.vectors))
        }.sorted { $0.1 > $1.1 }
        guard let best = scores.first else { return SpeakerMatch(status: .unavailable) }
        if scores.count > 1, scores[1].1 >= scores[1].2 - 0.1, best.1 - scores[1].1 < 0.04 {
            return SpeakerMatch(status: .ambiguous)
        }
        if best.1 >= best.2 { return SpeakerMatch(status: .matched, name: best.0.name) }
        if best.1 >= best.2 - 0.1 { return SpeakerMatch(status: .likely, name: best.0.name) }
        return SpeakerMatch(status: .unknown)
    }
}

enum SpeakerIdentityError: LocalizedError {
    case noModel, badModel, resetRequired, badSample, duplicate, full, damaged
    var errorDescription: String? {
        switch self {
        case .noModel: "先导入兼容的 ONNX 声纹模型"
        case .badModel: "模型无法使用，需要 Sherpa 兼容的说话人 embedding ONNX 模型（最多 128 MiB）"
        case .resetRequired: "更换模型需要清空旧声纹档案并重新录入"
        case .badSample: "这段录音不适合录入，请用一至三十秒、清晰且只有一个人说话的录音"
        case .duplicate: "这段录音已经录入，请换一段不同时间或距离的自然说话"
        case .full: "最多一位本人、三位熟人；每人最多二十段"
        case .damaged: "声纹档案损坏，未覆盖原文件"
        }
    }
}

actor SpeakerIdentityStore {
    nonisolated static let enabledKey = "speakerIdentity.enabled.v1"
    static let shared = SpeakerIdentityStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MemoryPalace/speaker-identities", isDirectory: true))
    private let root: URL
    private var extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper?
    private var loadedHash: String?
    private var epoch = 0
    private struct Database: Codable {
        var version = 1
        var modelHash: String?
        var modelName: String?
        var people: [SpeakerIdentity] = []
    }
    init(root: URL) { self.root = root.resolvingSymlinksInPath() }
    private var index: URL { root.appendingPathComponent("identities.json") }
    private var model: URL { root.appendingPathComponent("speaker.onnx") }
    private func read() throws -> Database {
        guard FileManager.default.fileExists(atPath: index.path) else { return Database() }
        guard let values = try? index.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024,
              let db = try? JSONDecoder().decode(Database.self, from: Data(contentsOf: index)),
              db.version == 1, db.people.count <= 4,
              db.people.filter({ $0.role == .owner }).count <= 1,
              db.people.filter({ $0.role == .familiar }).count <= 3,
              db.people.allSatisfy({ $0.vectors.count <= 20 && $0.vectors.count == $0.sampleHashes.count
                  && $0.vectors.allSatisfy({ SpeakerMatcher.normalized($0) != nil }) }) else { throw SpeakerIdentityError.damaged }
        return db
    }
    private func write(_ db: Database) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(db).write(to: index, options: .atomic)
    }
    func identities() throws -> [SpeakerIdentity] { try read().people }
    func modelName() throws -> String? { try read().modelName }
    func invalidatePending() { epoch &+= 1 }
    func isCurrent(_ result: SpeakerMatch) -> Bool { result.generation == epoch }
    func resetAll() throws {
        extractor = nil; loadedHash = nil; epoch &+= 1
        // 只清这个模块的两个文件，不递归删除应用目录。
        for url in [index, model] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func add(name: String, role: SpeakerRole) throws {
        var db = try read()
        guard db.modelHash != nil else { throw SpeakerIdentityError.noModel }
        let label = String(name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(40))
        guard !label.isEmpty else { throw SpeakerIdentityError.badSample }
        guard db.people.filter({ $0.role == role }).count < (role == .owner ? 1 : 3) else { throw SpeakerIdentityError.full }
        db.people.append(SpeakerIdentity(id: UUID().uuidString, name: label, role: role))
        try write(db)
    }
    func remove(id: String) throws {
        var db = try read(); db.people.removeAll { $0.id == id }; try write(db); epoch &+= 1
    }
    func importModel(_ url: URL, reset: Bool) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "onnx",
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 128 * 1024 * 1024 else { throw SpeakerIdentityError.badModel }
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var db = try read()
        if db.modelHash != hash, !db.people.isEmpty, !reset { throw SpeakerIdentityError.resetRequired }
        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: url.path, numThreads: 1)
        let probe = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
        guard probe.impl != nil, (1...1024).contains(probe.dim) else { throw SpeakerIdentityError.badModel }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = FileManager.default.fileExists(atPath: model.path) ? try Data(contentsOf: model) : nil
        try data.write(to: model, options: .atomic)
        if db.modelHash != hash { db.people = [] }
        db.modelHash = hash; db.modelName = String(url.deletingPathExtension().lastPathComponent.prefix(80))
        do { try write(db) }
        catch {
            if let previous { try? previous.write(to: model, options: .atomic) } else { try? FileManager.default.removeItem(at: model) }
            throw error
        }
        extractor = nil; loadedHash = nil; epoch &+= 1
    }
    private func embed(_ samples: [Float], db: Database) throws -> [Float] {
        guard let hash = db.modelHash, FileManager.default.fileExists(atPath: model.path) else { throw SpeakerIdentityError.noModel }
        if loadedHash != hash || extractor == nil {
            guard try model.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SpeakerIdentityError.badModel }
            let actual = SHA256.hash(data: try Data(contentsOf: model)).map { String(format: "%02x", $0) }.joined()
            guard actual == hash else { throw SpeakerIdentityError.badModel }
            var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model.path, numThreads: 1)
            let candidate = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
            guard candidate.impl != nil, (1...1024).contains(candidate.dim) else { throw SpeakerIdentityError.badModel }
            extractor = candidate; loadedHash = hash
        }
        guard let extractor else { throw SpeakerIdentityError.noModel }
        let stream = extractor.createStream()
        guard stream.impl != nil else { throw SpeakerIdentityError.badSample }
        stream.acceptWaveform(samples: samples, sampleRate: 16_000)
        stream.inputFinished()
        guard extractor.isReady(stream: stream),
              let raw = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor.impl, stream.impl) else { throw SpeakerIdentityError.badSample }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(raw) }
        guard let result = SpeakerMatcher.normalized(Array(UnsafeBufferPointer(start: raw, count: extractor.dim))) else { throw SpeakerIdentityError.badSample }
        return result
    }
    private func samples(_ url: URL) async throws -> [Float] {
        let data = try await VoiceEffectAudio.decode(url, maxDuration: 30, outputSampleRate: 16_000)
        let rms = sqrt(data.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(max(1, data.count)))
        guard data.count >= 16_000, rms >= 0.002,
              Double(data.filter { abs($0) >= 0.99 }.count) / Double(data.count) < 0.01 else { throw SpeakerIdentityError.badSample }
        return data
    }
    func enroll(url: URL, id: String) async throws {
        let ticket = epoch, initial = try read()
        guard let person = initial.people.first(where: { $0.id == id }), person.vectors.count < 20 else { throw SpeakerIdentityError.full }
        let frames = try await samples(url)
        try Task.checkCancellation()
        guard ticket == epoch else { throw CancellationError() }
        var db = try read()
        guard let i = db.people.firstIndex(where: { $0.id == id }), db.people[i].vectors.count < 20 else { throw SpeakerIdentityError.full }
        let hash = frames.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
        guard !db.people[i].sampleHashes.contains(hash) else { throw SpeakerIdentityError.duplicate }
        let vector = try embed(frames, db: db)
        try Task.checkCancellation()
        guard db.people[i].vectors.allSatisfy({ $0.count == vector.count }) else { throw SpeakerIdentityError.badModel }
        db.people[i].vectors.append(vector); db.people[i].sampleHashes.append(hash); try write(db)
    }
    func recognize(url: URL) async -> SpeakerMatch {
        let ticket = epoch
        do {
            guard try read().people.contains(where: \.ready) else { return SpeakerMatch(status: .unavailable) }
            let frames = try await samples(url)
            try Task.checkCancellation()
            guard ticket == epoch else { return SpeakerMatch(status: .unavailable) }
            let db = try read()
            var result = SpeakerMatcher.match(try embed(frames, db: db), identities: db.people)
            result.generation = ticket
            return result
        } catch { return SpeakerMatch(status: .unavailable) }
    }
}
