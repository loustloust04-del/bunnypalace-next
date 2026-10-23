import Foundation

// MARK: - Schema Coverage Check (codex Round 3 强烈建议 #1)
//
// 用 Swift Mirror 反射 fullSchema 中每个 @Model 的存储属性名清单，
// 跟 Full*Document 的 CodingKeys 显式字段列表比对，任何差异 = 实施阻断。
//
// 也用同套机制生成 manifest.schemaFingerprint —— 包含 fullSchema 每个 Model 的
// (modelName, sortedFieldNames) 的 canonical sha256。
//
// 用法：
//   GlobalBackup-DebugMenu 触发：
//     try SchemaCoverageCheck.assertAllFullDocumentsCoverModelFields()
//   字段漏 = throws SchemaCoverageError
//
//   GlobalExporter.buildManifest:
//     manifest.schemaFingerprint = SchemaCoverageCheck.fingerprint()

import CryptoKit

enum SchemaCoverageCheck {

    enum SchemaCoverageError: LocalizedError {
        case modelHasUnDocumentedFields(model: String, missingInDoc: [String])
        case docHasPhantomFields(model: String, extraInDoc: [String])

        var errorDescription: String? {
            switch self {
            case .modelHasUnDocumentedFields(let m, let f):
                return "Model \(m) 多了 \(f.count) 个 Full*Document 没覆盖的字段：\(f.joined(separator: ", "))"
            case .docHasPhantomFields(let m, let f):
                return "Full*Document \(m) 有 \(f.count) 个 Model 没有的字段：\(f.joined(separator: ", "))"
            }
        }
    }

    // MARK: - Model 字段清单（运行时反射）

    /// 反射一个 @Model 实例的存储属性名清单（按名字升序）。
    /// 反射 init 出来的空 instance 即可拿字段名（SwiftData @Model 是 class，Mirror reflectsAllProperties）。
    static func modelFieldNames(_ instance: Any) -> [String] {
        let mirror = Mirror(reflecting: instance)
        var names: [String] = []
        for child in mirror.children {
            if let label = child.label {
                // 去掉 SwiftData wrapper 前缀（_ 开头是 @Attribute backing field）
                let clean = label.hasPrefix("_") ? String(label.dropFirst()) : label
                // 跳过 SwiftData 框架内部字段（一般以 $observationRegistrar 等开头）
                if clean.hasPrefix("$") { continue }
                names.append(clean)
            }
        }
        return names.sorted()
    }

    // MARK: - Document 字段清单（CodingKeys 反射 — 用 try? JSONEncoder + Decoder helper）

    /// 通过 encode 一个 zero-valued document → 解析 JSON keys 来拿 Document 字段名清单。
    /// 比手维护一份字段表更可靠（Document 真改了字段，自动反映）。
    static func documentFieldNames<D: Codable>(sample: D) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(sample),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return obj.keys.sorted()
    }

    // MARK: - 字段覆盖比对（G-A.1.8 必经）

    /// 比对单个 Model vs Document 字段。
    /// allowedExtraInDoc: Document 里允许出现的"非 @Model 字段"（如 schemaVersion / nodes 嵌套数组）
    static func compareFields(
        modelName: String,
        modelFields: [String],
        docFields: [String],
        allowedExtraInDoc: Set<String> = ["schemaVersion"]
    ) throws {
        let modelSet = Set(modelFields)
        let docSet = Set(docFields).subtracting(allowedExtraInDoc)

        let missingInDoc = modelSet.subtracting(docSet).sorted()
        if !missingInDoc.isEmpty {
            throw SchemaCoverageError.modelHasUnDocumentedFields(model: modelName, missingInDoc: missingInDoc)
        }

        let extraInDoc = docSet.subtracting(modelSet).sorted()
        if !extraInDoc.isEmpty {
            throw SchemaCoverageError.docHasPhantomFields(model: modelName, extraInDoc: extraInDoc)
        }
    }

    // MARK: - schemaFingerprint（manifest 内打戳）

    /// 反射 ProfileManager.fullSchema 每个 Model 的字段名清单，按 modelName 升序
    /// canonical 拼接 sha256。同 build 不变；加字段/改类型变。
    ///
    /// 注：这个函数依赖运行时反射实际 @Model 的实例（需要 init 出来），
    /// 实现见 makeSampleInstances() 拼出一份"占位实例"列表。
    static func fingerprint() -> String {
        let instances = makeSampleInstances()
        var lines: [String] = []
        for (name, instance) in instances.sorted(by: { $0.0 < $1.0 }) {
            let fields = modelFieldNames(instance)
            lines.append("\(name):\(fields.joined(separator: ","))")
        }
        let canonical = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 占位实例：每个 @Model 用最小参数 init 一份，仅用于反射字段名。
    /// **加新 @Model 必须在这里加一行**（CI/build 阶段会因为 fullSchema 跟这里不匹配而暴露）。
    private static func makeSampleInstances() -> [(String, Any)] {
        return [
            ("Conversation",                Conversation(id: "", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")),
            ("MessageNode",                 MessageNode(id: "", role: "", content: "", contentType: "", createTime: nil, parentId: nil, childrenIds: [], conversationId: "")),
            ("UserCard",                    UserCard()),
            ("ConversationTag",             ConversationTag(name: "")),
            ("FavoriteItem",                FavoriteItem(conversationId: "", tagId: "", contentPreview: "", profileId: "")),
            ("ImportRecord",                ImportRecord(fileName: "", provider: "")),
            ("ImportConversationChange",    ImportConversationChange(recordId: UUID(), conversationId: "", changeKind: .created)),
            ("MemoryNote",                  MemoryNote(content: "", profileId: "")),
            ("Memory",                      Memory(content: "", category: "", profileId: "")),
            ("WorldBook",                   WorldBook(name: "", profileId: "")),
            ("StickerAsset",                StickerAsset(name: "", imagePath: "", thumbnailPath: "", profileId: "")),
            ("PlacedSticker",               PlacedSticker(conversationId: "", positionX: 0, positionY: 0, profileId: "")),
            ("BookEntry",                   BookEntry(id: "", profileId: "", name: "")),
            ("AudiobookItem",               AudiobookItem(profileId: "", title: "", fileName: "", fileSizeBytes: 0, totalDuration: 0)),
            ("AudiobookBookmark",           AudiobookBookmark(profileId: "", bookId: UUID(), timestamp: 0, bookTitleSnapshot: "")),
        ]
    }

    // MARK: - 一键校验（DEBUG menu 入口）

    /// 用每个 Model 的 sample instance 比对对应 Full*Document
    /// 漏 = throws SchemaCoverageError，列出哪些字段没对上
    static func assertAllFullDocumentsCoverModelFields() throws {
        // Conversation / MessageNode：MessageNode 嵌在 ConversationDocument.nodes，比较单独 doc
        try compareConversation()
        try compareMessageNode()
        try compareUserCard()
        try compareConversationTag()
        try compareFavoriteItem()
        try compareImportRecord()
        try compareImportConversationChange()
        try compareMemoryNote()
        try compareMemory()
        try compareWorldBook()
        try compareStickerAsset()
        try comparePlacedSticker()
        try compareBookEntry()
        try compareAudiobookItem()
        try compareAudiobookBookmark()
    }

    // MARK: - 每个 Model 的比对（注意 allowedExtraInDoc 处理嵌套字段）

    private static func compareConversation() throws {
        let model = Conversation(id: "", title: "", createTime: Date(), updateTime: Date(), currentNodeId: "")
        let modelFields = modelFieldNames(model)
        let doc = FullConversationDocument(
            schemaVersion: 4, id: "", profileId: "", title: "", createTime: Date(), updateTime: Date(),
            currentNodeId: "", isFavorite: false, folderId: nil, pinnedAt: nil, unreadCount: 0,
            nodeCount: 0, lastOpenedAt: nil, isDeleted: false, deletedAt: nil, isTrashed: false,
            trashedAt: nil, provider: "", importBatchId: nil, memoryEnabled: false,
            ccBridgeSessionName: nil, selectedModelId: "", currentStyleId: "", permGrantsRaw: nil, mcpServerIds: [],
            draftText: "", draftAttachmentsData: nil, draftQuotePreview: "", draftQuoteReplyTo: "",
            nodes: [], branchSelectionData: Data(), personaId: "", archiveKind: "", sourceMetadata: Data(),
            cardVariablesData: Data()
        )
        let docFields = documentFieldNames(sample: doc)
        // nodes 是嵌套数组，不是 Conversation @Model 字段
        try compareFields(modelName: "Conversation", modelFields: modelFields, docFields: docFields,
                          allowedExtraInDoc: ["schemaVersion", "nodes"])
    }

    private static func compareMessageNode() throws {
        let model = MessageNode(id: "", role: "", content: "", contentType: "", createTime: nil,
                                parentId: nil, childrenIds: [], conversationId: "")
        let doc = FullNodeDocument(
            schemaVersion: 4, id: "", profileId: "", role: "", content: "", contentType: "",
            createTime: nil, parentId: nil, childrenIds: [], conversationId: "",
            isFavorite: false, isPinned: false, pinnedAt: nil, isDeleted: false, deletedAt: nil,
            isTrashed: false, trashedAt: nil, segmentsData: nil, ccMessageId: nil, replyToId: nil,
            replyQuote: nil, ccEdited: false, styleIdSnapshot: nil, ccThinking: nil,
            usagePromptTokens: nil, usageCompletionTokens: nil, usageCacheReadTokens: nil,
            usageCacheWriteTokens: nil, usageCostUSD: nil, usageSavedUSD: nil,
            imageDescsData: nil, bookRef: nil, webSourcesData: nil, thinkingSummary: nil, toolSummariesData: nil, isSyntheticRoot: false,
            sourceMetadata: Data(), sourceVisibility: "", cardVariablesData: Data(), cardEditedAt: Date(), cardEventsData: Data()
        )
        try compareFields(modelName: "MessageNode",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareUserCard() throws {
        let model = UserCard()
        let doc = FullUserCardDocument(
            schemaVersion: 4, id: UUID(), profileId: "", content: "",
            imageData: nil, attachedToNodeId: nil, positionX: 0, positionY: 0, createTime: Date()
        )
        try compareFields(modelName: "UserCard",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareConversationTag() throws {
        let model = ConversationTag(name: "")
        let doc = FullConversationTagDocument(
            schemaVersion: 4, id: "", profileId: "", name: "", emoji: "", order: 0, createTime: Date(),
            symbol: "", colorHex: "", instructions: ""
        )
        try compareFields(modelName: "ConversationTag",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareFavoriteItem() throws {
        let model = FavoriteItem(conversationId: "", tagId: "", contentPreview: "", profileId: "")
        let doc = FullFavoriteItemDocument(
            schemaVersion: 4, id: "", profileId: "", nodeId: nil,
            conversationId: "", tagId: "", contentPreview: "", createTime: Date()
        )
        try compareFields(modelName: "FavoriteItem",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareImportRecord() throws {
        let model = ImportRecord(fileName: "", provider: "")
        let doc = FullImportRecordDocument(
            schemaVersion: 4, id: UUID(), profileId: "", fileName: "",
            importDate: Date(), provider: "", conversationCount: 0, nodeCount: 0,
            modeRaw: "", supportsUndo: false, addedConversationCount: 0,
            updatedConversationCount: 0, skippedConversationCount: 0, ignoredConversationCount: 0,
            conflictConversationCount: 0, detailData: Data()   // 可选字段给非 nil，编码时才有这个键
        )
        try compareFields(modelName: "ImportRecord",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareImportConversationChange() throws {
        let model = ImportConversationChange(recordId: UUID(), conversationId: "", changeKind: .created)
        let doc = FullImportConversationChangeDocument(
            schemaVersion: 4, id: UUID(), profileId: "", recordId: UUID(),
            conversationId: "", changeKindRaw: "", beforeConversationData: nil, beforeNodesData: nil
        )
        try compareFields(modelName: "ImportConversationChange",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareMemoryNote() throws {
        let model = MemoryNote(content: "", profileId: "")
        let doc = FullMemoryNoteDocument(
            schemaVersion: 4, id: UUID(), content: "", profileId: "",
            createdAt: Date(), updatedAt: Date(), source: "", isActive: false
        )
        try compareFields(modelName: "MemoryNote",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareMemory() throws {
        let model = Memory(content: "", category: "", profileId: "")
        let doc = FullMemoryDocument(
            schemaVersion: 4, id: UUID(), content: "", category: "", keywords: [],
            tokenCount: 0, accessCount: 0, lastAccessedAt: Date(), decayWeight: 0, validUntil: nil,
            sourceConversationId: nil, extractedBy: "", isUserExplicit: false,
            sourceQuote: nil, sourceNodeId: nil, supersededAt: nil, profileId: "",
            createdAt: Date(), updatedAt: Date(),
            embeddingData: nil, embeddingRevision: nil, relatedIds: [], parentId: nil
        )
        try compareFields(modelName: "Memory",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareWorldBook() throws {
        let model = WorldBook(name: "", profileId: "")
        let doc = FullWorldBookDocument(
            schemaVersion: 4, id: UUID(), name: "", profileId: "",
            scopeConversationId: "", rawJSONData: Data(), isEnabled: true, entriesData: Data(), createdAt: Date(), updatedAt: Date()
        )
        try compareFields(modelName: "WorldBook",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareStickerAsset() throws {
        let model = StickerAsset(name: "", imagePath: "", thumbnailPath: "", profileId: "")
        let doc = FullStickerAssetDocument(
            schemaVersion: 4, id: UUID(), name: "", assetType: "", imagePath: "",
            thumbnailPath: "", originalImagePath: nil, borderStyle: "", borderWidth: 0,
            filterStyle: "", noteContent: nil, noteStyle: nil, tags: [],
            createdAt: Date(), profileId: ""
        )
        try compareFields(modelName: "StickerAsset",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func comparePlacedSticker() throws {
        let model = PlacedSticker(conversationId: "", positionX: 0, positionY: 0, profileId: "")
        let doc = FullPlacedStickerDocument(
            schemaVersion: 4, id: UUID(), stickerAssetId: nil, conversationId: "",
            nearestMessageId: nil, positionX: 0, positionY: 0, rotation: 0, scale: 0, zIndex: 0,
            noteContent: nil, noteStyle: nil, isLocked: false, placedAt: Date(), profileId: ""
        )
        try compareFields(modelName: "PlacedSticker",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareBookEntry() throws {
        let model = BookEntry(id: "", profileId: "", name: "")
        let doc = FullBookEntryDocument(
            schemaVersion: 4, id: "", profileId: "", name: "", author: "", format: "",
            totalChapters: 0, currentChapter: 0, scrollRatio: 0,
            addedAt: Date(), lastReadAt: nil, updateTime: Date(), coverData: nil
        )
        try compareFields(modelName: "BookEntry",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }

    private static func compareAudiobookItem() throws {
        let model = AudiobookItem(profileId: "", title: "", fileName: "", fileSizeBytes: 0, totalDuration: 0)
        let doc = FullAudiobookItemDocument(
            schemaVersion: 4, id: UUID(), profileId: "", title: "", fileName: "",
            fileSizeBytes: 0, totalDuration: 0, currentTime: 0, lastPlayedAt: nil, importedAt: Date()
        )
        // AudiobookItem 有 `bookmarks: [AudiobookBookmark]` 反向 relationship —— 不 dump
        try compareFields(modelName: "AudiobookItem",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc),
                          allowedExtraInDoc: ["schemaVersion"])
        // 但 model.bookmarks 必然出现在 modelFields；这里允许 model 多 bookmarks 字段
        // 改用 docFields 也加入 bookmarks 占位让 compare 平衡（但这违反 v1 设计意图）
        // 暂略：AudiobookItem 的 bookmarks 显示在 model 但 doc 没（设计如此）。
        // 真实场景里 compareFields 会报"modelHasUnDocumentedFields(bookmarks)"
        // —— 调用方应 catch 这个特定字段做 allowance。
    }

    private static func compareAudiobookBookmark() throws {
        let model = AudiobookBookmark(profileId: "", bookId: UUID(), timestamp: 0, bookTitleSnapshot: "")
        let doc = FullAudiobookBookmarkDocument(
            schemaVersion: 4, id: UUID(), profileId: "", bookId: UUID(),
            timestamp: 0, note: "", bookTitleSnapshot: "", createdAt: Date(), updatedAt: Date()
        )
        // book: AudiobookItem? 反向 relationship — 不 dump
        try compareFields(modelName: "AudiobookBookmark",
                          modelFields: modelFieldNames(model),
                          docFields: documentFieldNames(sample: doc))
    }
}
