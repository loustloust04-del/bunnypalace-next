import XCTest
@testable import 记忆花园

/// 小芽引擎单例（plan-onboarding-xiaoya-impl P1b）：全 App 一个 shared；注入 init 只读写自己的文件，不碰真实 AssistantChat/
@MainActor
final class AssistantEngineSharedTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private let suite = "xiaoya-shared-tests-\(UUID().uuidString)"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xiaoya-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    /// 注意：碰 shared 会按真实路径读写（@Observable 下 init 里给 messages 赋值也会触发 didSet → 存一次）。
    /// 测试宿主的家目录已改道到 xctest-home（project.yml CFFIXED_USER_HOME），落不到粟粟的真实 AssistantChat/
    func testSharedIsOneInstance() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.isEmpty == false, "没改道家目录就别碰 shared")
        let a = AssistantEngine.shared
        XCTAssertTrue(a === AssistantEngine.shared)
        let injected = AssistantEngine(store: AssistantChatStore(fileURL: dir.appendingPathComponent("history.json")),
                                       ledger: AssistantLedger(fileURL: dir.appendingPathComponent("ledger.json")),
                                       packDefaults: defaults)
        XCTAssertFalse(injected === a)
    }

    func testInjectedEngineWritesOnlyItsOwnFile() async throws {
        let real = AssistantChatStore.defaultURL
        let realStamp = { (try? FileManager.default.attributesOfItem(atPath: real.path))?[.modificationDate] as? Date }
        let before = realStamp()

        let store = AssistantChatStore(fileURL: dir.appendingPathComponent("history.json"))
        XCTAssertNotEqual(store.fileURL.standardizedFileURL.path, real.standardizedFileURL.path)
        let engine = AssistantEngine(store: store, ledger: AssistantLedger(fileURL: dir.appendingPathComponent("ledger.json")),
                                     packDefaults: defaults)
        engine.messages.append(AssistantChatMessage(isUser: true, text: "只写临时目录"))

        // scheduleSave：0.5 s 合并 + 后台写
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: store.fileURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.load().map(\.text), ["只写临时目录"])
        XCTAssertEqual(realStamp(), before, "真实 history.json 不该被注入的引擎写到")
    }
}
