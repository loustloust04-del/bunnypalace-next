import Foundation

/// 网页卡能请 app 做的事（research-chat-cards §13）。卡片里是 `mp.todo.add` / `mp.vocab.add` / `mp.ask` / `mp.report`
enum HTMLCardAction: Equatable {
    case addTodo(text: String, date: String?)
    case addVocab(word: String)
    /// 放进输入框，粟粟自己点发送（13.2.1）
    case ask(String)
    /// 记一条事件，下次发消息时捎带给模型
    case report(String)

    /// 写进粟粟自己数据的要原生弹窗确认；ask / report 发不发、带不带都还在她手里，只限量
    var needsConfirm: Bool {
        switch self {
        case .addTodo, .addVocab: return true
        case .ask, .report: return false
        }
    }
}

/// 回给卡片的错误码（JS 侧 reject 的 Error.message 就是 rawValue）
enum HTMLCardBridgeError: String, Error, Equatable {
    case invalid, unknownAction, tooLong, busy, denied, closed, notRunning, limit
}

struct HTMLCardRequest: Equatable {
    let id: String
    let token: String
    let action: HTMLCardAction

    /// 长度上限（按字符数）：超了直接拒，不替卡片截断
    static let maxTodo = 200
    static let maxWord = 64
    static let maxAsk = 500
    static let maxReport = 200
    static let maxId = 64

    /// 壳转过来的 body：{id, token, action, text, date?}
    static func parse(_ body: [String: Any]) -> Result<HTMLCardRequest, HTMLCardBridgeError> {
        guard let id = body["id"] as? String, !id.isEmpty, id.count <= maxId,
              let token = body["token"] as? String, let action = body["action"] as? String else { return .failure(.invalid) }
        let limit: Int
        switch action {
        case "todo.add": limit = maxTodo
        case "vocab.add": limit = maxWord
        case "ask": limit = maxAsk
        case "report": limit = maxReport
        default: return .failure(.unknownAction)
        }
        guard let raw = body["text"] as? String else { return .failure(.invalid) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.invalid) }
        guard text.count <= limit else { return .failure(.tooLong) }
        let parsed: HTMLCardAction
        switch action {
        case "todo.add":
            let date = body["date"] as? String
            if let date, !TodoManager.isValidDayKey(date) { return .failure(.invalid) }
            parsed = .addTodo(text: text, date: date)
        case "vocab.add": parsed = .addVocab(word: text)
        case "ask": parsed = .ask(text)
        default: parsed = .report(text)
        }
        return .success(HTMLCardRequest(id: id, token: token, action: parsed))
    }

}

/// 一次「运行」里的判定（纯逻辑，界面在 HTMLCardView）：每次点运行换新令牌、新会话
@MainActor
final class HTMLCardBridgeSession {
    enum Step: Equatable {
        /// 直接回卡片：error == nil 为成功
        case reply(id: String, error: HTMLCardBridgeError?)
        /// 先弹窗问粟粟，答完调 resolve
        case confirm(HTMLCardRequest)
        /// 去做，做完回 reply(id, nil)
        case perform(HTMLCardRequest)
    }

    static let maxDenials = 3
    static let maxAsks = 5
    static let maxReports = 20

    let token: String
    private(set) var pending: HTMLCardRequest?
    private var denials = 0
    private var asks = 0
    private var reports = 0

    var isClosed: Bool { denials >= Self.maxDenials }

    init(token: String) {
        self.token = token
    }

    func receive(_ body: [String: Any], running: Bool) -> Step {
        let id = (body["id"] as? String).map { String($0.prefix(HTMLCardRequest.maxId)) } ?? ""
        let request: HTMLCardRequest
        switch HTMLCardRequest.parse(body) {
        case .failure(let e): return .reply(id: id, error: e)
        case .success(let r): request = r
        }
        guard running, request.token == token else { return .reply(id: id, error: .notRunning) }
        guard !isClosed else { return .reply(id: id, error: .closed) }
        guard pending == nil else { return .reply(id: id, error: .busy) }
        switch request.action {
        case .ask:
            guard asks < Self.maxAsks else { return .reply(id: id, error: .limit) }
            asks += 1
        case .report:
            guard reports < Self.maxReports else { return .reply(id: id, error: .limit) }
            reports += 1
        case .addTodo, .addVocab:
            pending = request
            return .confirm(request)
        }
        return .perform(request)
    }

    /// 弹窗答了：允许 → 去做；拒 → 回 denied 并计数（满 3 次关桥）
    func resolve(allowed: Bool) -> Step? {
        guard let request = pending else { return nil }
        pending = nil
        if allowed { return .perform(request) }
        denials += 1
        return .reply(id: request.id, error: .denied)
    }

    /// 卡收起 / 离屏：挂着的请求回 closed，弹窗晚点回来也不执行
    func cancelPending() -> Step? {
        guard let request = pending else { return nil }
        pending = nil
        return .reply(id: request.id, error: .closed)
    }
}
