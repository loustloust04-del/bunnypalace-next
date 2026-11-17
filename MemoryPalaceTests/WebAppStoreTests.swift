import XCTest
@testable import 记忆花园

/// plan-webapp-as-file T1 / T2 / T3 / T8：应用 = 文件库里的 html；按层的表、改名 / 外部改名 / 删了、版本历史搬家、老应用搬进文件库。
/// 文件库根、page2 根、版本库都换到临时目录
@MainActor
final class WebAppStoreTests: XCTestCase {
    private var root: URL!
    private var previousLibrary: URL?
    private var previousPage2: URL!
    private let pid = "floor-a"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("webapps-\(UUID().uuidString)", isDirectory: true)
        previousLibrary = FileLibraryStore.testRootOverride
        FileLibraryStore.testRootOverride = root.appendingPathComponent("library", isDirectory: true)
        previousPage2 = WebAppStore.page2Root
        WebAppStore.page2Root = root.appendingPathComponent("Page2", isDirectory: true)
    }

    override func tearDown() async throws {
        FileLibraryStore.testRootOverride = previousLibrary
        WebAppStore.page2Root = previousPage2
        try? FileManager.default.removeItem(at: root)
    }

    private func store() -> WebAppStore {
        let store = WebAppStore()
        store.activate(profileId: pid)
        return store
    }

    private func libraryFile(_ path: String) -> URL { FileLibraryStore.testRootOverride!.appendingPathComponent("\(pid)/\(path)") }

    /// 文件库读写不许在主线程（`MainThreadIOTestObserver` 会判失败）
    private func off<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(operation: body).value
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    // MARK: html

    func testTitlePrefersTitleTagThenH1() {
        XCTAssertEqual(WebAppHTML.title(in: "<html><head><title> 喝水 &amp; 打卡 </title></head><h1>别的</h1>"), "喝水 & 打卡")
        XCTAssertEqual(WebAppHTML.title(in: "<div><h1 class=x>记 <b>账</b></h1></div>"), "记 账")
        XCTAssertNil(WebAppHTML.title(in: "<div>没有标题</div>"))
        XCTAssertNil(WebAppHTML.title(in: "<title>   </title>"))
    }

    func testIconHrefPrefersAppleTouchIcon() {
        let html = """
        <link rel="icon" href="https://a.com/fav.ico">
        <link href='data:image/png;base64,AAAA' rel='apple-touch-icon'>
        """
        XCTAssertEqual(WebAppHTML.iconHref(in: html), "data:image/png;base64,AAAA")
        XCTAssertEqual(WebAppHTML.iconHref(in: "<link rel=\"shortcut icon\" href=\"/f.png\">"), "/f.png")
        XCTAssertNil(WebAppHTML.iconHref(in: "<link rel=\"stylesheet\" href=\"a.css\">"))
    }

    func testDocumentWrapsFragmentsOnly() {
        let full = "<!doctype html><html><body>hi</body></html>"
        XCTAssertEqual(WebAppHTML.document(full, title: "x"), full)
        let wrapped = WebAppHTML.document("<div>hi</div>", title: "A<b")
        XCTAssertTrue(wrapped.contains("name=\"viewport\""))
        XCTAssertTrue(wrapped.contains("<title>A&lt;b</title>"))
        XCTAssertTrue(wrapped.contains("<div>hi</div>"))
    }

    func testToolIDParsingRejectsOthers() {
        let id = UUID()
        XCTAssertEqual(WebAppStore.appID(fromToolID: WebAppStore.toolID(id)), id)
        XCTAssertNil(WebAppStore.appID(fromToolID: "browser"))
        XCTAssertNil(WebAppStore.appID(fromToolID: "webapp.not-a-uuid"))
    }

    func testFileNameCleansUpTitles() {
        XCTAssertEqual(WebAppStore.fileName("  计数/器: "), "计数 器")
        XCTAssertEqual(WebAppStore.fileName(" .. "), WebAppHTML.fallbackTitle)
        XCTAssertEqual(WebAppStore.title(ofPath: "应用/喝水.html"), "喝水")
    }

    // MARK: 放进来

    func testCreateWritesIntoAppsFolderPerFloor() async throws {
        let store = store()
        let app = try await store.create(html: "<div>x</div>", title: " 计数器 ", profileId: pid)
        XCTAssertEqual(app.path, "应用/计数器.html")
        XCTAssertEqual(app.title, "计数器")
        let text = try String(contentsOf: libraryFile(app.path), encoding: .utf8)
        XCTAssertTrue(text.contains("<div>x</div>") && text.contains("<title>计数器</title>"))
        XCTAssertEqual(store.apps.map(\.id), [app.id])
        XCTAssertEqual(WebAppStore.storedApps(profileId: pid).map(\.path), ["应用/计数器.html"])
        XCTAssertTrue(WebAppStore.storedApps(profileId: "floor-b").isEmpty, "别的层看不到")

        let second = try await store.create(html: "<p>y</p>", title: "计数器", profileId: pid)
        XCTAssertEqual(second.path, "应用/计数器-2.html")
    }

    func testAddPointsAtExistingFileWithoutCopying() async throws {
        let store = store()
        let pid = pid
        try await off { try FileLibraryStore.write("工具/记账.html", content: "<!doctype html><title>记账</title>", profileId: pid) }
        let app = try await store.add(path: "工具/记账.html", profileId: pid)
        XCTAssertEqual(app.path, "工具/记账.html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryFile("应用").path), "不拷")
        let again = try await store.add(path: "工具/记账.html", profileId: pid)
        XCTAssertEqual(again.id, app.id, "同一个文件只登记一次")
        do {
            try await off { try FileLibraryStore.write("笔记.md", content: "x", profileId: pid) }
            _ = try await store.add(path: "笔记.md", profileId: pid)
            XCTFail("md 不能放到桌面")
        } catch {}
    }

    // MARK: 改名 / 删 / 写

    func testRenameInLibraryFollowsAndRenamedOutsideIsFoundByHash() async throws {
        let store = store()
        let app = try await store.create(html: "<div>喝水</div>", title: "喝水", profileId: pid)

        let pid = pid
        try await off { try FileLibraryStore.rename(app.path, to: "应用/每天喝水.html", profileId: pid) }
        await eventually { store.app(app.id)?.path == "应用/每天喝水.html" }
        XCTAssertEqual(store.app(app.id)?.title, "每天喝水")

        // 「文件」App 里改名：文件库收不到通知，打开时按内容找回
        try FileManager.default.moveItem(at: libraryFile("应用/每天喝水.html"), to: libraryFile("喝水打卡.html"))
        let url = await store.fileURL(app.id)
        XCTAssertEqual(url?.lastPathComponent, "喝水打卡.html")
        XCTAssertEqual(WebAppStore.storedApps(profileId: pid).first?.path, "喝水打卡.html")
    }

    func testDeletedFileVanishesOnce() async throws {
        let store = store()
        let app = try await store.create(html: "<div>a</div>", title: "番茄", profileId: pid)
        var vanished: [UUID] = []
        let token = NotificationCenter.default.addObserver(forName: .webAppDidVanish, object: nil, queue: .main) { note in
            if let gone = note.object as? WebApp { MainActor.assumeIsolated { vanished.append(gone.id) } }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try await store.remove(app.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryFile(app.path).path))
        XCTAssertNil(store.app(app.id))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(vanished, [app.id], "自己删 + 文件库删除通知，只清一次")
    }

    func testMissingFileWithNoMatchVanishes() async throws {
        let store = store()
        let app = try await store.create(html: "<div>a</div>", title: "没了", profileId: pid)
        try FileManager.default.removeItem(at: libraryFile(app.path))
        let url = await store.fileURL(app.id)
        XCTAssertNil(url)
        XCTAssertTrue(WebAppStore.storedApps(profileId: pid).isEmpty)
    }

    func testWritingTheFileBumpsRevision() async throws {
        let store = store()
        let app = try await store.create(html: "<div>1</div>", title: "计数", profileId: pid)
        XCTAssertEqual(store.revisions[app.id] ?? 0, 0)
        let pid = pid
        try await off { try FileLibraryStore.write(app.path, content: "<div>2</div>", profileId: pid) }
        await eventually { store.revisions[app.id] == 1 }
        let hash = try await off { FileLibraryStore.contentHash(app.path, profileId: pid) }
        XCTAssertEqual(store.app(app.id)?.sha256, hash)
    }

    func testRegisteredOnAnyFloor() async throws {
        let store = store()
        let app = try await store.create(html: "<div>a</div>", title: "x", profileId: pid)
        XCTAssertTrue(WebAppStore.isRegisteredOnAnyFloor(app.id))
        XCTAssertFalse(WebAppStore.isRegisteredOnAnyFloor(UUID()))
    }

    // MARK: 版本历史跟着改名走

    func testVersionHistoryMovesAndMerges() async throws {
        let versions = FileVersionStore(root: root.appendingPathComponent("versions", isDirectory: true))
        let old = FileVersionStore.Key.file(profileId: pid, relativePath: "a.md")
        let new = FileVersionStore.Key.file(profileId: pid, relativePath: "b.md")
        _ = try await versions.record(key: old, content: "一", source: .manualSave, date: Date(timeIntervalSince1970: 100))
        _ = try await versions.record(key: old, content: "二", source: .manualSave, date: Date(timeIntervalSince1970: 300))
        _ = try await versions.record(key: new, content: "旧的 b", source: .manualSave, date: Date(timeIntervalSince1970: 200))

        try await versions.move(from: old, to: new)
        let moved = try await versions.versions(key: new)
        XCTAssertEqual(moved.map(\.date.timeIntervalSince1970), [300, 200, 100], "按时间合在一起（新→旧）")
        let newest = try await versions.content(key: new, id: moved[0].id)
        XCTAssertEqual(newest, "二")
        let gone = try await versions.versions(key: old)
        XCTAssertTrue(gone.isEmpty)
        try await versions.move(from: old, to: new)
    }

    func testVersionPathNormalizesLikeThePanel() async throws {
        let pid = pid
        let inside = try await off { FileLibraryTools.versionPath(" ./应用/../应用/喝水.html ", profileId: pid) }
        let outside = try await off { FileLibraryTools.versionPath("../外面.html", profileId: pid) }
        XCTAssertEqual(inside, "应用/喝水.html")
        XCTAssertNil(outside)
    }

    // MARK: 老应用搬进文件库

    private func legacyApp(_ dir: URL, id: UUID, title: String, current: String, versions: [(String, String, Date)]) throws {
        let folder = dir.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("versions"), withIntermediateDirectories: true)
        try current.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        var list: [[String: Any]] = []
        for (n, (text, by, at)) in versions.enumerated() {
            try text.write(to: folder.appendingPathComponent("versions/v\(n).html"), atomically: true, encoding: .utf8)
            list.append(["id": "v\(n)", "at": at.timeIntervalSinceReferenceDate, "by": by, "note": ""])
        }
        try JSONSerialization.data(withJSONObject: list).write(to: folder.appendingPathComponent("versions/versions.json"))
    }

    private func legacyList(_ dir: URL, _ apps: [(UUID, String)]) throws {
        let list = apps.map { ["id": $0.0.uuidString, "title": $0.1, "createdAt": 0, "revision": 1] as [String: Any] }
        try JSONSerialization.data(withJSONObject: list).write(to: dir.appendingPathComponent("webapps.json"))
    }

    private func layout(_ floor: String?, showing toolIDs: [String]) throws {
        let page2 = WebAppStore.page2Root
        let url = floor.map { page2.appendingPathComponent("floors/\($0)/home-layout-v1.json") } ?? page2.appendingPathComponent("home-layout-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["items": toolIDs.map { ["kind": "app", "toolID": $0] }]).write(to: url)
    }

    func testMigrationMovesAppsWithHistoryIntoEachFloorThatShowsThem() async throws {
        let legacy = root.appendingPathComponent("WebApps", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let water = UUID(), loose = UUID()
        try legacyApp(legacy, id: water, title: "喝水", current: "<p>6 杯</p>", versions: [
            ("<p>8 杯</p>", "", Date(timeIntervalSinceReferenceDate: 10)),
            ("<p>6 杯</p>", "AI", Date(timeIntervalSinceReferenceDate: 20)),
        ])
        try legacyApp(legacy, id: loose, title: "没摆", current: "<p>x</p>", versions: [])
        try legacyList(legacy, [(water, "喝水"), (loose, "没摆")])
        try layout(pid, showing: [WebAppStore.toolID(water)])
        try layout("floor-b", showing: [WebAppStore.toolID(water)])
        let versions = FileVersionStore(root: root.appendingPathComponent("versions", isDirectory: true))

        let done = await WebAppMigration.migrate(from: legacy, currentProfileId: pid, page2Root: WebAppStore.page2Root, versions: versions)
        XCTAssertTrue(done)
        for floor in [pid, "floor-b"] {
            let app = try XCTUnwrap(WebAppStore.storedApps(profileId: floor).first { $0.id == water }, floor)
            XCTAssertEqual(app.path, "应用/喝水.html")
            let text = try await off { try FileLibraryStore.read(app.path, profileId: floor) }
            XCTAssertEqual(text, "<p>6 杯</p>")
            let history = try await versions.versions(key: .file(profileId: floor, relativePath: app.path))
            XCTAssertEqual(history.count, 2, "8 杯 → 6 杯（现在这版和最后一版一样，不重复记）")
            XCTAssertEqual(history.first?.actor, "AI")
        }
        XCTAssertEqual(WebAppStore.storedApps(profileId: pid).map(\.title).sorted(), ["喝水", "没摆"], "哪层都没摆的进当前层")
        XCTAssertFalse(WebAppStore.storedApps(profileId: "floor-b").contains { $0.id == loose })

        // 再跑一遍（老备份又导回来 / 上次中途失败）：不重复
        _ = await WebAppMigration.migrate(from: legacy, currentProfileId: pid, page2Root: WebAppStore.page2Root, versions: versions)
        XCTAssertEqual(WebAppStore.storedApps(profileId: pid).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryFile("应用/喝水-2.html").path))
    }

    /// sim 实测出的：同名同内容的两个应用（装了两遍）各要各的文件，不能指到同一个
    func testMigrationGivesTwinAppsTheirOwnFiles() async throws {
        let legacy = root.appendingPathComponent("WebApps", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let a = UUID(), b = UUID()
        try legacyApp(legacy, id: a, title: "喝水", current: "<p>同一份</p>", versions: [])
        try legacyApp(legacy, id: b, title: "喝水", current: "<p>同一份</p>", versions: [])
        try legacyList(legacy, [(a, "喝水"), (b, "喝水")])
        let versions = FileVersionStore(root: root.appendingPathComponent("versions", isDirectory: true))

        let done = await WebAppMigration.migrate(from: legacy, currentProfileId: pid, page2Root: WebAppStore.page2Root, versions: versions)
        XCTAssertTrue(done)
        XCTAssertEqual(Set(WebAppStore.storedApps(profileId: pid).map(\.path)), ["应用/喝水.html", "应用/喝水-2.html"])
        _ = await WebAppMigration.migrate(from: legacy, currentProfileId: pid, page2Root: WebAppStore.page2Root, versions: versions)
        XCTAssertEqual(WebAppStore.storedApps(profileId: pid).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryFile("应用/喝水-3.html").path))
    }

    func testMigrationUsesDefaultLayoutWhenCurrentFloorHasNone() throws {
        try layout(nil, showing: ["webapp.x"])
        XCTAssertEqual(WebAppMigration.floors(showing: "webapp.x", page2Root: WebAppStore.page2Root, current: pid), [pid])
        try layout("floor-b", showing: ["webapp.x"])
        XCTAssertEqual(WebAppMigration.floors(showing: "webapp.x", page2Root: WebAppStore.page2Root, current: pid), ["floor-b", pid])
        XCTAssertEqual(WebAppMigration.floors(showing: "webapp.y", page2Root: WebAppStore.page2Root, current: pid), [pid])
    }
}
