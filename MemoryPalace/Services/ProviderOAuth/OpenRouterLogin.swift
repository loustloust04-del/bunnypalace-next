import Foundation
import AuthenticationServices
import Observation
#if os(macOS)
import AppKit
import Network
#else
import UIKit
#endif

// MARK: - OpenRouter 一键登录（plan-provider-presets §5.5）
//
// PKCE S256 → openrouter.ai/auth → 回调拿 code → POST /api/v1/auth/keys 换一把用户自己的 key。
// 参数照官方文档（openrouter.ai/docs/use-cases/oauth-pkce，2026-10-15 核对）：
//   callback_url / code_challenge / code_challenge_method=S256 / key_label / state（回调原样带回，拒绝授权和无回调模式不带）；
//   不带 callback_url = 无回调模式，网页直接显示授权码（一次性，10 分钟过期），code_challenge 必填。
//   换 key：JSON {code, code_verifier, code_challenge_method} → {key}
//
// 回调三条路（Q7：官方只写了 localhost 任意端口和公开 https，没说自定义 scheme 行不行）：
//   localhost：   mac 默认，系统浏览器 + 本机随机端口监听
//   manualCode：  iOS 默认，不带回调，用户把网页上的授权码粘回来（mac 也能用）
//   customScheme：实验选项，两端都走 ASWebAuthenticationSession，回 memorygarden-oauth://openrouter（官方没写支持）
// 切换：defaults 键 `openRouterLoginCallbackMode`（customScheme / localhost / manualCode），iOS 上 localhost 按 manualCode 走。

enum OpenRouterLogin {

    enum CallbackMode: String {
        case customScheme, localhost, manualCode
    }

    static let callbackModeKey = "openRouterLoginCallbackMode"

    static var callbackMode: CallbackMode {
        resolveMode(UserDefaults.standard.string(forKey: callbackModeKey).flatMap(CallbackMode.init))
    }

    /// 没设 = 官方明写支持的那条：mac 本机监听，iOS 粘授权码
    static func resolveMode(_ stored: CallbackMode?) -> CallbackMode {
        #if os(macOS)
        return stored ?? .localhost
        #else
        let mode = stored ?? .manualCode
        return mode == .localhost ? .manualCode : mode
        #endif
    }

    static let scheme = "memorygarden-oauth"
    static let customSchemeCallback = URL(string: "\(scheme)://openrouter")!
    static let authURL = URL(string: "https://openrouter.ai/auth")!
    static let keysEndpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    static let keyLabel = "记忆花园"
    static let localhostTimeoutSeconds = 300
    static let maxRequestLineBytes = 8192

    static func localhostCallback(port: UInt16) -> URL { URL(string: "http://localhost:\(port)/callback")! }

    enum LoginError: LocalizedError, Equatable {
        case cancelled
        case denied(String)
        case missingCode
        case stateMismatch
        case unexpectedCallback
        case missingKey
        case http(Int, String)
        case listenerFailed(String)
        case browserOpenFailed
        case timeout

        var errorDescription: String? {
            switch self {
            case .cancelled: return "登录已取消"
            case .denied(let why): return "OpenRouter 没给授权：\(why)"
            case .missingCode: return "没拿到授权码，可能在网页上点了拒绝，再试一次？"
            case .stateMismatch: return "回来的结果对不上这次登录（state 不一致），再试一次。"
            case .unexpectedCallback: return "登录回来的地址不对，再试一次。"
            case .missingKey: return "OpenRouter 回了，但里面没有 key。"
            case .http(let code, let body): return "换 key 失败（HTTP \(code)）：\(body)"
            case .listenerFailed(let s): return "本机回调监听没起来：\(s)"
            case .browserOpenFailed: return "打不开登录页"
            case .timeout: return "等了 \(OpenRouterLogin.localhostTimeoutSeconds / 60) 分钟没等到登录结果，再试一次。"
            }
        }
    }

    /// 一次登录用的一组凭证；无回调模式不带 state（官方：不回传）
    struct Attempt: Equatable {
        let verifier: String
        let state: String?
        let url: URL
    }

    static func makeAttempt(callback: URL?) -> Attempt {
        let verifier = ChatGPTOAuthPKCE.newCodeVerifier()
        let state = callback == nil ? nil : ChatGPTOAuthPKCE.newState()
        let url = authorizationURL(callback: callback, challenge: ChatGPTOAuthPKCE.codeChallenge(verifier: verifier), state: state)
        return Attempt(verifier: verifier, state: state, url: url)
    }

    static func authorizationURL(callback: URL?, challenge: String, state: String?) -> URL {
        var c = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let callback { items.append(URLQueryItem(name: "callback_url", value: callback.absoluteString)) }
        items += [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: keyLabel),
        ]
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        c.queryItems = items
        return c.url!
    }

    /// 回调地址 → code。地址（scheme / host / 端口 / path）必须正好是这次登记的回调；参数规则见 code(fromQuery:)
    static func code(fromCallback url: URL, expected: URL, expectedState: String?) throws -> String {
        guard isExpectedCallback(url, expected) else { throw LoginError.unexpectedCallback }
        return try code(fromQuery: queryItems(url), expectedState: expectedState)
    }

    static func isExpectedCallback(_ url: URL, _ expected: URL) -> Bool {
        guard let got = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let want = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { return false }
        return got.scheme?.lowercased() == want.scheme?.lowercased()
            && got.host?.lowercased() == want.host?.lowercased()
            && got.port == want.port
            && got.percentEncodedPath == want.percentEncodedPath
    }

    /// state：完全没带靠 PKCE 兜（官方拒绝授权时不带）；带了就必须只有一个且等于这次的，空 / 重复 / 不同都拒。
    /// 先查 state 再看 error，对不上的「拒绝」也不认。code 必须恰好一个且非空
    static func code(fromQuery items: [URLQueryItem], expectedState: String?) throws -> String {
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.map { $0.value ?? "" } }
        if let expectedState {
            let states = values("state")
            if !states.isEmpty, states != [expectedState] { throw LoginError.stateMismatch }
        }
        if let error = values("error").first(where: { !$0.isEmpty }) {
            throw LoginError.denied(values("error_description").first(where: { !$0.isEmpty }) ?? error)
        }
        let codes = values("code")
        guard codes.count == 1, let code = codes.first, !code.isEmpty else { throw LoginError.missingCode }
        return code
    }

    private static func queryItems(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    /// ASWebAuthenticationSession 的完成回调 → 结果；用户关掉登录页 = cancelled（界面上静默）
    static func sessionOutcome(_ url: URL?, _ error: Error?) -> Result<URL, Error> {
        if let url { return .success(url) }
        if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
            return .failure(LoginError.cancelled)
        }
        return .failure(error ?? LoginError.missingCode)
    }

    /// 无回调模式粘回来的东西：一般是授权码本身；粘了整段带 code= 的地址也认
    static func code(fromPasted text: String) throws -> String {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw LoginError.missingCode }
        if raw.contains("code="), let url = URL(string: raw), url.query != nil {
            return try code(fromQuery: queryItems(url), expectedState: nil)
        }
        return raw
    }

    static func exchangeRequest(code: String, verifier: String) -> URLRequest {
        var req = URLRequest(url: keysEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ], options: [.sortedKeys])
        return req
    }

    static func exchange(code: String, verifier: String, session: URLSession = .shared) async throws -> String {
        let (data, resp) = try await session.data(for: exchangeRequest(code: code, verifier: verifier))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LoginError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["key"] as? String, !key.isEmpty else {
            throw LoginError.missingKey
        }
        return key
    }

    // MARK: 本机回调的请求解析（纯函数，单测覆盖；监听器只管收字节和回包）

    enum RequestLineScan: Equatable {
        case incomplete, tooLong
        case line(String)
    }

    /// 收到的字节里有没有完整请求行（到第一个 \r\n）；超过上限还没收完就不再等
    static func scanRequestLine(_ buffer: Data) -> RequestLineScan {
        if let end = buffer.range(of: Data("\r\n".utf8)) {
            let line = buffer[buffer.startIndex..<end.lowerBound]
            guard line.count <= maxRequestLineBytes else { return .tooLong }
            return .line(String(decoding: line, as: UTF8.self))
        }
        return buffer.count > maxRequestLineBytes ? .tooLong : .incomplete
    }

    enum LocalRequest: Equatable {
        case code(String)
        case failed(LoginError)
        /// 无关 / 畸形 / 对不上这次登录：只回 404 关这条连接，登录继续等
        case ignore
    }

    /// 请求行 → 这次登录的结果。只认 `GET <登记的回调 path>?… HTTP/x`；拒绝授权也算结果（state 对得上才认）
    static func localRequest(_ line: String, expected: URL, expectedState: String?) -> LocalRequest {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"), parts[2].hasPrefix("HTTP/"),
              let url = URL(string: String(parts[1]), relativeTo: expected)?.absoluteURL else { return .ignore }
        do {
            return .code(try code(fromCallback: url, expected: expected, expectedState: expectedState))
        } catch LoginError.denied(let why) {
            return .failed(.denied(why))
        } catch {
            return .ignore
        }
    }
}

// MARK: - 跑一次登录（每次点按钮建一个，async 期间由调用方的 Task 持有；Task 取消 = 收掉登录页 / 关掉监听）

@MainActor
final class OpenRouterLoginFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var authSession: ASWebAuthenticationSession?

    /// 自定义 scheme（实验）：ASWebAuthenticationSession 打开，回调直接交回来（不用在 Info.plist 注册 scheme）
    func runCustomScheme() async throws -> String {
        if Task.isCancelled { throw OpenRouterLogin.LoginError.cancelled }
        let callback = OpenRouterLogin.customSchemeCallback
        let attempt = OpenRouterLogin.makeAttempt(callback: callback)
        let once = ResumeOnce<URL>()
        let callbackURL: URL
        do {
            callbackURL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    guard once.install(cont) else { return }
                    let session = ASWebAuthenticationSession(url: attempt.url, callback: .customScheme(OpenRouterLogin.scheme)) { url, error in
                        once.finish(OpenRouterLogin.sessionOutcome(url, error))
                    }
                    session.presentationContextProvider = self
                    authSession = session
                    if !session.start() { once.finish(.failure(OpenRouterLogin.LoginError.browserOpenFailed)) }
                }
            } onCancel: {
                once.finish(.failure(OpenRouterLogin.LoginError.cancelled))
            }
        } catch {
            // 取消 / 失败：登录页还开着就收掉
            authSession?.cancel()
            authSession = nil
            throw error
        }
        authSession = nil
        let code = try OpenRouterLogin.code(fromCallback: callbackURL, expected: callback, expectedState: attempt.state)
        return try await OpenRouterLogin.exchange(code: code, verifier: attempt.verifier)
    }

    #if os(macOS)
    /// localhost：本机随机端口监听 + 系统浏览器
    func runLocalhost() async throws -> String {
        let server = try OpenRouterLocalCallback()
        let port = try await server.start()
        let callback = OpenRouterLogin.localhostCallback(port: port)
        let attempt = OpenRouterLogin.makeAttempt(callback: callback)
        server.expect(callback: callback, state: attempt.state)
        if Task.isCancelled {
            server.stop()
            throw OpenRouterLogin.LoginError.cancelled
        }
        guard NSWorkspace.shared.open(attempt.url) else {
            server.stop()
            throw OpenRouterLogin.LoginError.browserOpenFailed
        }
        let code = try await server.waitForCode(timeoutSeconds: OpenRouterLogin.localhostTimeoutSeconds)
        return try await OpenRouterLogin.exchange(code: code, verifier: attempt.verifier)
    }
    #endif

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            // 点按钮时一定有前台场景；万一没有窗口，就给第一个场景新建一个
            return windows.first { $0.isKeyWindow } ?? windows.first ?? UIWindow(windowScene: scenes[0])
            #endif
        }
    }
}

/// continuation 只 resume 一次：完成回调、start() 失败、Task 取消三路抢，先到的算；
/// 取消早于装上 continuation 时先存着，装上时立刻交出去
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false

    /// 返回 false = 已经有结果（已交给 continuation），别再起登录页
    func install(_ c: CheckedContinuation<T, Error>) -> Bool {
        let early: Result<T, Error>? = lock.withLock {
            if let p = pending { pending = nil; return p }
            cont = c
            return nil
        }
        if let early { c.resume(with: early); return false }
        return true
    }

    func finish(_ r: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            if done { return nil }
            done = true
            if let c = cont { cont = nil; return c }
            pending = r
            return nil
        }
        c?.resume(with: r)
    }
}

#if os(macOS)
/// 本机回调监听：只开在回环网卡，端口让系统挑（照 ChatGPTOAuthLoginCoordinator.waitForCallback）。
/// 每条连接攒到完整请求行再判；只有对得上这次登录的 GET /callback 才算结果，别的只关那条连接
final class OpenRouterLocalCallback: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var readyCont: CheckedContinuation<UInt16, Error>?
    private var callbackCont: CheckedContinuation<String, Error>?
    private var early: Result<String, Error>?
    private var delivered = false
    private var expected: (url: URL, state: String?)?

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        do {
            listener = try NWListener(using: params, on: .any)
        } catch {
            throw OpenRouterLogin.LoginError.listenerFailed(error.localizedDescription)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { readyCont = cont }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    resumeReady(.success(listener.port?.rawValue ?? 0))
                case .failed(let e):
                    let err = OpenRouterLogin.LoginError.listenerFailed(e.localizedDescription)
                    resumeReady(.failure(err))
                    deliver(.failure(err))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] conn in handle(conn) }
            listener.start(queue: .global())
        }
    }

    /// 登记这次登录的回调地址和 state；登记前来的请求一律当无关请求
    func expect(callback: URL, state: String?) {
        lock.withLock { expected = (callback, state) }
    }

    func waitForCode(timeoutSeconds: Int) async throws -> String {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) { [weak self] in
            self?.deliver(.failure(OpenRouterLogin.LoginError.timeout))
        }
        defer { stop() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let pending: Result<String, Error>? = lock.withLock {
                    if let e = early { early = nil; return e }
                    callbackCont = cont
                    return nil
                }
                if let pending { cont.resume(with: pending) }
            }
        } onCancel: {
            stop()
            deliver(.failure(OpenRouterLogin.LoginError.cancelled))
        }
    }

    func stop() { listener.cancel() }

    private func resumeReady(_ r: Result<UInt16, Error>) {
        let cont: CheckedContinuation<UInt16, Error>? = lock.withLock {
            defer { readyCont = nil }
            return readyCont
        }
        cont?.resume(with: r)
    }

    private func deliver(_ r: Result<String, Error>) {
        let cont: CheckedContinuation<String, Error>? = lock.withLock {
            if delivered { return nil }
            delivered = true
            if let c = callbackCont { callbackCont = nil; return c }
            early = r
            return nil
        }
        cont?.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        receive(conn, buffer: Data())
    }

    /// TCP 不保证一次 receive 就是整个请求：攒到请求行收完；EOF / 出错 / 超长只关这条连接
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch OpenRouterLogin.scanRequestLine(buffer) {
            case .line(let line):
                respond(conn, line)
            case .tooLong:
                conn.cancel()
            case .incomplete:
                if isComplete || error != nil { conn.cancel() } else { receive(conn, buffer: buffer) }
            }
        }
    }

    private func respond(_ conn: NWConnection, _ line: String) {
        let outcome = lock.withLock { expected }.map {
            OpenRouterLogin.localRequest(line, expected: $0.url, expectedState: $0.state)
        } ?? .ignore
        let isResult = outcome != .ignore
        let body = isResult ? "<meta charset=\"utf-8\"><p>登录结果已经交回记忆花园，可以关掉这一页了。</p>" : "not found"
        let head = isResult ? "HTTP/1.1 200 OK" : "HTTP/1.1 404 Not Found"
        let resp = "\(head)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
        switch outcome {
        case .code(let code): deliver(.success(code))
        case .failed(let e): deliver(.failure(e))
        case .ignore: break
        }
    }
}
#endif

// MARK: - 登录归属（编辑页持有一个）

/// 一次登录归谁：发起时记下 attempt 和当时的提供商（CredentialDraft.providerKey）。
/// 换家 / 取消 / 关页就作废并取消任务；回来的结果先核对「还是这一轮、没取消、页面上还是这家」，对不上一律丢掉（不写 key、不动新一轮的状态）
@MainActor @Observable
final class OpenRouterLoginRunner {
    /// 自动流程（本机监听 / 自定义 scheme）在等
    private(set) var isWaiting = false
    /// 粘授权码模式：这一轮的 attempt（界面显示粘贴步骤）
    private(set) var manualAttempt: OpenRouterLogin.Attempt?
    /// 粘授权码模式：正在换 key
    private(set) var isExchanging = false
    private(set) var errorText: String?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var owner: (id: UUID, providerKey: String)?

    /// 本机监听 / 自定义 scheme：work 跑完整个登录，返回 key
    func start(providerKey: String,
               context: @escaping @MainActor () -> String,
               work: @escaping @MainActor () async throws -> String,
               apply: @escaping @MainActor (String) -> Void) {
        let id = claim(providerKey)
        isWaiting = true
        run(id, context: context, work: work, apply: apply)
    }

    /// 粘授权码：新开一轮（旧的一并作废），返回要打开的登录页
    @discardableResult
    func beginManual(providerKey: String) -> OpenRouterLogin.Attempt {
        claim(providerKey)
        let attempt = OpenRouterLogin.makeAttempt(callback: nil)
        manualAttempt = attempt
        return attempt
    }

    /// 粘授权码：「完成登录」。换 key 的任务归这一轮，取消 / 换家时一起作废
    func finishManual(pasted: String,
                      context: @escaping @MainActor () -> String,
                      exchange: @escaping @MainActor (_ code: String, _ verifier: String) async throws -> String,
                      apply: @escaping @MainActor (String) -> Void) {
        guard let attempt = manualAttempt, let owner, !isExchanging else { return }
        errorText = nil
        isExchanging = true
        run(owner.id, context: context, work: {
            try await exchange(OpenRouterLogin.code(fromPasted: pasted), attempt.verifier)
        }, apply: apply)
    }

    /// 用户点取消 / 关页 / 换家：取消任务，这一轮作废
    func cancel() {
        task?.cancel()
        task = nil
        owner = nil
        isWaiting = false
        isExchanging = false
        manualAttempt = nil
    }

    /// 页面上的提供商变了：不是发起时那家就作废
    func providerChanged(to key: String) {
        if let owner, owner.providerKey != key { cancel() }
    }

    @discardableResult
    private func claim(_ providerKey: String) -> UUID {
        cancel()
        errorText = nil
        let id = UUID()
        owner = (id, providerKey)
        return id
    }

    private func run(_ id: UUID,
                     context: @escaping @MainActor () -> String,
                     work: @escaping @MainActor () async throws -> String,
                     apply: @escaping @MainActor (String) -> Void) {
        task = Task { @MainActor [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            // 已经不是这一轮（取消后又开了新的）：一个字段都不碰
            guard let self, let owner = self.owner, owner.id == id else { return }
            guard !Task.isCancelled, owner.providerKey == context() else { return self.cancel() }
            self.task = nil
            self.isWaiting = false
            self.isExchanging = false
            switch result {
            case .success(let key):
                apply(key)
                self.owner = nil
                self.manualAttempt = nil
            case .failure(let error as OpenRouterLogin.LoginError) where error == .cancelled:
                // 取消登录不算失败，静默
                if self.manualAttempt == nil { self.owner = nil }
            case .failure(let error):
                self.errorText = error.localizedDescription
                // 粘授权码模式留着这一轮，改了再点「完成登录」
                if self.manualAttempt == nil { self.owner = nil }
            }
        }
    }
}
