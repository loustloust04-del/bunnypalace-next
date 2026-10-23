import Foundation

// MARK: - Full*Document ↔ @Model 转换
//
// 集中放 Model → Document（export）和 Document → Model（staging import）的转换函数。
//
// 设计：
// - 每个 @Model 类型对应一组 init(from:) 和 toModel(profileId:) 函数
// - profileId 在 export 时从 model 字段直接读；import 时由调用方传（因为 staging 用包内 profileId）
// - 反向 relationship（AudiobookItem.bookmarks / AudiobookBookmark.book）由调用方 wire up
// - 不直接 ctx.insert — 调用方负责（GlobalExporter 用 fetch；GlobalImporter staging build 用 insert）
//
// 字段映射跟 SchemaCoverageCheck.modelFields 一一对应；改一处必须同步改另一处。

// MARK: - Constants

private let kSchemaV: Int = 4

// MARK: - Conversation + MessageNode

extension FullConversationDocument {
    init(model: Conversation, nodes: [MessageNode]) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            title: model.title,
            createTime: model.createTime,
            updateTime: model.updateTime,
            currentNodeId: model.currentNodeId,
            isFavorite: model.isFavorite,
            folderId: model.folderId,
            pinnedAt: model.pinnedAt,
            unreadCount: model.unreadCount,
            nodeCount: model.nodeCount,
            lastOpenedAt: model.lastOpenedAt,
            isDeleted: model.isDeleted,
            deletedAt: model.deletedAt,
            isTrashed: model.isTrashed,
            trashedAt: model.trashedAt,
            provider: model.provider,
            importBatchId: model.importBatchId,
            memoryEnabled: model.memoryEnabled,
            ccBridgeSessionName: model.ccBridgeSessionName,
            selectedModelId: model.selectedModelId,
            currentStyleId: model.currentStyleId,
            permGrantsRaw: model.permGrantsRaw,
            mcpServerIds: model.mcpServerIds,
            draftText: model.draftText,
            draftAttachmentsData: model.draftAttachmentsData,
            draftQuotePreview: model.draftQuotePreview,
            draftQuoteReplyTo: model.draftQuoteReplyTo,
            nodes: nodes.map(FullNodeDocument.init(model:)),
            branchSelectionData: model.branchSelectionData,
            personaId: model.personaId,
            archiveKind: model.archiveKind,
            sourceMetadata: model.sourceMetadata,
            cardVariablesData: model.cardVariablesData
        )
    }

    /// 用 Document 字段构造 Conversation；profileId 用包内字段（已含）
    func toConversationModel() -> Conversation {
        let conv = Conversation(
            id: id, title: title, createTime: createTime, updateTime: updateTime,
            currentNodeId: currentNodeId, provider: provider, profileId: profileId
        )
        conv.isFavorite = isFavorite
        conv.folderId = folderId
        conv.pinnedAt = pinnedAt
        conv.unreadCount = unreadCount
        conv.nodeCount = nodeCount
        conv.lastOpenedAt = lastOpenedAt
        conv.isDeleted = isDeleted
        conv.deletedAt = deletedAt
        conv.isTrashed = isTrashed
        conv.trashedAt = trashedAt
        conv.importBatchId = importBatchId
        conv.memoryEnabled = memoryEnabled
        conv.ccBridgeSessionName = ccBridgeSessionName
        conv.selectedModelId = selectedModelId
        conv.currentStyleId = currentStyleId
        // shell 授权是设备本地的：备份从别的 Mac 恢复过来，新设备首次跑命令必须重新问（codex 评审阻塞 3）
        conv.permGrantsRaw = PermissionGrants.strippingDeviceLocal(permGrantsRaw)
        conv.mcpServerIds = mcpServerIds
        conv.draftText = draftText
        conv.draftAttachmentsData = draftAttachmentsData
        conv.draftQuotePreview = draftQuotePreview
        conv.draftQuoteReplyTo = draftQuoteReplyTo
        conv.branchSelectionData = branchSelectionData
        conv.personaId = personaId
        conv.archiveKind = archiveKind
        conv.sourceMetadata = sourceMetadata
        conv.cardVariablesData = cardVariablesData
        return conv
    }
}

extension FullNodeDocument {
    init(model: MessageNode) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            role: model.role,
            content: model.content,
            contentType: model.contentType,
            createTime: model.createTime,
            parentId: model.parentId,
            childrenIds: model.childrenIds,
            conversationId: model.conversationId,
            isFavorite: model.isFavorite,
            isPinned: model.isPinned,
            pinnedAt: model.pinnedAt,
            isDeleted: model.isDeleted,
            deletedAt: model.deletedAt,
            isTrashed: model.isTrashed,
            trashedAt: model.trashedAt,
            segmentsData: model.segmentsData,
            ccMessageId: model.ccMessageId,
            replyToId: model.replyToId,
            replyQuote: model.replyQuote,
            ccEdited: model.ccEdited,
            styleIdSnapshot: model.styleIdSnapshot,
            ccThinking: model.ccThinking,
            usagePromptTokens: model.usagePromptTokens,
            usageCompletionTokens: model.usageCompletionTokens,
            usageCacheReadTokens: model.usageCacheReadTokens,
            usageCacheWriteTokens: model.usageCacheWriteTokens,
            usageCostUSD: model.usageCostUSD,
            usageSavedUSD: model.usageSavedUSD,
            imageDescsData: model.imageDescsData,
            bookRef: model.bookRef,
            webSourcesData: model.webSourcesData,
            thinkingSummary: model.thinkingSummary,
            toolSummariesData: model.toolSummariesData,
            isSyntheticRoot: model.isSyntheticRoot,
            sourceMetadata: model.sourceMetadata,
            sourceVisibility: model.sourceVisibility,
            cardVariablesData: model.cardVariablesData,
            cardEditedAt: model.cardEditedAt,
            cardEventsData: model.cardEventsData
        )
    }

    func toNodeModel() -> MessageNode {
        let node = MessageNode(
            id: id, role: role, content: content, contentType: contentType,
            createTime: createTime, parentId: parentId, childrenIds: childrenIds,
            conversationId: conversationId, profileId: profileId
        )
        node.isFavorite = isFavorite
        node.isPinned = isPinned
        node.pinnedAt = pinnedAt
        node.isDeleted = isDeleted
        node.deletedAt = deletedAt
        node.isTrashed = isTrashed
        node.trashedAt = trashedAt
        node.segmentsData = segmentsData
        node.ccMessageId = ccMessageId
        node.replyToId = replyToId
        node.replyQuote = replyQuote
        node.ccEdited = ccEdited
        node.styleIdSnapshot = styleIdSnapshot
        node.ccThinking = ccThinking
        node.usagePromptTokens = usagePromptTokens
        node.usageCompletionTokens = usageCompletionTokens
        node.usageCacheReadTokens = usageCacheReadTokens
        node.usageCacheWriteTokens = usageCacheWriteTokens
        node.usageCostUSD = usageCostUSD
        node.usageSavedUSD = usageSavedUSD
        node.imageDescsData = imageDescsData
        node.bookRef = bookRef
        node.webSourcesData = webSourcesData
        node.thinkingSummary = thinkingSummary
        node.toolSummariesData = toolSummariesData
        node.isSyntheticRoot = isSyntheticRoot ?? false
        node.sourceMetadata = sourceMetadata
        node.sourceVisibility = sourceVisibility
        node.cardVariablesData = cardVariablesData
        node.cardEditedAt = cardEditedAt
        node.cardEventsData = cardEventsData
        return node
    }
}

// MARK: - UserCard

extension FullUserCardDocument {
    init(model: UserCard) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            content: model.content,
            imageData: model.imageData,
            attachedToNodeId: model.attachedToNodeId,
            positionX: model.positionX,
            positionY: model.positionY,
            createTime: model.createTime
        )
    }

    func toModel() -> UserCard {
        let card = UserCard(content: content, attachedToNodeId: attachedToNodeId, profileId: profileId)
        card.id = id
        card.imageData = imageData
        card.positionX = positionX
        card.positionY = positionY
        card.createTime = createTime
        return card
    }
}

// MARK: - ConversationTag / FavoriteItem

extension FullConversationTagDocument {
    init(model: ConversationTag) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            name: model.name,
            emoji: model.emoji,
            order: model.order,
            createTime: model.createTime,
            symbol: model.symbol,
            colorHex: model.colorHex,
            instructions: model.instructions
        )
    }

    func toModel() -> ConversationTag {
        let tag = ConversationTag(name: name, emoji: emoji, order: order, profileId: profileId)
        tag.id = id
        tag.createTime = createTime
        tag.symbol = symbol ?? ""
        tag.colorHex = colorHex ?? ""
        tag.instructions = instructions ?? ""
        return tag
    }
}

extension FullFavoriteItemDocument {
    init(model: FavoriteItem) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            nodeId: model.nodeId,
            conversationId: model.conversationId,
            tagId: model.tagId,
            contentPreview: model.contentPreview,
            createTime: model.createTime
        )
    }

    func toModel() -> FavoriteItem {
        let fav = FavoriteItem(
            nodeId: nodeId, conversationId: conversationId,
            tagId: tagId, contentPreview: contentPreview, profileId: profileId
        )
        fav.id = id
        fav.createTime = createTime
        return fav
    }
}

// MARK: - ImportRecord / ImportConversationChange

extension FullImportRecordDocument {
    init(model: ImportRecord) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            fileName: model.fileName,
            importDate: model.importDate,
            provider: model.provider,
            conversationCount: model.conversationCount,
            nodeCount: model.nodeCount,
            modeRaw: model.modeRaw,
            supportsUndo: model.supportsUndo,
            addedConversationCount: model.addedConversationCount,
            updatedConversationCount: model.updatedConversationCount,
            skippedConversationCount: model.skippedConversationCount,
            ignoredConversationCount: model.ignoredConversationCount,
            conflictConversationCount: model.conflictConversationCount,
            detailData: model.detailData
        )
    }

    func toModel() -> ImportRecord {
        let rec = ImportRecord(
            fileName: fileName, provider: provider,
            conversationCount: conversationCount, nodeCount: nodeCount,
            mode: ImportMode(rawValue: modeRaw) ?? .normal,
            supportsUndo: supportsUndo,
            addedConversationCount: addedConversationCount,
            updatedConversationCount: updatedConversationCount,
            skippedConversationCount: skippedConversationCount,
            ignoredConversationCount: ignoredConversationCount,
            profileId: profileId
        )
        rec.id = id
        rec.importDate = importDate
        rec.conflictConversationCount = conflictConversationCount ?? 0
        rec.detailData = detailData
        return rec
    }
}

extension FullImportConversationChangeDocument {
    init(model: ImportConversationChange) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            recordId: model.recordId,
            conversationId: model.conversationId,
            changeKindRaw: model.changeKindRaw,
            beforeConversationData: model.beforeConversationData,
            beforeNodesData: model.beforeNodesData
        )
    }

    func toModel() -> ImportConversationChange {
        let change = ImportConversationChange(
            recordId: recordId,
            conversationId: conversationId,
            changeKind: ImportConversationChangeKind(rawValue: changeKindRaw) ?? .created,
            beforeConversationData: beforeConversationData,
            beforeNodesData: beforeNodesData,
            profileId: profileId
        )
        change.id = id
        return change
    }
}

// MARK: - MemoryNote / Memory

extension FullMemoryNoteDocument {
    init(model: MemoryNote) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            content: model.content,
            profileId: model.profileId,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt,
            source: model.source,
            isActive: model.isActive
        )
    }

    func toModel() -> MemoryNote {
        let note = MemoryNote(content: content, profileId: profileId, source: source, isActive: isActive)
        note.id = id
        note.createdAt = createdAt
        note.updatedAt = updatedAt
        return note
    }
}

extension FullMemoryDocument {
    init(model: Memory) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            content: model.content,
            category: model.category,
            keywords: model.keywords,
            tokenCount: model.tokenCount,
            accessCount: model.accessCount,
            lastAccessedAt: model.lastAccessedAt,
            decayWeight: model.decayWeight,
            validUntil: model.validUntil,
            sourceConversationId: model.sourceConversationId,
            extractedBy: model.extractedBy,
            isUserExplicit: model.isUserExplicit,
            sourceQuote: model.sourceQuote,
            sourceNodeId: model.sourceNodeId,
            supersededAt: model.supersededAt,
            profileId: model.profileId,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt,
            embeddingData: model.embeddingData,
            embeddingRevision: model.embeddingRevision,
            relatedIds: model.relatedIds,
            parentId: model.parentId
        )
    }

    func toModel() -> Memory {
        let mem = Memory(
            content: content, category: category, keywords: keywords,
            profileId: profileId, isUserExplicit: isUserExplicit,
            extractedBy: extractedBy, sourceConversationId: sourceConversationId
        )
        mem.id = id
        mem.tokenCount = tokenCount
        mem.accessCount = accessCount
        mem.lastAccessedAt = lastAccessedAt
        mem.decayWeight = decayWeight
        mem.validUntil = validUntil
        mem.sourceQuote = sourceQuote
        mem.sourceNodeId = sourceNodeId
        mem.supersededAt = supersededAt
        mem.createdAt = createdAt
        mem.updatedAt = updatedAt
        mem.embeddingData = embeddingData
        mem.embeddingRevision = embeddingRevision
        mem.relatedIds = relatedIds
        mem.parentId = parentId
        return mem
    }
}

// MARK: - WorldBook

extension FullWorldBookDocument {
    init(model: WorldBook) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            name: model.name,
            profileId: model.profileId,
            scopeConversationId: model.scopeConversationId,
            rawJSONData: model.rawJSONData,
            isEnabled: model.isEnabled,
            entriesData: model.entriesData,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt
        )
    }

    func toModel() -> WorldBook {
        let book = WorldBook(name: name, profileId: profileId)
        book.id = id
        book.scopeConversationId = scopeConversationId
        book.rawJSONData = rawJSONData
        book.isEnabled = isEnabled ?? true
        book.entriesData = entriesData
        book.createdAt = createdAt
        book.updatedAt = updatedAt
        return book
    }
}

// MARK: - StickerAsset / PlacedSticker

extension FullStickerAssetDocument {
    init(model: StickerAsset) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            name: model.name,
            assetType: model.assetType,
            imagePath: model.imagePath,
            thumbnailPath: model.thumbnailPath,
            originalImagePath: model.originalImagePath,
            borderStyle: model.borderStyle,
            borderWidth: model.borderWidth,
            filterStyle: model.filterStyle,
            noteContent: model.noteContent,
            noteStyle: model.noteStyle,
            tags: model.tags,
            createdAt: model.createdAt,
            profileId: model.profileId
        )
    }

    func toModel() -> StickerAsset {
        let asset: StickerAsset
        if assetType == "note", let content = noteContent, let style = noteStyle {
            asset = StickerAsset(noteContent: content, noteStyle: style, name: name, tags: tags, profileId: profileId)
        } else {
            asset = StickerAsset(
                name: name, imagePath: imagePath, thumbnailPath: thumbnailPath,
                originalImagePath: originalImagePath, borderStyle: borderStyle,
                borderWidth: borderWidth, tags: tags, profileId: profileId
            )
            asset.filterStyle = filterStyle
        }
        asset.id = id
        asset.createdAt = createdAt
        return asset
    }
}

extension FullPlacedStickerDocument {
    init(model: PlacedSticker) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            stickerAssetId: model.stickerAssetId,
            conversationId: model.conversationId,
            nearestMessageId: model.nearestMessageId,
            positionX: model.positionX,
            positionY: model.positionY,
            rotation: model.rotation,
            scale: model.scale,
            zIndex: model.zIndex,
            noteContent: model.noteContent,
            noteStyle: model.noteStyle,
            isLocked: model.isLocked,
            placedAt: model.placedAt,
            profileId: model.profileId
        )
    }

    func toModel() -> PlacedSticker {
        let placed = PlacedSticker(
            stickerAssetId: stickerAssetId,
            conversationId: conversationId,
            nearestMessageId: nearestMessageId,
            positionX: positionX, positionY: positionY,
            rotation: rotation, scale: scale, zIndex: zIndex,
            noteContent: noteContent, noteStyle: noteStyle,
            profileId: profileId
        )
        placed.id = id
        placed.isLocked = isLocked
        placed.placedAt = placedAt
        return placed
    }
}

// MARK: - BookEntry

extension FullBookEntryDocument {
    init(model: BookEntry) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            name: model.name,
            author: model.author,
            format: model.format,
            totalChapters: model.totalChapters,
            currentChapter: model.currentChapter,
            scrollRatio: model.scrollRatio,
            addedAt: model.addedAt,
            lastReadAt: model.lastReadAt,
            updateTime: model.updateTime,
            coverData: model.coverData
        )
    }

    func toModel() -> BookEntry {
        let book = BookEntry(
            id: id, profileId: profileId, name: name,
            author: author, format: format, totalChapters: totalChapters
        )
        book.currentChapter = currentChapter
        book.scrollRatio = scrollRatio
        book.addedAt = addedAt
        book.lastReadAt = lastReadAt
        book.updateTime = updateTime
        book.coverData = coverData
        return book
    }
}

// MARK: - AudiobookItem / AudiobookBookmark

extension FullAudiobookItemDocument {
    init(model: AudiobookItem) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            title: model.title,
            fileName: model.fileName,
            fileSizeBytes: model.fileSizeBytes,
            totalDuration: model.totalDuration,
            currentTime: model.currentTime,
            lastPlayedAt: model.lastPlayedAt,
            importedAt: model.importedAt
        )
    }

    func toModel() -> AudiobookItem {
        let item = AudiobookItem(
            profileId: profileId, title: title, fileName: fileName,
            fileSizeBytes: fileSizeBytes, totalDuration: totalDuration
        )
        item.id = id
        item.currentTime = currentTime
        item.lastPlayedAt = lastPlayedAt
        item.importedAt = importedAt
        return item
    }
}

extension FullAudiobookBookmarkDocument {
    init(model: AudiobookBookmark) {
        self.init(
            schemaVersion: kSchemaV,
            id: model.id,
            profileId: model.profileId,
            bookId: model.bookId,
            timestamp: model.timestamp,
            note: model.note,
            bookTitleSnapshot: model.bookTitleSnapshot,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt
        )
    }

    func toModel() -> AudiobookBookmark {
        let bm = AudiobookBookmark(
            profileId: profileId, bookId: bookId, timestamp: timestamp,
            note: note, bookTitleSnapshot: bookTitleSnapshot
        )
        bm.id = id
        bm.createdAt = createdAt
        bm.updatedAt = updatedAt
        return bm
    }
}
