import XCTest
import AuthenticationServices
@testable import 记忆花园

/// OpenRouter 一键登录：拼 URL、回调解析、换 key（plan-provider-presets §5.5 / §7）。不发真网络请求
final class OpenRouterLoginTests: XCTestCase {

    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var response: (Int, String) = (200, "{}")
        nonisolated(unsafe) static var seen: [(URLRequest, Data)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Stub.seen.append((request, Self.body(of: request)))
            let (code, body) = Stub.response
            let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        /// URLProtocol 里 httpBody 会被转成 stream
        private static func body(of request: URLRequest) -> Data {
            if let b = request.httpBody { return b }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        Stub.seen = []
        Stub.response = (200, "{}")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        session = URLSession(configuration: cfg)
    }

    private func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    // MARK: 授权 URL

    func testAuthorizationURLWithCallback() {
        let a = OpenRouterLogin.makeAttempt(callback: OpenRouterLogin.customSchemeCallback)
        XCTAssertEqual(a.url.scheme, "https")
        XCTAssertEqual(a.url.host, "openrouter.ai")
        XCTAssertEqual(a.url.path, "/auth")
        let q = query(a.url)
        XCTAssertEqual(q["callback_url"], "memorygarden-oauth://openrouter")
        XCTAssertEqual(q["code_challenge"], ChatGPTOAuthPKCE.codeChallenge(verifier: a.verifier))
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["key_label"], "记忆花园")
        XCTAssertNotNil(a.state)
        XCTAssertEqual(q["state"], a.state)
    }

    func testAuthorizationURLHeadlessHasNoCallbackOrState() {
        let a = OpenRouterLogin.makeAttempt(callback: nil)
        let q = query(a.url)
        XCTAssertNil(q["callback_url"])
        XCTAssertNil(q["state"])
        XCTAssertNil(a.state)
        XCTAssertEqual(q["code_challenge"], ChatGPTOAuthPKCE.codeChallenge(verifier: a.verifier), "无回调模式 code_challenge 必填")
        XCTAssertEqual(q["code_challenge_method"], "S256")
    }

    func testLocalhostCallbackEncoded() {
        let url = OpenRouterLogin.authorizationURL(callback: URL(string: "http://localhost:51423/callback")!, challenge: "c", state: "s")
        XCTAssertEqual(query(url)["callback_url"], "http://localhost:51423/callback")
        XCTAssertTrue(url.absoluteString.contains("callback_url=http://localhost:51423/callback")
                      || url.absoluteString.contains("callback_url=http%3A%2F%2Flocalhost%3A51423%2Fcallback"))
    }

    func testEachAttemptFresh() {
        let a = OpenRouterLogin.makeAttempt(callback: nil)
        let b = OpenRouterLogin.makeAttempt(callback: nil)
        XCTAssertNotEqual(a.verifier, b.verifier)
    }

    // MARK: 默认回调方式（官方明写支持的：mac 本机监听，iOS 粘授权码；自定义 scheme 只是实验选项）

    func testDefaultCallbackMode() {
        #if os(macOS)
        XCTAssertEqual(OpenRouterLogin.resolveMode(nil), .localhost)
        XCTAssertEqual(OpenRouterLogin.resolveMode(.localhost), .localhost)
        #else
        XCTAssertEqual(OpenRouterLogin.resolveMode(nil), .manualCode)
        XCTAssertEqual(OpenRouterLogin.resolveMode(.localhost), .manualCode, "iOS 没有本机监听")
        #endif
        XCTAssertEqual(OpenRouterLogin.resolveMode(.customScheme), .customScheme)
        XCTAssertEqual(OpenRouterLogin.resolveMode(.manualCode), .manualCode)
    }

    // MARK: 回调解析

    private let scheme = OpenRouterLogin.customSchemeCallback
    private let local = OpenRouterLogin.localhostCallback(port: 51423)

    func testCallbackCode() throws {
        let url = URL(string: "memorygarden-oauth://openrouter?code=abc123&state=s1")!
        XCTAssertEqual(try OpenRouterLogin.code(fromCallback: url, expected: scheme, expectedState: "s1"), "abc123")
        let lh = URL(string: "http://localhost:51423/callback?code=abc123&state=s1")!
        XCTAssertEqual(try OpenRouterLogin.code(fromCallback: lh, expected: local, expectedState: "s1"), "abc123")
    }

    func testCallbackAddressMustMatchExactly() {
        let wrong = [
            (URL(string: "memorygarden-oauth://evil?code=abc&state=s1")!, scheme),
            (URL(string: "memorygarden-oauth://openrouter/x?code=abc&state=s1")!, scheme),
            (URL(string: "other-scheme://openrouter?code=abc&state=s1")!, scheme),
            (URL(string: "http://localhost:51423/callback-not-real?code=abc&state=s1")!, local),
            (URL(string: "http://localhost:51423/callback/?code=abc&state=s1")!, local),
            (URL(string: "http://localhost:51424/callback?code=abc&state=s1")!, local),
            (URL(string: "http://127.0.0.2:51423/callback?code=abc&state=s1")!, local),
            (URL(string: "https://localhost:51423/callback?code=abc&state=s1")!, local),
        ]
        for (url, expected) in wrong {
            XCTAssertThrowsError(try OpenRouterLogin.code(fromCallback: url, expected: expected, expectedState: "s1")) {
                XCTAssertEqual($0 as? OpenRouterLogin.LoginError, .unexpectedCallback, url.absoluteString)
            }
        }
    }

    func testCallbackWithoutStateStillAccepted() throws {
        let url = URL(string: "memorygarden-oauth://openrouter?code=abc123")!
        XCTAssertEqual(try OpenRouterLogin.code(fromCallback: url, expected: scheme, expectedState: "s1"), "abc123", "OpenRouter 没回传 state 时靠 PKCE")
    }

    func testCallbackStateEmptyDuplicateOrMismatchRejected() {
        for q in ["code=abc&state=evil", "code=abc&state=", "code=abc&state", "code=abc&state=s1&state=s1", "code=abc&state=s1&state=evil"] {
            let url = URL(string: "memorygarden-oauth://openrouter?\(q)")!
            XCTAssertThrowsError(try OpenRouterLogin.code(fromCallback: url, expected: scheme, expectedState: "s1")) {
                XCTAssertEqual($0 as? OpenRouterLogin.LoginError, .stateMismatch, q)
            }
        }
    }

    func testDenialWithWrongStateIsMismatch() {
        let url = URL(string: "memorygarden-oauth://openrouter?error=access_denied&state=evil")!
        XCTAssertThrowsError(try OpenRouterLogin.code(fromCallback: url, expected: scheme, expectedState: "s1")) {
            XCTAssertEqual($0 as? OpenRouterLogin.LoginError, .stateMismatch, "对不上这次登录的「拒绝」不认")
        }
    }

    func testCallbackError() {
        let url = URL(string: "memorygarden-oauth://openrouter?error=access_denied&error_description=User%20denied")!
        XCTAssertThrowsError(try OpenRouterLogin.code(fromCallback: url, expected: scheme, expectedState: nil)) {
            XCTAssertEqual($0 as? OpenRouterLogin.LoginError, .denied("User denied"))
        }
        let bare = URL(string: "memorygarden-oauth://openrouter?error=access_denied")!
        XCTAssertThrowsError(try OpenRouterLogin.code(fromCallback: bare, expected: scheme, expectedState: "s1")) {
            XCTAssertEqual($0 as? OpenRouterLogin.LoginError, .denied("access_denied"), "拒绝授权不带 state")
        }
    }

    func testCallbackMissingCode() {
        let cases = [
            (URL(string: "memorygarden-oauth://openrouter")!, scheme),
            (URL(string: "memorygarden-oauth://openrouter?code=")!, scheme),
            (URL(string: "memorygarden-oauth://openrouter?code=a&code=b")!, scheme),
            (URL(string: "http://localhost:51423/callback?state=s1")!, local),
        ]
        for (url, expected) in cases {
            XCTAssertThrowsError(try OpenRouterLogin.code(fromCallback: url, expected: expected, expectedState: "s1")) {
                XCTAssertEqual($0 as? OpenRouterLogin.LoginError, .missingCode, url.absoluteString)
            }
        }
    }

    // MARK: 本机回调：请求行累积 + 判定（纯函数）

    func testRequestLineAccumulatesAcrossFragments() {
        let full = "GET /callback?code=abc123&state=s1 HTTP/1.1\r\nHost: localhost:51423\r\n\r\n"
        let bytes = Array(full.utf8)
        let lineEnd = Array("GET /callback?code=abc123&state=s1 HTTP/1.1".utf8).count
        // 每个切点都试：请求行没收完（含停在 \r 和 \n 之间）一律 incomplete，绝不提前交出截断的 code
        for cut in 0...bytes.count {
            let scan = OpenRouterLogin.scanRequestLine(Data(bytes[0..<cut]))
            if cut < lineEnd + 2 {
                XCTAssertEqual(scan, .incomplete, "cut=\(cut)")
            } else {
                XCTAssertEqual(scan, .line("GET /callback?code=abc123&state=s1 HTTP/1.1"), "cut=\(cut)")
            }
        }
    }

    func testRequestLineBounded() {
        let long = Data(("GET /callback?code=" + String(repeating: "a", count: OpenRouterLogin.maxRequestLineBytes)).utf8)
        XCTAssertEqual(OpenRouterLogin.scanRequestLine(long), .tooLong)
        XCTAssertEqual(OpenRouterLogin.scanRequestLine(long + Data("\r\n".utf8)), .tooLong)
        XCTAssertEqual(OpenRouterLogin.scanRequestLine(Data()), .incomplete)
    }

    func testLocalRequestOnlyAcceptsThisLogin() {
        func judge(_ line: String) -> OpenRouterLogin.LocalRequest {
            OpenRouterLogin.localRequest(line, expected: local, expectedState: "s1")
        }
        XCTAssertEqual(judge("GET /callback?code=abc&state=s1 HTTP/1.1"), .code("abc"))
        XCTAssertEqual(judge("GET /callback?code=abc HTTP/1.1"), .code("abc"))
        XCTAssertEqual(judge("GET /callback?error=access_denied HTTP/1.1"), .failed(.denied("access_denied")))
        for junk in [
            "POST /callback?code=abc&state=s1 HTTP/1.1",
            "GET /callback-not-real?code=abc&state=s1 HTTP/1.1",
            "GET /callback/?code=abc&state=s1 HTTP/1.1",
            "GET /favicon.ico HTTP/1.1",
            "GET /callback?code=abc&state=evil HTTP/1.1",
            "GET /callback?code=abc&state= HTTP/1.1",
            "GET /callback?state=s1 HTTP/1.1",
            "GET /callback?error=access_denied&state=evil HTTP/1.1",
            "GET http://evil/callback?code=abc&state=s1 HTTP/1.1",
            "GET //evil/callback?code=abc&state=s1 HTTP/1.1",
            "GET /callback?code=abc&state=s1",
            "GET  /callback?code=abc&state=s1 HTTP/1.1",
            "",
            "\u{FFFD}\u{FFFD}",
        ] {
            XCTAssertEqual(judge(junk), .ignore, junk)
        }
    }

    func testUserCancelIsCancelled() {
        let cancel = ASWebAuthenticationSessionError(.canceledLogin)
        guard case .failure(let e) = OpenRouterLogin.sessionOutcome(nil, cancel) else { return XCTFail("取消不能算成功") }
        XCTAssertEqual(e as? OpenRouterLogin.LoginError, .cancelled)

        let url = URL(string: "memorygarden-oauth://openrouter?code=x")!
        guard case .success(let got) = OpenRouterLogin.sessionOutcome(url, nil) else { return XCTFail() }
        XCTAssertEqual(got, url)

        let other = ASWebAuthenticationSessionError(.presentationContextInvalid)
        guard case .failure(let e2) = OpenRouterLogin.sessionOutcome(nil, other) else { return XCTFail() }
        XCTAssertNil(e2 as? OpenRouterLogin.LoginError, "别的错误原样往上报，不当取消吞掉")
    }

    func testPastedCode() throws {
        XCTAssertEqual(try OpenRouterLogin.code(fromPasted: "  abc-123\n"), "abc-123")
        XCTAssertEqual(try OpenRouterLogin.code(fromPasted: "https://openrouter.ai/x?code=zzz"), "zzz")
        XCTAssertThrowsError(try OpenRouterLogin.code(fromPasted: "  \n")) {
            XCTAssertEqual($0 as? OpenRouterLogin.LoginError, .missingCode)
        }
    }

    // MARK: 换 key

    func testExchangeRequestBody() async throws {
        Stub.response = (200, #"{"key":"sk-or-v1-test","user_id":"u1"}"#)
        let key = try await OpenRouterLogin.exchange(code: "code-1", verifier: "verifier-1", session: session)
        XCTAssertEqual(key, "sk-or-v1-test")

        XCTAssertEqual(Stub.seen.count, 1)
        let (req, body) = Stub.seen[0]
        XCTAssertEqual(req.url?.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["code": "code-1", "code_verifier": "verifier-1", "code_challenge_method": "S256"])
    }

    func testExchangeMissingKey() async {
        Stub.response = (200, #"{"user_id":"u1"}"#)
        do {
            _ = try await OpenRouterLogin.exchange(code: "c", verifier: "v", session: session)
            XCTFail("缺 key 要报错")
        } catch {
            XCTAssertEqual(error as? OpenRouterLogin.LoginError, .missingKey)
        }
    }

    func testExchangeHTTPError() async {
        Stub.response = (400, #"{"error":{"message":"Invalid code"}}"#)
        do {
            _ = try await OpenRouterLogin.exchange(code: "c", verifier: "v", session: session)
            XCTFail("400 要报错")
        } catch {
            guard case .http(let status, let body)? = error as? OpenRouterLogin.LoginError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("Invalid code"))
        }
    }

    // MARK: 预设

    func testOpenRouterPresetUsesLogin() {
        XCTAssertEqual(APIProvider.openrouter.login, .openRouter)
    }
}
