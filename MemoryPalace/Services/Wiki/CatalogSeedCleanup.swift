import Foundation

/// 旧种子一次性清理（第 6 段 A；粟粟已定 4、16）：先把目标楼层整个 wiki（含提案、状态、历史、整理记录）备份到
/// memory 旁「记忆备份」，逐文件核过才删，而且只删三类——旧 `.seed-state.json`、全部旧 origin=seed 提案（任何状态）、
/// 旧种子提案新建的页（连它的历史）。认定只看提案自己的记录，不追 regroup、不看标题；
/// 旧种子改过的非种子页、留下的页里还连着被删页的，只列清单给她看，不动。任何一步失败都整体回滚并逐样核实；回滚不全就留着原件、报路径和备份位置。
enum CatalogSeedCleanup {
    static let backupPrefix = "种子清理前-"
    static let listFileName = "种子清理清单.json"

    struct Plan: Codable, Equatable, Sendable {
        var stateFile: Bool
        var proposals: [String]
        var pages: [String]
        /// 旧种子改过的非种子页：不回滚、不动
        var touched: [String]
        /// 留下的页里还连到被删页的：不动，给她看
        var danglingLinks: [String]

        var isEmpty: Bool { !stateFile && proposals.isEmpty && pages.isEmpty }
    }

    struct Result: Equatable, Sendable {
        var plan: Plan
        var backup: URL

        var summary: String {
            var parts = ["清了旧种子：完成标记 \(plan.stateFile ? 1 : 0) 个 · 提案 \(plan.proposals.count) 份 · 种子新建的页 \(plan.pages.count) 页（连历史）"]
            if !plan.touched.isEmpty { parts.append("旧种子改过、没动的页：\(plan.touched.joined(separator: "、"))") }
            if !plan.danglingLinks.isEmpty { parts.append("还连着已删页、没动的页：\(plan.danglingLinks.joined(separator: "、"))") }
            parts.append("备份在「\(MemoryRegeneration.backupFolderName)/\(backup.lastPathComponent)」")
            return parts.joined(separator: " · ")
        }
    }

    /// 旧种子提案：origin = seed，但既不是新任务的目录（带种子目录项）也不是新任务的正文（带 directionRef）
    static func isLegacy(_ p: WikiProposal) -> Bool {
        p.origin == .seed && p.seedTask == nil && p.directionRef == nil && !p.items.contains { $0.change.direction?.mode == .seed }
    }

    static func plan(wiki: WikiStore) -> Plan {
        let legacy = WikiProposalStore(wiki: wiki).list().filter(isLegacy)
        var created: [String] = []
        var modified: [String] = []
        for p in legacy {
            for item in p.items where item.state == .approved {
                if case .newPage(let page) = item.change {
                    if !created.contains(page.path) { created.append(page.path) }
                } else if let path = item.change.targetPath, !modified.contains(path) {
                    modified.append(path)
                }
            }
        }
        let pages = created.filter(wiki.pageExists).sorted()
        let gone = Set(pages)
        let kept = wiki.pagePaths().filter { !gone.contains($0) }
        let dangling = kept.filter { path in wiki.read(path)?.links.contains { gone.contains($0.target) } ?? false }
        return Plan(stateFile: CatalogSeed.isLegacyState(wiki: wiki), proposals: legacy.map(\.id).sorted(), pages: pages,
                    touched: modified.filter { !gone.contains($0) && wiki.pageExists($0) }.sorted(), danglingLinks: dangling)
    }

    /// 删到一半出错、又没能全部挪回：原件留在暂存夹，报出没挪回的每一样和备份位置（不说「一个都没删」）
    enum CleanupError: LocalizedError, Equatable {
        case partial(failed: String, notRestored: [String], trash: String, backup: String)

        var errorDescription: String? {
            switch self {
            case .partial(let failed, let notRestored, let trash, let backup):
                return "清旧种子中途出错（\(failed)），有 \(notRestored.count) 样没能放回原处：\(notRestored.joined(separator: "、"))。"
                    + "挪走的原件都还在 \(trash)，完整备份在 \(backup)"
            }
        }
    }

    static let move: MemoryRegeneration.FileOp = { try FileManager.default.moveItem(at: $0, to: $1) }

    /// 有旧种子产物才做；整段拿着审批锁（不和批 / 驳回 / 认领交错），文件在后台
    @MainActor
    static func runIfNeeded(memoryRoot: URL, wiki: WikiStore, now: Date,
                            copy: @escaping MemoryRegeneration.FileOp = MemoryRegeneration.copy) async throws -> Result? {
        try await WikiProposalReview.exclusive(WikiProposalStore(wiki: wiki)) {
            try await Task.detached(priority: .utility) { try run(memoryRoot: memoryRoot, wiki: wiki, now: now, copy: copy) }.value
        }
    }

    /// 备份（.partial 暂存 → 逐文件大小 / SHA256 → 写完成清单 → 发布）→ 清单随备份存 → 按清单再核一遍 → 才删。
    /// 删是一个事务：先全部挪进暂存夹、再重建索引；哪一步出错，就把挪走的逐样挪回、索引恢复原样，并逐样核实回去了——
    /// 都回去了 = 一个都没删；有没回去的 = 暂存夹留着、报具体路径和备份位置
    static func run(memoryRoot: URL, wiki: WikiStore, now: Date, copy: MemoryRegeneration.FileOp = MemoryRegeneration.copy,
                    move: MemoryRegeneration.FileOp = CatalogSeedCleanup.move,
                    rebuild: (WikiStore) throws -> Void = { try $0.rebuildAllIndexes() }) throws -> Result? {
        let plan = plan(wiki: wiki)
        guard !plan.isEmpty else { return nil }
        let folder = wiki.root.lastPathComponent
        let backup = try MemoryRegeneration.makeBackup(memoryRoot: memoryRoot, name: backupPrefix + MemoryRegeneration.stamp(now),
                                                       folders: [folder], copy: copy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan).write(to: backup.appendingPathComponent(listFileName), options: .atomic)
        guard let manifest = MemoryRegeneration.manifest(of: backup) else {
            throw MemoryRegeneration.RegenError.incompleteBackup("没有完成清单")
        }
        _ = try MemoryRegeneration.verify(backup, manifest)

        let fm = FileManager.default
        let store = WikiProposalStore(wiki: wiki)
        var targets: [URL] = []
        if plan.stateFile { targets.append(CatalogSeed.stateURL(wiki)) }
        targets += plan.proposals.map { store.folder.appendingPathComponent($0 + ".json") }
        for page in plan.pages {
            targets.append(try wiki.pageURL(page))
            targets.append(wiki.historyURL(page))
        }
        let indexFolders = Array(Set([""] + WikiStore.branches + wiki.allFolders()))
        let branchExisted = Dictionary(uniqueKeysWithValues: WikiStore.branches.map { ($0, wiki.folderExists($0)) })
        let indexes = indexFolders.map { f -> (URL, Data?) in
            let url = wiki.folderURL(f).appendingPathComponent(WikiStore.indexFileName)
            return (url, try? Data(contentsOf: url))
        }
        let trash = store.folder.appendingPathComponent(".seed-cleanup-\(MemoryRegeneration.stamp(now))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        var moved: [(from: URL, to: URL)] = []
        do {
            for (index, url) in targets.enumerated() where MemoryRegeneration.itemExists(url) {
                let dest = trash.appendingPathComponent("\(index)-" + url.lastPathComponent)
                try move(url, dest)
                moved.append((url, dest))
            }
            try rebuild(wiki)
        } catch {
            var notRestored: [String] = []
            for m in moved.reversed() {
                try? fm.createDirectory(at: m.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? move(m.to, m.from)) == nil || !MemoryRegeneration.itemExists(m.from) { notRestored.append(m.from.path) }
            }
            for (url, data) in indexes {
                if let data {
                    if (try? Data(contentsOf: url)) != data, (try? WikiStore.writeAtomic(data, to: url)) == nil { notRestored.append(url.path) }
                } else if MemoryRegeneration.itemExists(url), (try? fm.removeItem(at: url)) == nil {
                    notRestored.append(url.path)
                }
            }
            for (branch, existed) in branchExisted where !existed {
                let dir = wiki.folderURL(branch)
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
            }
            WikiInjectionCache.shared.invalidate()
            guard notRestored.isEmpty else {
                throw CleanupError.partial(failed: error.localizedDescription, notRestored: notRestored, trash: trash.path, backup: backup.path)
            }
            try? fm.removeItem(at: trash)
            throw error
        }
        WikiInjectionCache.shared.invalidate()
        try? fm.removeItem(at: trash)
        for page in plan.pages { pruneEmptyFolders(above: page, wiki: wiki) }
        return Result(plan: plan, backup: backup)
    }

    /// 删页后空出来的分组文件夹（只剩生成的 INDEX.md）收掉；有别的东西（分组钩子、别的页）就留着
    private static func pruneEmptyFolders(above page: String, wiki: WikiStore) {
        var parts = page.split(separator: "/").map(String.init).dropLast()
        while parts.count >= 2 {
            let folder = parts.joined(separator: "/")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: wiki.folderURL(folder).path)) ?? []
            guard !names.isEmpty, names.allSatisfy({ $0 == WikiStore.indexFileName }) else { return }
            try? FileManager.default.removeItem(at: wiki.folderURL(folder))
            parts = parts.dropLast()
        }
    }
}
