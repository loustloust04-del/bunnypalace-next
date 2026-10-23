import Foundation
import Observation

@MainActor
@Observable
final class AgoraViewModel {
    private(set) var floorId: String? {
        didSet { if floorId != oldValue { loadRoomCustomizations() } }
    }
    private(set) var rooms: [AgoraRoomSummary] = [] {
        didSet { updateReadState() }
    }
    private(set) var readSequences: [String: Int] = [:]
    private let localDefaults: UserDefaults?

    private(set) var roomTitles: [String: String] = [:]
    private(set) var roomAppearances: [String: GroupAppearance] = [:]
    private(set) var roomAvatars: [String: Data] = [:]
    private(set) var reactionsByRoom: [String: [String: [String]]] = [:]

    private func loadRoomCustomizations() {
        roomTitles = [:]
        roomAppearances = [:]
        roomAvatars = [:]
        reactionsByRoom = [:]
        guard let floorId, let localDefaults else { return }
        let state = Page0LocalState(defaults: localDefaults, profileId: floorId)
        roomTitles = state.roomTitles
        reactionsByRoom = state.reactions
        roomAppearances = state.roomAppearances
        for roomId in roomAppearances.keys {
            roomAvatars[roomId] = state.roomAvatar(roomId: roomId)
        }
    }

    func displayTitle(for room: AgoraRoomSummary) -> String {
        guard localDefaults != nil, room.floorId == floorId else { return room.title }
        return roomTitles[room.id] ?? room.title
    }

    func appearance(for room: AgoraRoomSummary) -> GroupAppearance {
        guard localDefaults != nil, room.floorId == floorId else { return GroupAppearance() }
        return roomAppearances[room.id] ?? GroupAppearance()
    }

    func avatarData(for room: AgoraRoomSummary) -> Data? {
        guard localDefaults != nil, room.floorId == floorId else { return nil }
        return roomAvatars[room.id]
    }

    func saveCustomization(for room: AgoraRoomSummary, title: String,
                           appearance: GroupAppearance, avatar: Data?) throws {
        guard let floorId, let localDefaults, room.floorId == floorId else { return }
        let state = Page0LocalState(defaults: localDefaults, profileId: floorId)
        if let avatar { try state.saveRoomAvatar(avatar, roomId: room.id) }
        try state.setRoomAppearance(appearance, roomId: room.id)
        state.setRoomTitle(title, roomId: room.id)
        roomTitles = state.roomTitles
        roomAppearances = state.roomAppearances
        if let avatar { roomAvatars[room.id] = avatar }
    }

    func reactions(for message: AgoraMessage) -> [String] {
        reactionsByRoom[message.roomId]?[message.id] ?? []
    }

    func toggleReaction(_ emoji: String, on message: AgoraMessage) {
        guard let floorId, let localDefaults else { return }
        let state = Page0LocalState(defaults: localDefaults, profileId: floorId)
        state.toggleReaction(emoji, messageId: message.id, roomId: message.roomId)
        reactionsByRoom = state.reactions
    }

    private func updateReadState() {
        guard let floorId, let localDefaults else { return }
        let state = Page0LocalState(defaults: localDefaults, profileId: floorId)
        for room in rooms {
            state.establishBaseline(roomId: room.id, nextSeq: room.nextSeq)
            if room.id == selectedRoomId { state.markRead(roomId: room.id, sequence: room.nextSeq - 1) }
        }
        readSequences = state.readSequences
    }

    private func markRoomRead(_ roomId: String, sequence: Int) {
        guard let floorId, let localDefaults else { return }
        let state = Page0LocalState(defaults: localDefaults, profileId: floorId)
        state.markRead(roomId: roomId, sequence: sequence)
        readSequences = state.readSequences
    }

    func unreadCount(for room: AgoraRoomSummary) -> Int {
        max(0, room.nextSeq - 1 - (readSequences[room.id] ?? max(0, room.nextSeq - 1)))
    }

    #if DEBUG
    func injectPage0Rooms(_ seedRooms: [AgoraRoomSummary], floorId: String) {
        guard Page0ListSeed.isActive else { return }
        client.disconnect()
        self.floorId = floorId
        clearSelectedRoom(clearComposer: true)
        rooms = seedRooms.sorted { $0.updatedAt > $1.updatedAt }
    }
    #endif
    private(set) var selectedRoomId: String?
    private(set) var membersByActorId: [String: AgoraMember] = [:]
    private(set) var messages: [AgoraMessage] = []
    private(set) var mentions: [AgoraMention] = []
    private(set) var typingByActorId: [String: AgoraTypingPresence] = [:]
    private(set) var bridgeState: AgoraBridgeState?
    var composerText = ""
    private(set) var editingMessageId: String?
    /// 正在回复的那条（和编辑互斥）
    private(set) var replyingMessageId: String?
    private(set) var connectionState: AgoraConnectionState
    private(set) var isLoadingRooms = false
    private(set) var isLoadingRoom = false
    private(set) var isLoadingOlder = false
    private(set) var isPosting = false
    private(set) var hasMoreOlder = false
    private(set) var lastSeq = 0
    private(set) var mentionCounts = AgoraMentionCounts.zero
    private(set) var errorBanner: String?

    private let client: AgoraClientProtocol
    private var roomLoadGeneration = UUID()
    private var seenEventIds = Set<String>()
    private var seenEventOrder: [String] = []
    private var deferredGapMessages: [Int: AgoraMessage] = [:]
    private var pendingGapTargetSeq = 0
    private var isRecoveringGap = false
    private let pageSize = 100
    private let errorBannerDuration: Duration
    private let typingInactivityDuration: Duration
    private var errorDismissTask: Task<Void, Never>?
    private var typingStopTask: Task<Void, Never>?
    /// 远端 typing 本地过期（actorId → 过期 Task）：对方断连/漏发 stop 时"正在输入"不悬挂。
    private var typingExpiryTasks: [String: Task<Void, Never>] = [:]
    /// 远端 typing 本地过期窗口。CC 作答慢（服务端 executor 每轮续命），取服务端 executor TTL 同级。
    let remoteTypingExpiry: Duration = .seconds(150)
    private var localTypingRoomId: String?

    convenience init() {
        self.init(client: AgoraClient(), localDefaults: .standard)
    }

    init(
        client: AgoraClientProtocol,
        localDefaults: UserDefaults? = nil,
        errorBannerDuration: Duration = .seconds(5),
        typingInactivityDuration: Duration = .seconds(3)
    ) {
        self.localDefaults = localDefaults
        self.client = client
        self.connectionState = client.connectionState
        self.errorBannerDuration = errorBannerDuration
        self.typingInactivityDuration = typingInactivityDuration
        client.eventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handle(event)
            }
        }
        client.reconnectHandler = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reconnectSync()
            }
        }
        client.connectionStateHandler = { [weak self] state in
            self?.connectionState = state
            if state != .connected { self?.clearRemoteTyping() }
        }
    }

    var typingIndicatorText: String? {
        let names = typingByActorId.values
            .filter(\.isTyping)
            .map(\.displayName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return nil }
        return "\(names.joined(separator: "、")) 正在输入…"
    }

    /// 前台恢复时调（ContentView scenePhase）：连接断着就立即重连，不等退避。
    func nudgeReconnectIfNeeded() {
        #if DEBUG
        if Page0ListSeed.isActive { return }
        #endif
        guard floorId != nil else { return }   // 没激活过不动
        client.nudgeReconnect()
    }

    func activate(floorId newFloorId: String) async {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // R4 C-07：严格测量角色不激活群聊（connect 已声明抑制，抛的 CancellationError 会弹错误横幅落进测量窗口）
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("agora"); return }
        #endif
        #if DEBUG
        if Page0ListSeed.isActive {
            injectPage0Rooms(Page0ListSeed.rooms(profileId: newFloorId), floorId: newFloorId)
            return
        }
        #endif
        let trimmedFloorId = newFloorId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFloorId.isEmpty else { return }
        if floorId != trimmedFloorId {
            floorId = trimmedFloorId
            rooms = []
            clearSelectedRoom(clearComposer: true)
        }
        dismissError()
        do {
            try await client.connect()
            connectionState = client.connectionState
            try await loadRooms()
        } catch {
            connectionState = client.connectionState
            present(error)
        }
    }

    func deactivate() {
        client.disconnect()
        floorId = nil
        rooms = []
        clearSelectedRoom(clearComposer: true)
        connectionState = client.connectionState
        isLoadingRooms = false
        dismissError()
    }

    func loadRooms() async throws {
        guard let floorId else { return }
        isLoadingRooms = true
        defer { isLoadingRooms = false }
        let loaded = try await client.listRooms(floorId: floorId)
        guard self.floorId == floorId else { return }
        rooms = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    func listActors() async throws -> [AgoraActorSummary] {
        try await client.listActors()
    }

    func upsertCCActor(sessionName: String) async throws -> AgoraActorSummary {
        try await client.upsertCCActor(sessionName: sessionName)
    }

    func createRoom(
        title: String,
        ownerProfile: AgoraOwnerProfile,
        members: [AgoraRoomCreationMember]
    ) async -> Bool {
        guard let floorId else { return false }
        dismissError()
        do {
            var specs: [AgoraRoomMemberSpec] = []
            for member in members {
                let actor = try await client.upsertCCActor(sessionName: member.sessionName)
                specs.append(AgoraRoomMemberSpec(
                    actorId: actor.id,
                    handle: member.handle,
                    displayName: member.displayName,
                    avatarRef: member.avatarRef
                ))
            }
            guard self.floorId == floorId else { return false }
            let input = AgoraCreateRoomInput(
                clientRequestId: UUID().uuidString.lowercased(),
                floorId: floorId,
                title: title,
                isDM: false,
                ownerProfile: ownerProfile,
                memberSpecs: specs
            )
            let result = try await client.createRoom(input)
            guard self.floorId == floorId else { return false }
            upsertRoom(result.room)
            await openRoom(id: result.room.id)
            return selectedRoomId == result.room.id && errorBanner == nil
        } catch {
            present(error)
            return false
        }
    }

    func createDirectMessage(with member: AgoraMember) async -> Bool {
        guard let floorId,
              member.role == .member,
              member.isEnabled,
              member.executorKind == .ccBridge,
              let owner = membersByActorId.values.first(where: { $0.role == .owner && $0.isEnabled }) else {
            return false
        }
        dismissError()
        if let existing = rooms.first(where: { $0.isDM && $0.dmPeerActorId == member.actorId }) {
            await openRoom(id: existing.id)
            return selectedRoomId == existing.id && errorBanner == nil
        }
        do {
            let input = AgoraCreateRoomInput(
                clientRequestId: UUID().uuidString.lowercased(),
                floorId: floorId,
                title: member.displayName,
                isDM: true,
                ownerProfile: AgoraOwnerProfile(
                    handle: owner.handle,
                    displayName: owner.displayName,
                    avatarRef: owner.avatarRef
                ),
                memberSpecs: [AgoraRoomMemberSpec(
                    actorId: member.actorId,
                    handle: member.handle,
                    displayName: member.displayName,
                    avatarRef: member.avatarRef
                )]
            )
            let result = try await client.createRoom(input)
            guard self.floorId == floorId else { return false }
            upsertRoom(result.room)
            await openRoom(id: result.room.id)
            return selectedRoomId == result.room.id && errorBanner == nil
        } catch {
            present(error)
            return false
        }
    }

    func openRoom(id roomId: String) async {
        stopLocalTyping()
        selectedRoomId = roomId
        if let room = rooms.first(where: { $0.id == roomId }) { markRoomRead(roomId, sequence: room.nextSeq - 1) }
        #if DEBUG
        if Page0ListSeed.isActive {
            if let room = rooms.first(where: { $0.id == roomId }) {
                membersByActorId = Dictionary(room.members.map { ($0.actorId, $0) }, uniquingKeysWith: { a, _ in a })
                messages = Page0ListSeed.roomMessages(room)
                typingByActorId = Page0ListSeed.roomTyping(room)
            }
            return
        }
        #endif
        clearRoomContents(clearComposer: true)
        let generation = UUID()
        roomLoadGeneration = generation
        isLoadingRoom = true
        dismissError()
        defer {
            if roomLoadGeneration == generation { isLoadingRoom = false }
        }
        do {
            let opened = try await client.openRoom(roomId: roomId, beforeSeq: nil, limit: pageSize)
            guard selectedRoomId == roomId, roomLoadGeneration == generation else { return }
            apply(opened)
            do {
                let loadedMentions = try await client.listMentions(roomId: roomId, state: nil, limit: pageSize)
                guard selectedRoomId == roomId, roomLoadGeneration == generation else { return }
                mentions = loadedMentions
            } catch {
                present(error)
            }
        } catch {
            guard selectedRoomId == roomId, roomLoadGeneration == generation else { return }
            present(error)
        }
    }

    func loadOlder() async {
        guard let roomId = selectedRoomId,
              hasMoreOlder,
              !isLoadingOlder,
              let firstSeq = messages.first?.seq else { return }
        isLoadingOlder = true
        dismissError()
        defer { isLoadingOlder = false }
        do {
            let opened = try await client.openRoom(roomId: roomId, beforeSeq: firstSeq, limit: pageSize)
            guard selectedRoomId == roomId else { return }
            mergeMessages(opened.messages)
            hasMoreOlder = opened.hasMore
        } catch {
            present(error)
        }
    }

    func closeRoom() {
        stopLocalTyping()
        clearSelectedRoom(clearComposer: true)
        dismissError()
    }

    func composerChanged() {
        typingStopTask?.cancel()
        guard let roomId = selectedRoomId,
              connectionState == .connected,
              !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stopLocalTyping()
            return
        }

        if localTypingRoomId != roomId {
            stopLocalTyping()
            localTypingRoomId = roomId
            Task { @MainActor [weak self] in
                do {
                    _ = try await self?.client.setTyping(roomId: roomId, isTyping: true)
                } catch {
                    guard self?.localTypingRoomId == roomId else { return }
                    self?.localTypingRoomId = nil
                }
            }
        }
        typingStopTask = Task { @MainActor [weak self, typingInactivityDuration] in
            try? await Task.sleep(for: typingInactivityDuration)
            guard !Task.isCancelled else { return }
            self?.stopLocalTyping()
        }
    }

    func refreshMentions() async {
        guard let roomId = selectedRoomId else { return }
        dismissError()
        do {
            let loaded = try await client.listMentions(roomId: roomId, state: nil, limit: pageSize)
            guard selectedRoomId == roomId else { return }
            mentions = loaded.sorted { $0.createdAt > $1.createdAt }
            var counts = AgoraMentionCounts.zero
            for mention in loaded { counts[mention.state] += 1 }
            mentionCounts = counts
        } catch {
            present(error)
        }
    }

    func post() async {
        guard let roomId = selectedRoomId, !isPosting else { return }
        let sourceDraft = composerText
        let frozenContent = sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !frozenContent.isEmpty else { return }
        isPosting = true
        dismissError()
        defer { isPosting = false }
        do {
            if let editingMessageId {
                let message = try await client.editMessage(id: editingMessageId, content: frozenContent)
                guard selectedRoomId == roomId else { return }
                mergeMessages([message])
                if composerText == sourceDraft {
                    composerText = ""
                    self.editingMessageId = nil
                }
            } else {
                // 回复：正文前加一段 markdown 引用，AI 成员和 hub 都看得懂
                let replied = replyingMessage
                let quote = replied.map { Self.replyQuote(name: displayName(of: $0), content: $0.content) } ?? ""
                let result = try await client.postMessage(
                    roomId: roomId,
                    clientMessageId: UUID().uuidString.lowercased(),
                    content: quote + frozenContent
                )
                guard selectedRoomId == roomId else { return }
                mergeMessages([result.message])
                for mention in result.mentions { mergeMention(mention) }
                if composerText == sourceDraft {
                    composerText = ""
                    if replyingMessageId == replied?.id { replyingMessageId = nil }
                }
            }
        } catch {
            present(error)
        }
    }

    func beginEditing(_ message: AgoraMessage) {
        guard message.roomId == selectedRoomId,
              message.actorId == rooms.first(where: { $0.id == selectedRoomId })?.ownerActorId else { return }
        replyingMessageId = nil
        editingMessageId = message.id
        composerText = message.content
        dismissError()
    }

    func cancelEditing() {
        editingMessageId = nil
        composerText = ""
    }

    var replyingMessage: AgoraMessage? {
        guard let replyingMessageId else { return nil }
        return messages.first { $0.id == replyingMessageId }
    }

    func beginReply(_ message: AgoraMessage) {
        guard message.roomId == selectedRoomId, !message.isDeleted else { return }
        if editingMessageId != nil { cancelEditing() }
        replyingMessageId = message.id
        dismissError()
    }

    func cancelReply() {
        replyingMessageId = nil
    }

    func displayName(of message: AgoraMessage) -> String {
        membersByActorId[message.actorId]?.displayName ?? "未知成员"
    }

    /// 回复引用段：`> 名字：原话前 60 字` + 空行
    nonisolated static func replyQuote(name: String, content: String) -> String {
        "> \(name)：\(replySnippet(content, limit: 60))\n\n"
    }

    /// 原话摘要：去掉原话自己的引用行（回复的回复不套娃），空白压成一个空格，超长截断加「…」
    nonisolated static func replySnippet(_ content: String, limit: Int) -> String {
        let body = content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return body.count > limit ? String(body.prefix(limit)) + "…" : body
    }

    func deleteMessage(_ message: AgoraMessage) async {
        guard message.roomId == selectedRoomId else { return }
        dismissError()
        do {
            let deleted = try await client.deleteMessage(id: message.id)
            guard deleted.roomId == selectedRoomId else { return }
            mergeMessages([deleted])
            if editingMessageId == deleted.id { cancelEditing() }
            if replyingMessageId == deleted.id { replyingMessageId = nil }
        } catch {
            present(error)
        }
    }

    func retryMention(id: String) async {
        dismissError()
        do {
            let mention = try await client.retryMention(id: id)
            guard mention.roomId == selectedRoomId else { return }
            mergeMention(mention)
        } catch {
            present(error)
        }
    }

    func startBridge(
        prompt: String,
        firstActorId: String,
        secondActorId: String,
        maxTurns: Int
    ) async -> Bool {
        guard let roomId = selectedRoomId else { return false }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, firstActorId != secondActorId else { return false }
        dismissError()
        do {
            let result = try await client.startBridge(AgoraBridgeStartInput(
                roomId: roomId,
                clientRequestId: UUID().uuidString.lowercased(),
                firstActorId: firstActorId,
                secondActorId: secondActorId,
                prompt: trimmedPrompt,
                maxTurns: maxTurns
            ))
            guard selectedRoomId == roomId else { return false }
            bridgeState = result.state
            mergeMessages([result.message])
            mergeMention(result.mention)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func stopBridge() async {
        guard let bridge = bridgeState?.bridge, bridge.status == .active else { return }
        dismissError()
        do {
            let stopped = try await client.stopBridge(id: bridge.id)
            guard bridge.roomId == selectedRoomId else { return }
            bridgeState = stopped
            await refreshMentions()
        } catch {
            present(error)
        }
    }

    func handle(_ event: AgoraEvent) async {
        guard rememberEvent(event.id) else { return }

        switch event.data {
        case .room(let room):
            guard room.floorId == floorId else { return }
            upsertRoom(room)
            if room.id == selectedRoomId {
                membersByActorId = Dictionary(uniqueKeysWithValues: room.members.map { ($0.actorId, $0) })
            }

        case .mention(let mention):
            guard event.roomId == selectedRoomId else { return }
            mergeMention(mention)

        case .typing(let presence):
            guard event.roomId == selectedRoomId else { return }
            // 自己的 typing 不显示（hub 目前不回显给发送者，这里是零成本防御）
            guard membersByActorId[presence.actorId]?.role != .owner else { return }
            typingExpiryTasks[presence.actorId]?.cancel()
            if presence.isTyping {
                typingByActorId[presence.actorId] = presence
                let actorId = presence.actorId
                typingExpiryTasks[actorId] = Task { @MainActor [weak self, remoteTypingExpiry] in
                    try? await Task.sleep(for: remoteTypingExpiry)
                    guard !Task.isCancelled else { return }
                    self?.typingByActorId.removeValue(forKey: actorId)
                    self?.typingExpiryTasks.removeValue(forKey: actorId)
                }
            } else {
                typingByActorId.removeValue(forKey: presence.actorId)
                typingExpiryTasks.removeValue(forKey: presence.actorId)
            }

        case .bridge(let state):
            guard event.roomId == selectedRoomId else { return }
            bridgeState = state

        case .settings:
            // 全局设置由设置页自己的 client 监听，房间视图不消费
            break

        case .message(let message):
            guard event.roomId == selectedRoomId else { return }
            typingByActorId.removeValue(forKey: message.actorId)
            // 窗口外旧消息（edit/delete 的 message.updated 可以带任意低 seq）丢弃：
            // merge 进列表会造成假连续 → loadOlder 拿它当 beforeSeq，中间整段永远取不到。
            // 重开房间自然取到最新态，丢弃无损。
            if let windowStart = messages.first?.seq, message.seq < windowStart { return }
            if message.seq > lastSeq + 1 {
                deferredGapMessages[message.seq] = message
                pendingGapTargetSeq = max(pendingGapTargetSeq, message.seq)
                await recoverGapIfNeeded(roomId: event.roomId)
            } else {
                mergeMessages([message])
                drainDeferredMessages()
            }
        }
    }

    func reconnectSync() async {
        #if DEBUG
        if Page0ListSeed.isActive { return }
        #endif
        guard let floorId else { return }
        dismissError()
        do {
            let refreshedRooms = try await client.listRooms(floorId: floorId)
            guard self.floorId == floorId else { return }
            rooms = refreshedRooms.sorted { $0.updatedAt > $1.updatedAt }
            guard let roomId = selectedRoomId else { return }
            guard rooms.contains(where: { $0.id == roomId }) else {
                clearSelectedRoom(clearComposer: false)
                return
            }
            if lastSeq == 0 {
                await openRoom(id: roomId)
                return
            }
            try await syncMessagesAfter(roomId: roomId)
            let loadedMentions = try await client.listMentions(roomId: roomId, state: nil, limit: pageSize)
            guard selectedRoomId == roomId else { return }
            mentions = loadedMentions
            bridgeState = try await client.bridgeStatus(roomId: roomId)
        } catch {
            present(error)
        }
    }

    private func apply(_ opened: AgoraRoomOpenResult) {
        upsertRoom(opened.room)
        membersByActorId = Dictionary(uniqueKeysWithValues: opened.members.map { ($0.actorId, $0) })
        messages = []
        lastSeq = 0
        mergeMessages(opened.messages)
        mentionCounts = opened.mentionCounts
        bridgeState = opened.bridge
        hasMoreOlder = opened.hasMore
        deferredGapMessages.removeAll()
        pendingGapTargetSeq = 0
    }

    private func recoverGapIfNeeded(roomId: String) async {
        guard !isRecoveringGap else { return }
        isRecoveringGap = true
        defer { isRecoveringGap = false }
        do {
            while selectedRoomId == roomId, lastSeq < pendingGapTargetSeq {
                let previousLastSeq = lastSeq
                let page = try await client.messagesAfter(roomId: roomId, afterSeq: lastSeq, limit: pageSize)
                guard selectedRoomId == roomId else { return }
                mergeMessages(page.messages)
                drainDeferredMessages()
                if lastSeq >= pendingGapTargetSeq { break }
                if lastSeq == previousLastSeq || (!page.hasMore && page.messages.isEmpty) { break }
            }
        } catch {
            present(error)
        }
    }

    private func syncMessagesAfter(roomId: String) async throws {
        repeat {
            let previousLastSeq = lastSeq
            let page = try await client.messagesAfter(roomId: roomId, afterSeq: lastSeq, limit: pageSize)
            guard selectedRoomId == roomId else { return }
            mergeMessages(page.messages)
            drainDeferredMessages()
            if !page.hasMore || lastSeq == previousLastSeq { return }
        } while true
    }

    private func drainDeferredMessages() {
        while let next = deferredGapMessages.removeValue(forKey: lastSeq + 1) {
            mergeMessages([next])
        }
        if lastSeq >= pendingGapTargetSeq { pendingGapTargetSeq = 0 }
    }

    private func mergeMessages(_ incoming: [AgoraMessage]) {
        guard !incoming.isEmpty else { return }
        var bySequence = Dictionary(uniqueKeysWithValues: messages.map { ($0.seq, $0) })
        for message in incoming.sorted(by: { $0.seq < $1.seq }) {
            guard message.roomId == selectedRoomId else { continue }
            if let existing = bySequence[message.seq], existing.id != message.id { continue }
            bySequence[message.seq] = message
        }
        messages = bySequence.values.sorted { $0.seq < $1.seq }
        lastSeq = messages.last?.seq ?? 0
        if let roomId = selectedRoomId { markRoomRead(roomId, sequence: lastSeq) }
    }

    private func mergeMention(_ mention: AgoraMention) {
        guard mention.roomId == selectedRoomId else { return }
        // observe（自由发言旁听）不进收件箱不进角标——hub 的 mention.list/mentionCounts 已只算 direct，
        // 这里拦事件流同源对齐，否则 free 档每条消息全员 observe 会把角标刷爆。
        guard mention.kind == .direct else { return }
        if let index = mentions.firstIndex(where: { $0.id == mention.id }) {
            let oldState = mentions[index].state
            mentions[index] = mention
            if oldState != mention.state {
                mentionCounts[oldState] = max(0, mentionCounts[oldState] - 1)
                mentionCounts[mention.state] += 1
            }
        } else {
            mentions.append(mention)
            mentionCounts[mention.state] += 1
        }
        mentions.sort { $0.createdAt > $1.createdAt }
    }

    private func upsertRoom(_ room: AgoraRoomSummary) {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[index] = room
        } else {
            rooms.append(room)
        }
        rooms.sort { $0.updatedAt > $1.updatedAt }
    }

    private func clearSelectedRoom(clearComposer: Bool) {
        stopLocalTyping()
        selectedRoomId = nil
        clearRoomContents(clearComposer: clearComposer)
    }

    private func clearRoomContents(clearComposer: Bool) {
        roomLoadGeneration = UUID()
        membersByActorId = [:]
        messages = []
        mentions = []
        clearRemoteTyping()
        bridgeState = nil
        mentionCounts = .zero
        hasMoreOlder = false
        lastSeq = 0
        deferredGapMessages = [:]
        pendingGapTargetSeq = 0
        isRecoveringGap = false
        if clearComposer {
            composerText = ""
            editingMessageId = nil
            replyingMessageId = nil
        }
    }

    private func clearRemoteTyping() {
        typingByActorId = [:]
        for task in typingExpiryTasks.values { task.cancel() }
        typingExpiryTasks = [:]
    }

    private func stopLocalTyping() {
        typingStopTask?.cancel()
        typingStopTask = nil
        guard let roomId = localTypingRoomId else { return }
        localTypingRoomId = nil
        Task { @MainActor [weak self] in
            _ = try? await self?.client.setTyping(roomId: roomId, isTyping: false)
        }
    }

    private func rememberEvent(_ id: String) -> Bool {
        guard seenEventIds.insert(id).inserted else { return false }
        seenEventOrder.append(id)
        if seenEventOrder.count > 500 {
            let expiredCount = seenEventOrder.count - 500
            let expired = seenEventOrder.prefix(expiredCount)
            seenEventIds.subtract(expired)
            seenEventOrder.removeFirst(expiredCount)
        }
        return true
    }

    private func present(_ error: Error) {
        errorBanner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor [weak self, errorBannerDuration] in
            try? await Task.sleep(for: errorBannerDuration)
            guard !Task.isCancelled else { return }
            self?.errorBanner = nil
        }
    }

    func dismissError() {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        errorBanner = nil
    }
}
