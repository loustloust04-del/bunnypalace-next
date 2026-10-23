import Foundation

/// Kelivo 备份 zip 的容器约定（#049，格式见 docs/research-import-kelivo-format.md §A1 / §B1）。
/// 包根：旧版 `chats.json`，新版 `manifest.json` + `database/kelivo.db`；两代都有 `settings.json`（带凭证，**不读不拷**，plan D4）。
enum KelivoArchive {
    static let chatsEntry = "chats.json"
    static let manifestEntry = "manifest.json"
    static let databaseEntry = "database/kelivo.db"
    static let settingsLabel = "Kelivo 的设置和 API key"
    /// 消息附件所在的目录（avatars / fonts 是头像和字体，消息不引用）
    static let assetRoots: Set<String> = ["upload", "images"]

    static func isAsset(_ parts: [String]) -> Bool {
        parts.count >= 2 && assetRoots.contains(parts[0]) && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// 包根的 `manifest.json` 是不是 Kelivo 的（Claude 的清单也可能叫这个名字）
    static func isManifest(file url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4 << 20,
              let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        return KelivoBackup.isManifest(root)
    }
}

/// 扫描出来的一个 Kelivo 备份：staging 里的 chats.json 或 清单 + 库，加包里的附件
struct KelivoPackage {
    enum Content {
        case legacy(chats: URL)
        case modern(manifest: URL, root: URL)
    }

    /// 选进来的包名（提示里用）
    let name: String
    let content: Content
    /// 包内相对路径（`upload/…` / `images/…`）→ staging 里的文件
    var assets: [String: ImportAssetRef] = [:]
}

/// 预览页的数。后台线程算；导入时再解析一遍（同 Gemini）
struct KelivoPreview: Equatable {
    var conversations = 0
    var legacyPackages = 0
    var modernPackages = 0
    /// 有重新生成的槽位
    var regenerated = 0
    /// 包里能对上的附件
    var attachments = 0
    /// 读不了的包
    var failures: [String] = []
    /// 要写的对话 id（`<Kelivo id>@kelivo`，同写库引擎）：预览页提前查「已在其他楼层」（#061）
    var conversationIds: [String] = []

    static func make(_ packages: [KelivoPackage]) -> KelivoPreview {
        var preview = KelivoPreview()
        for package in packages {
            do {
                let report = try KelivoImporter.payloads(package) { preview.conversationIds.append($0.id) }
                preview.conversations += report.stats.conversations
                preview.regenerated += report.stats.regeneratedGroups
                preview.attachments += report.stats.packagedAttachments
                if case .legacy = package.content { preview.legacyPackages += 1 } else { preview.modernPackages += 1 }
            } catch {
                preview.failures.append("\(package.name)：\(error.localizedDescription)")
            }
        }
        return preview
    }
}

/// Kelivo 备份 → 花园（#049 plan §2 B 段）：每 200 段一批交写库引擎；包里的附件交给引擎只对真写入的对话转存
enum KelivoImporter {
    struct Report {
        var counts = KelivoBackup.Counts()
        var stats = KelivoPayloadBuilder.Stats()
        var newerThanKnown = false
        var migrationIncomplete = false
        var unreadable: [String] = []
        /// 读到一半出错：前面已经写进去的段数（sol #7）
        var partial: [(package: String, written: Int, reason: String)] = []

        var notes: [String] {
            var out = (counts.notes + stats.notes).map { "Kelivo：" + $0 }
            if newerThanKnown { out.append("Kelivo：这个备份的数据库比已知版本新，可能有没读到的内容") }
            if migrationIncomplete { out.append("Kelivo：备份里记着 Kelivo 从旧版存储升级没做完，可能缺对话") }
            out += unreadable.map { "有一个 Kelivo 备份没导：\($0)" }
            out += partial.map { "Kelivo 备份「\($0.package)」只导了一部分（前 \($0.written) 段），后面读不了：\($0.reason)" }
            return out
        }
    }

    /// 逐段出 payload（附件待转存）。读不了整个包时抛错
    static func payloads(_ package: KelivoPackage, timeZone: TimeZone = .current,
                         each: (ImportedConversationPayload) throws -> Void) throws -> Report {
        var report = Report()
        let members = Set(package.assets.keys)
        let pending = Dictionary(uniqueKeysWithValues: package.assets.map { (KelivoPayloadBuilder.assetKey($0.key), $0.value) })
        func emit(_ conversation: KelivoBackup.Conversation, format: String) throws {
            guard var payload = KelivoPayloadBuilder.payload(conversation, format: format, members: members,
                                                             stats: &report.stats) else { return }
            payload.pendingAssets = pending
            payload.externalizeOnWrite = true
            try each(payload)
        }
        switch package.content {
        case .legacy(let chats):
            let parsed = try KelivoLegacyParser.parse(data: ExportJSON.data(at: chats), timeZone: timeZone)
            report.counts = parsed.counts
            for conversation in parsed.conversations { try emit(conversation, format: "legacy") }
        case .modern(let manifestURL, let root):
            let manifest = try KelivoDatabaseReader.manifest(data: Data(contentsOf: manifestURL))
            let database = root.appendingPathComponent(manifest.databaseEntry)
            try KelivoDatabaseReader.verify(database: database, against: manifest)
            let summary = try KelivoDatabaseReader.read(database: database) { try emit($0, format: "v\(manifest.formatVersion)") }
            report.newerThanKnown = summary.newerThanKnown
            report.migrationIncomplete = summary.migrationIncomplete
        }
        return report
    }

    /// 后台线程同步跑。读不了的包跳过并记下，不挡别的包
    static func run(_ packages: [KelivoPackage], engine: PayloadImportEngine, timeZone: TimeZone = .current,
                    progress: (Double) -> Void = { _ in }) throws -> Report {
        var total = Report()
        for (index, package) in packages.enumerated() {
            var batch: [ImportedConversationPayload] = []
            var written = 0
            func flush() throws {
                guard !batch.isEmpty else { return }
                try autoreleasepool { try engine.importBatch(batch) }
                written += batch.count
                batch.removeAll(keepingCapacity: true)
            }
            func failed(_ reason: String) {
                if written > 0 {
                    total.partial.append((package.name, written, reason))
                } else {
                    total.unreadable.append("\(package.name)：\(reason)")
                }
            }
            do {
                let report = try payloads(package, timeZone: timeZone) { payload in
                    batch.append(payload)
                    if batch.count >= ImportRunner.batchSize { try flush() }
                }
                try flush()
                total.counts.add(report.counts)
                total.stats.add(report.stats)
                total.newerThanKnown = total.newerThanKnown || report.newerThanKnown
                total.migrationIncomplete = total.migrationIncomplete || report.migrationIncomplete
            } catch let error as KelivoDatabaseReader.ReadError {
                failed(error.localizedDescription)
            } catch let error as KelivoLegacyParser.ParseError {
                failed(error.localizedDescription)
            }
            progress(Double(index + 1) / Double(packages.count))
        }
        return total
    }
}
