#if PERSONAL_APPS
#if DEBUG
import Foundation
import Observation

// MARK: - pmBoard 子应用的数据层（docs/plan-dev-subapp-v2.md P0-d）
// 只发 pm_req（hub 原样转给 4793，按 req_id 对回）；收 NotificationCenter。面板挂载时机不定（iOS page2 子应用 / mac 右栏），所以用单例，跟军机处同法。
// 发送 = 先在本机插一条 sending 气泡，4793 收下以后以它的 outbox 为准（排着 / 卡住 / 已送都在那边算）。

@MainActor
@Observable
final class PMBoardStore {
    static let shared = PMBoardStore()

    enum Req {
        case home, board, occupancy, task
        case session(String)
        case send(sid: String, id: String)
        case outbox(sid: String)
        case open(String)
        case doc(String)
        case docState(String)
    }

    private(set) var home: PMHome?
    private(set) var homeError: String?
    private(set) var occupancy: PMOccupancy?
    private(set) var occupancyError: String?
    private(set) var task: PMTaskBoard?
    private(set) var taskError: String?
    private(set) var board: PMBoard?
    private(set) var boardError: String?
    private(set) var boardLoading = false
    private(set) var details: [String: PMDetail] = [:]
    private(set) var detailErrors: [String: String] = [:]
    private(set) var localOut: [String: [PMOutItem]] = [:]   // sid → 还没被 4793 outbox 认领的
    private(set) var openMessage: [String: String] = [:]
    private(set) var docs: [String: PMDoc] = [:]
    private(set) var docErrors: [String: String] = [:]
    private(set) var docLoading: Set<String> = []
    private(set) var pinOverride: [String: Bool] = PMBoardStore.loadPins()

    @ObservationIgnored private var pending: [String: Req] = [:]   // req_id → 这次请的是什么
    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let pinsKey = "pm.pinned"
    private static let replyTimeout: Duration = .seconds(10)

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .pmBoardFrame, object: nil, queue: .main) { note in
            guard let type = note.userInfo?["type"] as? String, let data = note.userInfo?["data"] as? Data else { return }
            MainActor.assumeIsolated { PMBoardStore.shared.handle(type: type, data: data) }
        }
    }

    var bridgeConnected: Bool { CCBridgeWebSocketClient.shared.isConnected }

    // MARK: 置顶（默认 = 四个管家；长按可取消，存本机）

    func isPinned(_ p: PMPerson) -> Bool { pinOverride[p.sid] ?? p.pinnedDefault }

    func togglePin(_ p: PMPerson) {
        pinOverride[p.sid] = !isPinned(p)
        UserDefaults.standard.set(pinOverride, forKey: Self.pinsKey)
    }

    private static func loadPins() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: Bool] ?? [:]
    }

    // MARK: 发

    func requestHome() { request(.home, "GET", "/api/home") }

    func requestBoard() {
        if board == nil { boardLoading = true }
        request(.board, "GET", "/api/board?view=phone")
    }

    func requestOccupancy() { request(.occupancy, "GET", "/api/occupancy") }

    func requestTask() { request(.task, "GET", "/api/task") }

    /// 路线图页面里垫片送出来的一次改动（{doc, key, patch|value}），原样交给 4793 落盘
    func postDocState(_ name: String, _ body: [String: Any]) {
        var b = body
        b["doc"] = name
        request(.docState(name), "POST", "/api/docstate", body: b)
    }

    func requestSession(_ sid: String) { request(.session(sid), "GET", "/api/session?sid=\(sid)") }

    func send(_ text: String, to sid: String, id: String = UUID().uuidString) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var list = localOut[sid, default: []].filter { $0.id != id }
        list.append(PMOutItem(id: id, sid: sid, text: body, createdAt: Date.now.timeIntervalSince1970 * 1000, state: "sending", why: "", stale: false, seen: false))
        localOut[sid] = list
        request(.send(sid: sid, id: id), "POST", "/api/send", body: ["sid": sid, "text": body, "clientMsgId": id])
    }

    /// 本机发失败的那条原样再交一次（同一个 clientMsgId，4793 端幂等）
    func resend(_ item: PMOutItem) { send(item.text, to: item.sid, id: item.id) }

    func dropLocal(_ item: PMOutItem) { localOut[item.sid]?.removeAll { $0.id == item.id } }

    func cancel(_ item: PMOutItem) { request(.outbox(sid: item.sid), "POST", "/api/outbox/cancel", body: ["id": item.id]) }

    /// how：enter = 补按回车；redo = 清掉重发
    func retry(_ item: PMOutItem, how: String) { request(.outbox(sid: item.sid), "POST", "/api/outbox/retry", body: ["id": item.id, "how": how]) }

    func openOnMac(_ sid: String) {
        openMessage[sid] = "正在叫 Mac…"
        request(.open(sid), "POST", "/api/open", body: ["sid": sid])
    }

    func requestDoc(name: String) {
        docLoading.insert(name)
        docErrors[name] = nil
        request(.doc(name), "GET", "/api/doc?name=\(name)")
    }

    /// 这个 session 的待送气泡：4793 outbox 为准，本机还没交过去的接在后面；已经在对话里出现的（seen）和撤回的不再单独显示
    func outbox(for sid: String) -> [PMOutItem] {
        let server = details[sid]?.outbox ?? []
        let known = Set(server.map(\.id))
        return server.filter { !$0.seen && $0.state != "cancelled" } + (localOut[sid] ?? []).filter { !known.contains($0.id) }
    }

    /// 轮询间隔：列表 / 占用 / 待验 10 秒；详情 4 秒；有排着 / 正在送的 2 秒
    func interval(detail sid: String?) -> Double {
        guard let sid else { return 10 }
        return outbox(for: sid).contains(where: \.isLive) ? 2 : 4
    }

    private func request(_ kind: Req, _ method: String, _ path: String, body: [String: Any]? = nil) {
        guard bridgeConnected else { fail(kind, "桥没连上（记忆花园没连到 Mac 上的 hub）"); return }
        let id = register(kind)
        var payload: [String: Any] = ["type": "pm_req", "req_id": id, "method": method, "path": path]
        if let body { payload["body"] = body }
        CCBridgeWebSocketClient.shared.send(payload) { err in
            guard let err else { return }
            Task { @MainActor in PMBoardStore.shared.settle(id, error: "发不出去：\(err.localizedDescription)") }
        }
        Task { [weak self] in   // hub 还没重启、不认 pm_req 时一声不吭，别让转圈挂着
            try? await Task.sleep(for: Self.replyTimeout)
            self?.settle(id, error: "Mac 那边 10 秒没回（hub 还没认 pm_req？要重启一次 hub）")
        }
    }

    /// 记下这次请求、发号；回帧按号对回（单测也从这里拿号）
    func register(_ kind: Req) -> String {
        let id = UUID().uuidString
        pending[id] = kind
        return id
    }

    private func settle(_ id: String, error: String) {
        guard let kind = pending.removeValue(forKey: id) else { return }
        fail(kind, error)
    }

    private func fail(_ kind: Req, _ msg: String) {
        switch kind {
        case .home: homeError = msg
        case .board: boardLoading = false; boardError = msg
        case .session(let sid): detailErrors[sid] = msg
        case .send(let sid, let id): setLocal(sid, id) { $0.state = "failed"; $0.why = msg }
        case .outbox(let sid), .open(let sid): openMessage[sid] = msg
        case .doc(let name): docLoading.remove(name); docErrors[name] = msg
        case .docState(let name): docErrors[name] = "这次改动没存上：\(msg)"
        case .occupancy: occupancyError = msg
        case .task: taskError = msg
        }
    }

    private func setLocal(_ sid: String, _ id: String, _ edit: (inout PMOutItem) -> Void) {
        guard let i = localOut[sid]?.firstIndex(where: { $0.id == id }) else { return }
        edit(&localOut[sid]![i])
    }

    // MARK: 收

    func handle(type: String, data: Data) {
        guard type == "pm_req_result" else { return }
        let dec = JSONDecoder()
        guard let env = try? dec.decode(PMEnvelope.self, from: data), let rid = env.req_id, let kind = pending.removeValue(forKey: rid) else { return }
        if let e = env.errorText { fail(kind, e); return }
        do {
            switch kind {
            case .home:
                home = try dec.decode(PMHome.self, from: data)
                homeError = nil
            case .board:
                boardLoading = false
                board = try dec.decode(PMBoard.self, from: data)
                boardError = nil
            case .session(let sid):
                let d = try dec.decode(PMDetail.self, from: data)
                details[sid] = d
                detailErrors[sid] = nil
                let claimed = Set(d.outbox.map(\.id))
                localOut[sid]?.removeAll { claimed.contains($0.id) }
            case .send(let sid, let id):
                setLocal(sid, id) { $0.state = env.state ?? "queued"; $0.why = "" }
                requestSession(sid)
            case .outbox(let sid):
                openMessage[sid] = nil
                requestSession(sid)
            case .open(let sid):
                openMessage[sid] = env.message ?? (env.ok == true ? "好了" : "没打开")
            case .doc(let name):
                docLoading.remove(name)
                docs[name] = try dec.decode(PMDoc.self, from: data)
                docErrors[name] = nil
            case .docState(let name):
                docErrors[name] = nil
            case .occupancy:
                occupancy = try dec.decode(PMOccupancy.self, from: data)
                occupancyError = nil
            case .task:
                task = try dec.decode(PMTaskBoard.self, from: data)
                taskError = nil
            }
        } catch {
            fail(kind, "看板版本对不上（\(Self.brief(error))）")
        }
    }

    private static func brief(_ e: Error) -> String {
        if case DecodingError.keyNotFound(let k, _) = e { return "缺 \(k.stringValue)" }
        if case DecodingError.typeMismatch(_, let c) = e { return "类型不对 \(c.codingPath.map(\.stringValue).joined(separator: "."))" }
        return "解析失败"
    }
}
#endif
#endif
