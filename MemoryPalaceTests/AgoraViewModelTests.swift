import XCTest
@testable import 记忆花园

@MainActor
final class AgoraViewModelTests: XCTestCase {
    func testServerFixturesDecodeMillisecondsAndEventPayloads() throws {
        let openedJSON = """
        {
          "room": {
            "id": "room-1", "floor_id": "floor-1", "title": "中庭",
            "owner_actor_id": "owner-1", "is_dm": false, "dm_peer_actor_id": null,
            "next_seq": 3, "is_enabled": true,
            "created_at_ms": 1710000000000, "updated_at_ms": 1710000005000,
            "member_count": 1,
            "members": [{
              "id": "member-1", "room_id": "room-1", "actor_id": "owner-1",
              "handle": "susu", "display_name": "Susu", "avatar_ref": null,
              "role": "owner", "executor_kind": "none", "is_enabled": true,
              "joined_at_ms": 1710000000000
            }]
          },
          "members": [{
            "id": "member-1", "room_id": "room-1", "actor_id": "owner-1",
            "handle": "susu", "display_name": "Susu", "avatar_ref": null,
            "role": "owner", "executor_kind": "none", "is_enabled": true,
            "joined_at_ms": 1710000000000
          }],
          "messages": [{
            "id": "message-1", "room_id": "room-1", "seq": 1,
            "actor_id": "owner-1", "client_message_id": "client-1",
            "content": "hello", "created_at_ms": 1710000001000,
            "edited_at_ms": null, "is_deleted": false, "deleted_at_ms": null
          }],
          "mention_counts": {"pending": 1, "claimed": 0, "completed": 0, "failed": 0},
          "has_more": false
        }
        """
        let opened = try AgoraJSON.decoder().decode(AgoraRoomOpenResult.self, from: Data(openedJSON.utf8))
        XCTAssertEqual(opened.room.floorId, "floor-1")
        XCTAssertFalse(opened.room.isDM)
        XCTAssertNil(opened.room.dmPeerActorId)
        XCTAssertEqual(opened.members.first?.executorKind, AgoraExecutorKind.none)
        let firstCreatedAt = try XCTUnwrap(opened.messages.first?.createdAt)
        XCTAssertEqual(firstCreatedAt.timeIntervalSince1970, 1_710_000_001, accuracy: 0.001)
        XCTAssertEqual(opened.mentionCounts.pending, 1)

        let eventJSON = """
        {
          "type": "agora_event", "event_id": "event-1", "room_id": "room-1",
          "kind": "message.created",
          "data": {"message": {
            "id": "message-2", "room_id": "room-1", "seq": 2,
            "actor_id": "owner-1", "client_message_id": "client-2",
            "content": "world", "created_at_ms": 1710000002000,
            "edited_at_ms": null, "is_deleted": false, "deleted_at_ms": null
          }}
        }
        """
        let event = try AgoraJSON.decoder().decode(AgoraEvent.self, from: Data(eventJSON.utf8))
        guard case .message(let message) = event.data else {
            return XCTFail("message.created 必须解成 message payload")
        }
        XCTAssertEqual(event.id, "event-1")
        XCTAssertEqual(message.seq, 2)

        let typingJSON = """
        {
          "type": "agora_event", "event_id": "event-typing", "room_id": "room-1",
          "kind": "typing.start",
          "data": {"typing": {
            "room_id": "room-1", "actor_id": "actor-alice", "membership_id": "member-alice",
            "handle": "alice", "display_name": "Alice", "is_typing": true,
            "updated_at_ms": 1710000003000
          }}
        }
        """
        let typingEvent = try AgoraJSON.decoder().decode(AgoraEvent.self, from: Data(typingJSON.utf8))
        guard case .typing(let typing) = typingEvent.data else {
            return XCTFail("typing.start 必须解成 typing payload")
        }
        XCTAssertEqual(typing.displayName, "Alice")
        XCTAssertTrue(typing.isTyping)
    }

    func testAgoraURLDerivationReplacesPathAndToken() {
        let bases = [
            URL(string: "ws://127.0.0.1:7890/cc?token=old")!,
            URL(string: "wss://mac.example.ts.net/cc")!,
        ]
        let urls = AgoraClient.deriveAgoraURLs(from: bases, token: "new token")
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].path, "/agora")
        XCTAssertEqual(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "token" }.map(\.value), ["new token"])
        XCTAssertEqual(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "bundle" }.map(\.value), [Bundle.main.bundleIdentifier])
        XCTAssertEqual(urls[1].scheme, "wss")
        XCTAssertEqual(urls[1].path, "/agora")
    }

    func testBridgeStartAndStopUpdateRoomIndicatorState() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [])
        let active = bridgeState(status: .active, turnsCompleted: 0)
        let bridgeMention = AgoraMention(
            id: "mention-bridge", roomId: "room-1", sourceMessageId: "message-1",
            sourceSeq: 1, sourcePreview: "bridge", targetMembershipId: "member-alice",
            targetMember: member(roomId: "room-1"), state: .pending, kind: .direct, depth: 0,
            claimedAt: nil, leaseExpiresAt: nil, completedAt: nil, resultMessageId: nil,
            attemptCount: 0, lastError: nil, createdAt: Date(timeIntervalSince1970: 1)
        )
        fake.bridgeStartResult = AgoraBridgeStartResult(
            bridge: active.bridge,
            currentTurn: active.currentTurn,
            message: message(1, content: "@alice discuss"),
            mention: bridgeMention
        )
        fake.bridgeStopResult = bridgeState(status: .stopped, turnsCompleted: 0)
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        let started = await viewModel.startBridge(
            prompt: " discuss ", firstActorId: "actor-alice", secondActorId: "actor-bob", maxTurns: 5
        )
        XCTAssertTrue(started)
        XCTAssertEqual(fake.bridgeStartCalls.first?.prompt, "discuss")
        XCTAssertEqual(viewModel.bridgeState?.bridge.status, .active)
        XCTAssertEqual(viewModel.messages.map(\.id), ["message-1"])

        await viewModel.stopBridge()
        XCTAssertEqual(fake.bridgeStopCalls, ["bridge-1"])
        XCTAssertEqual(viewModel.bridgeState?.bridge.status, .stopped)
    }

    func testActivateOpenLoadOlderAndFloorSwitch() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(3), message(4)], hasMore: true)
        fake.olderResults = [openResult(roomId: "room-1", messages: [message(1), message(2)], hasMore: false)]
        let viewModel = AgoraViewModel(client: fake)

        await viewModel.activate(floorId: "floor-1")
        XCTAssertEqual(viewModel.rooms.map(\.id), ["room-1"])
        XCTAssertEqual(viewModel.connectionState, .connected)

        await viewModel.openRoom(id: "room-1")
        XCTAssertEqual(viewModel.messages.map(\.seq), [3, 4])
        XCTAssertTrue(viewModel.hasMoreOlder)
        await viewModel.loadOlder()
        XCTAssertEqual(viewModel.messages.map(\.seq), [1, 2, 3, 4])
        XCTAssertFalse(viewModel.hasMoreOlder)
        XCTAssertEqual(fake.openCalls.last?.beforeSeq, 3)

        fake.roomsByFloor["floor-2"] = []
        await viewModel.activate(floorId: "floor-2")
        XCTAssertEqual(viewModel.floorId, "floor-2")
        XCTAssertNil(viewModel.selectedRoomId)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testCreateUpsertsActorsThenOpensCanonicalRoom() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = []
        fake.actorsBySession["agent-a"] = actor(id: "actor-a", session: "agent-a")
        fake.createResult = AgoraRoomCreateResult(room: room(id: "room-new", floorId: "floor-1"), idempotent: false)
        fake.openResults["room-new"] = openResult(roomId: "room-new", messages: [])
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")

        await viewModel.createRoom(
            title: "新房间",
            ownerProfile: AgoraOwnerProfile(handle: "susu", displayName: "Susu", avatarRef: nil),
            members: [AgoraRoomCreationMember(sessionName: "agent-a", handle: "fog", displayName: "小岚", avatarRef: nil)]
        )

        XCTAssertEqual(fake.upsertCalls, ["agent-a"])
        XCTAssertEqual(fake.createCalls.first?.memberSpecs.first?.actorId, "actor-a")
        XCTAssertEqual(viewModel.selectedRoomId, "room-new")
        XCTAssertEqual(fake.openCalls.last?.roomId, "room-new")
    }

    func testCreateDirectMessageUsesCurrentMembershipAndOpensCanonicalDM() async {
        let fake = FakeAgoraClient()
        let owner = member(roomId: "room-1")
        let alice = AgoraMember(
            id: "member-alice", roomId: "room-1", actorId: "actor-alice", handle: "alice",
            displayName: "Alice", avatarRef: "avatar-alice", role: .member, executorKind: .ccBridge,
            isEnabled: true, joinedAt: Date(timeIntervalSince1970: 1)
        )
        let sourceRoom = room(id: "room-1", floorId: "floor-1", members: [owner, alice])
        let dmOwner = member(roomId: "room-dm")
        let dmAlice = AgoraMember(
            id: "member-dm-alice", roomId: "room-dm", actorId: alice.actorId, handle: alice.handle,
            displayName: alice.displayName, avatarRef: alice.avatarRef, role: .member, executorKind: .ccBridge,
            isEnabled: true, joinedAt: Date(timeIntervalSince1970: 2)
        )
        let dmRoom = room(
            id: "room-dm", floorId: "floor-1", title: "Alice", isDM: true,
            dmPeerActorId: alice.actorId,
            members: [dmOwner, dmAlice]
        )
        fake.roomsByFloor["floor-1"] = [sourceRoom]
        fake.openResults["room-1"] = AgoraRoomOpenResult(
            room: sourceRoom, members: sourceRoom.members, messages: [],
            mentionCounts: .zero, bridge: nil, hasMore: false
        )
        fake.createResult = AgoraRoomCreateResult(room: dmRoom, idempotent: false)
        fake.openResults["room-dm"] = AgoraRoomOpenResult(
            room: dmRoom, members: dmRoom.members, messages: [],
            mentionCounts: .zero, bridge: nil, hasMore: false
        )
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        let created = await viewModel.createDirectMessage(with: alice)

        XCTAssertTrue(created)
        XCTAssertEqual(fake.createCalls.first?.isDM, true)
        XCTAssertEqual(fake.createCalls.first?.ownerProfile.handle, "susu")
        XCTAssertEqual(fake.createCalls.first?.memberSpecs.map(\.actorId), ["actor-alice"])
        XCTAssertEqual(viewModel.selectedRoomId, "room-dm")
        XCTAssertEqual(viewModel.rooms.first(where: { $0.id == "room-dm" })?.isDM, true)
    }

    func testCreateDirectMessageOpensLoadedCanonicalDMWithoutCreatingAgain() async {
        let fake = FakeAgoraClient()
        let owner = member(roomId: "room-1")
        let alice = AgoraMember(
            id: "member-alice", roomId: "room-1", actorId: "actor-alice", handle: "alice",
            displayName: "Alice", avatarRef: nil, role: .member, executorKind: .ccBridge,
            isEnabled: true, joinedAt: Date(timeIntervalSince1970: 1)
        )
        let sourceRoom = room(id: "room-1", floorId: "floor-1", members: [owner, alice])
        let dmRoom = room(
            id: "room-dm", floorId: "floor-1", title: "Alice", isDM: true,
            dmPeerActorId: alice.actorId,
            members: [member(roomId: "room-dm")]
        )
        fake.roomsByFloor["floor-1"] = [sourceRoom, dmRoom]
        fake.openResults["room-1"] = AgoraRoomOpenResult(
            room: sourceRoom, members: sourceRoom.members, messages: [],
            mentionCounts: .zero, bridge: nil, hasMore: false
        )
        fake.openResults["room-dm"] = AgoraRoomOpenResult(
            room: dmRoom, members: dmRoom.members, messages: [],
            mentionCounts: .zero, bridge: nil, hasMore: false
        )
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        let opened = await viewModel.createDirectMessage(with: alice)
        XCTAssertTrue(opened)
        XCTAssertTrue(fake.createCalls.isEmpty)
        XCTAssertEqual(viewModel.selectedRoomId, "room-dm")
    }

    func testPostFreezesTrimmedPayloadAndClearsOnlyAfterAck() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [])
        fake.postResult = AgoraPostResult(message: message(1, content: "@fog hello"), mentions: [], idempotent: false)
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")
        viewModel.composerText = "  @fog hello  \n"

        await viewModel.post()

        XCTAssertEqual(fake.postCalls.first?.content, "@fog hello")
        XCTAssertNotNil(UUID(uuidString: fake.postCalls.first?.clientMessageId ?? ""))
        XCTAssertEqual(viewModel.messages.map(\.seq), [1])
        XCTAssertEqual(viewModel.composerText, "")
    }

    func testReplyPrefixesQuoteAndIsExclusiveWithEditing() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(1, content: "原话\n第二行")])
        fake.postResult = AgoraPostResult(message: message(2, content: "reply"), mentions: [], idempotent: false)
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")
        let original = viewModel.messages[0]

        // 编辑中开始回复：编辑清掉；回复中开始编辑：回复清掉
        viewModel.beginEditing(original)
        viewModel.beginReply(original)
        XCTAssertNil(viewModel.editingMessageId)
        XCTAssertEqual(viewModel.composerText, "")
        XCTAssertEqual(viewModel.replyingMessage?.id, "message-1")
        viewModel.beginEditing(original)
        XCTAssertNil(viewModel.replyingMessageId)
        viewModel.cancelEditing()

        viewModel.beginReply(original)
        viewModel.composerText = " 收到 "
        await viewModel.post()
        XCTAssertEqual(fake.postCalls.first?.content, "> Susu：原话 第二行\n\n收到")
        XCTAssertNil(viewModel.replyingMessageId)
        XCTAssertEqual(viewModel.composerText, "")
    }

    func testReactionsToggleThroughViewModelPerFloor() async {
        let suite = "AgoraViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(1)])
        let viewModel = AgoraViewModel(client: fake, localDefaults: defaults)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")
        let target = viewModel.messages[0]

        viewModel.toggleReaction("👍", on: target)
        viewModel.toggleReaction("🎉", on: target)
        XCTAssertEqual(viewModel.reactions(for: target), ["👍", "🎉"])
        viewModel.toggleReaction("👍", on: target)
        XCTAssertEqual(viewModel.reactions(for: target), ["🎉"])
        XCTAssertEqual(Page0LocalState(defaults: defaults, profileId: "floor-1").reactions["room-1"]?["message-1"], ["🎉"])

        await viewModel.activate(floorId: "floor-2")
        XCTAssertTrue(viewModel.reactionsByRoom.isEmpty)
    }

    func testEditingOwnMessageUsesComposerAndReplacesCanonicalSequence() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(1, content: "before")])
        fake.editResult = AgoraMessage(
            id: "message-1", roomId: "room-1", seq: 1, actorId: "owner-1",
            clientMessageId: "client-1", content: "after",
            createdAt: Date(timeIntervalSince1970: 1), editedAt: Date(timeIntervalSince1970: 2),
            isDeleted: false, deletedAt: nil
        )
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        viewModel.beginEditing(viewModel.messages[0])
        viewModel.composerText = " after "
        await viewModel.post()

        XCTAssertEqual(fake.editCalls.first?.id, "message-1")
        XCTAssertEqual(fake.editCalls.first?.content, "after")
        XCTAssertEqual(viewModel.messages.map(\.content), ["after"])
        XCTAssertNil(viewModel.editingMessageId)
        XCTAssertEqual(viewModel.composerText, "")
    }

    func testDeleteReplacesMessageWithSoftDeletedTombstone() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(1, content: "before")])
        fake.deleteResult = AgoraMessage(
            id: "message-1", roomId: "room-1", seq: 1, actorId: "owner-1",
            clientMessageId: "client-1", content: "", createdAt: Date(timeIntervalSince1970: 1),
            editedAt: nil, isDeleted: true, deletedAt: Date(timeIntervalSince1970: 3)
        )
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        await viewModel.deleteMessage(viewModel.messages[0])

        XCTAssertEqual(fake.deleteCalls, ["message-1"])
        XCTAssertTrue(viewModel.messages[0].isDeleted)
        XCTAssertEqual(viewModel.messages[0].seq, 1)
        XCTAssertEqual(viewModel.messages[0].content, "")
    }

    func testPostErrorAndOfflineActivationPreserveDraft() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [])
        fake.postError = TestError.offline
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")
        viewModel.composerText = "不要丢"

        await viewModel.post()

        XCTAssertEqual(viewModel.composerText, "不要丢")
        XCTAssertEqual(viewModel.errorBanner, TestError.offline.localizedDescription)

        let offline = FakeAgoraClient()
        offline.connectError = TestError.offline
        let offlineViewModel = AgoraViewModel(client: offline)
        await offlineViewModel.activate(floorId: "floor-x")
        XCTAssertEqual(offlineViewModel.connectionState, .failed(TestError.offline.localizedDescription))
        XCTAssertNotNil(offlineViewModel.errorBanner)
    }

    func testErrorBannerAutoDismisses() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [])
        fake.postError = TestError.offline
        let viewModel = AgoraViewModel(client: fake, errorBannerDuration: .milliseconds(10))
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")
        viewModel.composerText = "保留草稿"

        await viewModel.post()
        XCTAssertNotNil(viewModel.errorBanner)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(viewModel.errorBanner)
        XCTAssertEqual(viewModel.composerText, "保留草稿")
    }

    func testDuplicateEventIsIdempotentAndGapRecoversBeforeMerge() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(1)])
        fake.afterResults = [AgoraMessagePage(messages: [message(2), message(3)], hasMore: false)]
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        let duplicate = AgoraEvent(id: "event-duplicate", roomId: "room-1", kind: .messageCreated, data: .message(message(1)))
        await viewModel.handle(duplicate)
        await viewModel.handle(duplicate)
        XCTAssertEqual(viewModel.messages.map(\.seq), [1])

        let gap = AgoraEvent(id: "event-gap", roomId: "room-1", kind: .messageCreated, data: .message(message(3)))
        await viewModel.handle(gap)
        XCTAssertEqual(fake.afterCalls, [1])
        XCTAssertEqual(viewModel.messages.map(\.seq), [1, 2, 3])
        XCTAssertEqual(Set(viewModel.messages.map(\.id)).count, 3)
    }

    func testReconnectReloadsRoomsAndSyncsSelectedRoomCursor() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1", title: "旧标题")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(1)])
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1", title: "新标题")]
        fake.afterResults = [AgoraMessagePage(messages: [message(2)], hasMore: false)]
        await viewModel.reconnectSync()

        XCTAssertEqual(viewModel.rooms.first?.title, "新标题")
        XCTAssertEqual(fake.afterCalls, [1])
        XCTAssertEqual(viewModel.messages.map(\.seq), [1, 2])
    }

    func testStaleMutationEventBelowWindowIsDropped() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [message(151), message(152)], hasMore: true)
        let viewModel = AgoraViewModel(client: fake)
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        // 双设备场景：另一端软删/编辑了窗口外的 seq 10 → message.updated 事件不能混进窗口，
        // 否则 loadOlder 拿 10 当 beforeSeq，11-150 永远取不到。
        let stale = AgoraEvent(id: "event-stale", roomId: "room-1", kind: .messageUpdated, data: .message(message(10)))
        await viewModel.handle(stale)
        XCTAssertEqual(viewModel.messages.map(\.seq), [151, 152])

        // 窗口内 mutation 照常 merge（同 seq 覆盖）
        let edited = AgoraEvent(id: "event-edited", roomId: "room-1", kind: .messageUpdated, data: .message(message(151, content: "edited")))
        await viewModel.handle(edited)
        XCTAssertEqual(viewModel.messages.first?.content, "edited")
        XCTAssertEqual(viewModel.messages.map(\.seq), [151, 152])
    }

    func testTypingEventsAndThreeSecondInactivityLifecycle() async {
        let fake = FakeAgoraClient()
        fake.roomsByFloor["floor-1"] = [room(id: "room-1", floorId: "floor-1")]
        fake.openResults["room-1"] = openResult(roomId: "room-1", messages: [])
        let viewModel = AgoraViewModel(client: fake, typingInactivityDuration: .milliseconds(10))
        await viewModel.activate(floorId: "floor-1")
        await viewModel.openRoom(id: "room-1")

        let typing = AgoraTypingPresence(
            roomId: "room-1", actorId: "actor-alice", membershipId: "member-alice",
            handle: "alice", displayName: "Alice", isTyping: true,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        await viewModel.handle(AgoraEvent(
            id: "typing-start", roomId: "room-1", kind: .typingStart, data: .typing(typing)
        ))
        XCTAssertEqual(viewModel.typingIndicatorText, "Alice 正在输入…")
        await viewModel.handle(AgoraEvent(
            id: "typing-stop", roomId: "room-1", kind: .typingStop,
            data: .typing(AgoraTypingPresence(
                roomId: typing.roomId, actorId: typing.actorId, membershipId: typing.membershipId,
                handle: typing.handle, displayName: typing.displayName, isTyping: false,
                updatedAt: Date(timeIntervalSince1970: 2)
            ))
        ))
        XCTAssertNil(viewModel.typingIndicatorText)

        viewModel.composerText = "hello"
        viewModel.composerChanged()
        try? await Task.sleep(for: .milliseconds(2))
        XCTAssertEqual(fake.typingCalls.first?.isTyping, true)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fake.typingCalls.map(\.isTyping), [true, false])
    }

    private func actor(id: String, session: String) -> AgoraActorSummary {
        AgoraActorSummary(id: id, kind: .ccBridge, sessionName: session, createdAt: Date(timeIntervalSince1970: 1), disabledAt: nil)
    }

    private func member(roomId: String = "room-1") -> AgoraMember {
        AgoraMember(
            id: "member-owner", roomId: roomId, actorId: "owner-1", handle: "susu",
            displayName: "Susu", avatarRef: nil, role: .owner, executorKind: .none,
            isEnabled: true, joinedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func room(
        id: String,
        floorId: String,
        title: String = "中庭",
        isDM: Bool = false,
        dmPeerActorId: String? = nil,
        members: [AgoraMember]? = nil
    ) -> AgoraRoomSummary {
        let members = members ?? [member(roomId: id)]
        return AgoraRoomSummary(
            id: id, floorId: floorId, title: title, ownerActorId: "owner-1", isDM: isDM,
            dmPeerActorId: dmPeerActorId,
            nextSeq: 10, isEnabled: true, createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), memberCount: members.count, members: members
        )
    }

    private func message(_ seq: Int, roomId: String = "room-1", content: String? = nil) -> AgoraMessage {
        AgoraMessage(
            id: "message-\(seq)", roomId: roomId, seq: seq, actorId: "owner-1",
            clientMessageId: "client-\(seq)", content: content ?? "message \(seq)",
            createdAt: Date(timeIntervalSince1970: TimeInterval(seq)), editedAt: nil,
            isDeleted: false, deletedAt: nil
        )
    }

    private func openResult(roomId: String, messages: [AgoraMessage], hasMore: Bool = false) -> AgoraRoomOpenResult {
        let room = room(id: roomId, floorId: "floor-1")
        return AgoraRoomOpenResult(
            room: room, members: room.members, messages: messages,
            mentionCounts: .zero, bridge: nil, hasMore: hasMore
        )
    }

    private func bridgeState(status: AgoraBridgeStatus, turnsCompleted: Int) -> AgoraBridgeState {
        let bridge = AgoraBridge(
            id: "bridge-1", roomId: "room-1", ownerActorId: "owner-1",
            clientRequestId: "request-1", firstActorId: "actor-alice", secondActorId: "actor-bob",
            prompt: "discuss", status: status, maxTurns: 5, turnsCompleted: turnsCompleted,
            stopReason: status == .stopped ? "user_stopped" : nil, lastError: nil,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            completedAt: status == .active ? nil : Date(timeIntervalSince1970: 2)
        )
        let turn = status == .active ? AgoraBridgeTurn(
            id: "turn-1", bridgeId: bridge.id, turnIndex: 0, sourceMessageId: "message-1",
            mentionId: "mention-bridge", expectedActorId: "actor-alice", replyMessageId: nil,
            state: .pending, error: nil, createdAt: Date(timeIntervalSince1970: 1),
            claimedAt: nil, completedAt: nil
        ) : nil
        return AgoraBridgeState(bridge: bridge, currentTurn: turn)
    }
}

private enum TestError: Error, LocalizedError {
    case offline
    var errorDescription: String? { "离线" }
}

@MainActor
private final class FakeAgoraClient: AgoraClientProtocol {
    var connectionState: AgoraConnectionState = .disconnected
    var eventHandler: ((AgoraEvent) -> Void)?
    var reconnectHandler: (() -> Void)?
    var connectionStateHandler: ((AgoraConnectionState) -> Void)?

    var connectError: Error?
    var roomsByFloor: [String: [AgoraRoomSummary]] = [:]
    var actorsBySession: [String: AgoraActorSummary] = [:]
    var createResult: AgoraRoomCreateResult?
    var openResults: [String: AgoraRoomOpenResult] = [:]
    var olderResults: [AgoraRoomOpenResult] = []
    var afterResults: [AgoraMessagePage] = []
    var postResult: AgoraPostResult?
    var postError: Error?
    var editResult: AgoraMessage?
    var deleteResult: AgoraMessage?
    var mentionsByRoom: [String: [AgoraMention]] = [:]
    var retryResults: [String: AgoraMention] = [:]
    var bridgeStartResult: AgoraBridgeStartResult?
    var bridgeStopResult: AgoraBridgeState?
    var bridgeStatusResult: AgoraBridgeState?

    var upsertCalls: [String] = []
    var createCalls: [AgoraCreateRoomInput] = []
    var openCalls: [(roomId: String, beforeSeq: Int?)] = []
    var afterCalls: [Int] = []
    var postCalls: [(roomId: String, clientMessageId: String, content: String)] = []
    var editCalls: [(id: String, content: String)] = []
    var deleteCalls: [String] = []
    var typingCalls: [(roomId: String, isTyping: Bool)] = []
    var bridgeStartCalls: [AgoraBridgeStartInput] = []
    var bridgeStopCalls: [String] = []

    func connect() async throws {
        if let connectError {
            connectionState = .failed(connectError.localizedDescription)
            connectionStateHandler?(connectionState)
            throw connectError
        }
        connectionState = .connected
        connectionStateHandler?(connectionState)
    }

    func disconnect() {
        connectionState = .disconnected
        connectionStateHandler?(connectionState)
    }

    func listActors() async throws -> [AgoraActorSummary] {
        Array(actorsBySession.values)
    }

    func upsertCCActor(sessionName: String) async throws -> AgoraActorSummary {
        upsertCalls.append(sessionName)
        guard let actor = actorsBySession[sessionName] else { throw TestError.offline }
        return actor
    }

    func listRooms(floorId: String) async throws -> [AgoraRoomSummary] {
        roomsByFloor[floorId] ?? []
    }

    func createRoom(_ input: AgoraCreateRoomInput) async throws -> AgoraRoomCreateResult {
        createCalls.append(input)
        guard let createResult else { throw TestError.offline }
        return createResult
    }

    func openRoom(roomId: String, beforeSeq: Int?, limit: Int) async throws -> AgoraRoomOpenResult {
        openCalls.append((roomId, beforeSeq))
        if beforeSeq != nil, !olderResults.isEmpty { return olderResults.removeFirst() }
        guard let result = openResults[roomId] else { throw TestError.offline }
        return result
    }

    func messagesAfter(roomId: String, afterSeq: Int, limit: Int) async throws -> AgoraMessagePage {
        afterCalls.append(afterSeq)
        guard !afterResults.isEmpty else { return AgoraMessagePage(messages: [], hasMore: false) }
        return afterResults.removeFirst()
    }

    func postMessage(roomId: String, clientMessageId: String, content: String) async throws -> AgoraPostResult {
        postCalls.append((roomId, clientMessageId, content))
        if let postError { throw postError }
        guard let postResult else { throw TestError.offline }
        return postResult
    }

    func editMessage(id: String, content: String) async throws -> AgoraMessage {
        editCalls.append((id, content))
        guard let editResult else { throw TestError.offline }
        return editResult
    }

    func deleteMessage(id: String) async throws -> AgoraMessage {
        deleteCalls.append(id)
        guard let deleteResult else { throw TestError.offline }
        return deleteResult
    }

    func setTyping(roomId: String, isTyping: Bool) async throws -> AgoraTypingPresence {
        typingCalls.append((roomId, isTyping))
        return AgoraTypingPresence(
            roomId: roomId, actorId: "owner-1", membershipId: "member-owner",
            handle: "susu", displayName: "Susu", isTyping: isTyping, updatedAt: Date()
        )
    }

    func startBridge(_ input: AgoraBridgeStartInput) async throws -> AgoraBridgeStartResult {
        bridgeStartCalls.append(input)
        guard let bridgeStartResult else { throw TestError.offline }
        return bridgeStartResult
    }

    func stopBridge(id: String) async throws -> AgoraBridgeState {
        bridgeStopCalls.append(id)
        guard let bridgeStopResult else { throw TestError.offline }
        return bridgeStopResult
    }

    func bridgeStatus(roomId: String) async throws -> AgoraBridgeState? {
        bridgeStatusResult
    }

    func listMentions(roomId: String, state: AgoraMentionState?, limit: Int) async throws -> [AgoraMention] {
        let mentions = mentionsByRoom[roomId] ?? []
        guard let state else { return Array(mentions.prefix(limit)) }
        return Array(mentions.filter { $0.state == state }.prefix(limit))
    }

    func retryMention(id: String) async throws -> AgoraMention {
        guard let mention = retryResults[id] else { throw TestError.offline }
        return mention
    }
}
