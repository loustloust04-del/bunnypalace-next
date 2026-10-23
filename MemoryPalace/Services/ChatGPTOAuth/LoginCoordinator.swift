import Foundation
import Network
#if os(macOS)
import AppKit
#endif

// MARK: - ChatGPT OAuth 登录 flow（macOS 系统浏览器 + 本地 NWListener / iOS WKWebView）
//
// 平台差异：
// - macOS：NWListener 监 :1455 → NSWorkspace 开系统浏览器 → 收回调拿 code
// - iOS：上层视图弹 ChatGPTOAuthWebView (WKWebView)，拦 navigation 拿 code
//   （iOS 不调用本类的 startMacFlow，只用 buildAuthorizationURL + exchangeCode）
//
// 入口：startMacOSLogin() async throws -> OAuthTokenSet
// iOS：先 buildAuthorizationURL() 拿 url + verifier + state，扔给 WebView；
//      WebView 拦到 code 后调 exchangeFromCallbackURL(_:) 完成换 token。

@MainActor
final class ChatGPTOAuthLoginCoordinator {

    enum LoginError: Error, LocalizedError {
        case stateMismatch
        case missingCode
        case timeout
        case cancelled
        case listenerFailed(String)
        case browserOpenFailed
        case exchange(Error)

        var errorDescription: String? {
            switch self {
            case .stateMismatch: return "OAuth 回调 state 不匹配（可能被劫持）"
            case .missingCode: return "OAuth 回调缺 code"
            case .timeout: return "登录等待超时（\(ChatGPTOAuthConfig.loginTimeoutSeconds)s）"
            case .cancelled: return "登录已取消"
            case .listenerFailed(let s): return "本地监听失败：\(s)"
            case .browserOpenFailed: return "无法打开系统浏览器"
            case .exchange(let e): return "换 token 失败：\(e.localizedDescription)"
            }
        }
    }

    /// 这次登录用的 verifier / state（一次一组；持久化到 UserDefaults 5 分钟 TTL，
    /// 解决 iOS app 切后台被回收后 verifier 丢失换不了 token 的问题）
    private var verifier: String {
        get { Self.loadPending()?.verifier ?? "" }
        set { /* 通过 buildAuthorizationURL 写入 pending；setter 不单独用 */ }
    }
    private var state: String {
        get { Self.loadPending()?.state ?? "" }
    }

    /// 构造 OAuth 授权 URL —— 每次调用都生新一组 PKCE 凭证 + 覆写 pending。
    /// 这保证「用户主动点登录」永远是干净的新一轮，不会撞上之前残留的旧 state。
    /// 想"恢复未完成的登录"走 `loadPendingURLIfFresh()` 不调本函数。
    func buildAuthorizationURL() -> URL? {
        let v = ChatGPTOAuthPKCE.newCodeVerifier()
        let s = ChatGPTOAuthPKCE.newState()
        let challenge = ChatGPTOAuthPKCE.codeChallenge(verifier: v)

        var components = URLComponents(string: ChatGPTOAuthConfig.authURL)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: ChatGPTOAuthConfig.clientId),
            URLQueryItem(name: "redirect_uri", value: ChatGPTOAuthConfig.redirectURI),
            URLQueryItem(name: "scope", value: ChatGPTOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: s),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        ]
        guard let url = components?.url else { return nil }
        // 持久化
        Self.savePending(.init(
            verifier: v,
            state: s,
            authURL: url.absoluteString,
            expiresAt: Date().timeIntervalSince1970 + ChatGPTOAuthConfig.pendingPersistSeconds
        ))
        return url
    }

    /// iOS 通用：拿到 callback URL 后调这个完成换 token
    /// 从 UserDefaults pending 读 verifier（即使本 coordinator 实例已被 GC）
    func exchangeFromCallbackURL(_ url: URL) async throws -> OAuthTokenSet {
        guard let pending = Self.loadPending() else {
            throw LoginError.cancelled  // pending 已过期或被清
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LoginError.missingCode
        }
        let q = comps.queryItems ?? []
        let callbackState = q.first(where: { $0.name == "state" })?.value ?? ""
        let code = q.first(where: { $0.name == "code" })?.value ?? ""
        guard callbackState == pending.state else { throw LoginError.stateMismatch }
        guard !code.isEmpty else { throw LoginError.missingCode }
        do {
            let token = try await ChatGPTOAuthExchange.exchangeCode(code, codeVerifier: pending.verifier)
            Self.clearPending()  // 成功 → 清
            return token
        } catch {
            throw LoginError.exchange(error)
        }
    }

    /// 上层（APICredentialEditor）启动时检测，看是否有未过期的 pending → 可自动恢复 sheet
    static func loadPendingURLIfFresh() -> URL? {
        guard let p = loadPending() else { return nil }
        return URL(string: p.authURL)
    }

    /// 用户手动取消 / 完成 / 重新开始 → 清掉
    static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    // MARK: - Pending 持久化（UserDefaults）

    private struct Pending: Codable {
        let verifier: String
        let state: String
        let authURL: String
        let expiresAt: TimeInterval
    }

    private static let pendingKey = "chatgptOAuthPendingV1"

    private static func loadPending() -> Pending? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let p = try? JSONDecoder().decode(Pending.self, from: data) else { return nil }
        if Date().timeIntervalSince1970 >= p.expiresAt {
            // 过期 → 静默清掉
            UserDefaults.standard.removeObject(forKey: pendingKey)
            return nil
        }
        return p
    }

    private static func savePending(_ p: Pending) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    /// macOS 主路径：起本地监听 + 开系统浏览器 + 等回调 → 换 token
    #if os(macOS)
    func startMacOSLogin() async throws -> OAuthTokenSet {
        guard let url = buildAuthorizationURL() else {
            throw LoginError.browserOpenFailed
        }
        // 开本地 listener（异步等回调）+ 同时开浏览器
        async let waitCode = waitForCallback()
        let opened = NSWorkspace.shared.open(url)
        if !opened {
            throw LoginError.browserOpenFailed
        }
        let code = try await waitCode
        do {
            return try await ChatGPTOAuthExchange.exchangeCode(code, codeVerifier: verifier)
        } catch {
            throw LoginError.exchange(error)
        }
    }

    /// macOS：NWListener 监 :1455，等收到一个 GET /auth/callback?code=&state=
    private func waitForCallback() async throws -> String {
        // 把 actor-isolated state 提前拷一份，闭包用 sendable 字符串
        let expectedState = self.state
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let port = NWEndpoint.Port(rawValue: UInt16(ChatGPTOAuthConfig.redirectPort))!
            let listener: NWListener
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                listener = try NWListener(using: params, on: port)
            } catch {
                cont.resume(throwing: LoginError.listenerFailed(error.localizedDescription))
                return
            }

            // 一次性 continuation：第一个 resume 之后忽略后续
            let box = OnceBox<Result<String, Error>>()
            let finish: @Sendable (Result<String, Error>) -> Void = { result in
                if box.set(result) {
                    listener.cancel()
                    switch result {
                    case .success(let s): cont.resume(returning: s)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }

            // 超时
            let timeoutSec = ChatGPTOAuthConfig.loginTimeoutSeconds
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSec)) {
                finish(.failure(LoginError.timeout))
            }

            listener.newConnectionHandler = { conn in
                Self.handleConnection(conn, expectedState: expectedState, finish: finish)
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(err) = state {
                    finish(.failure(LoginError.listenerFailed(err.localizedDescription)))
                }
            }
            listener.start(queue: .global())
        }
    }

    /// 单连接处理：读 HTTP request line → 解 query → 回响应 + 拿 code
    nonisolated private static func handleConnection(
        _ conn: NWConnection,
        expectedState: String,
        finish: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            defer { conn.cancel() }
            guard let data, let req = String(data: data, encoding: .utf8) else { return }
            // 第一行形如 "GET /auth/callback?code=...&state=... HTTP/1.1"
            let firstLine = req.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else { return }
            let path = String(parts[1])

            // 构造一个伪 URL 给 URLComponents 解析
            guard let comps = URLComponents(string: "http://localhost\(path)") else { return }
            let items = comps.queryItems ?? []
            let callbackState = items.first(where: { $0.name == "state" })?.value ?? ""
            let code = items.first(where: { $0.name == "code" })?.value ?? ""

            // 回 HTTP 200（用户看到「Login captured」）
            let body = "Login captured. You can close this tab."
            let resp = """
            HTTP/1.1 200 OK\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in })

            if callbackState != expectedState {
                finish(.failure(LoginError.stateMismatch))
            } else if code.isEmpty {
                finish(.failure(LoginError.missingCode))
            } else {
                finish(.success(code))
            }
        }
    }
    #endif
}

/// 一次性 result box：第一个 set 调用胜出，后续被忽略，避免重复 resume continuation。
private final class OnceBox<T> {
    private let lock = NSLock()
    private var value: T?

    @discardableResult
    func set(_ v: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value != nil { return false }
        value = v
        return true
    }
}
