import Foundation
import SwiftData

/// Claude 导出包里的项目（A 代 projects.json 数组 / B、C 代 projects/<uuid>.json 单个）
struct ClaudeProject: Decodable, Equatable {
    struct Doc: Decodable, Equatable {
        let uuid: String?
        let filename: String?
        let content: String?
    }

    let uuid: String
    let name: String?
    let description: String?
    let prompt_template: String?
    let docs: [Doc]?

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "未命名项目" : trimmed
    }

    /// 读一个项目文件：数组或单个对象都认；读不了返回 nil
    static func load(_ url: URL) -> [ClaudeProject]? {
        guard let data = try? ExportJSON.data(at: url) else { return nil }
        if let many = try? JSONDecoder().decode([ClaudeProject].self, from: data) { return many }
        if let one = try? JSONDecoder().decode(ClaudeProject.self, from: data) { return [one] }
        return nil
    }
}

/// 一个要写进文件库的文本文件
struct LibraryWrite: Equatable {
    let relPath: String
    let content: String
}

/// 项目文档 / 记忆文件 / artifact → 当前楼层文件库（#043 plan §3.3，D3）。
/// `plan` 是纯函数（测试只测它）；`apply` 才碰文件库，且绝不覆盖已有文件。
enum ClaudeLibraryImporter {
    static let projectsRoot = "Claude 项目"
    static let memoriesRoot = "Claude 记忆"
    static let artifactsRoot = "Claude Artifacts"

    /// 文件库按文本写的扩展名（`FileLibraryStore.textExtensions`）；别的扩展名补 `.md`
    static let textExtensions: Set<String> = ["md", "markdown", "html", "htm", "txt", "json", "css", "js"]

    struct Plan: Equatable {
        var writes: [LibraryWrite] = []
        /// 没法写的（不支持的格式、缺版本文件），给结果页
        var skipped: [String] = []
    }

    static func plan(projects: [ClaudeProject], memoryFiles: [(path: String, content: String)], artifactDirs: [URL]) -> Plan {
        var plan = Plan()
        var namer = UniqueNamer()

        for project in projects {
            guard let folder = namer.name(cleanComponent(project.displayName) ?? "未命名项目",
                                          in: projectsRoot, source: project.uuid) else {
                plan.skipped.append("项目 \(project.displayName)：重名")
                continue
            }
            let base = "\(projectsRoot)/\(folder)"
            let desc = project.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = project.prompt_template?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !desc.isEmpty || !prompt.isEmpty {
                var text = "# \(project.displayName)\n"
                if !desc.isEmpty { text += "\n## 描述\n\n\(desc)\n" }
                if !prompt.isEmpty { text += "\n## 项目指令\n\n\(prompt)\n" }
                if let name = namer.name("说明.md", in: base, source: project.uuid + "#readme") {
                    plan.writes.append(LibraryWrite(relPath: "\(base)/\(name)", content: text))
                }
            }
            for (i, doc) in (project.docs ?? []).enumerated() {
                guard let content = doc.content else { continue }
                let raw = textFileName(cleanComponent(doc.filename ?? "") ?? "文档 \(i + 1)")
                if let name = namer.name(raw, in: base, source: doc.uuid ?? "\(project.uuid)#\(i)") {
                    plan.writes.append(LibraryWrite(relPath: "\(base)/\(name)", content: content))
                } else {
                    plan.skipped.append("\(base)/\(raw)：重名")
                }
            }
        }

        for file in memoryFiles {
            guard let rel = cleanRelativePath(file.path) else {
                plan.skipped.append(file.path)
                continue
            }
            let parts = rel.split(separator: "/").map(String.init)
            let dir = ([memoriesRoot] + parts.dropLast()).joined(separator: "/")
            if let name = namer.name(textFileName(parts.last!), in: dir, source: file.path) {
                plan.writes.append(LibraryWrite(relPath: "\(dir)/\(name)", content: file.content))
            } else {
                plan.skipped.append("\(file.path)：重名")
            }
        }

        for dir in artifactDirs {
            planArtifact(dir, into: &plan, namer: &namer)
        }
        return plan
    }

    // MARK: - artifact

    private struct ArtifactMeta: Decodable {
        struct Version: Decodable {
            let id: String
            let title: String?
        }
        let id: String?
        let versions: [Version]?
        let active_version: String?
    }

    /// 只取 active_version：单文件 `versions/<ver>.<ext>` 或目录 `versions/<ver>/**`
    private static func planArtifact(_ dir: URL, into plan: inout Plan, namer: inout UniqueNamer) {
        let fm = FileManager.default
        let label = dir.lastPathComponent
        guard let data = try? ExportJSON.data(at: dir.appendingPathComponent("artifact.json")),
              let meta = try? JSONDecoder().decode(ArtifactMeta.self, from: data),
              let active = meta.active_version, !active.isEmpty,
              cleanComponent(active) == active else {
            plan.skipped.append("artifact \(label)：缺 artifact.json 或当前版本")
            return
        }
        let title = meta.versions?.first { $0.id == active }?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = meta.id ?? label
        guard let folder = namer.name(cleanComponent(title ?? "") ?? cleanComponent(label) ?? "artifact",
                                      in: artifactsRoot, source: source) else {
            plan.skipped.append("artifact \(title ?? label)：重名")
            return
        }
        let base = "\(artifactsRoot)/\(folder)"
        let versions = dir.appendingPathComponent("versions")

        var isDir: ObjCBool = false
        let versionDir = versions.appendingPathComponent(active)
        if fm.fileExists(atPath: versionDir.path, isDirectory: &isDir), isDir.boolValue {
            guard let e = fm.enumerator(at: versionDir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard v?.isSymbolicLink != true, v?.isRegularFile == true else { continue }
                addArtifactFile(url, rel: url.pathComponents.suffix(e.level).joined(separator: "/"), base: base, source: source,
                                plan: &plan, namer: &namer)
            }
            return
        }

        let names = (try? fm.contentsOfDirectory(atPath: versions.path)) ?? []
        guard let file = names.first(where: { ($0 as NSString).deletingPathExtension == active && !$0.hasSuffix(".files.json") }) else {
            plan.skipped.append("artifact \(title ?? label)：缺当前版本文件")
            return
        }
        let ext = (file as NSString).pathExtension
        let fileName = ext.isEmpty ? folder : "\(folder).\(ext)"
        addArtifactFile(versions.appendingPathComponent(file), rel: fileName, base: base, source: source,
                        plan: &plan, namer: &namer)
    }

    private static func addArtifactFile(_ url: URL, rel: String, base: String, source: String,
                                        plan: inout Plan, namer: inout UniqueNamer) {
        guard let clean = cleanRelativePath(rel) else {
            plan.skipped.append(rel)
            return
        }
        let ext = (clean as NSString).pathExtension.lowercased()
        guard textExtensions.contains(ext),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            plan.skipped.append("\(base)/\(clean)：不是文本文件")
            return
        }
        let parts = clean.split(separator: "/").map(String.init)
        let dir = ([base] + parts.dropLast()).joined(separator: "/")
        if let name = namer.name(parts.last!, in: dir, source: "\(source)/\(clean)") {
            plan.writes.append(LibraryWrite(relPath: "\(dir)/\(name)", content: content))
        } else {
            plan.skipped.append("\(dir)/\(clean)：重名")
        }
    }

    // MARK: - 写库

    struct ApplyResult: Equatable {
        var written = 0
        var existing = 0
        var failed: [String] = []
        /// 逐条去向（#061 导入清单）
        var items: [ImportManifest.LibraryItem] = []
    }

    /// 后台线程调。`create` 默认写当前楼层文件库；测试传临时目录的实现。
    static func apply(_ writes: [LibraryWrite], create: (LibraryWrite) throws -> Bool) -> ApplyResult {
        var result = ApplyResult()
        for write in writes {
            do {
                if try create(write) {
                    result.written += 1
                    result.items.append(.init(path: write.relPath))
                } else {
                    result.existing += 1
                    result.items.append(.init(path: write.relPath, reason: "同名已有，没覆盖"))
                }
            } catch {
                result.failed.append(write.relPath)
                result.items.append(.init(path: write.relPath, reason: "写失败：\(error.localizedDescription)"))
            }
        }
        return result
    }

    // MARK: - 名字清洗（astra #10 #11）

    /// 单个名字：去控制字符、斜杠换全角、NFC、拒绝空 / . / ..、隐藏文件加前缀、按字节截长
    static func cleanComponent(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var s = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: "\\", with: "＼")
            .replacingOccurrences(of: ":", with: "：")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !s.isEmpty, s != ".", s != ".." else { return nil }
        if s.hasPrefix(".") { s = "_" + s }
        return FileLibraryStore.clampComponent(s)
    }

    /// 带子目录的相对路径：逐段清洗；有 `..` 整条拒绝；空段丢掉
    static func cleanRelativePath(_ raw: String) -> String? {
        var out: [String] = []
        for seg in raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            let t = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == "." { continue }
            if t == ".." { return nil }
            guard let c = cleanComponent(t) else { return nil }
            out.append(c)
        }
        return out.isEmpty ? nil : out.joined(separator: "/")
    }

    /// 文本类扩展名保留，别的补 `.md`（`报告.pdf` → `报告.pdf.md`）
    static func textFileName(_ name: String) -> String {
        textExtensions.contains((name as NSString).pathExtension.lowercased()) ? name : name + ".md"
    }

    /// 同一目录下的重名：按 NFC + 不分大小写判断；同一来源永远拿到同一个名字，
    /// 不同来源撞名就在名字后加来源前 4 位（不按枚举顺序加序号，再导一次路径不变）
    struct UniqueNamer {
        private var taken: [String: [String: String]] = [:]   // dir → (key → source)

        /// nil = 换了完整来源 id 还撞（几乎不可能），调用方记进「跳过」，不静默丢
        mutating func name(_ wanted: String, in dir: String, source: String) -> String? {
            var bucket = taken[dir] ?? [:]
            let ext = (wanted as NSString).pathExtension
            let stem = ext.isEmpty ? wanted : (wanted as NSString).deletingPathExtension
            let tag = source.filter { $0.isLetter || $0.isNumber }
            let candidates = [wanted] + [String(tag.prefix(4)), tag].map { t in
                FileLibraryStore.clampComponent(ext.isEmpty ? "\(stem) · \(t)" : "\(stem) · \(t).\(ext)")
            }
            for candidate in candidates {
                let key = Self.key(candidate)
                if let owner = bucket[key], owner != source { continue }
                bucket[key] = source
                taken[dir] = bucket
                return candidate
            }
            return nil
        }

        static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
    }
}

// MARK: - 导入建文件夹（通用：Claude 项目、别的导入源的「助手」等都走这里）

enum ImportFolders {
    struct Spec {
        /// 来源里的稳定 id（项目 uuid…）
        let source: String
        /// 文件夹 id 前缀，区分来源种类（`claude-project`、`claude-design`…）
        let idPrefix: String
        let name: String
        let instructions: String
    }

    struct Result: Equatable {
        var created = 0
        var existing = 0
        /// 来源 id → 文件夹 id（新建或复用的）
        var folderIdBySource: [String: String] = [:]
        /// 新建 / 复用的是哪些（#061 导入清单）
        var createdFolders: [ImportManifest.Ref] = []
        var existingFolders: [ImportManifest.Ref] = []
    }

    /// 文件夹 id：同一楼层同一来源永远同一个（再导一次认得出来，不重复建、不改你编辑过的）
    static func folderId(source: String, idPrefix: String, profileId: String) -> String {
        "\(idPrefix):\(source):\(profileId.prefix(8))"
    }

    /// 建文件夹。`instructions` 进「文件夹说明」；本楼层已有同名文件夹就直接用（不改它）。
    /// 新建的每个记一行 `createdFolder` 变更，撤回导入时删。
    static func ensure(_ specs: [Spec], profileId: String, recordId: UUID, context: ModelContext) throws -> Result {
        var result = Result()
        let pid = profileId
        let tags = try context.fetch(FetchDescriptor<ConversationTag>(predicate: #Predicate { $0.profileId == pid }))
        var byId = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byName = Dictionary(tags.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var nextOrder = (tags.map(\.order).max() ?? -1) + 1

        for spec in specs where result.folderIdBySource[spec.source] == nil {
            let id = folderId(source: spec.source, idPrefix: spec.idPrefix, profileId: profileId)
            let name = spec.name
            if let tag = byId[id] ?? byName[name] {
                result.existing += 1
                result.existingFolders.append(.init(id: tag.id, title: tag.name))
                result.folderIdBySource[spec.source] = tag.id
                continue
            }
            let tag = ConversationTag(name: name, order: nextOrder, profileId: profileId)
            tag.id = id
            tag.symbol = "folder"
            tag.instructions = spec.instructions
            context.insert(tag)
            context.insert(ImportConversationChange(recordId: recordId, conversationId: id,
                                                    changeKind: .createdFolder, profileId: profileId))
            nextOrder += 1
            byId[id] = tag
            byName[name] = tag
            result.created += 1
            result.createdFolders.append(.init(id: id, title: name))
            result.folderIdBySource[spec.source] = id
        }
        try context.save()
        return result
    }
}

/// Claude 项目 / 设计项目 → 花园文件夹（D7）
enum ClaudeProjectFolders {
    static func folderId(source: String, kind: String, profileId: String) -> String {
        ImportFolders.folderId(source: source, idPrefix: "claude-\(kind)", profileId: profileId)
    }

    static func apply(projects: [ClaudeProject], designProjects: [(uuid: String, name: String)],
                      profileId: String, recordId: UUID, context: ModelContext) throws -> ImportFolders.Result {
        let projectSpecs = projects.map { project -> ImportFolders.Spec in
            let prompt = project.prompt_template?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let desc = project.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(source: project.uuid, idPrefix: "claude-project", name: project.displayName,
                         instructions: prompt.isEmpty ? desc : prompt)
        }
        let designSpecs = designProjects.map { design -> ImportFolders.Spec in
            let name = design.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(source: design.uuid, idPrefix: "claude-design", name: name.isEmpty ? "设计项目" : name,
                         instructions: "")
        }
        return try ImportFolders.ensure(projectSpecs + designSpecs, profileId: profileId, recordId: recordId, context: context)
    }
}
