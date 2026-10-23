import Foundation

/// 导入包扫描（#043 plan §2）：把选中的 zip / 文件夹 / json 里用得上的文件拷进 staging，
/// 按路径 + 结构分类。之后的导入只读 staging，不再碰原 URL（安全作用域在扫描期间配对开关）。
///
/// 三代 Claude 包 + ChatGPT 包用同一套规则，不看是哪一代：
/// - `artifacts/<id>/**` → artifact（子树里不再识别别的类别）
/// - `design_chats/*.json` → 设计对话
/// - `projects.json` / `projects/*.json` → 项目；`memories.json` / `memories/*.json` → 记忆
/// - 其余 `conversations.json` 和直接选中的 json → 按结构判 Claude / ChatGPT
/// - `MyActivity.json` / `.html` → Google 活动记录，只收 Gemini 那份（#047）；没扩展名的按内容认 AI Studio
struct ExportPackageScan {
    enum Source { case claude, chatgpt }

    struct ConversationEntry {
        let id: String
        let updated: Date?
        let messageCount: Int
    }

    struct ConversationFile {
        let url: URL
        let source: Source
        let entries: [ConversationEntry]
        /// 排序用：先按文件里最新的更新时间，再按包名里的序号
        let latest: Date?
        let order: Int
    }

    var stagingDir: URL
    /// 已按「旧 → 新」排好
    var claudeFiles: [ConversationFile] = []
    var chatGPTFiles: [ConversationFile] = []
    var designChatFiles: [URL] = []
    var projectFiles: [URL] = []
    var memoryFiles: [URL] = []
    var artifactDirs: [URL] = []
    var manifestFiles: [URL] = []
    /// Takeout 里 Gemini 的活动记录（JSON 或 HTML）
    var geminiActivityFiles: [URL] = []
    var aiStudioFiles: [URL] = []
    /// RikkaHub 备份（#048）：每个包一个 staging 目录（库 + WAL + 附件），助手名已从 settings.json 读进内存
    var rikkaHubPackages: [RikkaHubPackage] = []
    /// 只有 settings.json、没带数据库的 RikkaHub 备份（包名）
    var rikkaHubSettingsOnly: [String] = []
    /// Kelivo 备份（#049）：staging 里的 chats.json 或 清单 + 库 + 附件；settings.json 不读不拷
    var kelivoPackages: [KelivoPackage] = []
    /// 只有设置、没勾聊天记录的 Kelivo 备份（包名）
    var kelivoSettingsOnly: [String] = []
    /// 认得、但这次不导的（账号信息、登录记录…），已去重
    var ignoredLabels: [String] = []
    var unrecognized: [String] = []
    var emptyFiles: [String] = []
    /// manifest 里列了、但这次没选到的包名 / 包里没有的分片
    var missingFromManifest: [String] = []
    /// 第一份能解析的 Claude 下载清单（#059）：只选了清单时导入页据此进下载页，不算「没找到」
    var claudeManifest: ClaudeExportManifest?
    /// ChatGPT 包里带的附件字节（#050 E6）
    var chatGPTAssets = ChatGPTAssetIndex()
    /// 这次选中的全部包名（staging 第 i 格对应第 i 个）（#061 导入清单）
    var packageNames: [String] = []

    /// staging 里的文件 → 「包名 › 包内路径」（导入清单 / 详情页用）；不在 staging 里的给文件名
    func sourceLabel(_ url: URL) -> String {
        let base = stagingDir.path + "/"
        guard url.path.hasPrefix(base) else { return url.lastPathComponent }
        var parts = String(url.path.dropFirst(base.count)).split(separator: "/").map(String.init)
        guard let box = parts.first.flatMap({ Int($0) }), box < packageNames.count else { return url.lastPathComponent }
        parts.removeFirst()
        // 文件夹里直接放着的 zip 解在 zips/<相对路径>/ 下
        if parts.first == "zips" { parts.removeFirst() }
        let inner = parts.joined(separator: "/")
        let package = packageNames[box]
        return inner.isEmpty || inner == package ? package : "\(package) › \(inner)"
    }

    var claudeConversationCount: Int { Set(claudeFiles.flatMap { $0.entries.map(\.id) }).count }
    var chatGPTConversationCount: Int { Set(chatGPTFiles.flatMap { $0.entries.map(\.id) }).count }
    /// 在多个文件里都出现的对话数
    var duplicateConversationCount: Int {
        func dups(_ files: [ConversationFile]) -> Int {
            var seen: [String: Int] = [:]
            for f in files { for id in Set(f.entries.map(\.id)) { seen[id, default: 0] += 1 } }
            return seen.values.filter { $0 > 1 }.count
        }
        return dups(claudeFiles) + dups(chatGPTFiles)
    }

    var isEmpty: Bool {
        claudeFiles.isEmpty && chatGPTFiles.isEmpty && designChatFiles.isEmpty && projectFiles.isEmpty
            && memoryFiles.isEmpty && artifactDirs.isEmpty && geminiActivityFiles.isEmpty && aiStudioFiles.isEmpty
            && rikkaHubPackages.isEmpty && kelivoPackages.isEmpty
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: stagingDir)
    }
}

enum ExportPackageError: LocalizedError {
    case unreadable(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "读不了「\(name)」"
        case .tooLarge(let why): return "导出包太大：\(why)"
        }
    }
}

enum ExportPackageScanner {
    static let stagingPrefix = "mp-import-"
    /// 酒馆（SillyTavern）的聊天 jsonl：这里不导，导入页提示去卡库（#050 E10）
    static let sillyTavernLabel = "酒馆聊天"

    /// 解包预算（plan §2.5）：多选的包共用
    static let limits = ZipExtractLimits(maxEntries: 20_000, maxEntryBytes: 2 << 30, maxTotalBytes: 4 << 30, maxRatio: 1000)

    enum Category: Equatable {
        case conversation
        case designChat
        case project
        case memory
        case artifact(dir: String)
        case manifest
        /// Takeout 活动记录：每个 Google 产品都有一份，收进来再按内容挑 Gemini
        case geminiActivity
        case aiStudio
        case ignored(String)
        case unrecognizedJSON
        /// 没扩展名的文件（AI Studio 导出常这样）：拷进来按内容认
        case candidate
        /// ChatGPT 包里的附件（图片、上传文件、`file-<id>.dat`）：拷进来建索引（#050 E6）
        case asset
        /// `conversation_asset_file_names.json`：附件的原始文件名
        case assetNames
        /// 隐私门户包外层 zip 里套的分卷 zip（`Conversations__…zip` / `Files__…zip` / `Dall-E__…zip`）
        case exportVolume
        /// RikkaHub 备份根目录的 `rikka_hub.db`
        case rikkaHubDatabase
        /// RikkaHub 的老包 WAL、`upload/`、`media_creation/`：落盘，跟着库用
        case rikkaHubAsset
        /// 根目录的 `settings.json`：带 API key，**不落盘**，只读进内存取助手名
        case rikkaHubSettings
        /// Kelivo 旧版包根的 `chats.json`（新版的 `manifest.json` 先归 manifest，收集时按内容挑出来）
        case kelivoChats
        /// Kelivo 新版的 `database/kelivo.db`
        case kelivoDatabase
        /// Kelivo 的 `upload/` `images/`：落盘，跟着包用
        case kelivoAsset
    }

    /// 认得但不导的文件（Claude 账号 / 登录 / 回顾；ChatGPT 其他数据）
    private static let ignoredNames: [String: String] = [
        "users.json": "账号信息", "user.json": "账号信息", "login_history.json": "登录记录",
        "shared_conversations.json": "分享链接", "message_feedback.json": "消息反馈",
        "group_chats.json": "群聊", "shopping.json": "购物记录", "sora.json": "Sora",
        "basispoints.json": "其他数据", "model_comparisons.json": "其他数据",
    ]

    /// 包内相对路径 → 类别。nil = 不是我们要的（图片、chat.html…），不落盘也不提示。
    static func classify(_ path: String) -> Category? {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let last = parts.last, !last.hasPrefix(".") else { return nil }
        if parts.count == 1, last == KelivoArchive.chatsEntry { return .kelivoChats }
        if parts.joined(separator: "/") == KelivoArchive.databaseEntry { return .kelivoDatabase }
        if parts.count == 1, last == RikkaHubArchive.settingsEntry { return .rikkaHubSettings }
        if parts.count == 1, last == RikkaHubArchive.shmEntry { return nil }
        if RikkaHubArchive.neededForImport(parts.joined(separator: "/")) {
            return last == RikkaHubArchive.databaseEntry && parts.count == 1 ? .rikkaHubDatabase : .rikkaHubAsset
        }
        // RikkaHub 也有 `upload/<文件>`（上面已收、落盘）；Kelivo 的更深的层级和 images/ 在这收
        if KelivoArchive.isAsset(parts) { return .kelivoAsset }
        if parts.count >= 2, let label = RikkaHubArchive.ignoredDirectories[parts[0]] { return .ignored(label) }
        if let i = parts.firstIndex(of: "artifacts"), parts.count > i + 2 {
            return .artifact(dir: parts[...(i + 1)].joined(separator: "/"))
        }
        let parent = parts.count >= 2 ? parts[parts.count - 2] : ""
        let isJSON = last.lowercased().hasSuffix(".json")
        if parent == "reflections" { return .ignored("月度回顾") }
        // 分卷只认导出的命名，附件目录里的 zip 是上传的附件（sol #7）
        if isExportVolume(last), !ChatGPTAssetIndex.isAssetPath(path) { return .exportVolume }
        if ["myactivity.json", "myactivity.html"].contains(last.lowercased()) { return .geminiActivity }
        // AI Studio 的文件常没扩展名，名字里又常带点（`Notes v1.5`）：它那个文件夹里的一律按内容认，别处「扩展名」不像扩展名的也按内容认
        if parts.contains("Google AI Studio") { return .candidate }
        // 代码沙盒输出的 json 也是附件（sol #10）；别处的 json 照常认
        if ChatGPTAssetIndex.isAssetPath(path), !isJSON || path.contains("/mnt/data/") { return .asset }
        let ext = (last as NSString).pathExtension
        if ext.isEmpty || ext.allSatisfy(\.isNumber) || ext.contains(" ") { return .candidate }
        if last.lowercased().hasSuffix(".jsonl"), parts.contains("chats") || parts.contains("group chats") {
            return .ignored(sillyTavernLabel)
        }
        guard isJSON else { return nil }
        if last == "conversations.json" || isConversationShard(last) { return .conversation }
        if last == "export_manifest.json" { return .manifest }
        if last == "conversation_asset_file_names.json" { return .assetNames }
        if parent == "design_chats" { return .designChat }
        if last == "projects.json" || parent == "projects" { return .project }
        if last == "memories.json" || parent == "memories" { return .memory }
        if let label = ignoredNames[last] { return .ignored(label) }
        if last.hasPrefix("manifest") { return .manifest }
        return .unrecognizedJSON
    }

    /// ChatGPT 新版分片：`conversations-000.json`
    static func isConversationShard(_ name: String) -> Bool {
        name.range(of: #"^conversations-\d+\.json$"#, options: .regularExpression) != nil
    }

    /// 隐私门户包里的分卷 zip：只认这三种命名，别的 zip（比如上传过的 zip 附件）不展开
    static func isExportVolume(_ name: String) -> Bool {
        ["Conversations__", "Files__", "Dall-E__"].contains { name.hasPrefix($0) } && name.lowercased().hasSuffix(".zip")
    }

    /// 只建索引、不解开的分卷（附件分卷）
    private static func isAssetVolume(_ name: String) -> Bool {
        name.hasPrefix("Files__") || name.hasPrefix("Dall-E__")
    }

    /// 扫描。必须在后台线程调。`tempRoot` 只给测试用。
    static func scan(_ urls: [URL], tempRoot: URL = FileManager.default.temporaryDirectory) throws -> ExportPackageScan {
        cleanupStale(in: tempRoot)
        let staging = tempRoot.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var result = ExportPackageScan(stagingDir: staging)
        do {
            result.packageNames = urls.map(\.lastPathComponent)
            try collect(urls, into: &result)
        } catch {
            result.cleanup()
            throw error
        }
        return result
    }

    /// 上次没清掉的 staging（崩溃 / 杀进程）：超过 1 小时的删掉
    static func cleanupStale(in root: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix(stagingPrefix) {
            let url = root.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - 收集

    private struct Pending {
        var conversation: [(url: URL, direct: Bool, order: Int)] = []
        var direct: [URL] = []
        /// 包里没扩展名的文件：认不出就算了，不进「没认出来」
        var candidates: Set<URL> = []
        var artifactDirs: Set<URL> = []
        var assets: [(url: URL, rel: String)] = []
        var assetNames: [URL] = []
        var activity: [URL] = []
        /// RikkaHub：有库的目录；settings.json 所在目录 → (读进内存的内容, 包名)
        var rikkaHubDirs: [URL] = []
        var rikkaHubSettings: [URL: (data: Data?, package: String)] = [:]
        /// Kelivo：旧版 chats.json / 新版清单 → 包名
        var kelivoChats: [(url: URL, package: String)] = []
        var kelivoManifests: [(url: URL, package: String)] = []
    }

    private static func collect(_ urls: [URL], into result: inout ExportPackageScan) throws {
        let fm = FileManager.default
        var pending = Pending()
        var ignored: [String] = []
        var unrecognized: [String] = []
        var pickedNames = urls.map(\.lastPathComponent)
        /// 包里见过的文件名（对 ChatGPT 清单里的分片）
        var seenNames = Set<String>()
        let budget = ZipExtractBudget(limits)

        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let box = result.stagingDir.appendingPathComponent(String(format: "%03d", index))
            let order = packageOrder(url.lastPathComponent)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw ExportPackageError.unreadable(url.lastPathComponent)
            }

            var picked: [(rel: String, category: Category)] = []
            var inMemory: [String: Data] = [:]
            if isDir.boolValue {
                let rels = try walk(url)
                let kelivo = isKelivoRoot(rels.compactMap { rel in classify(rel).map { (rel, $0) } }) {
                    url.appendingPathComponent($0)
                }
                for rel in rels {
                    // Kelivo 附件目录里的 zip 是用户发过的附件，原样拷，不展开（sol #8）
                    let keepZip = kelivo && KelivoArchive.isAsset(rel.split(separator: "/").map(String.init))
                    if rel.lowercased().hasSuffix(".zip"), !keepZip {
                        let name = (rel as NSString).lastPathComponent
                        if isAssetVolume(name) {
                            // 附件分卷：拷进来只建索引
                            try budget.chargeFile(name: rel, bytes: fileSize(url.appendingPathComponent(rel)))
                            let dst = box.appendingPathComponent(rel)
                            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fm.copyItem(at: url.appendingPathComponent(rel), to: dst)
                            picked.append((rel, .exportVolume))
                            continue
                        }
                        // 文件夹里直接放着导出 zip（下载目录原样选进来）
                        pickedNames.append(name)
                        try extractZip(url.appendingPathComponent(rel), to: box.appendingPathComponent("zips/\(rel)"),
                                       prefix: "zips/\(rel)/", budget: budget, picked: &picked, inMemory: &inMemory)
                        continue
                    }
                    guard var category = classify(rel) else { continue }
                    if kelivo, category == .rikkaHubSettings { category = .ignored(KelivoArchive.settingsLabel) }
                    picked.append((rel, category))
                    if category == .rikkaHubSettings {
                        inMemory[rel] = try readInMemory(url.appendingPathComponent(rel), name: rel, budget: budget)
                    }
                    if shouldStage(category) {
                        try budget.chargeFile(name: rel, bytes: fileSize(url.appendingPathComponent(rel)))
                        let dst = box.appendingPathComponent(rel)
                        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: url.appendingPathComponent(rel), to: dst)
                    }
                }
            } else if url.pathExtension.lowercased() == "zip" {
                try extractZip(url, to: box, prefix: "", budget: budget, picked: &picked, inMemory: &inMemory)
            } else if url.lastPathComponent == RikkaHubArchive.settingsEntry {
                // 单独选中的 RikkaHub settings.json：带 API key，只读进内存，不拷进 staging
                let data = try readInMemory(url, name: url.lastPathComponent, budget: budget)
                pending.rikkaHubSettings[url.deletingLastPathComponent()] = (data, url.lastPathComponent)
                continue
            } else {
                // 直接选中的 json：不看文件名，按内容认
                try budget.chargeFile(name: url.lastPathComponent, bytes: fileSize(url))
                try fm.createDirectory(at: box, withIntermediateDirectories: true)
                let dst = box.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: url, to: dst)
                pending.direct.append(dst)
                continue
            }

            for (rel, category) in picked {
                let staged = box.appendingPathComponent(rel)
                switch category {
                case .conversation: pending.conversation.append((staged, false, order))
                case .designChat: result.designChatFiles.append(staged)
                case .project: result.projectFiles.append(staged)
                case .memory: result.memoryFiles.append(staged)
                case .artifact(let dir): pending.artifactDirs.insert(box.appendingPathComponent(dir))
                case .manifest:
                    if KelivoArchive.isManifest(file: staged) {
                        pending.kelivoManifests.append((staged, url.lastPathComponent))
                    } else {
                        result.manifestFiles.append(staged)
                    }
                case .geminiActivity: pending.activity.append(staged)
                case .aiStudio: result.aiStudioFiles.append(staged)
                case .ignored(let label): ignored.append(label)
                case .unrecognizedJSON: unrecognized.append((rel as NSString).lastPathComponent)
                case .candidate: pending.direct.append(staged); pending.candidates.insert(staged)
                case .rikkaHubDatabase: pending.rikkaHubDirs.append(staged.deletingLastPathComponent())
                case .rikkaHubAsset, .kelivoDatabase, .kelivoAsset: break
                case .kelivoChats: pending.kelivoChats.append((staged, url.lastPathComponent))
                case .rikkaHubSettings:
                    pending.rikkaHubSettings[staged.deletingLastPathComponent()] = (inMemory[rel], url.lastPathComponent)
                case .asset: pending.assets.append((staged, rel))
                case .assetNames: pending.assetNames.append(staged)
                case .exportVolume:
                    let name = staged.lastPathComponent
                    pickedNames.append(name)
                    if isAssetVolume(name) {
                        try indexVolume(staged, into: &result.chatGPTAssets, budget: budget)
                    } else {
                        // 对话分卷：再解一层（里面的 zip 不再展开），解完删掉分卷省空间
                        let dir = staged.deletingLastPathComponent()
                        var inner: [(rel: String, category: Category)] = []
                        var innerMemory: [String: Data] = [:]
                        try extractZip(staged, to: dir, prefix: "", budget: budget, picked: &inner,
                                       inMemory: &innerMemory, volumes: false)
                        try? fm.removeItem(at: staged)
                        for (innerRel, category) in inner {
                            let full = dir.appendingPathComponent(innerRel)
                            seenNames.insert(full.lastPathComponent)
                            switch category {
                            case .conversation: pending.conversation.append((full, false, order))
                            case .manifest: result.manifestFiles.append(full)
                            case .assetNames: pending.assetNames.append(full)
                            case .asset: pending.assets.append((full, innerRel))
                            case .ignored(let label): ignored.append(label)
                            case .unrecognizedJSON: unrecognized.append(full.lastPathComponent)
                            case .candidate: pending.direct.append(full); pending.candidates.insert(full)
                            default: break
                            }
                        }
                    }
                }
                seenNames.insert(staged.lastPathComponent)
            }
        }

        for (url, rel) in pending.assets {
            result.chatGPTAssets.add(ImportAssetRef(location: .file(url), fileName: url.lastPathComponent,
                                                    size: fileSize(url)), path: rel)
        }
        for url in pending.assetNames {
            result.chatGPTAssets.displayNames.merge(assetDisplayNames(url), uniquingKeysWith: { a, _ in a })
        }

        for url in pending.direct {
            switch sniffDirectJSON(url) {
            case .conversation: pending.conversation.append((url, true, packageOrder(url.lastPathComponent)))
            case .designChat: result.designChatFiles.append(url)
            case .project: result.projectFiles.append(url)
            case .memory: result.memoryFiles.append(url)
            case .manifest: result.manifestFiles.append(url)
            case .geminiActivity: result.geminiActivityFiles.append(url)
            case .aiStudio: result.aiStudioFiles.append(url)
            case .kelivoChats: pending.kelivoChats.append((url, url.lastPathComponent))
            default: if !pending.candidates.contains(url) { unrecognized.append(url.lastPathComponent) }
            }
        }

        for url in pending.activity {
            if isGeminiActivity(url) { result.geminiActivityFiles.append(url) } else { ignored.append("其他 Google 产品的活动记录") }
        }

        for item in pending.conversation {
            switch probeConversations(item.url) {
            case .some(let probe) where probe.entries.isEmpty:
                result.emptyFiles.append(item.url.lastPathComponent)
            case .some(let probe):
                let file = ExportPackageScan.ConversationFile(
                    url: item.url, source: probe.source, entries: probe.entries,
                    latest: probe.entries.compactMap(\.updated).max(), order: item.order)
                if probe.source == .claude { result.claudeFiles.append(file) } else { result.chatGPTFiles.append(file) }
            case .none:
                unrecognized.append(item.url.lastPathComponent)
            }
        }

        for dir in pending.rikkaHubDirs {
            let names = pending.rikkaHubSettings[dir]?.data.flatMap(RikkaHubSettingsPeek.assistantNames) ?? [:]
            result.rikkaHubPackages.append(RikkaHubPackage(stagingDir: dir, assistantNames: names,
                                                           hasSettings: pending.rikkaHubSettings[dir] != nil))
        }
        let databaseDirs = Set(pending.rikkaHubDirs)
        for (dir, settings) in pending.rikkaHubSettings.sorted(by: { $0.key.path < $1.key.path })
            where !databaseDirs.contains(dir) {
            if settings.data.flatMap(RikkaHubSettingsPeek.assistantNames) != nil {
                result.rikkaHubSettingsOnly.append(settings.package)
            } else {
                unrecognized.append(RikkaHubArchive.settingsEntry)
            }
        }

        for item in pending.kelivoChats {
            result.kelivoPackages.append(KelivoPackage(name: item.package, content: .legacy(chats: item.url),
                                                       assets: kelivoAssets(item.url.deletingLastPathComponent())))
        }
        for item in pending.kelivoManifests {
            let root = item.url.deletingLastPathComponent()
            do {
                _ = try KelivoDatabaseReader.manifest(data: Data(contentsOf: item.url))
            } catch KelivoDatabaseReader.ReadError.settingsOnly {
                result.kelivoSettingsOnly.append(item.package)
                continue
            } catch {
                // 版本太新这类：照样收下，预览里说读不了
            }
            result.kelivoPackages.append(KelivoPackage(name: item.package, content: .modern(manifest: item.url, root: root),
                                                       assets: kelivoAssets(root)))
        }

        result.claudeFiles.sort(by: fileOrder)
        result.chatGPTFiles.sort(by: fileOrder)
        result.designChatFiles.sort { $0.path < $1.path }
        result.projectFiles.sort { $0.path < $1.path }
        result.memoryFiles.sort { $0.path < $1.path }
        result.artifactDirs = pending.artifactDirs.sorted { $0.path < $1.path }
        result.geminiActivityFiles.sort { $0.path < $1.path }
        result.aiStudioFiles.sort { $0.path < $1.path }
        result.ignoredLabels = unique(ignored)
        result.unrecognized = unique(unrecognized)
        result.claudeManifest = result.manifestFiles.lazy
            .compactMap { try? ExportJSON.data(at: $0) }.compactMap(ClaudeExportManifest.parse).first
        result.missingFromManifest = missingPackages(manifests: result.manifestFiles, picked: pickedNames)
            + missingShards(manifests: result.manifestFiles, seen: seenNames)
    }

    /// 解一个 zip 到 `dst`；条目在 picked 里记成 `prefix + 条目路径`（相对本次 box）。
    /// 不落盘、只读进内存的条目（RikkaHub settings.json）放进 inMemory，键同 picked。
    /// `volumes`：认不认分卷 zip（分卷里面再套的不认，免得把上传过的 zip 附件也拆了）
    private static func extractZip(_ zip: URL, to dst: URL, prefix: String, budget: ZipExtractBudget,
                                   picked: inout [(rel: String, category: Category)],
                                   inMemory: inout [String: Data], volumes: Bool = true) throws {
        var found: [(rel: String, category: Category)] = []
        do {
            try TwitterZipExtractor.extract(zip, to: dst, include: { name in
                guard var category = classify(name) else { return false }
                if category == .exportVolume, !volumes { return false }
                // artifact 目录也是相对 box 的，要跟条目一样加前缀
                if case .artifact(let dir) = category { category = .artifact(dir: prefix + dir) }
                found.append((prefix + name, category))
                return shouldStage(category)
            }, budget: budget)
        } catch let e as ZipLimitError {
            throw ExportPackageError.tooLarge(e.description)
        } catch {
            throw ExportPackageError.unreadable(zip.lastPathComponent)
        }
        let entries = found.map { (String($0.rel.dropFirst(prefix.count)), $0.category) }
        if isKelivoRoot(entries, file: { dst.appendingPathComponent($0) }) {
            for i in found.indices where found[i].category == .rikkaHubSettings {
                found[i].category = .ignored(KelivoArchive.settingsLabel)
            }
        }
        for (rel, category) in found where category == .rikkaHubSettings {
            // 读不了 / 超过上限：当没有助手名（文件夹名退回助手 id），不挡导入
            guard let data = try? TwitterZipExtractor.readEntry(zip, name: String(rel.dropFirst(prefix.count)),
                                                                maxBytes: RikkaHubSettingsPeek.maxBytes) else { continue }
            do { try budget.chargeFile(name: rel, bytes: UInt64(data.count)) } catch let e as ZipLimitError {
                throw ExportPackageError.tooLarge(e.description)
            }
            inMemory[rel] = data
        }
        picked += found
    }

    /// 包根是不是 Kelivo 备份（chats.json / 库 / Kelivo 清单）：是的话根上的 settings.json 不当 RikkaHub 的读（带凭证，D4）。
    /// 同一个根上有 RikkaHub 的库就还是 RikkaHub 的（sol #4）
    private static func isKelivoRoot(_ entries: [(String, Category)], file: (String) -> URL) -> Bool {
        guard !entries.contains(where: { $0.1 == .rikkaHubDatabase }) else { return false }
        return entries.contains { rel, category in
            category == .kelivoChats || category == .kelivoDatabase
                || (rel == KelivoArchive.manifestEntry && KelivoArchive.isManifest(file: file(rel)))
        }
    }

    /// Kelivo 包里的附件：包内相对路径 → staging 里的文件
    private static func kelivoAssets(_ root: URL) -> [String: ImportAssetRef] {
        var out: [String: ImportAssetRef] = [:]
        for dir in KelivoArchive.assetRoots {
            let base = root.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: base.path), let rels = try? walk(base) else { continue }
            for rel in rels {
                let file = base.appendingPathComponent(rel)
                out["\(dir)/\(rel)"] = ImportAssetRef(location: .file(file), fileName: file.lastPathComponent, size: fileSize(file))
            }
        }
        return out
    }

    /// 附件分卷不解开：列条目建索引，写库时按条目读
    /// 条目不解开，但照样计进同一份解压预算（写库时会读出来）（sol #8）
    private static func indexVolume(_ zip: URL, into index: inout ChatGPTAssetIndex, budget: ZipExtractBudget) throws {
        let entries: [TwitterZipExtractor.Entry]
        do {
            entries = try TwitterZipExtractor.listEntries(zip, maxEntries: limits.maxEntries)
            for e in entries {
                try budget.charge(name: e.name, method: e.method, compressed: e.compressedSize, uncompressed: e.uncompressedSize)
            }
        } catch let e as ZipLimitError {
            throw ExportPackageError.tooLarge(e.description)
        } catch {
            throw ExportPackageError.unreadable(zip.lastPathComponent)
        }
        for e in entries {
            let name = (e.name as NSString).lastPathComponent
            guard !name.hasPrefix("."), !e.name.hasPrefix("__MACOSX") else { continue }
            index.add(ImportAssetRef(location: .zipEntry(zip: zip, entry: e), fileName: name, size: e.uncompressedSize),
                      path: e.name)
        }
    }

    /// `conversation_asset_file_names.json`：没有官方说明，认「包里文件名 → 原名」的对象，或带这两项的数组
    static func assetDisplayNames(_ url: URL) -> [String: String] {
        guard let data = try? ExportJSON.data(at: url), let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        if let dict = obj as? [String: String] { return dict }
        var out: [String: String] = [:]
        let rows = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?.values.compactMap { $0 as? [[String: Any]] }.first ?? [])
        for row in rows {
            let archive = (row["archive_file_name"] ?? row["file_name"] ?? row["filename"] ?? row["path"]) as? String
            let display = (row["original_file_name"] ?? row["display_name"] ?? row["name"]) as? String
            if let archive, let display { out[(archive as NSString).lastPathComponent] = display }
        }
        return out
    }

    /// ChatGPT `export_manifest.json`：`logical_files["conversations.json"].files` 里列了、包里没有的分片
    static func missingShards(manifests: [URL], seen: Set<String>) -> [String] {
        var missing: [String] = []
        for url in manifests {
            guard let data = try? ExportJSON.data(at: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let logical = obj["logical_files"] as? [String: Any],
                  let conv = logical["conversations.json"] as? [String: Any],
                  let files = conv["files"] as? [Any] else { continue }
            for file in files {
                let path = (file as? String) ?? (file as? [String: Any]).flatMap { ($0["path"] ?? $0["name"] ?? $0["file"]) as? String }
                guard let path else { continue }
                let name = (path as NSString).lastPathComponent
                if !seen.contains(name) { missing.append(name) }
            }
        }
        return unique(missing)
    }

    /// 文件夹里的 settings.json：只读进内存，计预算，超过上限当没有
    private static func readInMemory(_ url: URL, name: String, budget: ZipExtractBudget) throws -> Data? {
        let size = fileSize(url)
        guard size <= RikkaHubSettingsPeek.maxBytes, let data = try? Data(contentsOf: url) else { return nil }
        try budget.chargeFile(name: name, bytes: size)
        return data
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func shouldStage(_ category: Category) -> Bool {
        switch category {
        case .ignored, .unrecognizedJSON, .rikkaHubSettings: return false
        default: return true
        }
    }

    /// 递归列文件夹里的普通文件（相对路径）；跳过符号链接、隐藏文件和特殊文件
    private static func walk(_ root: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw ExportPackageError.unreadable(root.lastPathComponent)
        }
        var out: [String] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { e.skipDescendants(); continue }
            guard v?.isRegularFile == true else { continue }
            // 按深度取相对路径：临时目录枚举出来带 /private、传进来的不带，比前缀会全落空
            out.append(url.pathComponents.suffix(e.level).joined(separator: "/"))
        }
        return out
    }

    /// 文件排序：最新更新时间早的在前；时间相同 / 缺失按包名序号
    private static func fileOrder(_ a: ExportPackageScan.ConversationFile, _ b: ExportPackageScan.ConversationFile) -> Bool {
        let ta = a.latest ?? .distantPast, tb = b.latest ?? .distantPast
        if ta != tb { return ta < tb }
        return a.order < b.order
    }

    /// 包名里的序号：`conversations-003.zip` → 3，`…-batch-0001.zip` → 1；没有 = 0
    static func packageOrder(_ name: String) -> Int {
        let stem = (name as NSString).deletingPathExtension
        guard let r = stem.range(of: #"(\d+)$"#, options: .regularExpression) else { return 0 }
        return Int(stem[r]) ?? 0
    }

    private static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }

    // MARK: - 结构判定

    struct ConversationProbe {
        let source: ExportPackageScan.Source
        let entries: [ExportPackageScan.ConversationEntry]
    }

    /// 轻量解码：按对话切片，每段只解几个顶层键、消息体跳过（#050 E2：几百 MB 的文件也不整份解）。nil = 不是对话文件
    static func probeConversations(_ url: URL) -> ConversationProbe? {
        guard let file = try? JSONArrayFile(url: url) else { return nil }
        if file.count == 0 { return file.error == nil ? ConversationProbe(source: .claude, entries: []) : nil }
        let decoder = JSONDecoder()
        let rows = (0..<file.count).compactMap { try? file.decode(ProbeRow.self, at: $0, decoder: decoder) }
        // 逐条认，坏的几条不连累整份（sol #1）：哪家的多算哪家，坏条导入时进注意事项
        let claudeRows = rows.filter { $0.uuid != nil && $0.chat_messages != nil }
        let gptRows = rows.filter { $0.mapping != nil }
        guard !claudeRows.isEmpty || !gptRows.isEmpty else { return nil }
        if claudeRows.count >= gptRows.count {
            return ConversationProbe(source: .claude, entries: claudeRows.map {
                .init(id: $0.uuid!, updated: $0.updated_at.flatMap(ClaudeImporter.parseClaudeDate),
                      messageCount: $0.chat_messages!.count)
            })
        }
        // 缺 id 时导入按 conversation_id / 内容算（#050 E7）；都没有给个只用来计数的占位，带文件名不跟别的文件撞
        return ConversationProbe(source: .chatgpt, entries: gptRows.enumerated().map { index, row in
            .init(id: row.id ?? row.conversation_id ?? "无id:\(url.lastPathComponent)#\(index)",
                  updated: row.update_time.map { Date(timeIntervalSince1970: $0) },
                  messageCount: row.mapping!.count)
        })
    }

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    private struct ProbeRow: Decodable {
        let uuid: String?
        let id: String?
        let conversation_id: String?
        let updated_at: String?
        let update_time: Double?
        let chat_messages: [Skip]?
        let mapping: [String: Skip]?

        enum CodingKeys: String, CodingKey { case uuid, id, conversation_id, updated_at, update_time, chat_messages, mapping }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            conversation_id = try? c.decodeIfPresent(String.self, forKey: .conversation_id)
            updated_at = try? c.decodeIfPresent(String.self, forKey: .updated_at)
            update_time = try? c.decodeIfPresent(Double.self, forKey: .update_time)
            chat_messages = try? c.decodeIfPresent([Skip].self, forKey: .chat_messages)
            mapping = try? c.decodeIfPresent([String: Skip].self, forKey: .mapping)
        }
    }

    /// 直接选中的 json 按内容认（改过名也认）
    static func sniffDirectJSON(_ url: URL) -> Category? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if url.pathExtension.isEmpty, size > 64 << 20 { return nil }
        if let probe = probeConversations(url), !probe.entries.isEmpty { return .conversation }
        // 旧版 Kelivo 的 chats.json 可以很大：按名字收下，结构到预览时再核（sol #10）
        if size >= 64 << 20, url.lastPathComponent == KelivoArchive.chatsEntry { return .kelivoChats }
        guard size < 64 << 20, let data = try? ExportJSON.data(at: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return GeminiTakeoutParser.isTakeoutHTML(data) ? .geminiActivity : nil
        }
        if AIStudioParser.isAIStudio(obj) { return .aiStudio }
        if KelivoBackup.isLegacyChats(obj) { return .kelivoChats }
        if GeminiTakeoutParser.isTakeoutJSON(obj) { return .geminiActivity }
        let first: [String: Any]?
        if let dict = obj as? [String: Any] { first = dict }
        else { first = (obj as? [Any])?.first as? [String: Any] }
        guard let keys = first.map({ Set($0.keys) }) else { return nil }
        if keys.contains("data_files") { return .manifest }
        if keys.contains("prompt_template") || (keys.contains("docs") && keys.contains("uuid")) { return .project }
        if keys.contains("conversations_memory") || keys.contains("memory_files") || keys.contains("project_memories") { return .memory }
        // 更老的「一行一条」记忆：只在文件名像 memories 时认，免得把别的数组当记忆
        if url.lastPathComponent.lowercased().hasPrefix("memories"), obj is [Any], keys.contains("uuid"),
           keys.contains("content") || keys.contains("memory") { return .memory }
        if keys.contains("messages") && keys.contains("uuid") && obj is [String: Any] { return .designChat }
        return nil
    }

    /// Takeout 的 MyActivity 是不是 Gemini 的（别的产品也叫这个名字）。不限大小：用户照说明只勾了 Gemini 就只有这一份
    static func isGeminiActivity(_ url: URL) -> Bool {
        guard let data = try? ExportJSON.data(at: url) else { return false }
        if url.pathExtension.lowercased() == "html" { return GeminiTakeoutParser.isTakeoutHTML(data) }
        return GeminiImportSupport.jsonObject(data).map(GeminiTakeoutParser.isTakeoutJSON) ?? false
    }

    /// manifest 里列了、但没在这次选中的包名里出现的
    static func missingPackages(manifests: [URL], picked: [String]) -> [String] {
        let have = Set(picked)
        var missing: [String] = []
        for url in manifests {
            guard let data = try? ExportJSON.data(at: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = obj["data_files"] as? [[String: Any]] else { continue }
            for file in files {
                guard let name = file["filename"] as? String, !name.isEmpty, !have.contains(name) else { continue }
                // 月度回顾 / 账号信息本来就不导，缺了不提示
                let category = file["category"] as? String ?? ""
                if ["feedback", "light_metadata"].contains(category) { continue }
                missing.append(name)
            }
        }
        return unique(missing)
    }
}

/// 读导出 json：内存映射，剥 UTF-8 BOM
enum ExportJSON {
    static func data(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return data.dropFirst(3) }
        return data
    }
}
