#if (DEBUG || PERF_BENCH) && os(macOS)
import Foundation
import SwiftData
import Darwin

/// One-shot preparation, never part of a measurement. The host freezes the resulting
/// root and restores it at the same absolute path before each run. No production
/// provider manager is constructed here (its initializer warms the Keychain).
@MainActor
enum MacPerfSeed {
    private static let largeProfileID = "perf-bench-profile"
    private static let smallProfileID = "perf-bench-small"
    private static let streamConversationID = "mac-perf-stream"
    private static let streamPresetID = "mac-perf-stream-preset"
    private static let backgroundConversationID = "mac-perf-background"
    private static let backgroundMessageID = "mac-perf-background-edit"
    private static var started = false

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private struct Chat: Encodable {
        let name, profileID, conversationID: String
        let orderedPath: [String]
        let longNodeID: String
    }
    private struct Code: Encodable {
        let name, key, path: String
        let minimumBytes: UInt64
    }
    private struct File: Encodable {
        let path: String
        let bytes: UInt64
    }
    private struct Manifest: Encodable {
        let revision = "macV1-r1-fixture"
        let profiles: [String]
        let chats: [Chat]
        let code: [Code]
        let files: [File]
        // Live loads are added by the host only after real workers have started.
        let loads: [String] = []
        let streamConversationID: String
        let streamPresetID: String
    }
    private struct Floor: Encodable {
        let id: String
        let conversations, messages: Int
    }
    private struct CodeRound: Encodable {
        let round: Int
        let syntheticDay: Int
        let name, key: String
        let bytes: UInt64
        let messages, indexedUnits: Int
    }
    private struct Report: Encodable {
        let revision = "macV1-r1-seed"
        var status = "running"
        var stage = "preflight"
        var error: String?
        let startedAt = Date().timeIntervalSince1970
        var completedAt: Double?
        var profiles: [Floor] = []
        var codeRounds: [CodeRound] = []
        var files: [File] = []
        var bridgeFramesPath: String?
        let backgroundConversationID = MacPerfSeed.backgroundConversationID
        let backgroundMessageID = MacPerfSeed.backgroundMessageID
        let streamConversationID = MacPerfSeed.streamConversationID
        let streamPresetID = MacPerfSeed.streamPresetID
    }
    private struct ConversationSpec {
        let id, profileID, title: String
        let length: Int
        var branches = false
        var longText = false
        var background = false
    }

    /// Call once after prepareBenchProfile and after the isolated container exists,
    /// before normal startup jobs. Other seed modes and all measurement runs are inert.
    static func startIfRequested(context: ModelContext, profiles: ProfileManager) {
        guard BenchIsolation.active, let isolation = BenchIsolation.configuration,
              isolation.role == "seed", ProcessInfo.processInfo.environment["MP_PERF_SEED"] == "bulk",
              !started else { return }
        started = true
        Task { @MainActor in
            var report = Report()
            do {
                let directory = try isolation.check(isolation.root.appendingPathComponent("perf", isDirectory: true))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let manifestURL = try isolation.check(directory.appendingPathComponent("fixture.json"))
                guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
                    throw Failure("bulk seed requires a fresh root; an existing fixture will not be overwritten")
                }
                let manifest = try prepare(context: context, profiles: profiles, isolation: isolation, report: &report)
                report.status = "complete"
                report.stage = "complete"
                report.completedAt = Date().timeIntervalSince1970
                // Publish the manifest last: its existence is the commit marker. Both
                // files are independently atomic and all data/indices are saved first.
                try write(report, to: directory.appendingPathComponent("seed-result.json"), isolation: isolation)
                try write(manifest, to: manifestURL, isolation: isolation)
                FileHandle.standardOutput.write(Data("[mac-perf-seed] complete: 2700 conversations, 250000 messages; \(manifestURL.path)\n".utf8))
                exit(0)
            } catch {
                report.status = "failed"
                report.error = String(describing: error)
                report.completedAt = Date().timeIntervalSince1970
                FileHandle.standardError.write(Data("[mac-perf-seed] \(report.stage): \(error)\n".utf8))
                do {
                    let directory = try isolation.check(isolation.root.appendingPathComponent("perf", isDirectory: true))
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try write(report, to: directory.appendingPathComponent("seed-result.json"), isolation: isolation)
                } catch {
                    FileHandle.standardError.write(Data("[mac-perf-seed] cannot write failure result: \(error)\n".utf8))
                }
                exit(1)
            }
        }
    }

    private static func prepare(context: ModelContext, profiles: ProfileManager,
                                isolation: BenchIsolation.Configuration, report: inout Report) throws -> Manifest {
        guard context.container === profiles.container, profiles.currentProfile.id == largeProfileID else {
            throw Failure("prepareBenchProfile must select perf-bench-profile in the supplied container")
        }
        try profiles.ensureWritable()
        for configuration in context.container.configurations { _ = try isolation.check(configuration.url) }
        guard try context.fetchCount(FetchDescriptor<Conversation>()) == 0,
              try context.fetchCount(FetchDescriptor<MessageNode>()) == 0 else {
            throw Failure("bulk seed refuses a nonempty chat store; create a fresh isolated root")
        }
        for key in ["savedProfiles", "savedPresets"] { _ = try isolation.check(BlobStore.path(forKey: key)) }
        report.stage = "profiles-and-stream-selection"
        let model = ProviderModel(credentialId: PerfHarnessMacStream.credentialID,
                                  modelId: PerfHarnessMacStream.modelID, name: "Mac local scripted stream")
        var large = profiles.currentProfile
        large.presetId = streamPresetID
        large.preferredModel = model.id
        let small = Profile(id: smallProfileID, name: "Mac perf small", emoji: "S", description: "100 conversations / 2000 messages",
                            userName: "Benchmark user", assistantName: "Benchmark assistant", preferredModel: model.id)
        try profiles.persistNew(small)
        profiles.publish(small, activate: false)
        guard profiles.updateProfilesPersisting([large]) else { throw Failure("bench profile selection could not be persisted") }
        let presets = PresetManager()
        var preset = Preset.balanced
        preset.id = streamPresetID
        preset.name = "Mac perf scripted stream"
        preset.isBuiltIn = false
        preset.ownerProfileId = largeProfileID
        try presets.persistNew(preset)
        let credential = APICredential(id: model.credentialId, name: "Mac perf local scripted provider", emoji: "M",
                                       type: .openaiCompatible, baseURL: "http://127.0.0.1:9/v1", models: [model],
                                       toolsSupported: false)
        // Existing ProviderManager persistence ABI, confined to this bundle's isolated
        // preference domain. The scripted router intercepts this credential before I/O;
        // there is deliberately no API key, token, login or usable network fallback.
        let defaults = UserDefaults.standard
        defaults.set(try JSONEncoder().encode([credential]), forKey: "credentials")
        defaults.set(try JSONEncoder().encode([model.id]), forKey: "favoriteModels")
        defaults.set(model.id, forKey: "selectedChatModel")
        defaults.set(largeProfileID, forKey: "lastProfileId")

        report.stage = "bulk-chat-insert"
        let specs = conversationSpecs()
        let longText = longMarkdown()
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        // Short-lived contexts bound registered objects and autoreleased model work.
        // A save covers 16 conversations (~1500 nodes), never one save per node.
        for start in stride(from: 0, to: specs.count, by: 16) {
            try autoreleasepool {
                let batch = ModelContext(context.container)
                batch.autosaveEnabled = false
                for index in start..<min(start + 16, specs.count) {
                    insert(specs[index], into: batch, base: base.addingTimeInterval(Double(-index) * 3600), longText: longText, modelID: model.id)
                }
                try batch.save()
            }
        }
        for id in [largeProfileID, smallProfileID] {
            let conversations = try context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == id }))
            let messages = try context.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == id }))
            report.profiles.append(Floor(id: id, conversations: conversations, messages: messages))
        }
        guard report.profiles.map(\.conversations) == [2600, 100], report.profiles.map(\.messages) == [248000, 2000] else {
            throw Failure("persisted chat counts do not match 2600/248000 large and 100/2000 small")
        }
        let chats = zip(["A", "B", "C"], specs.prefix(3)).map { name, spec in
            Chat(name: name, profileID: spec.profileID, conversationID: spec.id,
                 orderedPath: (0..<spec.length).map { "\(spec.id)-\($0)" }, longNodeID: "\(spec.id)-\(spec.length - 3)")
        }
        report.stage = "code-incremental-aging"
        let code = try prepareCode(isolation: isolation, report: &report)
        report.stage = "bridge-replay-template"
        let bridgeURL = try isolation.check(isolation.root.appendingPathComponent("perf/bridge-frames.json"))
        try prepareBridge(at: bridgeURL, isolation: isolation)
        report.bridgeFramesPath = bridgeURL.path
        report.stage = "durable-fixture-publication"
        guard profiles.currentProfile.id == largeProfileID, defaults.synchronize() else {
            throw Failure("bench profile changed or isolated preferences could not be synchronized")
        }
        let paths = code.map(\.path) + [bridgeURL.path, BlobStore.path(forKey: "savedProfiles").path, BlobStore.path(forKey: "savedPresets").path]
        let files = try paths.map { path in
            let url = try isolation.check(URL(fileURLWithPath: path))
            return try File(path: url.path, bytes: fileBytes(url))
        }
        guard files.allSatisfy({ $0.bytes > 0 }) else { throw Failure("a fixture data file is empty") }
        report.files = files
        return Manifest(profiles: [largeProfileID, smallProfileID], chats: chats, code: code, files: files,
                        streamConversationID: streamConversationID, streamPresetID: streamPresetID)
    }

    private static func conversationSpecs() -> [ConversationSpec] {
        var specs = [
            ConversationSpec(id: "mac-perf-A", profileID: largeProfileID, title: "Mac perf A — 60 messages", length: 60, longText: true),
            ConversationSpec(id: "mac-perf-B", profileID: largeProfileID, title: "Mac perf B — 300 + 40 branch messages", length: 300, branches: true, longText: true),
            ConversationSpec(id: "mac-perf-C", profileID: largeProfileID, title: "Mac perf C — 2000 messages", length: 2000, longText: true),
            ConversationSpec(id: backgroundConversationID, profileID: largeProfileID, title: "Mac perf background bridge — 2000 messages", length: 2000, background: true),
            ConversationSpec(id: streamConversationID, profileID: largeProfileID, title: "Mac perf scripted stream", length: 2)
        ]
        // 4402 required nodes + 2263*94 + 332*93 = 248000 on the large floor.
        for index in 0..<2595 {
            specs.append(ConversationSpec(id: "mac-perf-bulk-\(index)", profileID: largeProfileID,
                                          title: "Mac perf library \(index): \(topics[index % topics.count])", length: index < 2263 ? 94 : 93))
        }
        for index in 0..<100 {
            specs.append(ConversationSpec(id: "mac-perf-small-\(index)", profileID: smallProfileID,
                                          title: "Mac perf small \(index): \(topics[index % topics.count])", length: 20))
        }
        return specs
    }

    private static let topics = ["Reading notes", "Project planning", "Markdown rendering", "SQLite indexing", "Branch comparison", "Conversation archive", "Incremental parsing", "Desktop layout"]

    private static func insert(_ spec: ConversationSpec, into context: ModelContext, base: Date, longText: String, modelID: String) {
        let conversation = Conversation(id: spec.id, title: spec.title, createTime: base,
                                        updateTime: base.addingTimeInterval(Double(spec.length)),
                                        currentNodeId: "\(spec.id)-\(spec.length - 1)", provider: "api", profileId: spec.profileID)
        conversation.nodeCount = spec.length + (spec.branches ? 40 : 0)
        conversation.selectedModelId = modelID
        var selections: [String: String] = [:]
        for index in 0..<spec.length {
            let id = "\(spec.id)-\(index)"
            var children = index + 1 < spec.length ? ["\(spec.id)-\(index + 1)"] : []
            if spec.branches && [100, 200].contains(index) {
                children.append("\(spec.id)-fork-\(index)-0")
                selections[id] = "\(spec.id)-\(index + 1)"
                for branch in 0..<20 {
                    context.insert(MessageNode(id: "\(spec.id)-fork-\(index)-\(branch)", role: branch.isMultiple(of: 2) ? "assistant" : "user",
                                               content: "Alternative branch \(index), revision \(branch). Compare the indexed result, preserve the chosen mainline, and explain the trade-off in the conversation.",
                                               contentType: "text", createTime: base.addingTimeInterval(Double(index + branch)),
                                               parentId: branch == 0 ? id : "\(spec.id)-fork-\(index)-\(branch - 1)",
                                               childrenIds: branch < 19 ? ["\(spec.id)-fork-\(index)-\(branch + 1)"] : [],
                                               conversationId: spec.id, profileId: spec.profileID))
                }
            }
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            let text = spec.longText && index == spec.length - 3 ? longText : messageText(conversation: spec.id, index: index, role: role)
            let node = MessageNode(id: id, role: role, content: text, contentType: "text", createTime: base.addingTimeInterval(Double(index)),
                                   parentId: index == 0 ? nil : "\(spec.id)-\(index - 1)", childrenIds: children,
                                   conversationId: spec.id, profileId: spec.profileID)
            if spec.background && index == spec.length - 1 { node.ccMessageId = backgroundMessageID }
            context.insert(node)
        }
        if !selections.isEmpty { conversation.branchSelectionData = BranchSelection.encode(selections) }
        context.insert(conversation)
    }

    private static func messageText(conversation: String, index: Int, role: String) -> String {
        let topic = topics[index % topics.count]
        if role == "user" {
            return "[\(conversation), turn \(index)] Review \(topic.lowercased()). Which observations should be retained, and how can the next step be checked without changing unrelated state?"
        }
        return "[\(conversation), turn \(index)] ## \(topic)\n\nKeep the ordered conversation path, compare the alternative, and save the relevant result as one transaction.\n\n- Record the concrete input and output.\n- Preserve the selected branch and floor boundary.\n- Reopen the saved discussion before drawing a conclusion.\n\n`revision_\(index)` identifies this answer, not a performance measurement."
    }

    private static func longMarkdown() -> String {
        (0..<48).map { section in
            """
            ## Section \(section): conversation rendering and ordered state

            This is a generated benchmark conversation, not personal history. A long answer exercises paragraph layout, emphasis, lists, tables and fenced code. The selected mainline remains ordered even when an alternative branch is present. 渲染长文时保留段落与列表之间的空白，楼层切换不会改变消息的父子关系；这些内容实际保存到隔离数据库，而非由 manifest 声称存在。

            - **Observation \(section)**: fetch the requested conversation on its own floor.
            - *Decision*: retain the existing path and compare one alternative.
            - Evidence belongs to the actual execution, never to this generated text.

            | phase | revision | state |
            | --- | ---: | --- |
            | prepare | \(section) | saved |
            | reopen | \(section + 1) | ordered |

            ```swift
            let revision = \(section)
            let next = revision + 1
            ```
            """
        }.joined(separator: "\n\n")
    }

    private static func prepareCode(isolation: BenchIsolation.Configuration, report: inout Report) throws -> [Code] {
        let root = try isolation.check(isolation.home.appendingPathComponent(".claude/projects", isDirectory: true))
        let project = try isolation.check(root.appendingPathComponent("mac-perf", isDirectory: true))
        let cwd = try isolation.check(isolation.root.appendingPathComponent("perf/code-project", isDirectory: true))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let adapter = ClaudeCodeAdapter(root: root)
        let indexURL = try isolation.check(CodingSessionIndex.defaultURL)
        let index = try CodingSessionIndex(url: indexURL)
        let cases: [(String, UInt64)] = [("small", 5_000_000), ("medium", 30_000_000), ("large", 100_000_000)]
        let code = cases.map { name, bytes in
            Code(name: name, key: "claude-code:mac-perf-code-\(name)", path: project.appendingPathComponent("mac-perf-code-\(name).jsonl").path, minimumBytes: bytes)
        }
        var nextRows = Array(repeating: 0, count: code.count)
        // Fifteen checkpoints span fourteen elapsed synthetic days. Every checkpoint
        // appends native rows and exercises the existing FTS replacement transaction.
        // Do not VACUUM, fabricate dbstat or write tables.
        for round in 1...15 {
            for (position, item) in code.enumerated() {
                try autoreleasepool {
                    let url = try isolation.check(URL(fileURLWithPath: item.path))
                    let target = item.minimumBytes * UInt64(round) / 15
                    try appendCode(to: url, targetBytes: target, nextRow: &nextRows[position], cwd: cwd.path, day: round - 1)
                    guard let ref = adapter.fileRef(url) else { throw Failure("Claude adapter rejected generated file \(url.path)") }
                    let parsed = try adapter.parseSession(ref)
                    guard parsed.unknownLines == 0, !parsed.units.isEmpty, parsed.meta.key == item.key else {
                        throw Failure("native Code parse failed its identity/content contract: \(item.name)")
                    }
                    guard try index.writeSession(parsed.meta, fileMtime: ref.mtimeMs, units: parsed.units),
                          try index.key(forPath: parsed.meta.filePath) == item.key else {
                        throw Failure("Code index did not persist \(item.name), round \(round)")
                    }
                    report.codeRounds.append(CodeRound(round: round, syntheticDay: round - 1, name: item.name, key: item.key, bytes: try fileBytes(url),
                                                       messages: parsed.meta.messageCount, indexedUnits: parsed.units.count))
                }
            }
        }
        for item in code {
            guard try fileBytes(URL(fileURLWithPath: item.path)) >= item.minimumBytes else { throw Failure("Code file below required size: \(item.name)") }
        }
        return code
    }

    private struct TextBlock: Encodable {
        let type = "text"
        let text: String
    }
    private struct CodeMessage: Encodable {
        let id, role: String
        let model = "mac-perf-fixture"
        let content: [TextBlock]
    }
    private struct CodeRow: Encodable {
        let type, uuid, sessionId, cwd: String
        let timestamp: Int64
        let message: CodeMessage
    }

    private static func appendCode(to url: URL, targetBytes: UInt64, nextRow: inout Int, cwd: String, day: Int) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            throw Failure("cannot open \(url.path), errno=\(code)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var bytes = try handle.seekToEnd()
        let session = url.deletingPathExtension().lastPathComponent
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while bytes < targetBytes {
            let row = nextRow
            let role = row.isMultiple(of: 2) ? "user" : "assistant"
            var text = ""
            text.reserveCapacity(8192)
            for paragraph in 0..<14 {
                if paragraph > 0 { text += "\n\n" }
                text += "Revision \(row), paragraph \(paragraph), session \(session). Review the incremental SQLite index, ordered conversation branches, native transcript parsing and desktop rendering. The source record is appended, parsed by the Claude adapter, then committed through the existing index transaction. Compare project \(row % 37), component \(paragraph), and change \(row * 14 + paragraph); retain concrete observations rather than inventing latency or allocation results."
            }
            let message = CodeMessage(id: "\(session)-message-\(row)", role: role, content: [TextBlock(text: text)])
            let object = CodeRow(type: role, uuid: "\(session)-row-\(row)", sessionId: session, cwd: cwd,
                                 timestamp: Int64(1_790_812_800_000) + Int64(day) * 86_400_000 + Int64(row) * 1000, message: message)
            var data = try encoder.encode(object)
            data.append(0x0a)
            try handle.write(contentsOf: data)
            bytes += UInt64(data.count)
            nextRow += 1
        }
        try handle.synchronize()
    }

    private struct BridgeEdit: Encodable {
        let type = "edit"
        let streaming = true
        let mp_msg_id = MacPerfSeed.backgroundMessageID
        let chat_id = MacPerfSeed.backgroundConversationID
        let content: String
    }
    private struct BridgeFrame: Encodable { let offset: Double; let text: String }
    private static func prepareBridge(at url: URL, isolation: BenchIsolation.Configuration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let frames = try (0...4000).map { frame -> BridgeFrame in
            let object = BridgeEdit(content: "Background replay frame \(frame): saved large-floor message update, revision \(frame).")
            let text = String(decoding: try encoder.encode(object), as: UTF8.self)
            return BridgeFrame(offset: Double(frame) * 0.15, text: text)
        }
        try write(frames, to: url, isolation: isolation)
    }

    private static func fileBytes(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw Failure("missing actual file size: \(url.path)") }
        return size.uint64Value
    }

    private static func write<T: Encodable>(_ value: T, to url: URL, isolation: BenchIsolation.Configuration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try isolation.writeAtomically(encoder.encode(value), to: url)
    }
}
#endif
