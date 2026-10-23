import Foundation

enum AgoraConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)
}

@MainActor
protocol AgoraClientProtocol: AnyObject {
    var connectionState: AgoraConnectionState { get }
    var eventHandler: ((AgoraEvent) -> Void)? { get set }
    var reconnectHandler: (() -> Void)? { get set }
    var connectionStateHandler: ((AgoraConnectionState) -> Void)? { get set }

    func connect() async throws
    func disconnect()
    func listActors() async throws -> [AgoraActorSummary]
    func upsertCCActor(sessionName: String) async throws -> AgoraActorSummary
    func listRooms(floorId: String) async throws -> [AgoraRoomSummary]
    func createRoom(_ input: AgoraCreateRoomInput) async throws -> AgoraRoomCreateResult
    func openRoom(roomId: String, beforeSeq: Int?, limit: Int) async throws -> AgoraRoomOpenResult
    func messagesAfter(roomId: String, afterSeq: Int, limit: Int) async throws -> AgoraMessagePage
    func postMessage(roomId: String, clientMessageId: String, content: String) async throws -> AgoraPostResult
    func editMessage(id: String, content: String) async throws -> AgoraMessage
    func deleteMessage(id: String) async throws -> AgoraMessage
    func setTyping(roomId: String, isTyping: Bool) async throws -> AgoraTypingPresence
    func startBridge(_ input: AgoraBridgeStartInput) async throws -> AgoraBridgeStartResult
    func stopBridge(id: String) async throws -> AgoraBridgeState
    func bridgeStatus(roomId: String) async throws -> AgoraBridgeState?
    func listMentions(roomId: String, state: AgoraMentionState?, limit: Int) async throws -> [AgoraMention]
    func retryMention(id: String) async throws -> AgoraMention

    /// 打断退避立即重连（前台恢复/用户点重连条）。默认 no-op（fake/测试不需要）。
    func nudgeReconnect()
}

extension AgoraClientProtocol {
    func nudgeReconnect() {}
}
