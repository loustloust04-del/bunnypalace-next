#if PERSONAL_APPS
#if DEBUG
import XCTest
@testable import 记忆花园

/// pmBoard 子应用：hub pm_req 回帧解码 + Store 状态（docs/plan-dev-subapp-v2.md P0-d-9 / P1）。
/// 夹具取自 cc-bridge/e2e/pm-relay.e2e.ts（PM_E2E_DUMP）的真回帧（假世界，无粟粟原话），补了喊了我 / outbox / 管家头衔。
@MainActor
final class PMBoardModelsTests: XCTestCase {
    static let A = "aaaaaaaa-0000-4000-8000-00000000000a"

    static func homeFrame(_ rid: String) -> String { #"""
    {"ok":true,"view":"home","generatedAt":1791050726159,"generatedText":"10-03 11:05:26",
     "strip":{"build":{"tone":"ok","text":"编译锁 空闲"},"device":{"tone":"warn","text":"设备 sim 🔒等你验"},"merge":{"tone":"ok","text":"合并队列 空 · 今天合了 0 单"},"frozen":false,"zonePaused":true,"lastDing":{"at":1791050000000,"text":"机器超载","src":"overload","sid":null}},
     "people":[{"sid":"aaaaaaaa-0000-4000-8000-00000000000a","displayName":"你好","rawName":"工位A","title":null,"kind":"worker","scope":"garden","project":"记忆花园","zones":["page1"],"state":"idle","stateText":"闲着 · 刚刚","preview":{"who":"粟粟","text":"你好","at":1791050726053},"lastAt":1791050726053,"unanswered":{"n":2,"lastAt":1791050726000,"lastText":"要不要合"},"badges":{"merges":0,"mergeAsk":true,"devices":[],"build":null,"agents":0},"openable":true,"pinnedDefault":false,"parent":null},
               {"sid":"fa7011ab-6fbd-45c7-a9f1-1e595e97fbcf","displayName":"Herald","rawName":"memorypalace-5f","title":"发行管家","kind":"steward","scope":"garden","project":"记忆花园","zones":["misc"],"state":"busy","stateText":"在忙","preview":null,"lastAt":1791050000000,"unanswered":null,"badges":{"merges":0,"mergeAsk":false,"devices":[],"build":"queued","agents":1},"openable":true,"pinnedDefault":true,"parent":"粟粟"}],
     "dingsToday":3,"errors":[],"type":"pm_req_result","req_id":"\#(rid)","http":200}
    """# }

    static func sessionFrame(_ rid: String) -> String { #"""
    {"ok":true,"generatedAt":1791050726159,"sid":"aaaaaaaa-0000-4000-8000-00000000000a","name":"工位A",
     "turns":[{"who":"susu","text":"你好","at":1791050726053},{"who":"upper","name":"Warden","text":"合了","at":1791050726054},{"who":"susu","via":"phone","text":"进度 怎样","at":1791050726055}],
     "canSend":{"ok":false,"code":"awaiting","why":"它卡在权限弹窗上"},
     "person":{"sid":"aaaaaaaa-0000-4000-8000-00000000000a","displayName":"你好","rawName":"工位A","title":null,"kind":"worker","scope":"garden","project":"记忆花园","zones":["page1"],"state":"wait","stateText":"在等你","preview":null,"lastAt":1791050726053,"unanswered":null,"badges":{"merges":0,"mergeAsk":false,"devices":[],"build":null,"agents":0},"openable":true,"pinnedDefault":false,"parent":null},
     "asks":[{"kind":"permission","text":"在等你批权限（手机上不代批）","at":1791050726159,"live":true,"answered":false},{"kind":"call","text":"要不要合","at":1791050726000,"live":false,"answered":true,"src":"ask"}],
     "resumeCmd":"cd '/tmp/repo/.claude/worktrees/page1' && claude --resume aaaaaaaa-0000-4000-8000-00000000000a",
     "outbox":[{"id":"m-1","sid":"aaaaaaaa-0000-4000-8000-00000000000a","text":"进度怎样","createdAt":1791050726000,"state":"sent","why":"","code":"","attempts":1,"stale":false,"seen":true,"typed":true,"enters":0,"doneAt":1,"nextTryAt":0},
               {"id":"m-2","sid":"aaaaaaaa-0000-4000-8000-00000000000a","text":"先别合","createdAt":1791050726100,"state":"queued-busy","why":"它卡在权限弹窗上","code":"awaiting","attempts":3,"stale":false,"seen":false,"typed":false,"enters":0,"doneAt":0,"nextTryAt":0}],
     "type":"pm_req_result","req_id":"\#(rid)","http":200}
    """# }

    func testHomeDecodes() throws {
        let h = try JSONDecoder().decode(PMHome.self, from: Data(Self.homeFrame("x").utf8))
        XCTAssertEqual(h.people.count, 2)
        XCTAssertEqual(h.people[0].unanswered?.n, 2)
        XCTAssertEqual(h.people[1].subtitle, "发行管家")
        XCTAssertEqual(h.people[0].subtitle, "page1")
        XCTAssertTrue(h.people[1].searchText.contains("memorypalace-5f"))
        XCTAssertEqual(h.strip.device?.color, PMState.wait.color)
        XCTAssertTrue(h.strip.zonePaused)
        XCTAssertEqual(h.strip.lastDing?.src, "overload")
    }

    func testDetailDecodes() throws {
        let d = try JSONDecoder().decode(PMDetail.self, from: Data(Self.sessionFrame("x").utf8))
        XCTAssertEqual(d.person?.state, .wait)
        XCTAssertEqual(d.asks.map(\.live), [true, false])
        XCTAssertEqual(d.asks[0].icon, "hand.raised.fill")
        XCTAssertEqual(d.turns.map(\.who), ["susu", "upper", "susu"])
        XCTAssertEqual(d.outbox.map(\.state), ["sent", "queued-busy"])
        XCTAssertFalse(d.canSend.ok)
    }

    func testNotRunningDetailDecodes() throws {
        let json = #"{"ok":true,"generatedAt":1,"sid":"dddddddd-0000-4000-8000-000000000004","name":"dddddddd","session":null,"agents":[],"turns":[],"canSend":{"ok":false,"code":"not-running","why":"它没在跑"},"person":null,"asks":[],"resumeCmd":"cd '/tmp' && claude --resume dddddddd-0000-4000-8000-000000000004","outbox":[],"type":"pm_req_result","req_id":"x"}"#
        let d = try JSONDecoder().decode(PMDetail.self, from: Data(json.utf8))
        XCTAssertNil(d.person)
        XCTAssertEqual(d.canSend.code, "not-running")
    }

    func testStoreRoutesByReqId() {
        let s = PMBoardStore.shared
        s.handle(type: "pm_req_result", data: Data(Self.homeFrame(s.register(.home)).utf8))
        XCTAssertEqual(s.home?.people.count, 2)
        XCTAssertNil(s.homeError)

        let rid = s.register(.home)
        s.handle(type: "pm_req_result", data: Data(#"{"type":"pm_req_result","req_id":"\#(rid)","ok":false,"code":"pm-down","error":"看板服务没开"}"#.utf8))
        XCTAssertEqual(s.homeError, "看板服务没开")
        XCTAssertNotNil(s.home, "出错时保留上一份数据")

        s.handle(type: "pm_req_result", data: Data(#"{"type":"pm_req_result","req_id":"\#(s.register(.home))","ok":true,"view":"home"}"#.utf8))
        XCTAssertTrue(s.homeError?.hasPrefix("看板版本对不上") == true)

        s.handle(type: "pm_req_result", data: Data(#"{"type":"pm_req_result","req_id":"不认识的号","ok":true}"#.utf8))   // 对不上号的丢掉不崩

        let sid = "cccccccc-0000-4000-8000-00000000000c"
        s.handle(type: "pm_req_result", data: Data(#"{"type":"pm_req_result","req_id":"\#(s.register(.session(sid)))","ok":false,"http":404,"message":"找不到这个对话"}"#.utf8))
        XCTAssertEqual(s.detailErrors[sid], "找不到这个对话")

        s.handle(type: "pm_req_result", data: Data(#"{"type":"pm_req_result","req_id":"\#(s.register(.open(Self.A)))","ok":true,"message":"已聚焦 工位A 的 Otty 标签"}"#.utf8))
        XCTAssertEqual(s.openMessage[Self.A], "已聚焦 工位A 的 Otty 标签")
    }

    func testOptimisticBubbleReconciles() {
        let s = PMBoardStore.shared
        guard !s.bridgeConnected else { return }   // 测试宿主一般没连桥
        s.send("先别合", to: Self.A, id: "m-2")
        s.send("再说一句", to: Self.A, id: "m-3")
        XCTAssertEqual(s.outbox(for: Self.A).map(\.state).suffix(2), ["failed", "failed"])
        XCTAssertTrue(s.outbox(for: Self.A).last?.why.contains("桥没连上") == true)

        s.handle(type: "pm_req_result", data: Data(Self.sessionFrame(s.register(.session(Self.A))).utf8))
        let shown = s.outbox(for: Self.A)
        XCTAssertEqual(shown.map(\.id), ["m-2", "m-3"], "4793 认领的 m-2 用它的状态；已在对话里的 m-1 不再单独显示；m-3 本机还在")
        XCTAssertEqual(shown.first?.state, "queued-busy")
        XCTAssertEqual(s.interval(detail: Self.A), 2)

        s.dropLocal(shown[1])
        XCTAssertEqual(s.outbox(for: Self.A).map(\.id), ["m-2"])
    }

    // MARK: P1：占用 / 待验 / 路线图（夹具取自隔离 e2e 真回帧，补了在编 / 排队 / 叫验 / 合并单）

    static func occupancyFrame(_ rid: String) -> String { #"""
    {"ok":true,"generatedAt":1791058372246,"generatedText":"10-03 13:12:52",
     "zones":[{"zone":"page1","desc":"消息 / 卡片 / 输入框 / 上下文","exists":true,"owner":null,"since":null,"ahead":null,"dirty":null,"lastTouched":null,"warn":"在用但没登记（你好）"},
              {"zone":"misc","desc":"零碎小改动","exists":true,"owner":{"sid":"fa7011ab-6fbd-45c7-a9f1-1e595e97fbcf","name":"Herald","title":"发行管家","alive":true},"since":1790969118000,"ahead":2,"dirty":0,"lastTouched":1791058000000,"warn":null}],
     "build":{"frozen":null,"zonePaused":true,
              "holder":{"who":{"sid":"aaaaaaaa-0000-4000-8000-00000000000a","name":"你好","title":null,"alive":true},"where":"page1","cmd":"build","since":1791058000000,"state":"overload","overloadWhy":"内存压力 critical"},
              "queue":[{"pos":1,"who":{"sid":null,"name":".integration","title":null,"alive":false},"where":".integration","cmd":"iw","queuedAt":1791058100000,"prio":true}],
              "last":{"where":".integration","secs":399,"ok":true,"at":1791057091000}},
     "devices":[{"dev":"air","note":"Air · 只给主仓 master","holder":{"who":{"sid":null,"name":"粟粟钉住","title":null,"alive":true},"why":"","label":"","since":0,"expires":null,"asked":null,"pinned":true},"queue":[]},
                {"dev":"sim","note":"模拟器 · 装包验证默认用它","holder":null,"queue":[{"who":{"sid":"aaaaaaaa-0000-4000-8000-00000000000a","name":"你好","title":null,"alive":true},"label":"page1"}]}],
     "merges":{"lockHeld":true,"processing":[{"id":"00161","branch":"tmp/x","why":"散成灰","from":"page1-5","submitted":"10-03 08:04","resolved":"","result":"","who":{"sid":"aaaaaaaa-0000-4000-8000-00000000000a","name":"你好","title":null,"alive":true}}],"pending":[],"recent":[]},
     "type":"pm_req_result","req_id":"\#(rid)","http":200}
    """# }

    static func taskFrame(_ rid: String) -> String { #"""
    {"ok":true,"generatedAt":1791058372246,"mtime":1791058372120,
     "sections":[{"title":"待验（自动）","groups":[{"title":"","note":"","items":[
        {"id":"","text":"待验 · 散成灰 · #00161","done":false,"line":5,"req":"00161","needs":null,"zone":"page1-5","who":{"sid":"aaaaaaaa-0000-4000-8000-00000000000a","name":"page1-007","title":null,"alive":false},"mergedAt":"10-03 10:16","how":"marker"},
        {"id":"page0-列表-04","text":"code 组","done":true,"line":9,"req":null,"needs":null,"zone":null,"who":null,"mergedAt":null,"how":"none"}]}]}],
     "temp":[{"who":{"sid":"aaaaaaaa-0000-4000-8000-00000000000a","name":"你好","title":null,"alive":true},"text":"sim 上装好了在等你验","at":1791058000000}],
     "type":"pm_req_result","req_id":"\#(rid)","http":200}
    """# }

    func testOccupancyDecodesAndRoutes() {
        let s = PMBoardStore.shared
        s.handle(type: "pm_req_result", data: Data(Self.occupancyFrame(s.register(.occupancy)).utf8))
        XCTAssertNil(s.occupancyError)
        let o = s.occupancy
        XCTAssertEqual(o?.zones.map(\.zone), ["page1", "misc"])
        XCTAssertEqual(o?.zones[1].owner?.title, "发行管家")
        XCTAssertEqual(o?.build.holder?.state, "overload")
        XCTAssertEqual(o?.build.queue.first?.prio, true)
        XCTAssertEqual(o?.devices[0].holder?.pinned, true)
        XCTAssertEqual(o?.merges.processing.first?.who.name, "你好")
    }

    func testTaskDecodesAndWhoLine() {
        let s = PMBoardStore.shared
        s.handle(type: "pm_req_result", data: Data(Self.taskFrame(s.register(.task)).utf8))
        XCTAssertNil(s.taskError)
        let items = s.task?.sections.first?.groups.first?.items ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].whoLine, "page1-007 · 已退出 · 工位 page1-5 · #00161 · 10-03 10:16 合")
        XCTAssertNil(items[1].whoLine)
        XCTAssertEqual(s.task?.temp.first?.who.name, "你好")
    }

    func testDocStateErrorSurfaces() {
        let s = PMBoardStore.shared
        s.handle(type: "pm_req_result", data: Data(#"{"type":"pm_req_result","req_id":"\#(s.register(.docState("plan-open-source")))","ok":false,"http":400,"message":"这份文档没有这个存档 key"}"#.utf8))
        XCTAssertEqual(s.docErrors["plan-open-source"], "这次改动没存上：这份文档没有这个存档 key")
        s.handle(type: "pm_req_result", data: Data(#"{"type":"pm_req_result","req_id":"\#(s.register(.docState("plan-open-source")))","ok":true,"version":3}"#.utf8))
        XCTAssertNil(s.docErrors["plan-open-source"])
    }

    func testAgo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PMTime.ago(1_000_000_000 - 30_000, now: now), "刚刚")
        XCTAssertEqual(PMTime.ago(1_000_000_000 - 600_000, now: now), "10 分钟前")
        XCTAssertEqual(PMTime.ago(0, now: now), "—")
    }
}
#endif
#endif
