import Foundation

/// 测试集（plan-memory-lab-2 §1）：`<楼层记忆根>/lab/sets/<编号>.json`，一份一个文件。
///
/// 一句话在不在某份集子里，**以集子文件为准**；记录上的 `sets` 只是回指。所以每个改动都先写集子、再尽力改回指：
/// - 抛错 = 集子没动，什么都没变；
/// - 不抛 = 集子已经改好。回指没写成（那条记录是新版本写的 / 写盘失败）就留着旧的——读的时候不看它
///   （`membership` / `setSummaries` / `entries` 都只看集子），同样的操作再做一遍会把它补齐。
public extension MemoryLabStore {
    private func setURL(_ id: String) -> URL {
        setsDir.appendingPathComponent(MemoryBenchStore.fileName(id) + ".json")
    }

    private func readSet(_ url: URL) -> MemoryLabSet? {
        (try? Data(contentsOf: url)).flatMap { try? MemoryBench.decoder.decode(MemoryLabSet.self, from: $0) }
    }

    /// 整份写一份测试集（不碰记录上的回指；挑进 / 拿出用下面的 `add` / `remove`）
    func save(_ set: MemoryLabSet) throws {
        try FileManager.default.createDirectory(at: setsDir, withIntermediateDirectories: true)
        try MemoryBench.encoder.encode(set).write(to: setURL(set.id), options: .atomic)
    }

    /// 取来改：没有 / 读不成 → `missingSet`；新版本写的 → `newerSetSchema`
    private func editable(_ id: String) throws -> MemoryLabSet {
        guard let set = set(id: id) else { throw StoreError.missingSet(id) }
        guard (set.schema ?? 1) <= Self.schema else { throw StoreError.newerSetSchema(id) }
        return set
    }

    // MARK: - 读

    /// 没有 / 读不成 = nil
    func set(id: String) -> MemoryLabSet? {
        readSet(setURL(id))
    }

    /// 全部测试集，按建的先后（同一刻按编号）；读不成的跳过
    func sets() -> [MemoryLabSet] {
        ((try? FileManager.default.contentsOfDirectory(at: setsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.compactMap(readSet)
            .sorted {
                let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
                return a != b ? a < b : $0.id < $1.id
            }
    }

    /// 每句话在哪几份测试集里（键 = `sentence`，值 = 测试集 id，按 `sets()` 的顺序）。只看集子文件，不看记录上的回指
    func membership() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for set in sets() {
            for item in set.items ?? [] where out[item.sentenceId]?.contains(set.id) != true {
                out[item.sentenceId, default: []].append(set.id)
            }
        }
        return out
    }

    struct SetSummary: Equatable, Sendable, Identifiable {
        public var set: MemoryLabSet
        /// 几句
        public var count: Int
        public var up: Int
        public var down: Int
        /// 没看过（含记录文件没了的那几句）
        public var unseen: Int
        /// 这份里最近跑的那一句是什么时候跑的；nil = 一句记录都没有
        public var latestAt: Date?
        /// 最近那一句算哪一组（`paramsGroup`）；`latestAt` 有值而这里是 nil = 在一组上改过没存就跑的
        public var latestParamsId: String?

        public var id: String { self.set.id }

        public init(set: MemoryLabSet, count: Int, up: Int, down: Int, unseen: Int,
                    latestAt: Date? = nil, latestParamsId: String? = nil) {
            self.set = set
            self.count = count
            self.up = up
            self.down = down
            self.unseen = unseen
            self.latestAt = latestAt
            self.latestParamsId = latestParamsId
        }
    }

    /// 一排测试集各自的数。一句话有好几条记录时看最新那条的拇指。
    /// `heads` = 调用方已经轻读过的那份（省一遍读盘）；不给就自己读
    func setSummaries(heads: [MemoryLabRecord.Head]? = nil) -> [SetSummary] {
        let latest = Self.latest(heads ?? self.heads())
        return sets().map { set in
            var summary = SetSummary(set: set, count: 0, up: 0, down: 0, unseen: 0)
            for item in set.items ?? [] {
                summary.count += 1
                let head = latest[item.sentenceId]
                switch head?.judgment?.verdict {
                case .up: summary.up += 1
                case .down: summary.down += 1
                case nil: summary.unseen += 1
                }
                if let head, summary.latestAt.map({ head.input.at >= $0 }) ?? true {
                    summary.latestAt = head.input.at
                    summary.latestParamsId = head.paramsGroup
                }
            }
            return summary
        }
    }

    struct SetEntry: Equatable, Sendable, Identifiable {
        public var item: MemoryLabSet.Item
        /// 这句话最新的那条记录；记录文件没了 / 读不成 = nil（`text` 照样有）
        public var record: MemoryLabRecord?

        public init(item: MemoryLabSet.Item, record: MemoryLabRecord?) {
            self.item = item
            self.record = record
        }

        public var id: String { item.sentenceId }
        public var text: String { item.text ?? record?.input.text ?? "" }
    }

    /// 一份测试集里的每一句，按挑进的先后；整条记录只读用得上的那几条。没有这份集子 = 空
    func entries(inSet id: String, heads: [MemoryLabRecord.Head]? = nil) -> [SetEntry] {
        guard let set = set(id: id) else { return [] }
        let latest = Self.latest(heads ?? self.heads())
        return (set.items ?? []).map { item in
            SetEntry(item: item, record: latest[item.sentenceId].flatMap { record(id: $0.id) })
        }
    }

    // MARK: - 测试集 × 参数组

    /// 一份测试集在一组参数下的每一句（按挑进的先后）：`record` = 这句话在这一组下最新的一条，nil = 这句在这组下没跑过。
    /// 最新那条没问成（没有回复）也照给：看得到出错原因和想起了什么；它算不算跑过看 `runSummary` / `notRun`。
    /// `paramsId` = `MemoryLabParamSet.currentId` 或某组的 id；没写 `paramsId` 的旧记录算哪一组见 `MemoryLabRecord.paramsGroup`
    func entries(inSet id: String, paramsId: String, heads: [MemoryLabRecord.Head]? = nil) -> [SetEntry] {
        guard let set = set(id: id) else { return [] }
        let heads = heads ?? self.heads()
        let inGroup = Self.latest(heads.filter { $0.paramsGroup == paramsId }), any = Self.latest(heads)
        return (set.items ?? []).map { item in
            var item = item
            // 老集子没存那句话、这组下又没跑过：从别的组的记录里拿
            if item.text == nil { item.text = any[item.sentenceId]?.input.text }
            return SetEntry(item: item, record: inGroup[item.sentenceId].flatMap { record(id: $0.id) })
        }
    }

    struct RunSummary: Equatable, Sendable {
        /// 这份集子一共几句
        public var count: Int
        /// 这一组下跑过几句（最新那条有回复）
        public var ran: Int
        /// 这一组下还要跑的（「重放 N 句」的 N）：没有记录的 + 最新那条没问成的
        public var notRun: Int
        /// `notRun` 里问过但没问成的（最新那条没有回复）
        public var failed: Int
        public var up: Int
        public var down: Int
        /// 跑过、还没点拇指
        public var unseen: Int

        public init(count: Int = 0, ran: Int = 0, notRun: Int = 0, failed: Int = 0, up: Int = 0, down: Int = 0, unseen: Int = 0) {
            self.count = count
            self.ran = ran
            self.notRun = notRun
            self.failed = failed
            self.up = up
            self.down = down
            self.unseen = unseen
        }
    }

    /// 一份测试集在一组参数下的小结（只轻读）。没有这份集子 = 全 0
    func runSummary(inSet id: String, paramsId: String, heads: [MemoryLabRecord.Head]? = nil) -> RunSummary {
        var out = RunSummary()
        guard let set = set(id: id) else { return out }
        let inGroup = Self.latest((heads ?? self.heads()).filter { $0.paramsGroup == paramsId })
        for item in set.items ?? [] {
            out.count += 1
            guard let head = inGroup[item.sentenceId], head.replied else {
                out.notRun += 1
                if inGroup[item.sentenceId] != nil { out.failed += 1 }
                continue
            }
            out.ran += 1
            switch head.judgment?.verdict {
            case .up: out.up += 1
            case .down: out.down += 1
            case nil: out.unseen += 1
            }
        }
        return out
    }

    /// 一份测试集在一组参数下还要跑的句子（按挑进的先后；口径同 `runSummary.notRun`）。`text` 没存在集子里的从记录里补
    func notRun(inSet id: String, paramsId: String, heads: [MemoryLabRecord.Head]? = nil) -> [MemoryLabSet.Item] {
        guard let set = set(id: id) else { return [] }
        let heads = heads ?? self.heads()
        let inGroup = Self.latest(heads.filter { $0.paramsGroup == paramsId }), any = Self.latest(heads)
        return (set.items ?? []).filter { inGroup[$0.sentenceId]?.replied != true }.map { item in
            var item = item
            if item.text == nil { item.text = any[item.sentenceId]?.input.text }
            return item
        }
    }

    /// 每句话最新的那条记录（`heads` 是旧的在前，后来的盖掉先前的）
    private static func latest(_ heads: [MemoryLabRecord.Head]) -> [String: MemoryLabRecord.Head] {
        var out: [String: MemoryLabRecord.Head] = [:]
        for head in heads { out[head.sentence] = head }
        return out
    }

    // MARK: - 改

    @discardableResult
    func createSet(name: String, id: String = UUID().uuidString, at: Date = MemoryBench.now()) throws -> MemoryLabSet {
        guard !FileManager.default.fileExists(atPath: setURL(id).path) else { throw StoreError.setExists(id) }
        let set = MemoryLabSet(id: id, name: name, createdAt: at, items: [])
        try save(set)
        return set
    }

    @discardableResult
    func renameSet(id: String, name: String) throws -> MemoryLabSet {
        var set = try editable(id)
        set.name = name
        try save(set)
        return set
    }

    /// 删这份集子：只删集子文件，再把各条记录上指向它的回指清掉。不删记录。本来就没有这份 = 只清回指
    func deleteSet(id: String) throws {
        let url = setURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        updateBackReferences(where: { $0.sets?.contains(id) == true }) { $0.sets?.removeAll { $0 == id } }
    }

    /// 把一条记录挑进一份测试集。记录还没有 `sentenceId` 时写成它自己的编号；已经在里面 = 不重复加（顺手把回指补齐）
    @discardableResult
    func add(recordId: String, toSet id: String, at: Date = MemoryBench.now()) throws -> MemoryLabSet {
        guard var record = record(id: recordId) else { throw StoreError.missing(recordId) }
        guard (record.schema ?? 1) <= Self.schema else { throw StoreError.newerSchema(recordId) }
        var set = try editable(id)
        let sentence = record.sentence
        if set.items?.contains(where: { $0.sentenceId == sentence }) != true {
            set.items = (set.items ?? []) + [.init(sentenceId: sentence, text: record.input.text, addedAt: at)]
            try save(set)
        }
        record.sentenceId = sentence
        if record.sets?.contains(id) != true { record.sets = (record.sets ?? []) + [id] }
        try? save(record)
        return set
    }

    /// 把一句话从一份测试集里拿出去（两边一起撤）。本来就不在里面 = 只清回指
    @discardableResult
    func remove(sentenceId: String, fromSet id: String) throws -> MemoryLabSet {
        var set = try editable(id)
        if set.items?.contains(where: { $0.sentenceId == sentenceId }) == true {
            set.items?.removeAll { $0.sentenceId == sentenceId }
            try save(set)
        }
        updateBackReferences(where: { $0.sentence == sentenceId && $0.sets?.contains(id) == true }) {
            $0.sets?.removeAll { $0 == id }
        }
        return set
    }

    /// 回指尽力改：先轻读挑出要改的，再整条读出来改；新版本写的记录不碰，写不成的跳过
    private func updateBackReferences(where matches: (MemoryLabRecord.Head) -> Bool, _ change: (inout MemoryLabRecord) -> Void) {
        for head in heads() where matches(head) {
            guard var record = record(id: head.id), (record.schema ?? 1) <= Self.schema else { continue }
            change(&record)
            try? save(record)
        }
    }
}
