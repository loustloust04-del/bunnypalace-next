import XCTest
import WebKit
@testable import 记忆花园

/// 卡库第二批 B1 + B2：脚本数两种形态 / 缓存失效、纯前端卡判定、不支持功能扫描、CDN 改写、CSP 拼装、lib 白名单 handler。
/// 全部临时目录 / 临时 suite，不碰 app 存储
@MainActor
final class CardWebPolicyTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("b12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "CardWebPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private var blobs: URL { dir.appendingPathComponent("blobs") }
    private var library: URL { dir.appendingPathComponent("cardlibrary") }

    private func card(extensions: [String: Any], greetings: [String] = ["你好"]) throws -> CharacterCard {
        var data: [String: Any] = ["name": "合成", "first_mes": greetings[0], "extensions": extensions]
        if greetings.count > 1 { data["alternate_greetings"] = Array(greetings.dropFirst()) }
        let raw = try JSONSerialization.data(withJSONObject: ["spec": "chara_card_v2", "data": data], options: [.sortedKeys])
        return CharacterCard(from: try TavernCard.parseJSON(data: raw))
    }

    private func script(_ content: String) -> [String: Any] { ["type": "script", "name": "s", "content": content] }

    // MARK: - B1 脚本数

    func testScriptCountReadsBothShapesAndPrefersNewKey() throws {
        XCTAssertEqual(try card(extensions: ["tavern_helper": ["scripts": [script("a"), script("b")]]]).scriptCount, 2, "字典形态")
        let pairs: [Any] = [["scripts", [script("a"), script("b"), script("c")]], ["variables", [String: Any]()]]
        XCTAssertEqual(try card(extensions: ["tavern_helper": pairs]).scriptCount, 3, "键值对数组形态")
        let both: [String: Any] = ["tavern_helper": [["scripts", [script("新")]]], "TavernHelper_scripts": [script("旧1"), script("旧2"), script("旧3")]]
        let preferNew = try card(extensions: both)
        XCTAssertEqual(preferNew.scriptCount, 1, "有新键就忽略旧键")
        XCTAssertEqual(preferNew.helperScriptSources, ["新"])
        XCTAssertEqual(try card(extensions: ["TavernHelper_scripts": [script("旧1"), script("旧2")]]).scriptCount, 2, "只有旧键")
        let folder: [String: Any] = ["type": "folder", "name": "f", "scripts": [script("x"), script("y")]]
        let tree = try card(extensions: ["tavern_helper": ["scripts": [folder, script("z")]]])
        XCTAssertEqual(tree.scriptCount, 3, "文件夹按里面的脚本数")
        XCTAssertEqual(tree.helperScriptSources, ["x", "y", "z"])
        XCTAssertEqual(try card(extensions: ["tavern_helper": [["variables", [String: Any]()]]]).scriptCount, 0)
    }

    /// B1 前的 blob：脚本数缓存是旧算法（键值对数组算 0）、没有版本号 → 解码丢掉、启动重算一次写回，再开是空操作；
    /// 撤回的旧首次 hash 仍认得出没改过
    func testStaleScriptCountCacheIsRecomputedOnceAndRetractStillMatches() throws {
        let pairs: [Any] = [["scripts", [script("a"), script("b"), script("c")]]]
        let manager = CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults)
        var fresh = try card(extensions: ["tavern_helper": pairs])
        fresh.id = "pairs-card"
        try manager.add(fresh)
        let stored = try XCTUnwrap(manager.cards.first)
        XCTAssertEqual(stored.originals.scriptCount, 3)
        let current = String(decoding: try Data(contentsOf: blobs.appendingPathComponent("savedCharacterCards")), as: UTF8.self)
        XCTAssertTrue(current.contains("\"scriptCount\":3"))
        XCTAssertTrue(current.contains("\"scriptCountVersion\":2"))

        // 伪造 B1 前写的 blob：同一张卡，缓存 0、无版本号（blob 不排序键，版本号可能在前也可能在后）
        let legacy = Self.dropVersion(current.replacingOccurrences(of: "\"scriptCount\":3", with: "\"scriptCount\":0"))
        XCTAssertFalse(legacy.contains("scriptCountVersion"))
        try BlobStore.set(Data(legacy.utf8), forKey: "savedCharacterCards", root: blobs)
        let decoded = try JSONDecoder().decode([CharacterCard].self, from: Data(legacy.utf8))
        XCTAssertNil(decoded[0].originals.scriptCount, "版本对不上的缓存解码时丢掉")
        // B1 前导入时记下的首次 hash（单卡、sortedKeys 编码）
        let oneLegacy = try XCTUnwrap(String(decoding: try CardLibraryStorage.encoder.encode(stored), as: UTF8.self)
            .replacingOccurrences(of: "\"scriptCount\":3", with: "\"scriptCount\":0")
            .replacingOccurrences(of: ",\"scriptCountVersion\":2", with: "").data(using: .utf8))
        XCTAssertFalse(String(decoding: oneLegacy, as: UTF8.self).contains("scriptCountVersion"))
        let preB1Hash = CardLibraryStorage.sha256(oneLegacy)

        let reopened = CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults)
        let loaded = try XCTUnwrap(reopened.cards.first)
        XCTAssertEqual(loaded.scriptCount, 3, "重算")
        let rewritten = try Data(contentsOf: blobs.appendingPathComponent("savedCharacterCards"))
        XCTAssertTrue(String(decoding: rewritten, as: UTF8.self).contains("\"scriptCountVersion\":2"), "写回带版本号")
        _ = CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: blobs.appendingPathComponent("savedCharacterCards")), rewritten, "再开一次：空操作")
        XCTAssertNotEqual(ImportFingerprint.of(loaded), preB1Hash)
        XCTAssertEqual(ImportFingerprint.preB1Card(loaded), preB1Hash, "撤回按 B1 前编码仍比对得上")
    }

    private static func dropVersion(_ json: String) -> String {
        let a = json.replacingOccurrences(of: ",\"scriptCountVersion\":2", with: "")
        return a != json ? a : json.replacingOccurrences(of: "\"scriptCountVersion\":2,", with: "")
    }

    // MARK: - B1 纯前端卡 / 不支持功能

    func testFrontendDetectionFollowsHelperMarkers() throws {
        for yes in ["<script>alert(1)</script>", "<SCRIPT src=x>", "<html><p>x</p></html>", "前面</html>", "<head><title>t</title>", "<body class=\"a\">"] {
            XCTAssertTrue(CardFrontendDetector.isFrontend(yes), yes)
        }
        for no in ["<div style=\"color:red\">纯样式</div>", "*星号* 和 `代码`", "html 这个词", "<HEAD>大写不算（同助手区分大小写）"] {
            XCTAssertFalse(CardFrontendDetector.isFrontend(no), no)
        }
        let pure = try card(extensions: [:], greetings: ["普通开场", "```html\n<html><body><button>选我</button></body></html>\n```"])
        XCTAssertTrue(pure.regexScripts.isEmpty)
        XCTAssertEqual(pure.scriptCount, 0)
        XCTAssertTrue(pure.hasFrontendGreeting)
        XCTAssertTrue(pure.needsExtensionConsent, "纯前端卡也要能许可")
        XCTAssertFalse(try card(extensions: [:], greetings: ["只有字"]).needsExtensionConsent)
    }

    func testUnsupportedFeatureScan() throws {
        let texts = [
            "await waitGlobalInitialized('Mvu'); const d = Mvu.getMvuData({ type: 'message' });",
            "import 'https://testingcf.jsdelivr.net/gh/MagicalAstrogy/MagVarUpdate@beta/artifact/bundle.js';",
            "const e = await getLorebookEntries('书');",
            "audioPlay('bgm');",
            "TavernHelper.generateRaw({ user_input: 'x' });",
        ]
        XCTAssertEqual(CardFeatureScanner.scan(texts), [.mvu, .worldBook, .audio, .generate, .remoteScript])
        XCTAssertEqual(CardFeatureScanner.scan(["const r = await generate({ user_input: 'x' })"]), [.generate])
        XCTAssertEqual(CardFeatureScanner.scan(["regenerate(); foo.generate(1); 文字里写 MVU. 不算; getChatMessages(0)"]), [])
        XCTAssertEqual(CardFeatureScanner.scan(["<script src=\"https://code.jquery.com/jquery-3.6.0.min.js\"></script>"]), [], "内置库接得住的不算远程")
        XCTAssertEqual(CardFeatureScanner.scan(["<script src=\"https://unpkg.com/vue@3\"></script>"]), [.remoteScript])
        XCTAssertEqual(CardFeatureScanner.scan(["import { klona } from \"https://testingcf.jsdelivr.net/npm/klona/+esm\";"]), [.remoteScript])
        XCTAssertEqual(CardFeatureScanner.describe(static: [.audio], runtime: ["getWorldbook", "triggerSlash", "audioPlay"]),
                       ["世界书", "音频", "triggerSlash"])

        var c = try card(extensions: ["tavern_helper": ["scripts": [script("eventOn('x', () => Mvu.getMvuData())")]]],
                         greetings: ["开场", "<script>playAudio('a')</script>"])
        var rule = RegexScript()
        rule.replaceString = "<script>getWorldbook('w')</script>"
        c.regexScripts = [rule]
        XCTAssertEqual(c.unsupportedFeatures, [.mvu, .worldBook, .audio], "脚本 + 开场 + 正则替换模板都扫")
    }

    // MARK: - B2 CDN 改写

    func testCDNRewriteMapsKnownLibrariesOnly() {
        let cases: [(String, String?)] = [
            ("https://code.jquery.com/jquery-3.6.0.min.js", "jquery@3.5.1/jquery.min.js"),
            ("//code.jquery.com/jquery-2.2.4.slim.min.js", "jquery@3.5.1/jquery.min.js"),
            ("https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js", "jquery@3.5.1/jquery.min.js"),
            ("https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js", "jquery@3.5.1/jquery.min.js"),
            ("https://testingcf.jsdelivr.net/npm/jquery", "jquery@3.5.1/jquery.min.js"),
            ("https://cdnjs.cloudflare.com/ajax/libs/lodash.js/4.17.21/lodash.min.js", "lodash@4.17.23/lodash.min.js"),
            ("https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js?v=1", "lodash@4.17.23/lodash.min.js"),
            ("https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css", "fontawesome-free@6.5.2/css/all.min.css"),
            ("https://cdnjs.cloudflare.com/ajax/libs/font-awesome/4.7.0/css/font-awesome.min.css", "fontawesome-free@6.5.2/css/all.min.css"),
            ("https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@6.5.1/css/solid.min.css", "fontawesome-free@6.5.2/css/solid.min.css"),
            ("https://testingcf.jsdelivr.net/npm/@fortawesome/fontawesome-free/css/fontawesome.css", "fontawesome-free@6.5.2/css/fontawesome.min.css"),
            ("https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/js/all.min.js", nil),
            ("https://unpkg.com/jquery@3.7.1/dist/jquery.min.js", nil),
            ("https://cdn.jsdelivr.net/npm/vue@3", nil),
            ("https://cdn.jsdelivr.net/gh/user/repo/jquery.min.js", nil),
            ("https://evil.example/code.jquery.com/jquery.min.js", nil),
        ]
        for (remote, local) in cases { XCTAssertEqual(CardWebLibrary.localPath(forRemote: remote), local, remote) }

        let html = """
        <head><script src="https://code.jquery.com/jquery-3.6.0.min.js" integrity="sha256-abc" crossorigin="anonymous"></script>
        <link rel='stylesheet' href='https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css' crossorigin>
        <script src="https://unpkg.com/vue@3"></script><img src="https://code.jquery.com/jquery.js"></head>
        """
        let out = CardWebLibrary.rewrite(html)
        XCTAssertTrue(out.contains("<script src=\"mp-card://lib/jquery@3.5.1/jquery.min.js\"></script>"), out)
        XCTAssertTrue(out.contains("<link rel='stylesheet' href=\"mp-card://lib/fontawesome-free@6.5.2/css/all.min.css\">"), out)
        XCTAssertFalse(out.contains("integrity") || out.contains("crossorigin"), "改写的标签去掉 SRI")
        XCTAssertTrue(out.contains("<script src=\"https://unpkg.com/vue@3\"></script>"), "别的库不改写（按规则被挡）")
        XCTAssertTrue(out.contains("<img src=\"https://code.jquery.com/jquery.js\">"), "只改 script / link")
        XCTAssertEqual(CardWebLibrary.rewrite("<p>没有标签</p>"), "<p>没有标签</p>")
    }

    /// 改写只在拼子文档时：登记的原文 / 消息原文不动；非卡网页不改写
    func testRewriteOnlyInComposedDocument() {
        let original = "<script src=\"https://code.jquery.com/jquery-3.6.0.min.js\"></script><p>x</p>"
        let r = HTMLEmbedRegistry()
        let id = HTMLEmbedIdentity(profileId: "p", conversationId: "c", nodeId: "n", segmentId: "h0")
        let card = r.register(id, content: original, mode: .interactive, network: .card(allowed: false))
        let plain = r.register(id, content: original, mode: .interactive)
        XCTAssertEqual(r.entry(card)?.content, original, "登记的还是原文")
        XCTAssertTrue(r.entry(card)?.document.contains("mp-card://lib/jquery@3.5.1/jquery.min.js") == true)
        XCTAssertFalse(r.entry(card)?.document.contains("code.jquery.com") == true)
        XCTAssertTrue(r.entry(plain)?.document.contains("https://code.jquery.com/jquery-3.6.0.min.js") == true, "非卡不改写")
        XCTAssertEqual(r.entry(card)?.network, .card(allowed: false))
    }

    /// B8：照酒馆助手给卡的子文档先装内置 jQuery / lodash（只交互）+ Font Awesome；卡代码之前、非卡不装
    func testCardDocumentPreloadsBundledLibraries() {
        let jq = "mp-card://lib/jquery@3.5.1/jquery.min.js", lo = "mp-card://lib/lodash@4.17.23/lodash.min.js"
        let fa = "mp-card://lib/fontawesome-free@6.5.2/css/all.min.css"
        let content = "<!doctype html><html><body><script>$(function () {})</script></body></html>"
        let live = HTMLEmbedPolicy.document(content: content, mode: .interactive, token: "t", network: .card(allowed: false))
        XCTAssertTrue(live.contains(jq) && live.contains(lo) && live.contains(fa))
        XCTAssertLessThan(live.range(of: jq)!.lowerBound, live.range(of: "$(function")!.lowerBound, "库在卡代码之前")
        XCTAssertTrue(live.hasPrefix("<!doctype html>"), "doctype 仍在最前")
        let still = HTMLEmbedPolicy.document(content: content, mode: .staticView, token: "t", nonce: "n", network: .card(allowed: true))
        XCTAssertTrue(still.contains(fa))
        XCTAssertFalse(still.contains(jq) || still.contains(lo), "静态段不装脚本")
        let plain = HTMLEmbedPolicy.document(content: content, mode: .interactive, token: "t")
        XCTAssertFalse(plain.contains("mp-card://lib/"), "非卡网页不变")
        for url in [jq, lo, fa] { XCTAssertNotNil(CardWebLibrary.file(for: URL(string: url)), "预装的都在白名单里：\(url)") }
    }

    // MARK: - B2 CSP

    func testCSPMatrix() {
        let old = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:; "
            + "connect-src 'none'; form-action 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'"
        XCTAssertEqual(HTMLEmbedPolicy.contentSecurityPolicy(.interactive), old, "非卡：和以前逐字一样")
        XCTAssertEqual(HTMLEmbedPolicy.contentSecurityPolicy(.staticView, nonce: "n1"),
                       old.replacingOccurrences(of: "script-src 'unsafe-inline'", with: "script-src 'nonce-n1'"))

        let staticDenied = HTMLEmbedPolicy.contentSecurityPolicy(.staticView, nonce: "n1", network: .card(allowed: false))
        let staticAllowed = HTMLEmbedPolicy.contentSecurityPolicy(.staticView, nonce: "n1", network: .card(allowed: true))
        let liveDenied = HTMLEmbedPolicy.contentSecurityPolicy(.interactive, network: .card(allowed: false))
        let liveAllowed = HTMLEmbedPolicy.contentSecurityPolicy(.interactive, network: .card(allowed: true))
        for csp in [staticDenied, staticAllowed, liveDenied, liveAllowed] {
            for d in ["default-src 'none'", "connect-src 'none'", "form-action 'none'", "frame-src 'none'", "child-src 'none'",
                      "worker-src 'none'", "object-src 'none'", "base-uri 'none'", "media-src data:;"] {
                XCTAssertTrue(csp.contains(d), "\(d) 缺失：\(csp)")
            }
            XCTAssertFalse(csp.contains(" https: ") || csp.contains(" https:;") || csp.contains("blob:") || csp.contains("*"), csp)
            XCTAssertTrue(csp.contains("style-src 'unsafe-inline' mp-card:"), "内置库样式（未许可也有，本地不联网）")
            XCTAssertTrue(csp.contains("font-src data: mp-card:"))
        }
        // 静态段不放宽 script-src：只有 nonce，连 mp-card: 都没有
        XCTAssertTrue(staticDenied.contains("script-src 'nonce-n1';"))
        XCTAssertTrue(staticAllowed.contains("script-src 'nonce-n1';"))
        XCTAssertTrue(liveDenied.contains("script-src 'unsafe-inline' mp-card:;"))
        XCTAssertTrue(liveAllowed.contains("script-src 'unsafe-inline' mp-card:;"), "网上的脚本一律不放")
        // 未许可：没有任何外部域名
        for csp in [staticDenied, liveDenied] { XCTAssertFalse(csp.contains("https://"), csp) }
        XCTAssertTrue(staticDenied.contains("img-src data:;"))
        // 已许可：三类白名单
        for csp in [staticAllowed, liveAllowed] {
            XCTAssertTrue(csp.contains("style-src 'unsafe-inline' mp-card: https://fonts.googleapis.com https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://fontsapi.zeoseven.com;"), csp)
            XCTAssertTrue(csp.contains("img-src data: https://files.catbox.moe https://i.imgur.com https://s41.ax1x.com https://i.ibb.co https://i.postimg.cc https://images.unsplash.com https://picsum.photos https://fastly.picsum.photos;"), csp)
            XCTAssertTrue(csp.contains("font-src data: mp-card: https://fonts.googleapis.com https://fonts.gstatic.com https://fontsapi.zeoseven.com https://fontsapi-storage.zeoseven.com;"), csp)
            XCTAssertFalse(csp.contains("script-src 'unsafe-inline' mp-card: https") || csp.contains("connect-src https"))
        }
        XCTAssertEqual(HTMLEmbedPermission.network(boundCard: nil), .offline)
    }

    /// 原生聊天卡聊天：meta CSP 与 Page2 同一份；静态带 nonce、交互不带（带了 'unsafe-inline' 会失效）；壳的上限覆盖已许可的子文档
    func testNativeCardPreludeAndShell() throws {
        let st = HTMLEmbedPolicy.nativeCardPrelude(mode: .staticView, nonce: "abc", allowed: true)
        XCTAssertTrue(st.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"\(HTMLEmbedPolicy.contentSecurityPolicy(.staticView, nonce: "abc", network: .card(allowed: true)))\">"))
        XCTAssertTrue(st.contains("<script nonce=\"abc\">") && st.contains("securitypolicyviolation") && st.contains("cspBlocked"))
        let live = HTMLEmbedPolicy.nativeCardPrelude(mode: .interactive, nonce: "abc", allowed: false)
        XCTAssertTrue(live.contains("content=\"\(HTMLEmbedPolicy.contentSecurityPolicy(.interactive, network: .card(allowed: false)))\""))
        XCTAssertFalse(live.contains("'nonce-abc'"))
        let shell = HTMLEmbedPolicy.nativeCardShellPolicy
        for host in CardWebWhitelist.font + CardWebWhitelist.style + CardWebWhitelist.image { XCTAssertTrue(shell.contains("https://\(host)"), host) }
        XCTAssertTrue(shell.contains("connect-src 'none'") && shell.contains("form-action 'none'") && !shell.contains("https: "))
        // 壳文件里的 CSP 必须与常量逐字一致（找得到源文件 / bundle 资源时比；WebKit harness 另外实跑比对）
        let candidates = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                            .appendingPathComponent("MemoryPalace/Resources/Web/html-preview-card.html"),
                          Bundle.main.url(forResource: "html-preview-card", withExtension: "html")].compactMap { $0 }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("找不到 html-preview-card.html（独立编译时由 WebKit harness 比对）")
        }
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("content=\"\(shell)\""))
    }

    // MARK: - B2 lib 白名单 handler

    func testLibraryWhitelistIsExact() {
        for path in CardWebLibrary.files.keys {
            XCTAssertNotNil(CardWebLibrary.file(for: URL(string: CardWebLibrary.url(path))), path)
        }
        XCTAssertEqual(CardWebLibrary.file(for: URL(string: "mp-card://lib/jquery@3.5.1/jquery.min.js"))?.contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(CardWebLibrary.file(for: URL(string: "mp-card://lib/fontawesome-free@6.5.2/css/all.min.css"))?.contentType, "text/css; charset=utf-8")
        XCTAssertEqual(CardWebLibrary.file(for: URL(string: "mp-card://lib/fontawesome-free@6.5.2/webfonts/fa-solid-900.woff2"))?.contentType, "font/woff2")
        for bad in ["mp-card://lib/jquery@3.5.1/jquery.min.js?x=1", "mp-card://lib/jquery@3.5.1/jquery.min.js#a",
                    "mp-card://lib/jquery@3.5.1/jquery.js", "mp-card://lib/jquery@3.5.1/../lodash@4.17.23/lodash.min.js",
                    "mp-card://lib//jquery@3.5.1/jquery.min.js",
                    "mp-card://document/jquery@3.5.1/jquery.min.js", "https://lib/jquery@3.5.1/jquery.min.js",
                    "mp-card://lib/fontawesome-free@6.5.2/webfonts/fa-solid-900.ttf", "mp-card://u@lib/jquery@3.5.1/jquery.min.js",
                    "mp-card://lib:8080/jquery@3.5.1/jquery.min.js"] {
            XCTAssertNil(CardWebLibrary.file(for: URL(string: bad)), bad)
        }
        XCTAssertNil(HTMLEmbedSchemeHandler.token(from: URL(string: "mp-card://lib/jquery@3.5.1/jquery.min.js")), "lib 不是文档 token")
    }

    final class FakeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: URLResponse?
        var data = Data()
        var finished = false
        var error: Error?
        init(_ url: String) { request = URLRequest(url: URL(string: url)!) }
        func didReceive(_ response: URLResponse) { self.response = response }
        func didReceive(_ data: Data) { self.data.append(data) }
        func didFinish() { finished = true }
        func didFailWithError(_ error: Error) { self.error = error }
    }

    func testSchemeHandlerServesOnlyWhitelistedLibraryFiles() {
        let handler = HTMLEmbedSchemeHandler()
        var asked: [String] = []
        handler.libraryData = { file in asked.append(file.resource); return Data("/*\(file.resource)*/".utf8) }
        let webView = WKWebView(frame: .zero)

        let ok = FakeTask("mp-card://lib/fontawesome-free@6.5.2/webfonts/fa-solid-900.woff2")
        handler.webView(webView, start: ok)
        let http = ok.response as? HTTPURLResponse
        XCTAssertTrue(ok.finished)
        XCTAssertEqual(http?.statusCode, 200)
        XCTAssertEqual(http?.value(forHTTPHeaderField: "Content-Type"), "font/woff2")
        XCTAssertEqual(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*", "字体是 CORS 请求")
        XCTAssertEqual(http?.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(String(decoding: ok.data, as: UTF8.self), "/*cardlib-fa-solid-900*/")

        let again = FakeTask("mp-card://lib/fontawesome-free@6.5.2/webfonts/fa-solid-900.woff2")
        handler.webView(webView, start: again)
        XCTAssertEqual(asked, ["cardlib-fa-solid-900"], "读过一次就缓存")

        for bad in ["mp-card://lib/jquery@3.5.1/evil.js", "mp-card://lib/../document/x", "mp-card://document/not-registered"] {
            let t = FakeTask(bad)
            handler.webView(webView, start: t)
            XCTAssertNotNil(t.error, bad)
            XCTAssertNil(t.response, bad)
        }
        let missing = HTMLEmbedSchemeHandler()
        missing.libraryData = { _ in nil }
        let t = FakeTask("mp-card://lib/jquery@3.5.1/jquery.min.js")
        missing.webView(webView, start: t)
        XCTAssertNotNil(t.error, "bundle 里没有就失败，不回空")
    }

    /// 打进 bundle 的文件都在（源码目录找得到时比）
    func testBundledLibraryFilesExist() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MemoryPalace/Resources/CardLib")
        let found = CardWebLibrary.files.values.allSatisfy { CardWebLibrary.bundleData($0) != nil }
        if found { return }
        guard FileManager.default.fileExists(atPath: dir.path) else { throw XCTSkip("独立编译：没有 bundle 也没有源码目录") }
        for file in CardWebLibrary.files.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(file.resource).\(file.ext)").path), file.resource)
        }
    }

    // MARK: - B2 被挡资源计数

    func testBlockedResourceParsingAndHostBadge() throws {
        XCTAssertEqual(CardBlockedResource.parse("img-src https://img.example.cn/a.png?x=1")?.kind, .image)
        XCTAssertEqual(CardBlockedResource.parse("script-src-elem https://unpkg.com/vue")?.host, "unpkg.com")
        XCTAssertEqual(CardBlockedResource.parse("font-src https://fonts.gstatic.com/s/x.woff2")?.kind.label, "字体")
        XCTAssertEqual(CardBlockedResource.parse("connect-src https://api.example.com/x")?.kind.label, "联网")
        for notExternal in ["script-src-elem inline", "script-src eval", "img-src data", "style-src-elem mp-card://lib/x", "garbage"] {
            XCTAssertNil(CardBlockedResource.parse(notExternal), notExternal)
        }

        var js: [String] = []
        let host = HTMLEmbedHost()
        host.eval = { js.append($0) }
        host.network = .card(allowed: false)
        let id = HTMLEmbedIdentity(profileId: "p", conversationId: "c", nodeId: "n1", segmentId: "h0")
        host.replaceSources([(id, "<img src=\"https://img.example.cn/a.png\">")])
        host.handle(.mount(nodeId: "n1", segmentId: "h0"))
        let token = try XCTUnwrap(host.registry.entries.keys.first)
        XCTAssertTrue(host.registry.entry(token)?.document.contains("style-src 'unsafe-inline' mp-card:;") == true, "卡聊天未许可：只多内置库")
        js = []
        for text in ["img-src https://img.example.cn/a.png", "img-src https://img.example.cn/a.png", "script-src-elem https://unpkg.com/vue",
                     "script-src-elem inline", "img-src https://img.example.cn/b.png"] {
            host.handle(.cspReport(token: token, nodeId: "n1", segmentId: "h0", kind: "csp", text: text))
        }
        let report = try XCTUnwrap(host.runtimeReports["p"])
        XCTAssertEqual(report.blockedBySegment["n1|h0"]?.count, 3, "按地址去重、内联脚本不算")
        let last = try XCTUnwrap(js.last)
        XCTAssertTrue(last.hasPrefix("window.mp && mp.htmlBlocked && mp.htmlBlocked(\"n1\", \"h0\", "), last)
        XCTAssertTrue(last.contains("\"count\":3") && last.contains("img.example.cn") && last.contains("unpkg.com"), last)
        XCTAssertTrue(last.contains(CardBlockedResource.notAllowedNote) && last.contains("只允许白名单里的字体、图标和图片"), last)
        XCTAssertEqual(js.filter { $0.contains("htmlBlocked") }.count, 4, "内联那条不发")

        // 同一段内容变了 → 清掉这段的记录
        host.replaceSources([(id, "<p>换了</p>")])
        XCTAssertNil(host.runtimeReports["p"]?.blockedBySegment["n1|h0"])

        // 许可变了 → 已挂的全按新 CSP 重挂（注销旧 token）
        host.replaceSources([(id, "<p>x</p>")])
        host.handle(.mount(nodeId: "n1", segmentId: "h0"))
        XCTAssertEqual(host.registry.count, 1)
        let token2 = try XCTUnwrap(host.registry.entries.keys.first)
        host.handle(.cspReport(token: token2, nodeId: "n1", segmentId: "h0", kind: "csp", text: "font-src https://fonts.gstatic.com/a.woff2"))
        XCTAssertEqual(host.runtimeReports["p"]?.blockedBySegment["n1|h0"]?.count, 1)
        host.network = .card(allowed: true)
        XCTAssertEqual(host.registry.count, 0)
        XCTAssertNil(host.runtimeReports["p"]?.blockedBySegment["n1|h0"], "档位变了：之前记的作废重数")
        XCTAssertTrue(js.contains { $0.contains("mp.htmlBlocked(\"n1\", \"h0\", {\"count\":0})") }, "web 角标一并摘掉")
        XCTAssertTrue(js.contains { $0.contains("mp.htmlSuspend") } && js.contains { $0.contains("mp.htmlResume") })
        host.handle(.mount(nodeId: "n1", segmentId: "h0"))
        let allowed = try XCTUnwrap(host.registry.entries.values.first)
        XCTAssertTrue(allowed.document.contains("https://fonts.gstatic.com"))
        XCTAssertEqual(allowed.network, .card(allowed: true))
    }
}
