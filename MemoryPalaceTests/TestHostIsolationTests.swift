import XCTest
import Security
import SwiftUI
import UserNotifications
@testable import 记忆花园

/// #035：测试宿主跑在本工位临时家目录 + 专属偏好 suite + 加后缀的钥匙串 service 里，系统 / 网络适配层闸着。
/// 只看「适配层没调、路径都在临时家里」，不读粟粟的真偏好域、不读真钥匙串值（docs/plan-test-host-isolation.md §3）。
final class TestHostIsolationTests: XCTestCase {
    private var home: URL {
        get throws { try XCTUnwrap(TestHostIsolation.home) }
    }

    func testActiveInTestHost() throws {
        XCTAssertTrue(TestHostIsolation.active)
        XCTAssertEqual(try home.lastPathComponent, "xctest-home")
        XCTAssertEqual(TestHostIsolation.runTag.count, 8)
    }

    func testHomeDerivedPathsStayInsideTempHome() throws {
        let home = try home
        var paths = TestHostIsolation.probedPaths().map { ($0.name, $0.url) }
        paths.append(("localDocumentsBaseRoot", FileLibraryStore.localDocumentsBaseRoot()))
        paths.append(("iCloudDocumentsRoot", try XCTUnwrap(FileLibraryStore.iCloudDocumentsRoot())))
        paths.append(("unifiedStoreURL", ProfileManager.unifiedStoreURL))
        for (name, url) in paths {
            XCTAssertTrue(TestHostIsolation.contains(url, home), "\(name)=\(url.path) 不在 \(home.path) 里")
        }
    }

    func testPathContainmentIsByComponent() {
        let root = URL(fileURLWithPath: "/tmp/a/xctest-home")
        XCTAssertTrue(TestHostIsolation.contains(URL(fileURLWithPath: "/tmp/a/xctest-home/Library"), root))
        XCTAssertFalse(TestHostIsolation.contains(URL(fileURLWithPath: "/tmp/a/xctest-home2/Library"), root))
        XCTAssertFalse(TestHostIsolation.contains(URL(fileURLWithPath: "/tmp/a"), root))
    }

    func testStandardDefaultsAndAppStorageLandInSuite() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: TestHostIsolation.defaultsSuiteName))
        let key = "mp.xctest.isolation.\(UUID().uuidString)"
        defer { suite.removeObject(forKey: key); suite.removeObject(forKey: key + ".appstorage") }

        UserDefaults.standard.set("standard", forKey: key)
        XCTAssertEqual(suite.string(forKey: key), "standard")

        let storage = AppStorage(wrappedValue: "", key + ".appstorage")
        storage.wrappedValue = "appstorage"
        XCTAssertEqual(suite.string(forKey: key + ".appstorage"), "appstorage")
    }

    func testDefaultKeychainIsPrivateToTempHome() throws {
        let home = try home
        let path = try XCTUnwrap(TestHostIsolation.defaultKeychainPath())
        XCTAssertTrue(TestHostIsolation.contains(URL(fileURLWithPath: path), home), path)
        let users = TestHostIsolation.userKeychainPaths()
        XCTAssertEqual(users.count, 1, "\(users)")
        XCTAssertTrue(users.allSatisfy { TestHostIsolation.contains(URL(fileURLWithPath: $0), home) }, "\(users)")
    }

    /// 删除根只认「本次构建」的 TARGET_TEMP_DIR/xctest-home（从宿主 app 位置推出来）
    func testExpectedHomeIsDerivedFromHostBundle() throws {
        let bundle = URL(fileURLWithPath: "/u/Library/Developer/Xcode/DerivedData/MP-abc/Build/Products/Debug/记忆花园.app")
        XCTAssertEqual(TestHostIsolation.expectedHome(bundle: bundle)?.path,
                       "/u/Library/Developer/Xcode/DerivedData/MP-abc/Build/Intermediates.noindex/MemoryPalace.build/Debug/MemoryPalace.build/xctest-home")
        XCTAssertNil(TestHostIsolation.expectedHome(bundle: URL(fileURLWithPath: "/Applications/记忆花园.app")))
        XCTAssertEqual(TestHostIsolation.expectedHome(bundle: Bundle.main.bundleURL.resolvingSymlinksInPath())?.path, try home.path)
    }

    func testKeychainQueryMapping() {
        let service = "com.susu.MemoryPalace.xctest-probe"
        let mapped = TestHostIsolation.keychainService(service)
        XCTAssertEqual(mapped, service + TestHostIsolation.keychainSuffix)
        XCTAssertEqual(TestHostIsolation.keychainService(mapped), mapped, "映射要幂等")

        let query = TestHostIsolation.keychainQuery([
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ])
        XCTAssertEqual(query[kSecAttrService as String] as? String, mapped)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)

        for input: Any? in [kSecAttrSynchronizableAny, kCFBooleanFalse!, nil] {
            var raw: [String: Any] = [kSecAttrService as String: service]
            raw[kSecAttrSynchronizable as String] = input
            XCTAssertEqual(TestHostIsolation.keychainQuery(raw)[kSecAttrSynchronizable as String] as? Bool, false, "\(String(describing: input))")
        }
    }

    /// KeychainStore 写进去的条目在原 service 名下找不到（只在加后缀的 service 下）。service 是一次性 UUID，不是她的条目
    func testKeychainStoreWritesUnderSuffixedService() {
        let service = "com.susu.MemoryPalace.xctest-probe.\(UUID().uuidString)"
        let account = "probe"
        defer { KeychainStore.remove(account: account, service: service) }
        XCTAssertTrue(KeychainStore.set("v", account: account, sync: true, service: service))
        XCTAssertEqual(KeychainStore.get(account: account, service: service), "v")

        func status(_ service: String) -> OSStatus {
            let raw: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnAttributes as String: kCFBooleanTrue!,
            ]
            var out: CFTypeRef?
            return SecItemCopyMatching(raw as CFDictionary, &out)
        }
        XCTAssertEqual(status(service), errSecItemNotFound)
        XCTAssertEqual(status(TestHostIsolation.keychainService(service)), errSecSuccess)
    }

    func testNotificationAdapterIsGated() async {
        let center = SystemMedNotificationCenter()
        let before = TestHostIsolation.blockedCount(.notifications)
        let pending = await center.pendingMedIdentifiers()
        XCTAssertEqual(pending, [])
        let status = await center.authorizationStatus()
        XCTAssertEqual(status, .denied)
        let granted = await center.requestAuthorization()
        XCTAssertFalse(granted)
        center.remove(identifiers: ["x"])
        await center.add(ReminderSpec(identifier: "med-xctest-0", title: "t", body: "b", hour: 9, minute: 0))
        // >=：启动链的异步 resync 可能同时打到这个闸；本用例五个入口各自都是在系统调用前 return 的
        XCTAssertGreaterThanOrEqual(TestHostIsolation.blockedCount(.notifications), before + 5)
    }

    @MainActor
    func testHubAndExternalSideEffectsAreGated() {
        let hubBefore = TestHostIsolation.blockedCount(.hub)
        XCTAssertNil(HubTokenStore.get())
        let client = CCBridgeWebSocketClient(dedupDefaults: UserDefaults(suiteName: "mp.xctest.hub.\(UUID().uuidString)")!)
        client.connect(url: URL(string: "ws://127.0.0.1:9/ws")!)
        XCTAssertFalse(client.isConnected)
        XCTAssertGreaterThanOrEqual(TestHostIsolation.blockedCount(.hub), hubBefore + 2)

        let mcpBefore = TestHostIsolation.blockedCount(.mcp)
        MCPProvider.shared.loadAndConnectEnabledServers()
        XCTAssertGreaterThanOrEqual(TestHostIsolation.blockedCount(.mcp), mcpBefore + 1)

        let hookBefore = TestHostIsolation.blockedCount(.ccHook)
        CCThinkingHookInstaller.ensureInstalled()
        XCTAssertGreaterThanOrEqual(TestHostIsolation.blockedCount(.ccHook), hookBefore + 1)

        XCTAssertNil(SubscriptionQuotaService.readKeychainPassword(service: "Claude Code-credentials"))
    }

    /// 名单独立写在测试里（实现删了一个也会红）；真起一个子进程看它继承到的环境
    func testChildProcessEnvironmentIsWashed() throws {
        let home = try home
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var env: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        for name in ["HOME", "ZDOTDIR"] {
            XCTAssertEqual(env[name], home.path, name)
        }
        for name in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"] {
            let value = try XCTUnwrap(env[name], name)
            XCTAssertTrue(TestHostIsolation.contains(URL(fileURLWithPath: value), home), "\(name)=\(value)")
        }
        for name in ["CODEX_HOME", "HERMES_HOME", "OPENCODE_DB", "OPENCLAW_STATE_DIR", "QODER_CONFIG_DIR",
                     "CLAUDE_CONFIG_DIR", "MP_CODE_HOME", "MP_CODE_STATE", "MP_CC_WORKDIR"] {
            XCTAssertNil(env[name], name)
        }
    }
}
