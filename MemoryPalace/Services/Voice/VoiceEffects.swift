import Foundation
import AVFoundation
import CoreMedia
import ZIPFoundation

/// 组的用法：插入 = 台词之间插一段（多选随机）；垫底 = 垫在后续台词底下直到关掉（单选、循环）
enum VoiceEffectMode: String, Codable, CaseIterable, Sendable {
    case insert, bed
    var title: String { self == .insert ? "插入" : "垫底" }
    var maxDuration: Double { self == .insert ? 10 : 60 }
}

struct VoiceEffectGroupSettings: Codable, Hashable, Sendable {
    var mode: VoiceEffectMode
    /// 相对组文件夹的路径（`深/亲4.wav`）；旧版 UUID 引用经 legacy 表解析，设置页打开时改写成路径
    var selected: [String] = []
    var db = -18.0

    private enum CodingKeys: String, CodingKey { case mode, selected, db }
    init(mode: VoiceEffectMode, selected: [String] = [], db: Double = -18) {
        self.mode = mode; self.selected = selected; self.db = db
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(VoiceEffectMode.self, forKey: .mode)) ?? .insert
        selected = try c.decodeIfPresent([String].self, forKey: .selected) ?? []
        db = try c.decodeIfPresent(Double.self, forKey: .db) ?? -18
    }

    /// 已选素材所在的种类（组下一层子文件夹）
    var kinds: [String] {
        Array(Set(selected.compactMap(VoiceEffectClip.kind(of:)))).sorted()
    }
}

struct VoiceEffectConfiguration: Codable, Hashable, Sendable {
    static let kissGroup = "亲吻", waterGroup = "水声"
    var enabled = false
    var callEnabled = false
    /// 组名（`音效/` 下的文件夹名）→ 用法 / 已选 / 音量
    var groups: [String: VoiceEffectGroupSettings] = [:]

    private enum CodingKeys: String, CodingKey { case enabled, callEnabled, groups, kissIDs, waterID, waterDB }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        callEnabled = try c.decodeIfPresent(Bool.self, forKey: .callEnabled) ?? false
        groups = try c.decodeIfPresent([String: VoiceEffectGroupSettings].self, forKey: .groups) ?? [:]
        // 老字段只读：并进预置两组，新结构里已有就不覆盖
        let kissIDs = try c.decodeIfPresent([String].self, forKey: .kissIDs) ?? []
        let waterID = try c.decodeIfPresent(String.self, forKey: .waterID)
        let waterDB = try c.decodeIfPresent(Double.self, forKey: .waterDB)
        if groups[Self.kissGroup] == nil, !kissIDs.isEmpty { groups[Self.kissGroup] = .init(mode: .insert, selected: kissIDs) }
        if groups[Self.waterGroup] == nil, let waterID {
            groups[Self.waterGroup] = .init(mode: .bed, selected: [waterID], db: waterDB ?? -18)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(callEnabled, forKey: .callEnabled)
        try c.encode(groups, forKey: .groups)
    }

    /// 老接口：亲吻 / 水声两组的已选与音量
    var kissIDs: [String] {
        get { groups[Self.kissGroup]?.selected ?? [] }
        set { groups[Self.kissGroup, default: .init(mode: .insert)].selected = newValue }
    }
    var waterID: String? {
        get { groups[Self.waterGroup]?.selected.first }
        set { groups[Self.waterGroup, default: .init(mode: .bed)].selected = newValue.map { [$0] } ?? [] }
    }
    var waterDB: Double {
        get { groups[Self.waterGroup]?.db ?? -18 }
        set { groups[Self.waterGroup, default: .init(mode: .bed)].db = newValue }
    }

    /// 标记里的组名 → 配置里的组：两边空格忽略、不分大小写；kiss / water 是亲吻 / 水声的别名
    func groupName(for raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if groups[name] != nil { return name }
        if let hit = groups.keys.sorted().first(where: { $0.lowercased() == name.lowercased() }) { return hit }
        let alias = ["kiss": Self.kissGroup, "water": Self.waterGroup][name.lowercased()]
        return alias.flatMap { groups[$0] == nil ? nil : $0 }
    }

    /// 有勾选素材的组：亲吻、水声在前（金样顺序），其余按名字
    var activeGroups: [(name: String, settings: VoiceEffectGroupSettings)] {
        func rank(_ name: String) -> Int { name == Self.kissGroup ? 0 : name == Self.waterGroup ? 1 : 2 }
        return groups.filter { !$0.value.selected.isEmpty }
            .sorted { rank($0.key) != rank($1.key) ? rank($0.key) < rank($1.key) : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private static func kindHint(_ name: String, _ group: VoiceEffectGroupSettings) -> String {
        let kinds = group.kinds
        return kinds.isEmpty ? "" : "可指定种类：" + kinds.map { "[sfx:\(name):\($0)]" }.joined(separator: " ") + "，不指定就随机。"
    }

    var promptHint: String? {
        let active = activeGroups
        guard enabled, !active.isEmpty else { return nil }
        var lines = ["<本机音效>", "以下标记写在 voice 脚本中，由本机处理，不是要念的台词；缺素材时忽略，不要把标记解释成声音。"]
        for (name, group) in active {
            switch (name, group.mode) {
            case (Self.kissGroup, .insert): lines.append("[sfx:kiss] 插入一段已选亲吻片段，一条最多一两下；它是独立片段，别用普通的亲字代替标记。" + Self.kindHint(name, group))
            case (Self.waterGroup, .bed): lines.append("[sfx:water] 开始给后续台词垫水声，[/sfx:water] 结束；一条语音条最多垫一段水声，开一次关一次，不要整段都垫。")
            case (_, .insert): lines.append("[sfx:\(name)] 插入一段「\(name)」音效，一条最多一两下。" + Self.kindHint(name, group))
            case (_, .bed): lines.append("[sfx:\(name)] 开始给后续台词垫「\(name)」，[/sfx:\(name)] 结束；一条最多垫一段，开一次关一次。")
            }
        }
        return (lines + ["</本机音效>"]).joined(separator: "\n") + "\n"
    }

    var callActive: Bool { enabled && callEnabled && !activeGroups.isEmpty }
    var callHint: String? {
        guard callActive else { return nil }
        var hints = ["本通电话支持本机音效。标记写在普通回复里，不要包 voice 代码块，也不要念出标记。"]
        for (name, group) in activeGroups {
            switch (name, group.mode) {
            case (Self.kissGroup, .insert): hints.append("[sfx:kiss] 插入已选亲吻片段。" + Self.kindHint(name, group))
            case (Self.waterGroup, .bed): hints.append("[sfx:water] 给后续台词垫水声，[/sfx:water] 结束；缺素材就忽略。")
            case (_, .insert): hints.append("[sfx:\(name)] 插入「\(name)」音效。" + Self.kindHint(name, group))
            case (_, .bed): hints.append("[sfx:\(name)] 给后续台词垫「\(name)」，[/sfx:\(name)] 结束。")
            }
        }
        return hints.joined(separator: " ")
    }
}

/// 一段素材 = `音效/<组>/[<种类>/]<名字>.wav`；文件夹是真相源，没有清单
struct VoiceEffectClip: Hashable, Identifiable, Sendable {
    let group: String
    /// 相对组文件夹
    let path: String
    let duration: Double
    let byteCount: Int
    /// 非 nil = 标灰、不参与播放（读不了 / 太长 / 超上限）
    var issue: String?
    var id: String { group + "/" + path }
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var kind: String? { Self.kind(of: path) }
    static func kind(of path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count == 2 ? String(parts[0]) : nil
    }
}

struct VoiceEffectGroup: Hashable, Identifiable, Sendable {
    let name: String
    let clips: [VoiceEffectClip]
    /// 组下一层子文件夹（含空的）
    let kinds: [String]
    var id: String { name }
    /// 设置里还没配过：亲吻 / 水声按预置，其余按最长那段猜（都 ≤10 秒 → 插入）
    var guessedMode: VoiceEffectMode {
        if name == VoiceEffectConfiguration.kissGroup { return .insert }
        if name == VoiceEffectConfiguration.waterGroup { return .bed }
        let longest = clips.filter { $0.issue == nil }.map(\.duration).max() ?? 0
        return longest > VoiceEffectMode.insert.maxDuration + 0.05 ? .bed : .insert
    }
}

enum VoiceEffectError: LocalizedError {
    case badAudio, tooLarge, full, brokenIndex, noAudio, badArchive, badName, exists, notFound
    var errorDescription: String? {
        switch self {
        case .badAudio: "音频无法读取，或没有可用声音"
        case .tooLarge: "音频太长或太大（插入最多十秒，垫底最多一分钟，源文件最多十 MB）"
        case .full: "本楼层音效已满（最多十六组、每组六十四段、共六十四 MB）"
        case .brokenIndex: "「音效」文件夹不可用（是链接或越界），请在文件库里检查"
        case .noAudio: "脚本没有可用台词或音效"
        case .badArchive: "压缩包无法读取、含越界路径，或超过上限（最多六十四个文件、六十四 MB）"
        case .badName: "名字不能为空、最多四十字，不能含 / \\ : [ ]，也不能以 . 开头"
        case .exists: "已经有同名的组或文件"
        case .notFound: "文件找不到了，可能在文件库里改名或删掉了"
        }
    }
}

enum VoiceEffectScript {
    /// bed = 垫在这段台词底下的组；insert = 插一段（组、种类）
    enum Part: Equatable { case speech(String, bed: String?), insert(String, kind: String?) }
    private static let markers = try! NSRegularExpression(pattern: "\\[(/?sfx:[^\\]\\r\\n]*)\\]", options: [.caseInsensitive])
    private static let dangling = try! NSRegularExpression(pattern: "\\[/?sfx:[^\\]\\r\\n]*$", options: [.caseInsensitive])

    /// `sfx:亲吻:深` / `/sfx:雨声` → (关?, 组, 种类)
    private static func cue(_ body: String) -> (close: Bool, group: String, kind: String?)? {
        let close = body.hasPrefix("/")
        let rest = body.dropFirst(close ? 5 : 4)  // 前缀已由正则保证是 sfx:（不分大小写）
        let fields = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let group = fields.first, !group.isEmpty else { return nil }
        return (close, group, fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil)
    }

    static func parts(_ text: String, configuration: VoiceEffectConfiguration) -> [Part] {
        let source = text as NSString
        var result: [Part] = [], bed: String?, offset = 0
        func speech(_ range: NSRange) {
            let raw = source.substring(with: range)
            let ns = raw as NSString
            let cleaned = dangling.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.speech(cleaned, bed: bed)) }
        }
        for match in markers.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            speech(NSRange(location: offset, length: match.range.location - offset))
            // 保留命名空间：未知组 / 没配的组也不能送去念
            if let cue = cue(source.substring(with: match.range(at: 1))),
               let name = configuration.groupName(for: cue.group), let mode = configuration.groups[name]?.mode {
                switch (cue.close, mode) {
                case (false, .insert): result.append(.insert(name, kind: cue.kind))
                case (false, .bed): bed = name  // 同一时刻只垫一层：开新的就换掉旧的
                case (true, .bed): if bed == name { bed = nil }
                case (true, .insert): break
                }
            }
            offset = NSMaxRange(match.range)
        }
        speech(NSRange(location: offset, length: source.length - offset))
        return result
    }

    static func textOnly(_ script: String) -> String {
        parts(script, configuration: .init()).compactMap { if case .speech(let text, _) = $0 { return text }; return nil }.joined()
    }

    /// 通话按句合成：这句念完后开着的是哪一组垫底
    static func bedState(after text: String, starting: String?, configuration: VoiceEffectConfiguration) -> String? {
        var bed = starting
        let ns = text as NSString
        for match in markers.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let cue = cue(ns.substring(with: match.range(at: 1))),
                  let name = configuration.groupName(for: cue.group), configuration.groups[name]?.mode == .bed else { continue }
            if !cue.close { bed = name } else if bed == name { bed = nil }
        }
        return bed
    }
}

/// 文件解码与混音全部在后台执行；样本数有硬上限，不依赖容器报的时长阻止解压膨胀。
enum VoiceEffectAudio {
    static let sampleRate = 24_000

    static func decode(_ url: URL, maxDuration: Double, outputSampleRate: Int = sampleRate) async throws -> [Float] {
        guard maxDuration.isFinite, maxDuration > 0, maxDuration <= 600,
              [16_000, 24_000].contains(outputSampleRate) else { throw VoiceEffectError.badAudio }
        let task = Task.detached(priority: .utility) { () throws -> [Float] in
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= maxDuration else { throw VoiceEffectError.tooLarge }
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw VoiceEffectError.badAudio }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: outputSampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw VoiceEffectError.badAudio }
            reader.add(output)
            guard reader.startReading() else { throw VoiceEffectError.badAudio }
            defer { reader.cancelReading() }
            var samples: [Float] = []
            let limit = Int(maxDuration * Double(outputSampleRate)) + 1024
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw VoiceEffectError.badAudio }
                let size = CMBlockBufferGetDataLength(block)
                guard size.isMultiple(of: 4), samples.count + size / 4 <= limit else { throw VoiceEffectError.tooLarge }
                if size == 0 { continue }
                var chunk = [Float](repeating: 0, count: size / 4)
                let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: base)
                }
                guard status == 0, chunk.allSatisfy(\.isFinite) else { throw VoiceEffectError.badAudio }
                samples.append(contentsOf: chunk)
            }
            guard reader.status == .completed, !samples.isEmpty else { throw VoiceEffectError.badAudio }
            return samples
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func decode(_ clip: AudioClip, maxDuration: Double = 180) async throws -> [Float] {
        guard clip.data.count <= 32 * 1024 * 1024 else { throw VoiceEffectError.tooLarge }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-effects-\(UUID().uuidString).wav")
        try clip.playableData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await decode(url, maxDuration: maxDuration)
    }

    static func faded(_ samples: [Float]) -> [Float] {
        var result = samples
        let n = min(sampleRate / 100, samples.count / 2)  // 10ms 接缝包络，短片段不越界
        guard n > 0 else { return result }
        for i in 0..<n {
            let gain = Float(i) / Float(n)
            result[i] *= gain
            result[result.count - 1 - i] *= gain
        }
        return result
    }

    static func mix(_ voice: [Float], water: [Float], db: Double) -> [Float] {
        guard !voice.isEmpty, !water.isEmpty else { return voice }
        let voicePeak = voice.reduce(Float(0)) { max($0, abs($1)) }
        let waterPeak = water.reduce(Float(0)) { max($0, abs($1)) }
        guard waterPeak > 0 else { return voice }
        let level = db.isFinite ? min(-6, max(-30, db)) : -18
        let gain = voicePeak / waterPeak * Float(pow(10, level / 20))
        var mixed = voice.enumerated().map { $0.element + water[$0.offset % water.count] * gain }
        let peak = mixed.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0.98 { for i in mixed.indices { mixed[i] *= 0.98 / peak } }
        return mixed
    }

    /// 我们写出的 24k 单声道 PCM16 WAV：看头 44 字节 + 文件总长，合格就给时长（秒）。扫描文件夹只读头，不读全文件
    static func canonicalDuration(header: Data, fileSize: Int) -> Double? {
        let data = Data(header.prefix(44))
        guard data.count == 44, fileSize >= 44, fileSize <= 10 * 1024 * 1024 else { return nil }
        let ok = data.withUnsafeBytes { raw -> Bool in
            func u16(_ i: Int) -> UInt16 { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt16.self)) }
            func u32(_ i: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)) }
            return data.prefix(4) == Data("RIFF".utf8) && data[8..<16] == Data("WAVEfmt ".utf8)
                && data[36..<40] == Data("data".utf8) && u32(16) == 16 && u16(20) == 1
                && u16(22) == 1 && u32(24) == sampleRate && u16(34) == 16
                && Int(u32(40)) == fileSize - 44 && (fileSize - 44).isMultiple(of: 2)
        }
        return ok ? Double(fileSize - 44) / 2 / Double(sampleRate) : nil
    }

    /// 仅解我们自己写出的 24k 单声道 PCM16 WAV，避免将其他 WAV 布局误作样本。
    static func canonicalSamples(_ data: Data) throws -> [Float] {
        guard canonicalDuration(header: data, fileSize: data.count) != nil else { throw VoiceEffectError.badAudio }
        return data.withUnsafeBytes { raw in
            stride(from: 44, to: data.count, by: 2).map {
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32768
            }
        }
    }
}

/// 批量导入用：把 zip 里的音频解到 dir（调用方负责删 dir），逐个再走 importAudio。
enum VoiceEffectZip {
    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "caf", "aif", "aiff", "aifc", "flac"]

    static func extractAudio(_ zip: URL, to dir: URL, maxBytes: Int = 64 * 1024 * 1024, maxCount: Int = 64) throws -> [URL] {
        try extractAudioEntries(zip, to: dir, maxBytes: maxBytes, maxCount: maxCount).map(\.url)
    }

    /// 同上，另带每个文件在 zip 里的路径（导进插入组时一层子文件夹 → 种类）
    static func extractAudioEntries(_ zip: URL, to dir: URL, maxBytes: Int = 64 * 1024 * 1024, maxCount: Int = 64) throws -> [(url: URL, path: String)] {
        let archive: Archive
        do { archive = try Archive(url: zip, accessMode: .read) } catch { throw VoiceEffectError.badArchive }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [(url: URL, path: String)] = [], total = 0
        for entry in archive {
            // Finder 压缩的中文名不设 UTF-8 标志位：名字是合法 UTF-8 就按 UTF-8，否则退回 ZIPFoundation 的解码
            let utf8Path = entry.path(using: .utf8)
            let path = (utf8Path.isEmpty ? entry.path : utf8Path).replacingOccurrences(of: "\\", with: "/")
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !parts.contains("..") else { throw VoiceEffectError.badArchive }
            guard entry.type == .file, let name = parts.last.map(String.init), !name.hasPrefix("."),
                  !parts.contains("__MACOSX"), audioExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            guard urls.count < maxCount else { throw VoiceEffectError.badArchive }
            // 每个文件单独一层目录：同名不撞，原名留给素材显示名；名字过长就退回序号
            let folder = dir.appendingPathComponent(String(urls.count), isDirectory: true)
            let safeName = name.utf8.count <= 200 ? name : "\(urls.count).\((name as NSString).pathExtension)"
            let target = folder.appendingPathComponent(safeName)
            guard target.standardized.path.hasPrefix(dir.standardized.path + "/") else { throw VoiceEffectError.badArchive }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    // 头里声明的大小可能是假的，按实际解出的字节计
                    total += chunk.count
                    guard total <= maxBytes else { throw VoiceEffectError.badArchive }
                    data.append(chunk)
                }
            } catch { throw VoiceEffectError.badArchive }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: target)
            urls.append((target, path))
        }
        return urls
    }

    /// zip 内路径 → 种类：只认一层子文件夹；整包外面套了同一层文件夹（Finder 压缩文件夹）就先剥掉
    static func kinds(_ paths: [String]) -> [String?] {
        var split = paths.map { $0.split(separator: "/").map(String.init) }
        if let first = split.first?.first, split.allSatisfy({ $0.count > 1 && $0[0] == first }) {
            split = split.map { Array($0.dropFirst()) }
        }
        return split.map { $0.count == 2 ? VoiceEffectLibrary.validName($0[0]) : nil }
    }
}

/// 楼层文件库 `音效/<组>/[<种类>/]<名字>.wav`：文件夹是真相源，在文件库 / 访达里改名、删除、挪动，下次扫描就跟着变。
/// 只播我们写出的 24k 单声道 WAV；别的音频扫描时就地转换，读不了 / 太长的标灰。
actor VoiceEffectLibrary {
    static let folderName = "音效"
    static let maxGroups = 16, maxClipsPerGroup = 64
    static let maxTotalBytes = 64 * 1024 * 1024, maxFileBytes = 10 * 1024 * 1024
    static let shared = VoiceEffectLibrary(base: { FileLibraryStore.filesystemRoot(profileId: $0) },
                                           metadata: { FileLibraryStore.metadataDirectory(profileId: $0) })
    private let base: @Sendable (String) -> URL
    private let metadata: @Sendable (String) -> URL
    private var recent: [String: [String]] = [:]
    private var migrated: Set<String> = []
    private var legacy: [String: [String: String]] = [:]
    /// 转换失败的（按大小 + 修改时间）不每次重解
    private var failed: [String: (stamp: String, issue: String)] = [:]
    private var converting: Set<String> = []
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    init(base: @escaping @Sendable (String) -> URL, metadata: (@Sendable (String) -> URL)? = nil) {
        self.base = base
        self.metadata = metadata ?? { base($0).appendingPathComponent(".memorypalace", isDirectory: true) }
    }

    // MARK: 名字与路径

    /// 组名 / 种类名：一层、写得进标记（不含 / \ : [ ] 换行），不以 . 开头，最多 40 字
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let banned = CharacterSet(charactersIn: "/\\:[]").union(.newlines).union(.controlCharacters)
        guard !name.isEmpty, name.count <= 40, !name.hasPrefix("."), name.rangeOfCharacter(from: banned) == nil else { return nil }
        return name
    }

    /// 显示名 → 文件名主干：去路径符 / 开头的点 / 换行，最多 200 字节（留出 ` (2).wav`）
    static func baseName(_ raw: String) -> String {
        let name = raw.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.newlines).union(.controlCharacters))
            .joined(separator: " ").drop(while: { $0 == "." || $0.isWhitespace })
        var out = ""
        for ch in name {
            guard out.utf8.count + String(ch).utf8.count <= 200 else { break }
            out.append(ch)
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "素材" : out
    }

    private static func values(_ url: URL) -> URLResourceValues? { try? url.resourceValues(forKeys: Set(keys)) }
    private static func isFolder(_ url: URL) -> Bool {
        let v = values(url)
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }
    private static func isAudioFile(_ url: URL) -> Bool {
        values(url)?.isRegularFile == true && VoiceEffectZip.audioExtensions.contains(url.pathExtension.lowercased())
    }
    /// 一层里的条目：跳过隐藏文件和链接
    private static func children(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .filter { values($0)?.isSymbolicLink != true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private static func subfolders(_ dir: URL) -> [URL] {
        children(dir).filter { isFolder($0) && validName($0.lastPathComponent) == $0.lastPathComponent }
    }

    /// `音效/`：本身或上层是链接 → 整区拒绝
    private func root(_ profileID: String) throws -> URL {
        let dir = base(profileID).resolvingSymlinksInPath().appendingPathComponent(Self.folderName, isDirectory: true)
        guard dir.resolvingSymlinksInPath().standardizedFileURL.path == dir.standardizedFileURL.path else { throw VoiceEffectError.brokenIndex }
        return dir
    }

    /// 第一次建「音效」时顺手建好预置两组
    private func prepare(_ root: URL) throws {
        guard Self.values(root) == nil else { return }
        for name in [VoiceEffectConfiguration.kissGroup, VoiceEffectConfiguration.waterGroup] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        notifyFileLibrary()
    }

    /// 组 / 种类文件夹：名字只能一层，已存在的不能是链接
    private func folder(_ root: URL, _ group: String, _ kind: String? = nil, create: Bool = false) throws -> URL {
        guard Self.validName(group) == group, kind.map({ Self.validName($0) == $0 }) ?? true else { throw VoiceEffectError.badName }
        if create { try prepare(root) }
        var dir = root
        for name in [group] + (kind.map { [$0] } ?? []) {
            dir = dir.appendingPathComponent(name, isDirectory: true)
            if let v = Self.values(dir) {
                guard v.isDirectory == true, v.isSymbolicLink != true else { throw VoiceEffectError.brokenIndex }
            } else if create {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        return dir
    }

    private func fileURL(_ root: URL, group: String, path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let file = parts.last, !file.hasPrefix("."), !file.contains("\\"),
              VoiceEffectZip.audioExtensions.contains((file as NSString).pathExtension.lowercased()) else { throw VoiceEffectError.badName }
        return try folder(root, group, parts.count == 2 ? parts[0] : nil).appendingPathComponent(file)
    }

    /// `名字.wav` 被占了就 `名字 (2).wav`…
    private static func unique(_ dir: URL, _ name: String, ext: String = "wav") throws -> URL {
        for n in 1...999 {
            let url = dir.appendingPathComponent(FileLibraryStore.clampComponent((n == 1 ? name : "\(name) (\(n))") + "." + ext))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw VoiceEffectError.full
    }

    private nonisolated func notifyFileLibrary() {
        Task { @MainActor in NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil) }
    }

    // MARK: 扫描

    func groups(profileID: String) async throws -> [VoiceEffectGroup] {
        migrateIfNeeded(profileID)
        let root = try root(profileID)
        try prepare(root)
        var result: [VoiceEffectGroup] = [], total = 0
        for dir in Self.subfolders(root).prefix(Self.maxGroups) {
            let group = dir.lastPathComponent, kinds = Self.subfolders(dir)
            let entries = Self.children(dir).map { ($0, String?.none) }
                + kinds.flatMap { sub in Self.children(sub).map { ($0, Optional(sub.lastPathComponent)) } }
            var clips: [VoiceEffectClip] = [], usable = 0
            for (url, kind) in entries {
                guard var clip = await inspect(url, group: group, kind: kind) else { continue }
                if clip.issue == nil {
                    if usable >= Self.maxClipsPerGroup { clip.issue = "超过每组六十四段上限" }
                    else if total + clip.byteCount > Self.maxTotalBytes { clip.issue = "超过本楼层六十四 MB 上限" }
                    else { usable += 1; total += clip.byteCount }
                }
                clips.append(clip)
            }
            result.append(.init(name: group, clips: clips, kinds: kinds.map(\.lastPathComponent)))
        }
        return result
    }

    /// 一个文件 → 素材。标准 WAV 按大小算时长；别的音频就地转成标准 WAV；不是音频的不列
    private func inspect(_ url: URL, group: String, kind: String?) async -> VoiceEffectClip? {
        guard Self.isAudioFile(url), let size = Self.values(url)?.fileSize else { return nil }
        func clip(_ file: URL, _ bytes: Int, _ duration: Double, _ issue: String?) -> VoiceEffectClip {
            VoiceEffectClip(group: group, path: (kind.map { $0 + "/" } ?? "") + file.lastPathComponent,
                            duration: duration, byteCount: bytes, issue: issue)
        }
        guard size <= Self.maxFileBytes else { return clip(url, size, 0, "超过十 MB") }
        let isWAV = url.pathExtension.lowercased() == "wav"
        let handle = isWAV ? (try? FileHandle(forReadingFrom: url)) : nil
        let header = try? handle?.read(upToCount: 44)
        try? handle?.close()
        if let header, let duration = VoiceEffectAudio.canonicalDuration(header: header, fileSize: size) {
            return clip(url, size, duration, duration > VoiceEffectMode.bed.maxDuration + 0.05 ? "太长，最多一分钟" : nil)
        }
        let stamp = "\(size)-\(Self.values(url)?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let known = failed[url.path], known.stamp == stamp { return clip(url, size, 0, known.issue) }
        guard converting.insert(url.path).inserted else { return clip(url, size, 0, "正在转换") }
        defer { converting.remove(url.path) }
        do {
            let samples = try await VoiceEffectAudio.decode(url, maxDuration: VoiceEffectMode.bed.maxDuration)
            guard samples.contains(where: { abs($0) >= 0.0001 }) else { throw VoiceEffectError.badAudio }
            let data = WAV.encode(VoiceEffectAudio.faded(samples), sampleRate: VoiceEffectAudio.sampleRate)
            var target = url
            if !isWAV { target = try Self.unique(url.deletingLastPathComponent(), url.deletingPathExtension().lastPathComponent) }
            try data.write(to: target, options: .atomic)  // 先写好标准 WAV 再删原件
            if target != url { try? FileManager.default.removeItem(at: url) }
            notifyFileLibrary()
            return clip(target, data.count, Double(samples.count) / Double(VoiceEffectAudio.sampleRate), nil)
        } catch is CancellationError {
            return clip(url, size, 0, "正在转换")
        } catch {
            let issue = (error as? VoiceEffectError) == .tooLarge ? "太长，最多一分钟" : "读不了，或没有声音"
            failed[url.path] = (stamp, issue)
            return clip(url, size, 0, issue)
        }
    }

    private static func usage(_ root: URL) -> (groups: [String], clips: [String: Int], bytes: Int) {
        var clips: [String: Int] = [:], bytes = 0
        let groups = children(root).filter(isFolder)
        for dir in groups {
            for file in children(dir) + children(dir).filter(isFolder).flatMap(children) where isAudioFile(file) {
                clips[dir.lastPathComponent, default: 0] += 1
                bytes += values(file)?.fileSize ?? 0
            }
        }
        return (groups.map(\.lastPathComponent), clips, bytes)
    }

    // MARK: 增删改

    /// 导入一段到组（可指定种类）：原名、重名加 (2)；解码 / 淡入淡出 / 24k 单声道
    func importAudio(_ url: URL, group: String, kind: String? = nil, mode: VoiceEffectMode, profileID: String) async throws -> VoiceEffectClip {
        guard url.isFileURL,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.maxFileBytes else { throw VoiceEffectError.tooLarge }
        guard Self.validName(group) == group, kind.map({ Self.validName($0) == $0 }) ?? true else { throw VoiceEffectError.badName }
        let samples = try await VoiceEffectAudio.decode(url, maxDuration: mode.maxDuration)
        try Task.checkCancellation()
        guard samples.contains(where: { abs($0) >= 0.0001 }) else { throw VoiceEffectError.badAudio }
        let data = WAV.encode(VoiceEffectAudio.faded(samples), sampleRate: VoiceEffectAudio.sampleRate)
        migrateIfNeeded(profileID)
        let root = try root(profileID)
        let usage = Self.usage(root)
        guard usage.groups.contains(group) || usage.groups.count < Self.maxGroups,
              usage.clips[group, default: 0] < Self.maxClipsPerGroup,
              usage.bytes + data.count <= Self.maxTotalBytes else { throw VoiceEffectError.full }
        let target = try Self.unique(folder(root, group, kind, create: true), Self.baseName(url.deletingPathExtension().lastPathComponent))
        try data.write(to: target, options: .atomic)
        notifyFileLibrary()
        return VoiceEffectClip(group: group, path: (kind.map { $0 + "/" } ?? "") + target.lastPathComponent,
                               duration: Double(samples.count) / Double(VoiceEffectAudio.sampleRate), byteCount: data.count)
    }

    func createGroup(_ raw: String, profileID: String) throws -> String {
        guard let name = Self.validName(raw) else { throw VoiceEffectError.badName }
        migrateIfNeeded(profileID)
        let root = try root(profileID), groups = Self.usage(root).groups
        guard !groups.contains(where: { $0.lowercased() == name.lowercased() }) else { throw VoiceEffectError.exists }
        guard groups.count < Self.maxGroups else { throw VoiceEffectError.full }
        _ = try folder(root, name, create: true)
        notifyFileLibrary()
        return name
    }

    func renameGroup(_ old: String, to raw: String, profileID: String) throws -> String {
        guard let name = Self.validName(raw) else { throw VoiceEffectError.badName }
        let root = try root(profileID), from = try folder(root, old)
        guard Self.isFolder(from) else { throw VoiceEffectError.notFound }
        guard name != old else { return name }
        guard !Self.usage(root).groups.contains(where: { $0 != old && $0.lowercased() == name.lowercased() }) else { throw VoiceEffectError.exists }
        try FileManager.default.moveItem(at: from, to: folder(root, name))
        notifyFileLibrary()
        return name
    }

    /// 连文件一起删
    func removeGroup(_ name: String, profileID: String) throws {
        let dir = try folder(root(profileID), name)
        guard Self.isFolder(dir) else { return }
        try FileManager.default.removeItem(at: dir)
        notifyFileLibrary()
    }

    /// 改显示名（文件名主干，扩展名不变）；返回新的组内路径
    func renameClip(group: String, path: String, to raw: String, profileID: String) throws -> String {
        let from = try fileURL(root(profileID), group: group, path: path)
        guard Self.isAudioFile(from) else { throw VoiceEffectError.notFound }
        let to = from.deletingLastPathComponent()
            .appendingPathComponent(FileLibraryStore.clampComponent(Self.baseName(raw) + "." + from.pathExtension))
        guard to.lastPathComponent != from.lastPathComponent else { return path }
        guard to.lastPathComponent.lowercased() == from.lastPathComponent.lowercased()
                || !FileManager.default.fileExists(atPath: to.path) else { throw VoiceEffectError.exists }
        try FileManager.default.moveItem(at: from, to: to)
        notifyFileLibrary()
        return (path.contains("/") ? String(path.split(separator: "/")[0]) + "/" : "") + to.lastPathComponent
    }

    /// 放进种类（nil = 移出到组根）；同名加 (2)；返回新的组内路径
    func moveClip(group: String, path: String, toKind raw: String?, profileID: String) throws -> String {
        var kind: String?
        if let raw {
            guard let name = Self.validName(raw) else { throw VoiceEffectError.badName }
            kind = name
        }
        guard kind != VoiceEffectClip.kind(of: path) else { return path }
        let root = try root(profileID), from = try fileURL(root, group: group, path: path)
        guard Self.isAudioFile(from) else { throw VoiceEffectError.notFound }
        let dir = try folder(root, group, kind, create: true)
        let to = try Self.unique(dir, from.deletingPathExtension().lastPathComponent, ext: from.pathExtension)
        try FileManager.default.moveItem(at: from, to: to)
        notifyFileLibrary()
        return (kind.map { $0 + "/" } ?? "") + to.lastPathComponent
    }

    func removeClip(group: String, path: String, profileID: String) throws {
        let url = try fileURL(root(profileID), group: group, path: path)
        guard Self.isAudioFile(url) else { return }
        try FileManager.default.removeItem(at: url)
        notifyFileLibrary()
    }

    /// 访达里显示用
    func fileURL(group: String, path: String, profileID: String) -> URL? {
        guard let url = try? fileURL(root(profileID), group: group, path: path), Self.isAudioFile(url) else { return nil }
        return url
    }

    // MARK: 播放取素材

    /// 读一段标准 WAV；引用可以是组内路径或旧版 UUID
    func clip(group: String, path ref: String, profileID: String, maxDuration: Double = VoiceEffectMode.bed.maxDuration) throws -> AudioClip? {
        migrateIfNeeded(profileID)
        guard let path = resolve(ref, group: group, profileID: profileID),
              let url = try? fileURL(root(profileID), group: group, path: path),
              let v = Self.values(url), v.isRegularFile == true, v.isSymbolicLink != true,
              (v.fileSize ?? .max) <= Self.maxFileBytes else { return nil }
        let data = try Data(contentsOf: url)
        let samples = try VoiceEffectAudio.canonicalSamples(data)
        guard Double(samples.count) / Double(VoiceEffectAudio.sampleRate) <= maxDuration + 0.05 else { throw VoiceEffectError.tooLarge }
        return AudioClip(data: data, format: .wav, sampleRate: VoiceEffectAudio.sampleRate)
    }

    /// 插入组抽一段：指定种类就只从那个种类的已选里抽（一条没选 → 退回全组已选）；各自避免连着重复
    func insert(group: String, kind: String?, selected: [String], profileID: String) throws -> AudioClip? {
        migrateIfNeeded(profileID)
        let paths = selected.compactMap { resolve($0, group: group, profileID: profileID) }
        let wanted = kind?.trimmingCharacters(in: .whitespaces).lowercased()
        let inKind = wanted.map { k in paths.filter { VoiceEffectClip.kind(of: $0)?.lowercased() == k } } ?? []
        let candidates = inKind.isEmpty ? paths : inKind
        let key = [profileID, group, inKind.isEmpty ? "" : wanted ?? ""].joined(separator: "\n")
        let recentPicks = recent[key] ?? []
        let fresh = candidates.filter { !recentPicks.contains($0) }
        let avoidLast = candidates.filter { $0 != recentPicks.last }
        var pool = fresh.isEmpty ? (avoidLast.isEmpty ? candidates : avoidLast) : fresh
        while let path = pool.randomElement() {
            pool.removeAll { $0 == path }
            if let clip = try? clip(group: group, path: path, profileID: profileID, maxDuration: VoiceEffectMode.insert.maxDuration) {
                recent[key] = Array((recentPicks + [path]).suffix(5))
                return clip
            }
        }
        return nil
    }

    // MARK: 旧版迁移

    private struct LegacyIndex: Decodable {
        struct Asset: Decodable { let id: String; let name: String; let kind: String }
        let assets: [Asset]
    }

    private func legacyURL(_ profileID: String) -> URL { metadata(profileID).appendingPathComponent("voice-effects-legacy.json") }

    private func legacyTable(_ profileID: String) -> [String: String] {
        if let cached = legacy[profileID] { return cached }
        let table = (try? Data(contentsOf: legacyURL(profileID))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        legacy[profileID] = table
        return table
    }

    /// 旧 UUID → `组/文件名.wav`（相对 `音效/`），设置页拿去把配置改写成路径
    func legacyMap(profileID: String) -> [String: String] {
        migrateIfNeeded(profileID)
        return legacyTable(profileID)
    }

    /// 配置里的引用 → 组内路径：旧版 UUID 查 legacy 表，只认同组的
    private func resolve(_ ref: String, group: String, profileID: String) -> String? {
        guard UUID(uuidString: ref) != nil else { return ref }
        let parts = legacyTable(profileID)[ref]?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        return parts.count == 2 && parts[0] == group ? parts[1] : nil
    }

    /// 旧 `voice-effects/manifest.json` + `UUID.wav` → `音效/亲吻|水声/<原名>.wav`。先拷 → 表落盘 → 才删旧文件；
    /// 中途失败下次重来（同名同内容的直接复用，不多出 (2)）；清单外的文件不删，目录空了才删。任何失败都不抛。
    private func migrateIfNeeded(_ profileID: String) {
        guard migrated.insert(profileID).inserted else { return }
        let old = base(profileID).resolvingSymlinksInPath().appendingPathComponent("voice-effects", isDirectory: true)
        let manifest = old.appendingPathComponent("manifest.json")
        guard Self.isFolder(old), let root = try? root(profileID),
              let values = Self.values(manifest), values.isRegularFile == true, (values.fileSize ?? .max) <= 128 * 1024,
              let index = try? JSONDecoder().decode(LegacyIndex.self, from: Data(contentsOf: manifest)) else { return }
        var table = legacyTable(profileID), moved: [URL] = [], complete = true
        for asset in index.assets where UUID(uuidString: asset.id)?.uuidString == asset.id {
            let source = old.appendingPathComponent(asset.id + ".wav")
            if let done = table[asset.id], Self.isAudioFile(root.appendingPathComponent(done)) { moved.append(source); continue }
            guard let v = Self.values(source), v.isRegularFile == true, v.isSymbolicLink != true else { continue }  // 早没了：没得搬
            do {
                let group = asset.kind == "water" ? VoiceEffectConfiguration.waterGroup : VoiceEffectConfiguration.kissGroup
                let target = try Self.place(Data(contentsOf: source), in: folder(root, group, create: true), name: Self.baseName(asset.name))
                table[asset.id] = group + "/" + target.lastPathComponent
                moved.append(source)
            } catch { complete = false }
        }
        do {
            try FileManager.default.createDirectory(at: metadata(profileID), withIntermediateDirectories: true)
            try JSONEncoder().encode(table).write(to: legacyURL(profileID), options: .atomic)
        } catch { return }  // 表没落盘就不动旧文件
        legacy[profileID] = table
        for source in moved { try? FileManager.default.removeItem(at: source) }
        if complete { try? FileManager.default.removeItem(at: manifest) }
        if ((try? FileManager.default.contentsOfDirectory(atPath: old.path)) ?? ["?"]).allSatisfy({ $0 == ".DS_Store" }) {
            try? FileManager.default.removeItem(at: old)
        }
        notifyFileLibrary()
    }

    /// 迁移落位：同名同内容的（上次迁到一半）直接复用
    private static func place(_ data: Data, in dir: URL, name: String) throws -> URL {
        for n in 1...999 {
            let url = dir.appendingPathComponent((n == 1 ? name : "\(name) (\(n))") + ".wav")
            guard FileManager.default.fileExists(atPath: url.path) else {
                try data.write(to: url, options: .atomic)
                return url
            }
            if (try? Data(contentsOf: url)) == data { return url }
        }
        throw VoiceEffectError.full
    }
}

enum VoiceEffectsRenderer {
    private enum PreparedPart { case speech(String, bed: String?), effect([Float]) }
    /// 相邻两段人声之间的静音（120ms），替代硬接；插入片段前后不加
    static let speechGap = VoiceEffectAudio.sampleRate * 12 / 100
    static let contextLimit = 500

    static func render(_ script: String, configuration: VoiceEffectConfiguration, profileID: String,
                       library: VoiceEffectLibrary = .shared,
                       synthesize: (String, VoiceSynthesisContext?) async throws -> AudioClip) async throws -> AudioClip {
        let parts = VoiceEffectScript.parts(script, configuration: configuration)
        let requested = parts.contains { part in
            switch part { case .insert: true; case .speech(_, let bed): bed != nil }
        }
        guard configuration.enabled, requested else {
            let text = VoiceEffectScript.textOnly(script)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceEffectError.noAudio }
            return try await synthesize(text, nil)
        }
        guard parts.count <= 24 else { throw VoiceEffectError.tooLarge }
        var beds: [String: [Float]] = [:]
        for case .speech(_, let bed?) in parts where beds[bed] == nil {
            var samples: [Float] = []
            if let path = configuration.groups[bed]?.selected.first,
               let clip = try? await library.clip(group: bed, path: path, profileID: profileID) {
                samples = (try? VoiceEffectAudio.canonicalSamples(clip.data)) ?? []
            }
            beds[bed] = samples
        }
        var prepared: [PreparedPart] = [], effectFrames = 0
        for part in parts {
            try Task.checkCancellation()
            switch part {
            case .insert(let group, let kind):
                guard let clip = try? await library.insert(group: group, kind: kind, selected: configuration.groups[group]?.selected ?? [],
                                                           profileID: profileID) else { continue }
                let samples = try VoiceEffectAudio.canonicalSamples(clip.data)
                effectFrames += samples.count
                guard effectFrames <= VoiceEffectAudio.sampleRate * 180 else { throw VoiceEffectError.tooLarge }
                prepared.append(.effect(samples))
            case .speech(let text, let bed): prepared.append(.speech(text, bed: bed.flatMap { beds[$0]?.isEmpty == false ? $0 : nil }))
            }
        }
        let hasEffect = prepared.contains { part in
            switch part { case .effect: true; case .speech(_, let bed): bed != nil }
        }
        if !hasEffect {
            let text = VoiceEffectScript.textOnly(script)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceEffectError.noAudio }
            return try await synthesize(text, nil)
        }
        let speeches = prepared.compactMap { part -> String? in
            if case .speech(let text, _) = part { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
        // 连续人声段攒成一串，垫底对整串混一次：段间静音也垫着，接缝里不断；换垫底就断开另起一串
        var output: [Float] = [], run: [Float] = [], runBed: String?, afterSpeech = false, index = 0
        let gap = [Float](repeating: 0, count: speechGap)
        func flushRun() {
            if let runBed, let bed = beds[runBed] {
                output += VoiceEffectAudio.faded(VoiceEffectAudio.mix(run, water: bed, db: configuration.groups[runBed]?.db ?? -18))
            } else {
                output += run
            }
            run = []
        }
        for part in prepared {
            try Task.checkCancellation()
            switch part {
            case .effect(let effect):
                flushRun()
                output += VoiceEffectAudio.faded(effect)
                afterSpeech = false
            case .speech(let text, let useBed):
                let previous = index > 0 ? String(speeches[index - 1].suffix(contextLimit)) : ""
                let next = index + 1 < speeches.count ? String(speeches[index + 1].prefix(contextLimit)) : ""
                index += 1
                let clip = try await synthesize(text, VoiceSynthesisContext(previous: previous.isEmpty ? nil : previous,
                                                                             next: next.isEmpty ? nil : next))
                let voice = VoiceEffectAudio.faded(try await VoiceEffectAudio.decode(clip))
                if afterSpeech {
                    // 静音归有垫底的那一侧（两边都有就归前一段）
                    if useBed == runBed { run += gap } else if runBed != nil { run += gap; flushRun() } else { flushRun(); run = gap }
                }
                runBed = useBed
                run += voice
                afterSpeech = true
            }
            guard output.count + run.count <= VoiceEffectAudio.sampleRate * 180 else { throw VoiceEffectError.tooLarge }
        }
        flushRun()
        guard !output.isEmpty else { throw VoiceEffectError.noAudio }
        return AudioClip(data: WAV.encode(output, sampleRate: VoiceEffectAudio.sampleRate), format: .wav,
                         sampleRate: VoiceEffectAudio.sampleRate)
    }
}
