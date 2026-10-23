import XCTest
@testable import 记忆花园

/// #068 自建中继：配对码 u3/p3、扫码整体替换、候选收口、中继严格判活、SPKI pin（和 cc-bridge 同一个定义）。
final class CCRelayPairingTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "CCRelayPairingTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func payload(_ json: String) -> CCPairPayload? { CCPairPayload.parse(json) }

    func testParseAcceptsRelayFieldsAndRelayOnly() throws {
        let p = try XCTUnwrap(payload(#"{"mpcc":1,"u":"ws://192.168.1.2:7890/cc","u2":null,"u3":"wss://relay.example.com:8443/cc","p3":"abc=","t":"tok"}"#))
        XCTAssertEqual(p.relayURL?.absoluteString, "wss://relay.example.com:8443/cc")
        XCTAssertEqual(p.p3, "abc=")
        // 只有中继也算合法配对码（hub 没 LAN / Tailscale 时）
        XCTAssertNotNil(payload(#"{"mpcc":1,"u":null,"u3":"wss://relay.example.com/cc","t":"tok"}"#))
        // 老格式照旧
        XCTAssertNotNil(payload(#"{"mpcc":1,"u":"ws://192.168.1.2:7890/cc","t":"tok"}"#))
    }

    func testRelayMustBeWss() {
        let p = payload(#"{"mpcc":1,"u":"ws://192.168.1.2:7890/cc","u3":"ws://relay.example.com/cc","t":"tok"}"#)
        XCTAssertNil(p?.relayURL)
        XCTAssertNil(payload(#"{"mpcc":1,"u":null,"u3":"http://relay.example.com/cc","t":"tok"}"#))
        XCTAssertNil(payload(#"{"mpcc":1,"u":null,"u3":null,"t":"tok"}"#))
    }

    func testSaveReplacesEverythingAndClearsMissingFields() throws {
        let first = try XCTUnwrap(payload(#"{"mpcc":1,"u":"ws://192.168.1.2:7890/cc","u2":"ws://100.64.0.2:7890/cc","u3":"wss://old-relay.example.com/cc","p3":"oldpin=","t":"t1"}"#))
        CCBridgeEndpoints.save(first, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CCBridgeEndpoints.relayKey), "wss://old-relay.example.com/cc")
        XCTAssertEqual(defaults.string(forKey: CCBridgeEndpoints.relayPinKey), "oldpin=")

        // 换配一个没有中继、没有 Tailscale 的码：旧中继 / 旧 pin / 旧备地址都要清掉，不然新口令会发给旧中继
        let second = try XCTUnwrap(payload(#"{"mpcc":1,"u":"ws://192.168.1.9:7890/cc","t":"t2"}"#))
        CCBridgeEndpoints.save(second, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CCBridgeEndpoints.overrideKey), "ws://192.168.1.9:7890/cc")
        XCTAssertNil(defaults.string(forKey: CCBridgeEndpoints.backupKey))
        XCTAssertNil(defaults.string(forKey: CCBridgeEndpoints.relayKey))
        XCTAssertNil(defaults.string(forKey: CCBridgeEndpoints.relayPinKey))

        // pin 只跟着中继走：码里有 p3 但中继地址不合法 → 不存 pin
        let third = try XCTUnwrap(payload(#"{"mpcc":1,"u":"ws://192.168.1.9:7890/cc","u3":"ws://x/cc","p3":"pin=","t":"t3"}"#))
        CCBridgeEndpoints.save(third, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: CCBridgeEndpoints.relayPinKey))
    }

    @MainActor
    func testConfiguredURLsOrderAndRelayExclusion() throws {
        let p = try XCTUnwrap(payload(#"{"mpcc":1,"u":"ws://192.168.1.2:7890/cc","u2":"ws://100.64.0.2:7890/cc","u3":"wss://relay.example.com:8443/cc","t":"t"}"#))
        CCBridgeEndpoints.save(p, defaults: defaults)
        XCTAssertEqual(CCBridgeEndpoints.configuredURLs(defaults: defaults).map(\.absoluteString),
                       ["ws://192.168.1.2:7890/cc", "ws://100.64.0.2:7890/cc", "wss://relay.example.com:8443/cc"])
        // /agora 不走中继
        XCTAssertEqual(CCBridgeEndpoints.configuredURLs(includeRelay: false, defaults: defaults).count, 2)
        XCTAssertEqual(AgoraClient.configuredCCURLs(defaults: defaults).count, 2)
        // 手动塞进去的非 wss 中继不认
        defaults.set("ws://relay.example.com/cc", forKey: CCBridgeEndpoints.relayKey)
        XCTAssertEqual(CCBridgeEndpoints.configuredURLs(defaults: defaults).count, 2)
    }

    func testLocalFallbackOnlyWhenNothingConfigured() throws {
        // 什么都没配：补默认本机地址（ContentView 冷启动照旧）；fallbackToLocal=false（语音）不补
        XCTAssertEqual(CCBridgeEndpoints.configuredURLs(defaults: defaults).map(\.absoluteString), [APIProvider.ccBridge.baseURL])
        XCTAssertTrue(CCBridgeEndpoints.configuredURLs(fallbackToLocal: false, defaults: defaults).isEmpty)
        // 只配了中继：不偷偷加本机地址
        let relayOnly = try XCTUnwrap(payload(#"{"mpcc":1,"u":null,"u3":"wss://relay.example.com/cc","t":"t"}"#))
        CCBridgeEndpoints.save(relayOnly, defaults: defaults)
        XCTAssertEqual(CCBridgeEndpoints.configuredURLs(defaults: defaults).map(\.absoluteString), ["wss://relay.example.com/cc"])
    }

    func testManualTargetChangeDropsRelay() throws {
        let p = try XCTUnwrap(payload(#"{"mpcc":1,"u":"ws://192.168.1.2:7890/cc","u2":"ws://100.64.0.2:7890/cc","u3":"wss://relay-a.example.com/cc","p3":"pinA=","t":"t"}"#))
        CCBridgeEndpoints.save(p, defaults: defaults)
        // 地址没改（只是点重连）：中继留着
        CCBridgeEndpoints.saveManual(primary: "ws://192.168.1.2:7890/cc", backup: "ws://100.64.0.2:7890/cc", defaults: defaults)
        XCTAssertNotNil(CCBridgeEndpoints.relayURL(defaults: defaults))
        // 手填了电脑 B：中继 A 和它的 pin 一起清掉，B 的口令不会发给 A
        CCBridgeEndpoints.saveManual(primary: "ws://192.168.1.50:7890/cc", backup: "", defaults: defaults)
        XCTAssertNil(CCBridgeEndpoints.relayURL(defaults: defaults))
        XCTAssertNil(defaults.string(forKey: CCBridgeEndpoints.relayPinKey))
        XCTAssertEqual(CCBridgeEndpoints.configuredURLs(defaults: defaults).map(\.absoluteString), ["ws://192.168.1.50:7890/cc"])
    }

    func testPinDecision() throws {
        let ec = try XCTUnwrap(Data(base64Encoded: ecDER))
        XCTAssertEqual(CCRelayPin.decide(pin: nil, leafDER: ec), .performDefaultHandling)      // 没 pin：系统校验
        XCTAssertEqual(CCRelayPin.decide(pin: ecPin, leafDER: ec), .useCredential)             // 对上：自签也放行
        XCTAssertEqual(CCRelayPin.decide(pin: rsaPin, leafDER: ec), .cancelAuthenticationChallenge)   // 对不上：拒，不回退
        XCTAssertEqual(CCRelayPin.decide(pin: ecPin, leafDER: nil), .cancelAuthenticationChallenge)   // 拿不到证书：拒
    }

    func testProbeRefusesRedirects() throws {
        let url = try XCTUnwrap(URL(string: "https://relay.example.com/health"))
        let resp = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/health"]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var followed: URLRequest? = URLRequest(url: url)
        CCBridgeProbeDelegate().urlSession(session, task: session.dataTask(with: url), willPerformHTTPRedirection: resp,
                                           newRequest: URLRequest(url: try XCTUnwrap(URL(string: "https://evil.example/health")))) { followed = $0 }
        XCTAssertNil(followed)
    }

    func testRelayPinOnlyForRelayHostAndPort() throws {
        let p = try XCTUnwrap(payload(#"{"mpcc":1,"u":"ws://192.168.1.2:7890/cc","u3":"wss://Relay.Example.com:8443/cc","p3":"pin=","t":"t"}"#))
        CCBridgeEndpoints.save(p, defaults: defaults)
        XCTAssertEqual(CCBridgeEndpoints.relayPin(host: "relay.example.com", port: 8443, defaults: defaults), "pin=")
        XCTAssertNil(CCBridgeEndpoints.relayPin(host: "relay.example.com", port: 443, defaults: defaults))
        XCTAssertNil(CCBridgeEndpoints.relayPin(host: "192.168.1.2", port: 7890, defaults: defaults))

        let noPort = try XCTUnwrap(payload(#"{"mpcc":1,"u":null,"u3":"wss://1.2.3.4/cc","p3":"pin2=","t":"t"}"#))
        CCBridgeEndpoints.save(noPort, defaults: defaults)
        XCTAssertEqual(CCBridgeEndpoints.relayPin(host: "1.2.3.4", port: 443, defaults: defaults), "pin2=")
    }

    func testStrictProbeForRelayCandidates() throws {
        let url = try XCTUnwrap(URL(string: "https://relay.example.com/health"))
        let bare403 = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [:]))
        let hub403 = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["x-mp-hub": "1"]))
        let relay503 = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: [:]))
        let redirect = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil/"]))
        XCTAssertTrue(CCBridgeWebSocketClient.isHubProbeResponse(bare403))                 // LAN 老 hub 兼容照旧
        XCTAssertFalse(CCBridgeWebSocketClient.isHubProbeResponse(bare403, strict: true))  // 中继候选必须带头
        XCTAssertTrue(CCBridgeWebSocketClient.isHubProbeResponse(hub403, strict: true))
        XCTAssertFalse(CCBridgeWebSocketClient.isHubProbeResponse(relay503, strict: true))
        XCTAssertFalse(CCBridgeWebSocketClient.isHubProbeResponse(redirect, strict: true))
    }

    func testHealthURLForRelay() throws {
        let relay = try XCTUnwrap(URL(string: "wss://relay.example.com:8443/cc?token=t&bundle=b"))
        XCTAssertEqual(CCBridgeWebSocketClient.healthURL(for: relay)?.absoluteString, "https://relay.example.com:8443/health")
    }

    // 证书和期望值由 cc-bridge relay-connector.ts 的 spkiSha256 生成（Node X509Certificate 导出 SPKI 再 sha256），
    // 两边同一个定义：relay.json 里的 pin、配对码 p3、app 校验必须一致。证书是一次性自签，私钥已丢。
    private let ecDER = "MIIBfzCCASWgAwIBAgIUNN/s9PLn6xWiXs0Y17IPUBA5hoAwCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKcmVsYXkudGVzdDAeFw0yNjEwMTAxNjUwMzVaFw0zNjEwMDcxNjUwMzVaMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQLvZrNJ/zIqmwmVBdfAVPF2YPdeV1WtCDP/OEjDm8P8qxey1ictiwzu8ZC3E/UNqdNOtUqtWmSW/PGo0R+ODRBo1MwUTAdBgNVHQ4EFgQUR+L9rl+6Qp/M34NWj30/sEM5NaowHwYDVR0jBBgwFoAUR+L9rl+6Qp/M34NWj30/sEM5NaowDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAwVD8Q2Xf72AJ4he0LjU3Nmr3WpimnVXtJp/wg/DNz8MCIEblKdZ+SQZEbikH4HAIO0YoParke4WVeKHebvAo09SG"
    private let ecPin = "cOX1+Jp7YR2GOQP+WeiTReSPXvCOtvtGociLI1HoWH8="
    private let rsaDER = "MIIDCzCCAfOgAwIBAgIUJBaPVtQtlIZaupFg7RlqvG0GJxYwDQYJKoZIhvcNAQELBQAwFTETMBEGA1UEAwwKcmVsYXkudGVzdDAeFw0yNjEwMTAxNjUwMzVaFw0zNjEwMDcxNjUwMzVaMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCpKWgtQgJpmS/A8zK57bBAVLLWViGukrKukIfIJmR3Vf0bVU4q7tgun5YgQ8whbqG6os5228IifuSUrVurtOXXYwFQ+pFBWddMJnCy1YLRrMIyEy1D/PWUybsHaiCdRHV7oVujp5Lx1pKpTrutKjqhjOqAVGN9hL41IrfMMKjyLPR3slm3SojhHRQVyo6GCSS73zeWxVbUCmx8KQA7skD+pHI8QPHtW4S4mEwoHBmePhnSGoWvslDpV4jfl9stZgJxY2Sf7QkojZB6LxhIduOMfVf31hHKoPM4ivjtWMabx6XdrNKRzf3i51FRvv0L7dwufQds5hkXjN3LOAIYAG9HAgMBAAGjUzBRMB0GA1UdDgQWBBTIkOoS8ZNc3WrKqdPrF0ZUCB59CTAfBgNVHSMEGDAWgBTIkOoS8ZNc3WrKqdPrF0ZUCB59CTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBip/zrGDuyr8EhH/Jh16i0sjoTbvFyZy/3wJiOUTZB8T5se0C2DUH9TgrtH6ICWnevxzfHEQ5fA4LivcH8dDdT71XcCeQJpid1i6QtHXhJXhPA/Mtxu7+6cbE2Ac3UoU58dOWTqlg5vAAKi7zURir4SHTh68DUjdCh2+O2+7MurFsdZI2N6D5dL5AcXADAhu9/BnKUNl2vK15j8AO68fyrXjg8pHMCGqyvyaL4Rcc7/hL49cXQgE3VJFLIQSXlNUS6Gka8azEoEiEAkEauaDWgh51p2EYGaBbLAfvjaWd8oYwIh2eWMxMziaH7em8+6ZFDcBaGL5++HF2W+QRMmGMF"
    private let rsaPin = "+1UBzpv7fMiD/u+VnYmZQnW19cMwQFdGiIrYDWTkzGo="

    func testSPKIPinMatchesCCBridgeDefinition() throws {
        XCTAssertEqual(CCRelayPin.spkiSHA256(certDER: try XCTUnwrap(Data(base64Encoded: ecDER))), ecPin)
        XCTAssertEqual(CCRelayPin.spkiSHA256(certDER: try XCTUnwrap(Data(base64Encoded: rsaDER))), rsaPin)
    }

    func testSPKIPinRejectsGarbage() throws {
        XCTAssertNil(CCRelayPin.spkiSHA256(certDER: Data()))
        XCTAssertNil(CCRelayPin.spkiSHA256(certDER: Data([0x30, 0x82, 0xFF, 0xFF, 0x00])))
        let truncated = try XCTUnwrap(Data(base64Encoded: ecDER)).prefix(120)
        XCTAssertNil(CCRelayPin.spkiSHA256(certDER: Data(truncated)))
    }
}
