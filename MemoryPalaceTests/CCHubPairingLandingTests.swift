import XCTest
@testable import 记忆花园

/// 扫码落点（plan-multi-hub B4.3，小样第 4 屏）：classifyPairing 的四种结果 → 页面上说什么、按钮做什么
final class CCHubPairingLandingTests: XCTestCase {
    private let hubs = [
        CCHubRegistry.HubProfile(id: CCHubRegistry.primaryId, name: "MacBook", status: .ready),
        CCHubRegistry.HubProfile(id: "nyc", name: "纽约", status: .ready),
    ]
    private let old = CCHubPairing(primaryURL: "ws://203.0.113.58:7890/cc")

    private func landing(_ match: CCHubRegistry.PairingMatch, hostName: String? = nil, target: String? = nil,
                         new: CCHubPairing? = nil, token: String = "same") -> CCHubPairingLanding {
        CCHubPairingLanding.make(match, hostName: hostName, hubs: hubs, target: target, new: new ?? old, token: token,
                                 pairing: { [old] _ in old }, fingerprint: { _ in CCHubPairingStore.fingerprint("same") })
    }

    private func name(_ id: String) -> String { hubs.first { $0.id == id }?.name ?? "?" }

    func testUpdateListsAddressChange() {
        let new = CCHubPairing(primaryURL: "ws://198.51.100.7:7890/cc")
        let l = landing(.update("nyc"), new: new)
        XCTAssertEqual(l.kind, .update("nyc"))
        XCTAssertEqual(l.title, "认出来了：这是 纽约")
        XCTAssertEqual(l.changes, [.init(label: "主", old: "ws://203.0.113.58:7890/cc", new: "ws://198.51.100.7:7890/cc")])
        XCTAssertFalse(l.tokenChanged)
        XCTAssertEqual(l.commit(choice: nil), .update("nyc"))
        XCTAssertEqual(l.buttonTitle(choice: nil, names: name), "更新 纽约 的地址")
        XCTAssertFalse(l.needsName(choice: nil))
    }

    func testUpdateTokenOnly() {
        let l = landing(.update("nyc"), token: "new-token")
        XCTAssertTrue(l.changes.isEmpty)
        XCTAssertTrue(l.tokenChanged)
        XCTAssertTrue(l.hint.contains("只是口令变了"))
        XCTAssertEqual(l.buttonTitle(choice: nil, names: name), "更新 纽约 的口令")
    }

    func testAddNewDefaultsNameToHostName() {
        let l = landing(.addNew(reportedIdentity: "hub-x"), hostName: "vps-nyc-01")
        XCTAssertEqual(l.kind, .addNew)
        XCTAssertEqual(l.title, "这是一台新电脑")
        XCTAssertEqual(l.suggestedName, "vps-nyc-01")
        XCTAssertTrue(l.needsName(choice: nil))
        XCTAssertEqual(l.commit(choice: nil), .add)
        XCTAssertEqual(l.buttonTitle(choice: nil, names: name), "添加为新电脑")
        XCTAssertEqual(landing(.addNew(reportedIdentity: nil)).suggestedName, CCHubPairingLanding.fallbackName)
    }

    func testNeedsChoiceOffersEachHubThenNew() {
        let l = landing(.needsChoice)
        XCTAssertEqual(l.kind, .choose)
        XCTAssertEqual(l.choices.map(\.title), ["MacBook 换了口令", "纽约 换了口令", "这是一台新电脑"])
        XCTAssertEqual(l.commit(choice: l.choices[0]), .update(CCHubRegistry.primaryId))
        XCTAssertEqual(l.buttonTitle(choice: l.choices[1], names: name), "更新 纽约 的口令")
        XCTAssertFalse(l.needsName(choice: l.choices[0]))
        XCTAssertEqual(l.commit(choice: l.choices[2]), .add)
        XCTAssertTrue(l.needsName(choice: l.choices[2]))
        XCTAssertNil(l.commit(choice: nil))
        // 从某台「重新扫码」进来：只问那台
        XCTAssertEqual(landing(.needsChoice, target: "nyc").choices.map(\.hubId), ["nyc", nil])
    }

    func testDifferentMachineNeverOverwritesTarget() {
        let matched = landing(.differentMachine(target: CCHubRegistry.primaryId, matching: "nyc"), target: CCHubRegistry.primaryId)
        XCTAssertEqual(matched.kind, .update("nyc"))
        XCTAssertTrue(matched.hint.hasPrefix("这不是 MacBook，是 纽约。"))
        let other = landing(.differentMachine(target: CCHubRegistry.primaryId, matching: nil), hostName: "nas",
                            target: CCHubRegistry.primaryId)
        XCTAssertEqual(other.kind, .addNew)
        XCTAssertEqual(other.commit(choice: nil), .add)
        XCTAssertEqual(other.suggestedName, "nas")
    }

    func testUnreachableOnlyRetries() {
        let l = landing(.unreachable("这台电脑不认这个口令"))
        XCTAssertEqual(l.kind, .unreachable)
        XCTAssertTrue(l.hint.hasPrefix("这台电脑不认这个口令。"))
        XCTAssertNil(l.commit(choice: nil))
        XCTAssertEqual(l.buttonTitle(choice: nil, names: name), "再试一次")
    }

    func testCommitFailureWording() {
        XCTAssertNil(CCHubPairingLanding.failure(.added("x"), names: name))
        XCTAssertEqual(CCHubPairingLanding.failure(.duplicateToken("nyc"), names: name), "这个口令已经是「纽约」在用了：同一台电脑别加两次")
        XCTAssertNil(CCHubPairingLanding.failure(.updated, target: "nyc", names: name))
        XCTAssertEqual(CCHubPairingLanding.failure(.differentMachine, target: "nyc", names: name), "这是另一台电脑，不能拿来更新「纽约」")
    }

    func testPlaintextPublicHint() {
        XCTAssertTrue(CCHubPairingLanding.isPlaintextPublic("ws://203.0.113.58:7890/cc"))
        XCTAssertTrue(CCHubPairingLanding.isPlaintextPublic("ws://vps.example.com:7890/cc"))
        for private_ in ["ws://192.168.1.31:7890/cc", "ws://10.0.0.2:7890/cc", "ws://100.101.2.3:7890/cc", "ws://172.20.1.1:7890/cc",
                         "ws://mac.local:7890/cc", "ws://box.tail1234.ts.net:7890/cc", "ws://127.0.0.1:7890/cc",
                         "wss://203.0.113.58/cc", nil] {
            XCTAssertFalse(CCHubPairingLanding.isPlaintextPublic(private_), private_ ?? "nil")
        }
    }
}
