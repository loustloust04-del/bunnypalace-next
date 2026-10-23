import XCTest
@testable import 记忆花园

// MARK: - TXT 解析（契约 C1）

final class ProxyServiceTXTTests: XCTestCase {

    /// proxy 侧实测广播：`v=1 path=/v1 proto=anthropic,openai auth=lan ts=100.110.76.9`
    func testFullRecordMatchesProxyBroadcast() {
        let txt = ProxyServiceTXT.parse([
            "v": "1", "path": "/v1", "proto": "anthropic,openai",
            "auth": "lan", "ts": "100.110.76.9",
        ])
        XCTAssertEqual(txt.version, "1")
        XCTAssertEqual(txt.apiPath, "/v1")
        XCTAssertEqual(txt.protocols, ["anthropic", "openai"])
        XCTAssertEqual(txt.auth, "lan")
        XCTAssertEqual(txt.tailscaleIP, "100.110.76.9")
    }

    /// ts 是可选字段：proxy 拿不到 Tailscale IP 时整个省略
    func testRecordWithoutTailscaleField() {
        let txt = ProxyServiceTXT.parse([
            "v": "1", "path": "/v1", "proto": "anthropic,openai", "auth": "lan",
        ])
        XCTAssertNil(txt.tailscaleIP)
        XCTAssertEqual(txt.auth, "lan")
    }

    func testEmptyRecordFallsBackToV1AndAuthLAN() {
        let txt = ProxyServiceTXT.parse([:])
        XCTAssertEqual(txt.apiPath, "/v1")
        XCTAssertEqual(txt.auth, "lan")
        XCTAssertTrue(txt.protocols.isEmpty)
    }

    func testPathIsNormalized() {
        XCTAssertEqual(ProxyServiceTXT.parse(["path": "v2"]).apiPath, "/v2")
        XCTAssertEqual(ProxyServiceTXT.parse(["path": "/v1/"]).apiPath, "/v1")
        XCTAssertEqual(ProxyServiceTXT.parse(["path": "  /api/v1  "]).apiPath, "/api/v1")
        XCTAssertEqual(ProxyServiceTXT.parse(["path": "/"]).apiPath, "/")
    }

    func testProtocolListTolerantToSpacingAndCase() {
        let txt = ProxyServiceTXT.parse(["proto": " Anthropic , , OpenAI "])
        XCTAssertEqual(txt.protocols, ["anthropic", "openai"])
    }

    func testTailscaleIPOnlyWhenNonEmpty() {
        XCTAssertEqual(ProxyServiceTXT.parse(["ts": "100.110.76.9"]).tailscaleIP, "100.110.76.9")
        XCTAssertNil(ProxyServiceTXT.parse(["ts": "  "]).tailscaleIP)
    }

    func testDiscoveredProxyBuildsC2BaseURL() {
        let svc = DiscoveredProxy(
            id: "记忆花园 Claude（mimiair）",
            host: "mimiair.local.",
            port: 8792,
            txt: ProxyServiceTXT.parse(["v": "1", "path": "/v1"])
        )
        XCTAssertEqual(svc.baseURL, "http://mimiair.local:8792/v1")
        XCTAssertEqual(svc.healthURL?.absoluteString, "http://mimiair.local:8792/health")
        XCTAssertEqual(svc.displayHost, "mimiair.local:8792")
    }
}

// MARK: - 去重键规整（刀4）

final class ProxyBaseURLNormalizeTests: XCTestCase {

    func testFQDNTrailingDotAndCaseCollapse() {
        XCTAssertEqual(
            ProxyBaseURL.normalize("http://MimiAir.local.:8792/v1"),
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1")
        )
    }

    func testTrailingSlashCollapses() {
        XCTAssertEqual(
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1/"),
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1")
        )
    }

    func testDefaultPortCollapses() {
        XCTAssertEqual(
            ProxyBaseURL.normalize("http://example.com:80/v1"),
            ProxyBaseURL.normalize("http://example.com/v1")
        )
        XCTAssertEqual(
            ProxyBaseURL.normalize("https://api.example.com:443/v1"),
            ProxyBaseURL.normalize("https://api.example.com/v1")
        )
    }

    func testQueryAndFragmentIgnored() {
        XCTAssertEqual(
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1?token=abc#x"),
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1")
        )
    }

    func testMissingSchemeAssumedHTTP() {
        XCTAssertEqual(
            ProxyBaseURL.normalize("mimiair.local:8792/v1"),
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1")
        )
    }

    func testDifferentHostOrPortStaysDistinct() {
        XCTAssertNotEqual(
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1"),
            ProxyBaseURL.normalize("http://192.168.31.20:8792/v1")
        )
        XCTAssertNotEqual(
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1"),
            ProxyBaseURL.normalize("http://mimiair.local:8793/v1")
        )
    }

    func testDifferentPathStaysDistinct() {
        XCTAssertNotEqual(
            ProxyBaseURL.normalize("http://mimiair.local:8792/v1"),
            ProxyBaseURL.normalize("http://mimiair.local:8792/v2")
        )
    }

    func testSchemeIsNotCollapsed() {
        XCTAssertNotEqual(
            ProxyBaseURL.normalize("ws://127.0.0.1:7890/cc"),
            ProxyBaseURL.normalize("http://127.0.0.1:7890/cc")
        )
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(ProxyBaseURL.normalize("   "), "")
    }
}

// MARK: - 状态机（刀2：搜索中 / 找到 N 个 / 权限被拒 / 无结果 / 不可用）

final class ProxyDiscoveryMachineTests: XCTestCase {

    func testStartsIdleThenSearching() {
        var m = ProxyDiscoveryMachine()
        XCTAssertEqual(m.state, .idle)
        m.apply(.started)
        XCTAssertEqual(m.state, .searching)
    }

    func testStaysSearchingBeforeDeadlineWithZeroResults() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.browserReady)
        m.apply(.servicesChanged(0))
        XCTAssertEqual(m.state, .searching)
    }

    func testEmptyOnlyAfterDeadline() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.searchDeadlineReached)
        XCTAssertEqual(m.state, .empty)
    }

    func testFoundCountWins() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.servicesChanged(2))
        XCTAssertEqual(m.state, .found(2))
        m.apply(.searchDeadlineReached)
        XCTAssertEqual(m.state, .found(2), "已经找到就不该因为超时改口说没找到")
    }

    func testServicesDroppingToZeroAfterDeadlineBecomesEmpty() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.servicesChanged(1))
        m.apply(.searchDeadlineReached)
        m.apply(.servicesChanged(0))
        XCTAssertEqual(m.state, .empty)
    }

    func testDeniedBeatsDeadline() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.browserBlocked(denied: true, reason: "mDNS 错误 -65570"))
        XCTAssertEqual(m.state, .permissionDenied)
        m.apply(.searchDeadlineReached)
        XCTAssertEqual(m.state, .permissionDenied, "权限被拒不能被降级成「没找到」")
    }

    func testNonDeniedFailureIsUnavailable() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.browserBlocked(denied: false, reason: "系统错误 50"))
        XCTAssertEqual(m.state, .unavailable("系统错误 50"))
        m.apply(.searchDeadlineReached)
        XCTAssertEqual(m.state, .unavailable("系统错误 50"))
    }

    func testResultsRecoverFromDeniedState() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.browserBlocked(denied: true, reason: "x"))
        m.apply(.servicesChanged(1))
        XCTAssertEqual(m.state, .found(1), "拿得到结果就说明权限没问题")
    }

    func testBrowserReadyRecoversFromUnavailable() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.browserBlocked(denied: false, reason: "x"))
        m.apply(.browserReady)
        XCTAssertEqual(m.state, .searching)
    }

    func testStopResetsEverything() {
        var m = ProxyDiscoveryMachine()
        m.apply(.started)
        m.apply(.servicesChanged(3))
        m.apply(.searchDeadlineReached)
        m.apply(.stopped)
        XCTAssertEqual(m.state, .idle)
        m.apply(.started)
        XCTAssertEqual(m.state, .searching, "重开一轮不该带着上一轮的 deadline/计数")
    }
}

// MARK: - 权限被拒判定

final class ProxyDiscoveryDeniedDetectionTests: XCTestCase {

    func testPolicyDeniedAndNoAuthAreDenied() {
        XCTAssertTrue(ProxyDiscovery.isPermissionDenied(.dns(-65570)))   // kDNSServiceErr_PolicyDenied
        XCTAssertTrue(ProxyDiscovery.isPermissionDenied(.dns(-65555)))   // kDNSServiceErr_NoAuth
    }

    func testPosixPermissionErrorsAreDenied() {
        XCTAssertTrue(ProxyDiscovery.isPermissionDenied(.posix(.EPERM)))
        XCTAssertTrue(ProxyDiscovery.isPermissionDenied(.posix(.EACCES)))
    }

    func testOtherErrorsAreNotDenied() {
        XCTAssertFalse(ProxyDiscovery.isPermissionDenied(.dns(-65563)))
        XCTAssertFalse(ProxyDiscovery.isPermissionDenied(.posix(.ECONNREFUSED)))
        XCTAssertFalse(ProxyDiscovery.isPermissionDenied(.posix(.ENETDOWN)))
    }
}

// MARK: - /health 三态解析（proxy 侧已定的响应形状）

final class ProxyHealthParseTests: XCTestCase {

    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testOK() {
        let h = ProxyHealth.parse(statusCode: 200, body: body("""
        {"status":"ok","service":"claude-proxy","version":"0.2.0",
         "backend":{"path":"/Users/tester/.local/bin/claude","executable":true,"source":"which"}}
        """))
        XCTAssertEqual(h, .ok(version: "0.2.0"))
        XCTAssertTrue(h.isUsable)
    }

    func testDegradedBackendNotExecutable() {
        let h = ProxyHealth.parse(statusCode: 200, body: body("""
        {"status":"degraded","service":"claude-proxy","version":"0.2.0",
         "backend":{"path":"/Users/tester/.local/bin/claude","executable":false,"source":"which"}}
        """))
        XCTAssertFalse(h.isUsable)
        guard case .degraded(let why) = h else { return XCTFail("应判成 degraded，实际 \(h)") }
        XCTAssertTrue(why.contains("/Users/tester/.local/bin/claude"), "原因要带上后端路径，实际 \(why)")
    }

    /// 403 的 message 本身就是操作指引，必须原样透出去
    func testUntrustedNetworkSurfacesProxyMessage() {
        let message = "当前网络未被批准。在这台 Mac 上跑 `claude-proxy trust \"网络名\"` 后重试。"
        let payload: [String: Any] = [
            "error": ["type": "forbidden", "reason": "untrusted-network", "message": message],
        ]
        let h = ProxyHealth.parse(
            statusCode: 403,
            body: try! JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertEqual(h, .untrusted(message))
        XCTAssertFalse(h.isUsable)
        XCTAssertEqual(ProxyCardInstallError.health(h).errorDescription, message)
    }

    func testUntrustedWithoutMessageStillActionable() {
        let h = ProxyHealth.parse(statusCode: 403, body: body("{}"))
        guard case .untrusted(let msg) = h else { return XCTFail("403 一律判 untrusted，实际 \(h)") }
        XCTAssertFalse(msg.isEmpty)
    }

    /// 老版本 proxy 的 /health 不带 status —— 有 200 应答就当活着
    func testLegacyHealthWithoutStatusIsUsable() {
        XCTAssertTrue(ProxyHealth.parse(statusCode: 200, body: body("{}")).isUsable)
        XCTAssertTrue(ProxyHealth.parse(statusCode: 200, body: body("not json")).isUsable)
    }

    func testOtherHTTPErrorsAreDegraded() {
        guard case .degraded(let why) = ProxyHealth.parse(statusCode: 503, body: body("{}")) else {
            return XCTFail("非 2xx 非 403 应判 degraded")
        }
        XCTAssertTrue(why.contains("503"))
    }
}

// MARK: - 卡 id 前缀（能力边界识别）

final class ProxyCardInstallerIdTests: XCTestCase {

    func testProxyCardIdIsRecognizable() {
        XCTAssertTrue(ProxyCardInstaller.isProxyCard(id: ProxyCardInstaller.idPrefix + UUID().uuidString))
    }

    func testOtherCardIdsAreNotProxyCards() {
        XCTAssertFalse(ProxyCardInstaller.isProxyCard(id: "cred-\(UUID().uuidString)"))
        XCTAssertFalse(ProxyCardInstaller.isProxyCard(id: "cc-bridge"))
        XCTAssertFalse(ProxyCardInstaller.isProxyCard(id: "chatgpt-oauth"))
    }
}

// MARK: - 默认模型挑选（不按字母序拿第一个）

final class ProxyDefaultModelPickTests: XCTestCase {

    private func models(_ ids: [String]) -> [ProviderModel] {
        ids.map { ProviderModel(credentialId: "mpclaude-test", modelId: $0, name: $0) }
    }

    func testSonnetWinsOverAlphabeticalFirst() {
        // fetchModels 是字母序，haiku 会排在最前 —— 挑选必须无视这个顺序
        let picked = ProxyCardInstaller.pickDefaultModel(
            models(["claude-haiku-4-5-20251001", "claude-opus-5", "claude-sonnet-5"])
        )
        XCTAssertEqual(picked?.modelId, "claude-sonnet-5")
    }

    func testOpusBeatsHaikuWhenNoSonnet() {
        let picked = ProxyCardInstaller.pickDefaultModel(models(["claude-haiku-4-5-20251001", "claude-opus-5"]))
        XCTAssertEqual(picked?.modelId, "claude-opus-5")
    }

    func testUnknownNameBeatsHaiku() {
        let picked = ProxyCardInstaller.pickDefaultModel(models(["claude-haiku-4-5-20251001", "some-future-model"]))
        XCTAssertEqual(picked?.modelId, "some-future-model")
    }

    func testHaikuOnlyStillPicked() {
        let picked = ProxyCardInstaller.pickDefaultModel(models(["claude-haiku-4-5-20251001"]))
        XCTAssertEqual(picked?.modelId, "claude-haiku-4-5-20251001")
    }

    func testEmptyGivesNil() {
        XCTAssertNil(ProxyCardInstaller.pickDefaultModel([]))
    }

    func testTieBreaksDeterministically() {
        let picked = ProxyCardInstaller.pickDefaultModel(models(["claude-sonnet-5-b", "claude-sonnet-5-a"]))
        XCTAssertEqual(picked?.modelId, "claude-sonnet-5-a")
    }
}
