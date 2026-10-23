#if os(macOS)
import XCTest
@testable import 记忆花园

/// N5-a0（N3 缺陷回归）：SQLite 家的会话存 `库#id` 虚拟路径，adapter.fileRef 认不了——详情 / 导出必须经 `CodingSessionFileRef.fromMeta` 读到
@MainActor
final class CodingVirtualPathDetailTests: XCTestCase {
    private var dir: URL!
    private var home: URL { dir.appendingPathComponent("home") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-virtual-detail-\(UUID().uuidString)")
        let db = home.appendingPathComponent(".copilot/session-store.db")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        CodingContract.execSQL(db, CopilotAdapterContractTests.fixtureSQL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSQLiteSessionDetailAndExportLoad() async throws {
        let state = CodingSessionState(url: dir.appendingPathComponent("state.json"))
        let indexURL = dir.appendingPathComponent("index.sqlite")
        let library = CodingSessionLibrary(indexURL: indexURL, adapters: [CopilotAdapter(home: home)], state: state)
        await library.refresh()?.value
        let meta = try XCTUnwrap(CodingSessionIndex(url: indexURL).session(key: "copilot:cop-0001"))
        XCTAssertTrue(meta.filePath.contains("#cop-0001"), "Copilot 存的是虚拟路径：\(meta.filePath)")
        XCTAssertNil(CopilotAdapter(home: home).fileRef(URL(fileURLWithPath: meta.filePath)), "前提：adapter.fileRef 认不了虚拟路径")

        let ref = try XCTUnwrap(CodingSessionFileRef.fromMeta(meta))
        XCTAssertEqual(ref.nativeId, "cop-0001")
        XCTAssertEqual(ref.filePath, meta.filePath)

        library.select(meta.key)
        for _ in 0..<60 {
            if case .loaded = library.detail { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .loaded(let box) = library.detail else { return XCTFail("SQLite 会话详情没落地：\(library.detail)") }
        XCTAssertEqual(box.transcript.meta.title, "Copilot QR fix")

        let markdown = try CodingSessionExport.render(adapter: CopilotAdapter(home: home), meta: meta)
        XCTAssertTrue(markdown.contains("Copilot QR fix"), "导出同样要读到")

        // 底层库文件没了：回 nil（详情照旧报「会话文件不见了」）
        try FileManager.default.removeItem(at: home.appendingPathComponent(".copilot/session-store.db"))
        XCTAssertNil(CodingSessionFileRef.fromMeta(meta))
    }
}
#endif
