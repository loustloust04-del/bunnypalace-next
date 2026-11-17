import XCTest
import SwiftData
@testable import 记忆花园

/// iOS 真机 live（10-17 规矩：每轮下发的 tools 变了就 😷 真跑）。11-16 起（plan-webapp-as-file）只剩 garden_app_add，改应用走文件工具：
/// 1. 带上 iOS 整套设备工具问「做个计数器放桌面」，看 Haiku 按 schema 调 garden_app_add（title + 完整 html），真执行：
///    文件落在这一层文件库 `应用/`、进了表、生成图标，最后删掉（文件跟着删）。
/// 2. 桌面上已有「计数」（文件库 `应用/计数.html`），带上设备工具 + 文件工具让它改成 +2，看它用 fs_edit / fs_write 改那个文件，
///    真执行：文件变了、存数据的键名没改、版本历史里有改之前和改之后（署名助手名）、开着的应用会刷新（revision +1）。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头。
@MainActor
final class WebAppLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?
    private var model: ProviderModel?
    private let profileId = "xctest-webapp-live"

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "WebAppLive", code: 1, userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()

        let manager = ProviderManager()
        let id = "xctest-webapp-live-ios-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        manager.addCredential(APICredential(
            id: id, name: "WebApp Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        self.manager = manager
        self.model = model
        credentialId = id
        WebAppStore.shared.activate(profileId: profileId)
    }

    override func tearDown() async throws {
        CatalogLiveAuthProtocol.onOutgoingBody = nil
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        model = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    func testLiveHaikuCallsGardenAppAddAndInstallsOnDevice() async throws {
        let manager = try XCTUnwrap(manager), model = try XCTUnwrap(model)
        let defs = DeviceToolDispatcher.definitions
        XCTAssertTrue(defs.contains { $0.name == WebAppTools.addName }, "iOS 设备工具里要有 garden_app_add")

        var bodies: [Data] = []
        CatalogLiveAuthProtocol.onOutgoingBody = { bodies.append($0) }
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("webapp-live-ios-\(UUID().uuidString).jsonl"))
        var calls: [ToolCallBlock] = []
        var failure: String?
        let done = expectation(description: "tool")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "帮我做个特别简单的计数器放到我的花园桌面上，名字叫计数，一个大数字和一个 +1 按钮，数字存 localStorage。")],
            systemPrompt: "你是她的朋友小岚，在她的手机里，可以用工具。",
            providerManager: manager,
            samplingParams: SamplingParams(),
            tools: defs.map(ToolSchemaRenderer.anthropic),
            onToken: { _ in },
            onComplete: { _, _ in failure = "模型没调工具，直接回话了"; done.fulfill() },
            onError: { message in failure = message; done.fulfill() },
            onToolCalls: { blocks, _ in calls = blocks; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 180)
        if let failure { XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
        let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("\"name\":\"garden_app_add\""), "请求的 tools 里带着 garden_app_add")

        let call = try XCTUnwrap(calls.first { $0.name == WebAppTools.addName }, "要调 garden_app_add（实际：\(calls.map(\.name))）")
        let args = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        let html = try XCTUnwrap(args["html"] as? String)
        let title = try XCTUnwrap(args["title"] as? String)
        print("[WEBAPP-LIVE-IOS] tool: name=\(call.name) title=\(title) html=\(html.count)字 viewport=\(html.contains("viewport")) localStorage=\(html.contains("localStorage"))")
        XCTAssertTrue(html.lowercased().contains("<html") || html.lowercased().contains("<!doctype"), "按描述给完整 html")
        XCTAssertTrue(html.contains("localStorage"))

        // 这次调用真执行：落盘、出图标、进列表
        let before = Set(WebAppStore.shared.apps.map(\.id))
        let result = await DeviceToolDispatcher.execute(name: call.name, inputJSON: call.argumentsJSON, profileId: "", conversationId: "webapp-live")
        print("[WEBAPP-LIVE-IOS] exec: isError=\(result.isError) text=\(result.text.prefix(80))")
        XCTAssertFalse(result.isError)
        let added = try XCTUnwrap(WebAppStore.shared.apps.first { !before.contains($0.id) })
        XCTAssertEqual(added.title, WebAppStore.fileName(title))
        XCTAssertTrue(added.path.hasPrefix("\(WebAppStore.folderName)/"), "新应用落在文件库「应用」里：\(added.path)")
        let saved = try await Task.detached { [profileId] in try FileLibraryStore.read(added.path, profileId: profileId) }.value
        XCTAssertTrue(saved.contains("localStorage"))
        XCTAssertNotNil(Page2AppearanceStore.shared.value.icons[added.toolID]?.imageFile, "生成了默认图标")
        try await WebAppInstaller.delete(added)
        XCTAssertNil(WebAppStore.shared.app(added.id))
        let fileLeft = await Task.detached { [profileId] in FileLibraryStore.exists(added.path, profileId: profileId) }.value
        XCTAssertFalse(fileLeft, "删应用 = 删文件")
    }

    /// 改应用 = 改文件（plan-webapp-as-file §2.7）：桌面上已有「计数」，把 fs_list + fs_read 的结果直接给它，
    /// 看它用 fs_edit / fs_write 改 `应用/计数.html`；真执行后文件变了、版本历史有前后两版（后一版署名助手）、revision +1
    func testLiveHaikuEditsAppFileOnDevice() async throws {
        let manager = try XCTUnwrap(manager), model = try XCTUnwrap(model)
        let original = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>计数</title></head>
        <body><div id="n">0</div><button id="b">+1</button>
        <script>const k='count';const n=document.getElementById('n');n.textContent=localStorage.getItem(k)||'0';
        document.getElementById('b').onclick=()=>{const v=(+localStorage.getItem(k)||0)+1;localStorage.setItem(k,v);n.textContent=v;};</script></body></html>
        """
        let app = try await WebAppStore.shared.create(html: original, title: "计数", profileId: profileId)
        defer { Task { @MainActor in try? await WebAppInstaller.delete(app) } }
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        func fileTool(_ name: String, _ json: String) async -> FileLibraryTools.Result {
            await FileLibraryTools.run(name: name, inputJSON: json, profileId: profileId, userName: "她", actor: "小岚",
                                       conversationId: "webapp-live-edit", memoryEnabled: false, via: "chat", context: context)
        }
        let listing = await fileTool("fs_list", "{}")
        let source = await fileTool("fs_read", "{\"path\":\"\(app.path)\"}")
        XCTAssertTrue(listing.text.contains("桌面应用：计数"), "fs_list 标出桌面应用：\(listing.text.prefix(200))")
        XCTAssertFalse(source.isError)

        let tools = (DeviceToolDispatcher.definitions + FileLibraryTools.definitions).map(ToolSchemaRenderer.anthropic)
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("webapp-live-ios-update-\(UUID().uuidString).jsonl"))
        var calls: [ToolCallBlock] = []
        var failure: String?
        let done = expectation(description: "update")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: """
            把我桌面上的「计数」改成每次点按钮 +2，按钮上的字也改成 +2。我以前存的数别丢。
            （你刚才查到的：）
            fs_list →
            \(listing.text)
            fs_read \(app.path) →
            \(source.text)
            """)],
            systemPrompt: "你是她的朋友小岚，在她的手机里，可以用工具。",
            providerManager: manager,
            samplingParams: SamplingParams(),
            tools: tools,
            onToken: { _ in },
            onComplete: { _, _ in failure = "模型没调工具，直接回话了"; done.fulfill() },
            onError: { message in failure = message; done.fulfill() },
            onToolCalls: { blocks, _ in calls = blocks; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 180)
        if let failure { XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
        let edits = calls.filter { ["fs_edit", "fs_write", WebAppTools.editName].contains($0.name) }
        XCTAssertFalse(edits.isEmpty, "要用 fs_edit / fs_write / garden_app_edit 改（实际：\(calls.map(\.name))）")
        XCTAssertFalse(calls.contains { $0.name == WebAppTools.addName }, "改应用别再放一个新的")
        for call in edits {
            let isError: Bool
            if call.name == WebAppTools.editName {
                let result = await DeviceToolDispatcher.execute(name: call.name, inputJSON: call.argumentsJSON, profileId: "", conversationId: "webapp-live-edit")
                print("[WEBAPP-LIVE-IOS] edit: tool=\(call.name) isError=\(result.isError) text=\(result.text.prefix(60))")
                isError = result.isError
            } else {
                let args = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
                let path = args["path"] as? String
                let normalized = await Task.detached { [profileId] in path.flatMap { FileLibraryTools.versionPath($0, profileId: profileId) } }.value
                XCTAssertEqual(normalized, app.path)
                let result = await fileTool(call.name, call.argumentsJSON)
                print("[WEBAPP-LIVE-IOS] edit: tool=\(call.name) isError=\(result.isError) text=\(result.text.prefix(60))")
                isError = result.isError
            }
            XCTAssertFalse(isError)
        }
        let after = try await Task.detached { [profileId] in try FileLibraryStore.read(app.path, profileId: profileId) }.value
        print("[WEBAPP-LIVE-IOS] after: \(after.count)字 plus2=\(after.contains("+2")) keepsKey=\(after.contains("'count'") || after.contains("\"count\""))")
        XCTAssertNotEqual(after, original)
        XCTAssertTrue(after.contains("+2"))
        XCTAssertTrue(after.contains("'count'") || after.contains("\"count\""), "存数据的键名没改")
        let history = try await FileVersionStore.shared.versions(key: .file(profileId: profileId, relativePath: app.path))
        XCTAssertGreaterThanOrEqual(history.count, 2, "改之前 + 改之后")
        XCTAssertNotNil(history.first?.actor, "改后那版署名助手")
        for _ in 0..<50 where (WebAppStore.shared.revisions[app.id] ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(WebAppStore.shared.revisions[app.id] ?? 0, 1, "开着的应用会刷新")
    }

    /// Air 上 11-16 第二次：搬完代码它跟她说「两个应用读的是同一份存档（键名一样）」——错的，每个应用的存储各自一份。
    /// 带上工具描述问它，回答里要说清楚不是同一份
    func testLiveHaikuKnowsAppsHaveSeparateStorage() async throws {
        let manager = try XCTUnwrap(manager), model = try XCTUnwrap(model)
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("webapp-live-ios-storage-\(UUID().uuidString).jsonl"))
        var reply = ""
        var failure: String?
        let done = expectation(description: "reply")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "我桌面上有「年轮」和「年轮-2」两个应用，代码一模一样，存记录都用 localStorage 的 nianlun.entries.v1 这个键。它们存的是不是同一份？我直接删掉年轮-2，里面记的东西还在吗？直接回答，不用调工具。")],
            systemPrompt: "你是她的朋友小岚，在她的手机里，可以用工具。",
            providerManager: manager, samplingParams: SamplingParams(),
            tools: DeviceToolDispatcher.definitions.map(ToolSchemaRenderer.anthropic),
            onToken: { reply += $0 },
            onComplete: { _, _ in done.fulfill() },
            onError: { message in failure = message; done.fulfill() },
            onToolCalls: { blocks, _ in failure = "不该调工具：\(blocks.map(\.name))"; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 180)
        if let failure { return XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
        print("[WEBAPP-LIVE-IOS] storage reply: \(reply.prefix(200).replacingOccurrences(of: "\n", with: " "))")
        let separate = ["不是同一份", "各自", "独立", "分开", "不共用", "不是一份", "各存各", "读不到"].contains { reply.contains($0) }
        XCTAssertTrue(separate, "要说清楚两个应用的存储是分开的：\(reply.prefix(200))")
    }

    /// Air 上 11-16 出的事：那一层文件库权限关着（手里没有 fs 工具），让它改桌面上的应用，它只能再放一个新的「年轮-2」。
    /// 现在只带设备工具（没有 fs_*），要它用 garden_app_read / garden_app_edit 原地改，别再放新的
    func testLiveHaikuEditsAppWithoutFileTools() async throws {
        let manager = try XCTUnwrap(manager), model = try XCTUnwrap(model)
        let original = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>年轮</title></head>
        <body><h1>年轮</h1><button id="b">记一笔</button><ul id="l"></ul>
        <script>const k='rings';const l=document.getElementById('l');const all=JSON.parse(localStorage.getItem(k)||'[]');
        const draw=()=>{l.innerHTML=all.map(x=>'<li>'+x+'</li>').join('')};draw();
        document.getElementById('b').onclick=()=>{all.push(new Date().toLocaleString());localStorage.setItem(k,JSON.stringify(all));draw();};</script></body></html>
        """
        let app = try await WebAppStore.shared.create(html: original, title: "年轮", profileId: profileId)
        defer { Task { @MainActor in try? await WebAppInstaller.delete(app) } }
        let before = Set(WebAppStore.shared.apps.map(\.id))
        let tools = DeviceToolDispatcher.definitions
        XCTAssertFalse(tools.contains { $0.name.hasPrefix("fs_") }, "这条测的就是没有文件工具")
        XCTAssertTrue(tools.contains { $0.name == WebAppTools.editName })

        var messages: [(role: String, content: String)] = [(role: "user", content: "把我桌面上的「年轮」改一下：标题改成「我的年轮」，按钮字改成「切一刀」。我记的东西别丢。")]
        var edited = false
        var finished = false
        // 它可能分几次改（先改标题、再改按钮）：一直喂回结果，直到它不再调工具、直接回话
        for round in 0..<6 where !finished {
            let router = ProviderRouter()
            router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("webapp-live-ios-nofs-\(UUID().uuidString).jsonl"))
            var calls: [ToolCallBlock] = []
            var failure: String?
            let done = expectation(description: "round \(round)")
            router.sendStreaming(
                model: model, messages: messages,
                systemPrompt: "你是她的朋友小岚，在她的手机里，可以用工具。",
                providerManager: manager, samplingParams: SamplingParams(),
                tools: tools.map(ToolSchemaRenderer.anthropic),
                onToken: { _ in },
                onComplete: { [edited] _, _ in
                    if edited { finished = true } else { failure = "模型没调工具，直接回话了" }
                    done.fulfill()
                },
                onError: { message in failure = message; done.fulfill() },
                onToolCalls: { blocks, _ in calls = blocks; done.fulfill() }
            )
            await fulfillment(of: [done], timeout: 180)
            if let failure { return XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
            print("[WEBAPP-LIVE-IOS] nofs round \(round): \(calls.map(\.name))")
            XCTAssertFalse(calls.contains { $0.name == WebAppTools.addName }, "改应用别再放一个新的")
            // 下一轮把这轮的调用和结果当文字喂回去（测试里不走真对话循环）
            var log = ""
            for call in calls {
                let result = await DeviceToolDispatcher.execute(name: call.name, inputJSON: call.argumentsJSON, profileId: "", conversationId: "webapp-live-nofs")
                print("[WEBAPP-LIVE-IOS] nofs exec: tool=\(call.name) isError=\(result.isError) text=\(result.text.prefix(60))")
                if call.name == WebAppTools.editName { XCTAssertFalse(result.isError); edited = edited || !result.isError }
                log += "\(call.name)(\(call.argumentsJSON.prefix(200))) →\n\(result.text)\n"
            }
            messages += [(role: "assistant", content: "（我刚调了工具）"), (role: "user", content: "（工具结果）\n\(log)\n继续。")]
        }
        XCTAssertTrue(edited, "要调 garden_app_edit 原地改")
        XCTAssertEqual(Set(WebAppStore.shared.apps.map(\.id)), before, "没多出新应用")
        let after = try await Task.detached { [profileId] in try FileLibraryStore.read(app.path, profileId: profileId) }.value
        print("[WEBAPP-LIVE-IOS] nofs after: title=\(after.contains("我的年轮")) button=\(after.contains("切一刀")) keepsKey=\(after.contains("'rings'"))")
        XCTAssertTrue(after.contains("切一刀"))
        XCTAssertTrue(after.contains("'rings'") || after.contains("\"rings\""), "存数据的键名没改")
        let history = try await FileVersionStore.shared.versions(key: .file(profileId: profileId, relativePath: app.path))
        XCTAssertGreaterThanOrEqual(history.count, 2, "改之前 + 改之后")
    }
}
