import XCTest
@testable import 记忆花园

/// v5 Q4：「用户画像 · 做梦聚合」整个下线——不写、不注、画像文件留着不动
@MainActor
final class ProfileRetiredTests: XCTestCase {

    private var harness: PromptRealPathHarness?
    private let pid = "xctest-profile-retired"

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        let pid = pid
        await Task.detached {
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        }.value
    }

    func testNotInjectedEvenWhenSwitchOnAndFileStays() async throws {
        let pid = pid
        let file = await Task.detached { () -> URL in
            let url = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent("profile.md")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("---\nsourceCount: 3\n---\n粟粟是独立开发者（画像正文）".utf8).write(to: url)
            return url
        }.value
        let h = try await PromptRealPathHarness.make(PromptScenario(name: "profile-retired", profileId: pid))
        harness = h
        h.overrideDefault("mem_inject_profile", true)
        h.overrideDefault("mem_content_profile", true)
        let body = try await h.regenerateCapturingBody()
        let text = try h.canonical(body, droppingTools: true)
        XCTAssertFalse(text.contains("[用户画像]"), "她开着画像注入也不再注")
        XCTAssertFalse(text.contains("画像正文"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "画像文件不动")
    }

    func testNoDreamWritersOrWarnings() {
        XCTAssertNil(MemoryWriterID(health: .dream), "画像不进日志 / 状态卡")
        XCTAssertFalse(MemoryHealthStatusView.lines.contains { $0.0 == .dream }, "状态卡「写画像」那行删了")
        XCTAssertFalse(SettingsRoute.memoryWriter(.b3) != nil, "B3 是还没做的「做梦」，不是原画像")
    }
}
