import Foundation

enum AgoraJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let milliseconds = try container.decode(Double.self)
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
        }
        return encoder
    }
}

enum AgoraActorKind: String, Codable, Equatable {
    case owner
    case ccBridge = "cc_bridge"
}

enum AgoraMemberRole: String, Codable, Equatable {
    case owner
    case member
}

enum AgoraExecutorKind: String, Codable, Equatable {
    case none
    case ccBridge = "cc_bridge"
}

enum AgoraMentionState: String, Codable, CaseIterable, Equatable {
    case pending
    case claimed
    case completed
    case failed
}

enum AgoraBridgeStatus: String, Codable, Equatable {
    case active, completed, stopped, failed
}

enum AgoraBridgeTurnState: String, Codable, Equatable {
    case pending, claimed, completed, cancelled, failed
}

enum AgoraSpeechMode: String, Codable, Equatable, CaseIterable, Identifiable {
    case mentionOnly = "mention_only"
    case relay
    case free
    case roundRobin = "round_robin"

    var id: String { rawValue }
}

enum AgoraMentionKind: String, Codable, Equatable {
    /// 被显式 @，必答
    case direct
    /// 自由发言档的旁听机会，AI 可沉默——不进收件箱不进角标
    case observe
}

enum AgoraEventKind: String, Codable, Equatable {
    case roomCreated = "room.created"
    case roomUpdated = "room.updated"
    case messageCreated = "message.created"
    case messageUpdated = "message.updated"
    case typingStart = "typing.start"
    case typingStop = "typing.stop"
    case bridgeStarted = "bridge.started"
    case bridgeAdvanced = "bridge.advanced"
    case bridgeStopped = "bridge.stopped"
    case bridgeCompleted = "bridge.completed"
    case bridgeFailed = "bridge.failed"
    case mentionUpdated = "mention.updated"
    case settingsUpdated = "settings.updated"
}

/// 全局群聊设置（hub agora_settings，非按房间）。settings.get/update 响应与 settings.updated 事件共用。
struct AgoraSettings: Decodable, Equatable {
    let speechMode: AgoraSpeechMode
    let minSpeakIntervalMs: Int

    enum CodingKeys: String, CodingKey {
        case speechMode = "speech_mode"
        case minSpeakIntervalMs = "min_speak_interval_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speechMode = try container.decode(AgoraSpeechMode.self, forKey: .speechMode)
        // 旧 hub 不带此字段，缺省当 0=不限，别让整个 settings 解码失败
        minSpeakIntervalMs = try container.decodeIfPresent(Int.self, forKey: .minSpeakIntervalMs) ?? 0
    }
}

struct AgoraActorSummary: Codable, Equatable, Identifiable {
    let id: String
    let kind: AgoraActorKind
    let sessionName: String?
    let createdAt: Date
    let disabledAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case sessionName = "session_name"
        case createdAt = "created_at_ms"
        case disabledAt = "disabled_at_ms"
    }
}

struct AgoraMember: Codable, Equatable, Identifiable {
    let id: String
    let roomId: String
    let actorId: String
    let handle: String
    let displayName: String
    let avatarRef: String?
    let role: AgoraMemberRole
    let executorKind: AgoraExecutorKind
    let isEnabled: Bool
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, handle, role
        case roomId = "room_id"
        case actorId = "actor_id"
        case displayName = "display_name"
        case avatarRef = "avatar_ref"
        case executorKind = "executor_kind"
        case isEnabled = "is_enabled"
        case joinedAt = "joined_at_ms"
    }
}

struct AgoraRoomSummary: Codable, Equatable, Identifiable {
    let id: String
    let floorId: String
    let title: String
    let ownerActorId: String
    let isDM: Bool
    let dmPeerActorId: String?
    let nextSeq: Int
    let isEnabled: Bool
    let createdAt: Date
    let updatedAt: Date
    let memberCount: Int
    let members: [AgoraMember]

    enum CodingKeys: String, CodingKey {
        case id, title, members
        case floorId = "floor_id"
        case ownerActorId = "owner_actor_id"
        case isDM = "is_dm"
        case dmPeerActorId = "dm_peer_actor_id"
        case nextSeq = "next_seq"
        case isEnabled = "is_enabled"
        case createdAt = "created_at_ms"
        case updatedAt = "updated_at_ms"
        case memberCount = "member_count"
    }

    init(
        id: String,
        floorId: String,
        title: String,
        ownerActorId: String,
        isDM: Bool = false,
        dmPeerActorId: String? = nil,
        nextSeq: Int,
        isEnabled: Bool,
        createdAt: Date,
        updatedAt: Date,
        memberCount: Int,
        members: [AgoraMember]
    ) {
        self.id = id
        self.floorId = floorId
        self.title = title
        self.ownerActorId = ownerActorId
        self.isDM = isDM
        self.dmPeerActorId = dmPeerActorId
        self.nextSeq = nextSeq
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.memberCount = memberCount
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        floorId = try container.decode(String.self, forKey: .floorId)
        title = try container.decode(String.self, forKey: .title)
        ownerActorId = try container.decode(String.self, forKey: .ownerActorId)
        isDM = try container.decodeIfPresent(Bool.self, forKey: .isDM) ?? false
        dmPeerActorId = try container.decodeIfPresent(String.self, forKey: .dmPeerActorId)
        nextSeq = try container.decode(Int.self, forKey: .nextSeq)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        memberCount = try container.decode(Int.self, forKey: .memberCount)
        members = try container.decode([AgoraMember].self, forKey: .members)
    }
}

struct AgoraMessage: Codable, Equatable, Identifiable {
    let id: String
    let roomId: String
    let seq: Int
    let actorId: String
    let clientMessageId: String
    let content: String
    let createdAt: Date
    let editedAt: Date?
    let isDeleted: Bool
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, seq, content
        case roomId = "room_id"
        case actorId = "actor_id"
        case clientMessageId = "client_message_id"
        case createdAt = "created_at_ms"
        case editedAt = "edited_at_ms"
        case isDeleted = "is_deleted"
        case deletedAt = "deleted_at_ms"
    }
}

struct AgoraTypingPresence: Codable, Equatable {
    let roomId: String
    let actorId: String
    let membershipId: String
    let handle: String
    let displayName: String
    let isTyping: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case handle
        case roomId = "room_id"
        case actorId = "actor_id"
        case membershipId = "membership_id"
        case displayName = "display_name"
        case isTyping = "is_typing"
        case updatedAt = "updated_at_ms"
    }
}

struct AgoraBridge: Codable, Equatable, Identifiable {
    let id: String
    let roomId: String
    let ownerActorId: String
    let clientRequestId: String
    let firstActorId: String
    let secondActorId: String
    let prompt: String
    let status: AgoraBridgeStatus
    let maxTurns: Int
    let turnsCompleted: Int
    let stopReason: String?
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, prompt, status
        case roomId = "room_id"
        case ownerActorId = "owner_actor_id"
        case clientRequestId = "client_request_id"
        case firstActorId = "first_actor_id"
        case secondActorId = "second_actor_id"
        case maxTurns = "max_turns"
        case turnsCompleted = "turns_completed"
        case stopReason = "stop_reason"
        case lastError = "last_error"
        case createdAt = "created_at_ms"
        case updatedAt = "updated_at_ms"
        case completedAt = "completed_at_ms"
    }
}

struct AgoraBridgeTurn: Codable, Equatable, Identifiable {
    let id: String
    let bridgeId: String
    let turnIndex: Int
    let sourceMessageId: String
    let mentionId: String
    let expectedActorId: String
    let replyMessageId: String?
    let state: AgoraBridgeTurnState
    let error: String?
    let createdAt: Date
    let claimedAt: Date?
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, state, error
        case bridgeId = "bridge_id"
        case turnIndex = "turn_index"
        case sourceMessageId = "source_message_id"
        case mentionId = "mention_id"
        case expectedActorId = "expected_actor_id"
        case replyMessageId = "reply_message_id"
        case createdAt = "created_at_ms"
        case claimedAt = "claimed_at_ms"
        case completedAt = "completed_at_ms"
    }
}

struct AgoraBridgeState: Codable, Equatable {
    let bridge: AgoraBridge
    let currentTurn: AgoraBridgeTurn?

    enum CodingKeys: String, CodingKey {
        case bridge
        case currentTurn = "current_turn"
    }
}

struct AgoraMention: Codable, Equatable, Identifiable {
    let id: String
    let roomId: String
    let sourceMessageId: String
    let sourceSeq: Int
    let sourcePreview: String
    let targetMembershipId: String
    let targetMember: AgoraMember
    let state: AgoraMentionState
    let kind: AgoraMentionKind
    let depth: Int
    let claimedAt: Date?
    let leaseExpiresAt: Date?
    let completedAt: Date?
    let resultMessageId: String?
    let attemptCount: Int
    let lastError: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, state, kind, depth
        case roomId = "room_id"
        case sourceMessageId = "source_message_id"
        case sourceSeq = "source_seq"
        case sourcePreview = "source_preview"
        case targetMembershipId = "target_membership_id"
        case targetMember = "target_member"
        case claimedAt = "claimed_at_ms"
        case leaseExpiresAt = "lease_expires_at_ms"
        case completedAt = "completed_at_ms"
        case resultMessageId = "result_message_id"
        case attemptCount = "attempt_count"
        case lastError = "last_error"
        case createdAt = "created_at_ms"
    }
}

extension AgoraMention {
    /// init(from:) 放 extension：保住 memberwise init（测试 fixture 在用）。
    /// kind/depth decodeIfPresent 容错：老 hub 的 DTO 没这俩字段（v6 前），缺省 direct/0。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        roomId = try container.decode(String.self, forKey: .roomId)
        sourceMessageId = try container.decode(String.self, forKey: .sourceMessageId)
        sourceSeq = try container.decode(Int.self, forKey: .sourceSeq)
        sourcePreview = try container.decode(String.self, forKey: .sourcePreview)
        targetMembershipId = try container.decode(String.self, forKey: .targetMembershipId)
        targetMember = try container.decode(AgoraMember.self, forKey: .targetMember)
        state = try container.decode(AgoraMentionState.self, forKey: .state)
        kind = try container.decodeIfPresent(AgoraMentionKind.self, forKey: .kind) ?? .direct
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        claimedAt = try container.decodeIfPresent(Date.self, forKey: .claimedAt)
        leaseExpiresAt = try container.decodeIfPresent(Date.self, forKey: .leaseExpiresAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        resultMessageId = try container.decodeIfPresent(String.self, forKey: .resultMessageId)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

struct AgoraMentionCounts: Codable, Equatable {
    var pending: Int
    var claimed: Int
    var completed: Int
    var failed: Int

    static let zero = AgoraMentionCounts(pending: 0, claimed: 0, completed: 0, failed: 0)

    subscript(state: AgoraMentionState) -> Int {
        get {
            switch state {
            case .pending: pending
            case .claimed: claimed
            case .completed: completed
            case .failed: failed
            }
        }
        set {
            switch state {
            case .pending: pending = newValue
            case .claimed: claimed = newValue
            case .completed: completed = newValue
            case .failed: failed = newValue
            }
        }
    }
}

struct AgoraProtocolErrorDetails: Codable, Equatable {
    let unknownHandles: [String]?
    let disabledHandles: [String]?
    let handle: String?
    let limit: Int?
    let state: String?
    let retryAfterMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case handle, limit, state
        case unknownHandles = "unknown_handles"
        case disabledHandles = "disabled_handles"
        case retryAfterMilliseconds = "retry_after_ms"
    }
}

struct AgoraProtocolError: Codable, Error, Equatable, LocalizedError {
    let code: String
    let message: String
    let details: AgoraProtocolErrorDetails?

    var errorDescription: String? { message }
}

struct AgoraOwnerProfile: Codable, Equatable {
    let handle: String
    let displayName: String
    let avatarRef: String?

    enum CodingKeys: String, CodingKey {
        case handle
        case displayName = "display_name"
        case avatarRef = "avatar_ref"
    }
}

struct AgoraRoomMemberSpec: Codable, Equatable {
    let actorId: String
    let handle: String
    let displayName: String
    let avatarRef: String?

    enum CodingKeys: String, CodingKey {
        case handle
        case actorId = "actor_id"
        case displayName = "display_name"
        case avatarRef = "avatar_ref"
    }
}

struct AgoraRoomCreationMember: Equatable {
    let sessionName: String
    let handle: String
    let displayName: String
    let avatarRef: String?
}

struct AgoraCreateRoomInput: Codable, Equatable {
    let clientRequestId: String
    let floorId: String
    let title: String
    let isDM: Bool
    let ownerProfile: AgoraOwnerProfile
    let memberSpecs: [AgoraRoomMemberSpec]

    enum CodingKeys: String, CodingKey {
        case title
        case isDM = "is_dm"
        case clientRequestId = "client_request_id"
        case floorId = "floor_id"
        case ownerProfile = "owner_profile"
        case memberSpecs = "member_specs"
    }
}

struct AgoraRoomCreateResult: Codable, Equatable {
    let room: AgoraRoomSummary
    let idempotent: Bool
}

struct AgoraRoomOpenResult: Codable, Equatable {
    let room: AgoraRoomSummary
    let members: [AgoraMember]
    let messages: [AgoraMessage]
    let mentionCounts: AgoraMentionCounts
    let bridge: AgoraBridgeState?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case room, members, messages, bridge
        case mentionCounts = "mention_counts"
        case hasMore = "has_more"
    }
}

struct AgoraMessagePage: Codable, Equatable {
    let messages: [AgoraMessage]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}

struct AgoraPostResult: Codable, Equatable {
    let message: AgoraMessage
    let mentions: [AgoraMention]
    let idempotent: Bool
}

struct AgoraBridgeStartInput: Codable, Equatable {
    let roomId: String
    let clientRequestId: String
    let firstActorId: String
    let secondActorId: String
    let prompt: String
    let maxTurns: Int

    enum CodingKeys: String, CodingKey {
        case prompt
        case roomId = "room_id"
        case clientRequestId = "client_request_id"
        case firstActorId = "first_actor_id"
        case secondActorId = "second_actor_id"
        case maxTurns = "max_turns"
    }
}

struct AgoraBridgeStartResult: Codable, Equatable {
    let bridge: AgoraBridge
    let currentTurn: AgoraBridgeTurn?
    let message: AgoraMessage
    let mention: AgoraMention

    enum CodingKeys: String, CodingKey {
        case bridge, message, mention
        case currentTurn = "current_turn"
    }

    var state: AgoraBridgeState { AgoraBridgeState(bridge: bridge, currentTurn: currentTurn) }
}

struct AgoraEvent: Decodable, Equatable, Identifiable {
    enum DataValue: Equatable {
        case room(AgoraRoomSummary)
        case message(AgoraMessage)
        case typing(AgoraTypingPresence)
        case bridge(AgoraBridgeState)
        case mention(AgoraMention)
        case settings(AgoraSettings)
    }

    let id: String
    let roomId: String
    let kind: AgoraEventKind
    let data: DataValue

    enum CodingKeys: String, CodingKey {
        case id = "event_id"
        case roomId = "room_id"
        case kind, data
    }

    private enum DataKeys: String, CodingKey {
        case room, message, typing, mention, bridge
        case currentTurn = "current_turn"
    }

    init(id: String, roomId: String, kind: AgoraEventKind, data: DataValue) {
        self.id = id
        self.roomId = roomId
        self.kind = kind
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        roomId = try container.decode(String.self, forKey: .roomId)
        kind = try container.decode(AgoraEventKind.self, forKey: .kind)
        let nested = try container.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        switch kind {
        case .roomCreated, .roomUpdated:
            data = .room(try nested.decode(AgoraRoomSummary.self, forKey: .room))
        case .messageCreated, .messageUpdated:
            data = .message(try nested.decode(AgoraMessage.self, forKey: .message))
        case .typingStart, .typingStop:
            data = .typing(try nested.decode(AgoraTypingPresence.self, forKey: .typing))
        case .bridgeStarted, .bridgeAdvanced, .bridgeStopped, .bridgeCompleted, .bridgeFailed:
            data = .bridge(AgoraBridgeState(
                bridge: try nested.decode(AgoraBridge.self, forKey: .bridge),
                currentTurn: try nested.decodeIfPresent(AgoraBridgeTurn.self, forKey: .currentTurn)
            ))
        case .mentionUpdated:
            data = .mention(try nested.decode(AgoraMention.self, forKey: .mention))
        case .settingsUpdated:
            // settings.updated 的 data 是平铺对象（无 room/message 子键），直接整体解码
            data = .settings(try container.decode(AgoraSettings.self, forKey: .data))
        }
    }
}
