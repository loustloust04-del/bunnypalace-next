import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 读侧段④：本窗六项、上个窗口冻结 / 复核 / 失效、Z7 进 system 段（plan-recall-slice-4）。夹具名字全虚构
final class MemoryWindowChoicesTests: XCTestCase {
    private let pid = "xctest-window-choices-云桥城"
    private let keys = ["mem_master", "mem_content_summary", "mem_content_timeline", "mem_inject_keyword", "mem_inject_full",
                        "mem_inject_vector", "mem_inject_graph", "mem_inject_catalog",
                        MemoryOpenWindow.a2Key, MemoryOpenWindow.a4Key, MemoryOpenWindow.b4Key, MemoryOpenWindow.cKey,
                        MemoryOpenWindowStore.storageKey, RecallTuningStore.storageKey, "mem_inject_budget"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_inject_full")
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        super.tearDown()
    }

    private func profile() -> Profile {
        Profile(id: pid, name: "云桥城", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @discardableResult
    private func window(_ id: String, _ context: ModelContext, profileId: String? = nil, provider: String = "api",
                        stamp: Date? = nil, opened: Date? = nil) -> Conversation {
        let c = Conversation(id: id, title: "窗口\(id)", createTime: Date(timeIntervalSince1970: 1), updateTime: Date(timeIntervalSince1970: 1),
                             currentNodeId: "", provider: provider, profileId: profileId ?? pid)
        c.lastRealChatAt = stamp
        c.lastOpenedAt = opened
        context.insert(c)
        return c
    }

    @discardableResult
    private func node(_ id: String, _ role: String, _ text: String, parent: String?, in c: Conversation, _ context: ModelContext,
                      at: TimeInterval = 100) -> MessageNode {
        let n = MessageNode(id: id, role: role, content: text, contentType: "text", createTime: Date(timeIntervalSince1970: at),
                            parentId: parent, childrenIds: [], conversationId: c.id, profileId: c.profileId)
        context.insert(n)
        return n
    }

    // MARK: ④-1 六项

    func testLegacyEqualsTodaysChecksAndDefaultsReadNewKeys() {
        let legacy = MemoryWindowChoices.legacy(profileId: pid)
        XCTAssertEqual(legacy, MemoryWindowChoices(timeline: true, pending: true, selfMemory: true, archive: false,
                                                   previousWindow: false, pinned: false),
                       "老窗：待续跟时间轴、钉住跟档案（C 没写过 = 不勾）、没有上个窗口")
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        XCTAssertTrue(MemoryWindowChoices.legacy(profileId: pid).pinned)
        let fresh = MemoryWindowChoices.defaults(profileId: pid)
        XCTAssertTrue(fresh.pending && fresh.previousWindow && fresh.pinned, "新增三勾没写过 = 开")
        MemoryWindowChoices.setDefault(.pinned, false, profileId: pid)
        MemoryWindowChoices.setDefault(.previousWindow, false, profileId: pid)
        XCTAssertFalse(MemoryWindowChoices.defaults(profileId: pid).pinned)
        XCTAssertFalse(MemoryWindowChoices.defaults(profileId: pid).previousWindow)
        XCTAssertTrue(MemoryWindowChoices.defaults(profileId: "另一层").pinned, "只管这一个楼层")
        XCTAssertTrue(MemoryOpenWindowNote.enabled(profileId: pid))
        MemoryOpenWindowNote.set(false, profileId: pid)
        XCTAssertFalse(MemoryOpenWindowNote.enabled(profileId: pid))
    }

    func testNewArchiveDefaultIsRootOrTriggerAndLegacyRemainsRootOnly() {
        for root in [false, true] {
            for trigger in [false, true] {
                MemoryOpenWindowStore.save(.c, root, profileId: pid)
                RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: trigger), profileId: pid)
                XCTAssertEqual(MemoryWindowChoices.defaults(profileId: pid).archive, root || trigger)
                XCTAssertEqual(MemoryWindowChoices.legacy(profileId: pid).archive, root)
            }
        }
    }

    func testStoredChoicesWinAndGlobalChangeDoesNotRewriteThem() throws {
        let context = ModelContext(try container())
        let c = window("w1", context)
        XCTAssertNil(c.memoryWindowChoices)
        var mine = MemoryWindowChoices.allOff
        mine.pinned = true
        c.memoryWindowChoices = mine
        MemoryWindowChoices.setDefault(.pinned, false, profileId: pid)
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        XCTAssertEqual(EffectiveMemoryParticipation.resolve(profileId: pid, conversation: c, preset: nil).choices, mine.participationChoices)
        XCTAssertEqual(EffectiveMemoryParticipation.resolve(profileId: pid, conversation: nil, preset: nil).choices,
                       MemoryWindowChoices.legacy(profileId: pid).participationChoices)
    }

    @MainActor
    func testRoundInputsSplitsArchiveFromPinnedAndGatesSelfMemory() throws {
        let context = ModelContext(try container())
        let store = SwiftDataMemoryStore()
        try store.add(content: "星砚喜欢暖奶白", category: "preference", keywords: [], profileId: pid, isUserExplicit: true,
                      extractedBy: "t", sourceConversationId: nil, context: context)
        let fragment = try store.add(content: "岚舟在云桥城筹备合成展览", category: "event", keywords: [], profileId: pid,
                                     isUserExplicit: false, extractedBy: "t", sourceConversationId: nil, context: context)
        fragment.occurredDay = "2026-11-01"
        fragment.reviewedAt = Date()
        try context.save()
        func inputs(_ choices: MemoryWindowChoices?) -> MemoryInjector.RoundInputs {
            MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid, choices: choices),
                                       store: store, context: context, useCachedWiki: false)
        }
        var only = MemoryWindowChoices.allOff
        only.pinned = true
        XCTAssertEqual(inputs(only).memories.map(\.isUserExplicit), [true], "档案不勾、钉住勾 = 只带钉住")
        XCTAssertEqual(inputs(only).rootIndex, false)
        only = .allOff
        only.archive = true
        XCTAssertEqual(inputs(only).memories.map(\.isUserExplicit), [false], "档案勾、钉住不勾 = 不带钉住")
        XCTAssertNil(inputs(only).selfMemory)
        XCTAssertTrue(inputs(.allOff).memories.isEmpty)
        XCTAssertTrue(inputs(nil).memories.isEmpty, "老窗：C 没写过 = 钉住也不带（= 今天）")
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        XCTAssertEqual(inputs(nil).memories.count, 2, "老窗：C 勾上两样都带（= 今天）")
        XCTAssertTrue(MemoryInjector.roundInputs(profileId: pid,
                                                 participation: .testValue(profileId: pid, window: false,
                                                                           choices: .init(timeline: true, pending: true, selfMemory: true,
                                                                                          archive: true, previousWindow: true, pinned: true)),
                                                 store: store, context: context, useCachedWiki: false).memories.isEmpty,
                      "关闭记忆参与的窗口什么都不带")
    }

    func testTimelineAndPendingAreSeparateItems() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = MemoryDay.key(now.addingTimeInterval(-3600))
        let entry = TimelineEntry(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), conversationId: "conv-岚舟",
                                  title: "合成展览", text: "- 排了展位", pending: "", day: day, lastNodeId: "n1")
        func run(timeline: Bool, pending: Bool) -> TimelineStore.Injection {
            TimelineStore.injection(records: [:], entries: [day: [entry]], today: MemoryDay.key(now), currentConversationId: "",
                                    windowIds: [], openPending: pending ? ["conv-岚舟": ["写完布展清单"]] : [:],
                                    timelineLines: timeline)
        }
        let both = run(timeline: true, pending: true)
        XCTAssertTrue(both.text?.hasPrefix("[时间轴]") == true)
        XCTAssertTrue(both.text?.contains("[待续]") == true)
        let pendingOnly = run(timeline: false, pending: true)
        XCTAssertTrue(pendingOnly.text?.hasPrefix("[待续]") == true, "只要待续：不出时间轴那段")
        XCTAssertTrue(pendingOnly.units.isEmpty)
        XCTAssertTrue(pendingOnly.text?.contains("写完布展清单") == true)
        let timelineOnly = run(timeline: true, pending: false)
        XCTAssertFalse(timelineOnly.text?.contains("[待续]") ?? true)
        XCTAssertNil(run(timeline: false, pending: false).text)
        let legacy = TimelineStore.injection(records: [:], entries: [day: [entry]], today: MemoryDay.key(now), currentConversationId: "",
                                             windowIds: [], openPending: ["conv-岚舟": ["写完布展清单"]])
        XCTAssertEqual(legacy, both, "默认参数逐字等于今天")
    }

    // MARK: ④-2 上个窗口

    func testLatestIsLastRealChatNotLastOpenedAndSkipsIneligible() throws {
        let context = ModelContext(try container())
        window("a", context, stamp: Date(timeIntervalSince1970: 200), opened: Date(timeIntervalSince1970: 10))
        window("b", context, stamp: Date(timeIntervalSince1970: 100), opened: Date(timeIntervalSince1970: 999))
        window("other-floor", context, profileId: "别的楼层", stamp: Date(timeIntervalSince1970: 900))
        window("trashed", context, stamp: Date(timeIntervalSince1970: 900)).isTrashed = true
        window("off", context, stamp: Date(timeIntervalSince1970: 900)).memoryEnabled = false
        window("imported", context, provider: "chatgpt", stamp: Date(timeIntervalSince1970: 900))
        window("draft", context, stamp: Date(timeIntervalSince1970: 950))
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "draft", context: context)?.id, "a")
    }

    func testOldWindowsDeriveFromProviderRepliesAndCCRepliesDoNotCount() throws {
        let context = ModelContext(try container())
        window("stamped", context, stamp: Date(timeIntervalSince1970: 200))
        let old = window("old", context)
        node("old-u", "user", "岚舟问展位", parent: nil, in: old, context, at: 290)
        node("old-a", "assistant", "星砚回答", parent: "old-u", in: old, context, at: 300)
        let cc = window("cc", context)
        node("cc-a", "assistant", "终端回来的", parent: nil, in: cc, context, at: 500).ccMessageId = "cc-1"
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "", context: context)?.id, "old")
        XCTAssertNil(old.lastRealChatAt, "只读推导，不写回")
        window("tie-b", context, stamp: Date(timeIntervalSince1970: 400))
        window("tie-a", context, stamp: Date(timeIntervalSince1970: 400))
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "", context: context)?.id, "tie-a", "同刻按 id 稳定")
    }

    func testLatestUsesNewerReplyEvenWhenCrossDeviceStampAlreadyExists() throws {
        let context = ModelContext(try container())
        window("locally-newer", context, stamp: Date(timeIntervalSince1970: 200))
        let remote = window("remote-reply", context, stamp: Date(timeIntervalSince1970: 100))
        node("remote-a", "assistant", "星砚在另一台接着说", parent: nil, in: remote, context, at: 300)
        node("remote-cc", "assistant", "终端", parent: nil, in: remote, context, at: 500).ccMessageId = "cc"
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "", context: context)?.id, remote.id)
        XCTAssertEqual(remote.lastRealChatAt, Date(timeIntervalSince1970: 100), "只读推导，不写回戳")
        remote.lastRealChatAt = Date(timeIntervalSince1970: 400)
        window("other", context, stamp: Date(timeIntervalSince1970: 350))
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "", context: context)?.id, remote.id)
    }

    /// E2-7b：`latest` 先探最新一条节点，只在严格更旧时跳过 256 条扫描；同刻仍要扫（按 id 破并列）、更晚的回复仍要抓到
    func testLatestProbeKeepsTieBreakAndCatchesNewerReply() throws {
        let context = ModelContext(try container())
        let stamped = window("aaa", context, stamp: Date(timeIntervalSince1970: 500))
        node("stamped-a", "assistant", "戳对应的回复", parent: nil, in: stamped, context, at: 400)
        stamped.currentNodeId = "stamped-a"
        // 同刻窗 id 必须比戳窗小：探针若误写 `<=`（把同刻节点当更旧跳过）就会返回 `aaa`，
        // 这个组合才能让断言失败（id 更大时按 id 破并列本来就选 `aaa`，测试没有区分力）
        let tied = window("000", context)
        node("tied-a", "assistant", "同刻的另一窗", parent: nil, in: tied, context, at: 500)
        tied.currentNodeId = "tied-a"
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "", context: context)?.id, "000",
                       "同刻按 id 破并列，探针不能把同刻节点跳过")
        let newer = window("ccc", context)
        node("newer-a", "assistant", "戳没跟上的更晚回复", parent: nil, in: newer, context, at: 600)
        newer.currentNodeId = "newer-a"
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "", context: context)?.id, "ccc",
                       "更晚的回复必须被扫描抓到")
    }

    /// E2-7b：探针「最新节点严格早于戳 → 提前返回」分支——最新节点是 CC / hidden / 不合格窗也一样，
    /// 它只当时间上界（HEAD 全扫第一条带时间节点就 break，不看可见性 / 资格），结果必须仍是戳窗
    func testLatestProbeEarlyReturnMatchesFullScanOnUnusableNewestNodes() throws {
        for kind in ["cc", "hidden", "ineligible"] {
            let context = ModelContext(try container())
            let stamped = window("zzz-stamped", context, stamp: Date(timeIntervalSince1970: 500))
            node("stamped-a", "assistant", "戳对应的回复", parent: nil, in: stamped, context, at: 300)
            stamped.currentNodeId = "stamped-a"
            let other = window("other", context)
            let newest = node("newest", "assistant", "更早但比戳新的节点", parent: nil, in: other, context, at: 400)
            other.currentNodeId = "newest"
            switch kind {
            case "cc": newest.ccMessageId = "cc-1"
            case "hidden": newest.sourceVisibility = "hidden"
            default: other.memoryEnabled = false
            }
            try context.save()
            XCTAssertEqual(PreviousWindowPicker.latest(profileId: pid, excluding: "", context: context)?.id, stamped.id,
                           "\(kind)：探针提前返回必须与 HEAD 全扫一致")
        }
    }

    func testCaptureFreezesSelectedBranchVisibleMessagesOnly() throws {
        let context = ModelContext(try container())
        let src = window("src", context, stamp: Date(timeIntervalSince1970: 100))
        let root = node("root", "system", "", parent: nil, in: src, context)
        root.isSyntheticRoot = true
        node("u1", "user", "第一句", parent: "root", in: src, context, at: 1)
        node("a1", "assistant", "第一答", parent: "u1", in: src, context, at: 2)
        node("u2", "user", "第二句", parent: "a1", in: src, context, at: 3)
        node("a2-other", "assistant", "另一支", parent: "u2", in: src, context, at: 4)
        node("a2", "assistant", "  ", parent: "u2", in: src, context, at: 5)
        node("t2", "tool", "工具结果", parent: "a2", in: src, context, at: 6)
        node("hidden", "user", "隐藏的", parent: "t2", in: src, context, at: 7).sourceVisibility = "hidden"
        node("u3", "user", "第三句", parent: "hidden", in: src, context, at: 8)
        node("a3", "assistant", "第三答", parent: "u3", in: src, context, at: 9)
        src.currentNodeId = "a3"
        try context.save()
        let four = PreviousWindowPicker.capture(src, count: 4, context: context)
        XCTAssertEqual(four.messages.map(\.nodeId), ["a1", "u2", "u3", "a3"], "选中分支；空正文、工具、隐藏、另一支都不计")
        let all = PreviousWindowPicker.capture(src, count: 6, context: context)
        XCTAssertEqual(all.messages.map(\.nodeId), ["u1", "a1", "u2", "u3", "a3"], "不足照实")
        node("u4", "user", "源窗后来又聊", parent: "a3", in: src, context, at: 10)
        src.currentNodeId = "u4"
        XCTAssertEqual(all.messages.last?.nodeId, "a3", "快照是值，源窗续聊不动它")
    }

    func testCaptureCapsEachMessageAndKeepsOnlyNewestFifty() throws {
        let context = ModelContext(try container())
        let source = window("long-source", context)
        let text = String(repeating: "岚", count: 4_000) + "不应复制的尾巴"
        for i in 0..<52 {
            node("long-\(i)", i.isMultiple(of: 2) ? "user" : "assistant", text,
                 parent: i == 0 ? nil : "long-\(i - 1)", in: source, context)
        }
        source.currentNodeId = "long-51"
        try context.save()
        let snapshot = PreviousWindowPicker.capture(source, count: 100, context: context)
        XCTAssertEqual(snapshot.messages.map(\.nodeId), (2..<52).map { "long-\($0)" })
        XCTAssertTrue(snapshot.messages.allSatisfy { $0.text == String(repeating: "岚", count: 4_000) })
    }

    /// L-B10 落地：按 id 取消息 / 取窗口都带 profileId —— 两楼层同名的窗口互不串味；
    /// 复核区分「换楼层」(.missing) 与「本楼层进回收站」(.deleted)。
    func testCaptureAndValidateStayInsideTheFloor() throws {
        let pidB = pid + "-乙楼"
        let at = Date(timeIntervalSince1970: 1)
        func windowValue(_ floor: String) -> ConversationWindow {
            ConversationWindow(id: "shared", profileId: floor, title: "同名窗口", createTime: at, updateTime: at,
                               currentNodeId: "m2")
        }
        func pair(_ first: String, _ second: String) -> [ConversationMessage] {
            [ConversationMessage(id: "m1", conversationId: "shared", role: "user", content: first,
                                 createTime: at, parentId: nil, childrenIds: ["m2"]),
             ConversationMessage(id: "m2", conversationId: "shared", role: "assistant", content: second,
                                 createTime: at, parentId: "m1")]
        }
        let fake = FixedSource(nodesByFloor: [pid: pair("甲的上一句", "甲的最后一句"),
                                             pidB: pair("乙的上一句", "乙的最后一句")])
        XCTAssertEqual(PreviousWindowPicker.capture(windowValue(pid), count: 6, from: fake).messages.map(\.text),
                       ["甲的上一句", "甲的最后一句"])
        XCTAssertEqual(PreviousWindowPicker.capture(windowValue(pidB), count: 6, from: fake).messages.map(\.text),
                       ["乙的上一句", "乙的最后一句"])

        let context = ModelContext(try container())
        let source = window("shared", context)
        node("m1", "user", "甲的上一句", parent: nil, in: source, context, at: 1)
        node("m2", "assistant", "甲的最后一句", parent: "m1", in: source, context, at: 2)
        source.currentNodeId = "m2"
        try context.save()
        let snap = PreviousWindowPicker.capture(source, count: 6, context: context)
        XCTAssertEqual(snap.messages.map(\.text), ["甲的上一句", "甲的最后一句"])
        XCTAssertNil(PreviousWindowPicker.validate(snap, profileId: pid, context: context).invalid)
        XCTAssertEqual(PreviousWindowPicker.validate(snap, profileId: pidB, context: context).invalid, .missing)
        XCTAssertEqual(PreviousWindowPicker.validate(snap, profileId: "查无此楼", context: context).invalid, .missing)

        source.profileId = pidB
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.validate(snap, profileId: pid, context: context).invalid, .missing,
                       "换楼层了 = missing，不是 deleted")
        XCTAssertNil(PreviousWindowPicker.validate(snap, profileId: pidB, context: context).invalid)
        source.profileId = pid
        source.isTrashed = true
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.validate(snap, profileId: pid, context: context).invalid, .deleted)
    }

    /// §2.2 单口径：多分叉按 `branchSelection` 走，`currentNodeId` 只在没有选择表时兜底
    func testCaptureFollowsBranchSelectionOverCurrentNodeId() throws {
        let context = ModelContext(try container())
        let src = window("branch-src", context)
        node("u1", "user", "开个头", parent: nil, in: src, context, at: 1)
        node("a1", "assistant", "接一句", parent: "u1", in: src, context, at: 2)
        node("u2", "user", "分岔了", parent: "a1", in: src, context, at: 3)
        node("a2x", "assistant", "选中的这一支", parent: "u2", in: src, context, at: 4)
        node("a2y", "assistant", "没选中的这一支", parent: "u2", in: src, context, at: 5)
        src.branchSelectionData = BranchSelection.encode(["u2": "a2x"])
        src.currentNodeId = "a2y"
        try context.save()
        let snap = PreviousWindowPicker.capture(src, count: 10, context: context)
        XCTAssertEqual(snap.messages.map(\.nodeId), ["u1", "a1", "u2", "a2x"], "按选择表走，不跟 currentNodeId")
    }

    /// 空正文（纯空白 / 只有附件）不进快照
    func testCaptureSkipsMessagesWithoutText() throws {
        let context = ModelContext(try container())
        let src = window("blank-src", context)
        node("u1", "user", "上一窗最后说的话", parent: nil, in: src, context, at: 1)
        node("a1", "assistant", "   \n ", parent: "u1", in: src, context, at: 2)
        let attachment = node("a2", "assistant", "", parent: "a1", in: src, context, at: 3)
        attachment.segmentsData = try JSONEncoder().encode([MessageSegment.text("附件说明")])
        src.currentNodeId = "a2"
        try context.save()
        let snap = PreviousWindowPicker.capture(src, count: 10, context: context)
        XCTAssertEqual(snap.messages.map(\.nodeId), ["u1"], "纯空白与只有附件的消息不进上窗快照")
        XCTAssertEqual(snap.messages.map(\.text), ["上一窗最后说的话"])
    }

    /// 源抛错：吞成空快照，来源标识照填
    func testCaptureReturnsEmptySnapshotWhenSourceThrows() {
        var fake = FixedSource(nodesByFloor: [:])
        fake.throwing = true
        let at = Date(timeIntervalSince1970: 1)
        let window = ConversationWindow(id: "boom", profileId: pid, title: "抛错窗", createTime: at, updateTime: at,
                                        currentNodeId: "boom-leaf")
        let snap = PreviousWindowPicker.capture(window, count: 6, from: fake)
        XCTAssertTrue(snap.messages.isEmpty)
        XCTAssertEqual(snap.sourceId, "boom")
        XCTAssertEqual(snap.sourceTitle, "抛错窗")
        XCTAssertEqual(snap.leafId, "boom-leaf")
    }

    /// E2-7b A：倒序凑够即停必须与旧算法（整条路径逐条 trim 后 `suffix(count)`）逐字相同。
    /// 尾部 3 条纯空白节点**接在主线上**（空白算 `hasDisplayableContent`，过 `visiblePath`；
    /// 去空白为空才在 `capture` 里跳过）——倒序凑够必须真遇到空尾，才谈得上和旧 `suffix` 比
    func testCaptureReverseEarlyStopMatchesForwardSuffix() {
        let at = Date(timeIntervalSince1970: 1)
        let count = 4_000
        var nodes: [ConversationMessage] = []
        for i in 0..<count {
            nodes.append(.init(id: "m\(i)", conversationId: "reverse-src", role: i.isMultiple(of: 2) ? "user" : "assistant",
                               content: "第 \(i) 句", createTime: at.addingTimeInterval(Double(i)),
                               parentId: i == 0 ? nil : "m\(i - 1)", childrenIds: i + 1 < count ? ["m\(i + 1)"] : []))
        }
        // 尾部 3 条纯空白节点串成链（去掉空白后为空，但 content 非空所以进得了 visiblePath）
        let blanks = [" \n ", "   ", "\t"]
        for (offset, blank) in blanks.enumerated() {
            nodes.append(.init(id: "blank-\(offset)", conversationId: "reverse-src", role: "user", content: blank,
                               createTime: at.addingTimeInterval(Double(count + offset)),
                               parentId: offset == 0 ? "m\(count - 1)" : "blank-\(offset - 1)",
                               childrenIds: offset + 1 < blanks.count ? ["blank-\(offset + 1)"] : []))
        }
        let window = ConversationWindow(
            id: "reverse-src", profileId: pid, title: "倒序源窗", createTime: at, updateTime: at,
            currentNodeId: "m\(count - 1)",
            branchSelection: BranchSelection.encode(["m\(count - 1)": "blank-0", "blank-0": "blank-1", "blank-1": "blank-2"]))
        let source = FixedSource(nodesByFloor: [pid: nodes])
        XCTAssertEqual(visiblePath(window: window, nodes: nodes).map(\.id).suffix(3), ["blank-0", "blank-1", "blank-2"],
                       "夹具前提：空尾必须真在路径上，否则这条测试测的是空")

        // 旧算法在测试里内联一份作对照
        func legacy(_ wanted: Int) -> [PreviousWindowSnapshot.Message] {
            var messages: [PreviousWindowSnapshot.Message] = []
            for node in visiblePath(window: window, nodes: nodes) {
                let text = String(node.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(PreviousWindowPicker.maximumMessageCharacters))
                guard !text.isEmpty else { continue }
                messages.append(.init(nodeId: node.id, role: node.role, createTime: node.createTime, text: text))
            }
            return Array(messages.suffix(min(max(wanted, 0), PreviousWindowPicker.maximumMessages)))
        }
        for wanted in [-1, 0, 1, 6, 50, 100] {
            XCTAssertEqual(PreviousWindowPicker.capture(window, count: wanted, from: source).messages, legacy(wanted),
                           "count=\(wanted) 新旧算法必须逐字相同")
        }
        XCTAssertEqual(PreviousWindowPicker.capture(window, count: 6, from: source).messages.map(\.nodeId),
                       (count - 6..<count).map { "m\($0)" }, "凑够 6 条即停，尾部空正文不占名额")
    }

    func testValidateInvalidatesAndNeverRevives() throws {
        let context = ModelContext(try container())
        let src = window("src", context)
        node("u1", "user", "第一句", parent: nil, in: src, context)
        src.currentNodeId = "u1"
        try context.save()
        let snap = PreviousWindowPicker.capture(src, count: 6, context: context)
        XCTAssertEqual(PreviousWindowPicker.validate(snap, profileId: pid, context: context), snap)
        src.memoryEnabled = false
        let off = PreviousWindowPicker.validate(snap, profileId: pid, context: context)
        XCTAssertEqual(off.invalid, .memoryOff)
        XCTAssertTrue(off.messages.isEmpty, "失效即清正文")
        src.memoryEnabled = true
        XCTAssertEqual(PreviousWindowPicker.validate(off, profileId: pid, context: context).invalid, .memoryOff, "重新允许不复活")
        src.isTrashed = true
        XCTAssertEqual(PreviousWindowPicker.validate(snap, profileId: pid, context: context).invalid, .deleted)
        XCTAssertEqual(PreviousWindowPicker.validate(snap, profileId: "别的楼层", context: context).invalid, .missing)
        XCTAssertEqual(off.render(user: "岚舟", assistant: "星砚", budget: 10_000).text, "")
    }

    @MainActor
    func testSummaryValidatesPreviousWindowWithoutWritingBackInvalidation() throws {
        let db = try container()
        let context = ModelContext(db)
        let source = window("preview-source", context)
        node("preview-a", "assistant", "星砚接着上窗航图", parent: nil, in: source, context)
        source.currentNodeId = "preview-a"
        let target = window("preview-target", context)
        var choices = MemoryWindowChoices.allOff
        choices.previousWindow = true
        target.memoryWindowChoices = choices
        target.previousWindowId = source.id
        try context.save()
        target.previousWindowSnapshot = PreviousWindowPicker.capture(source, count: 6, context: context)
        source.memoryEnabled = false
        try context.save()
        let bytes = target.previousWindowSnapshotData
        let summary = MemoryResident.summary(profile: profile(), participation: .testValue(profileId: pid, choices: choices),
                                             container: db, selfMemories: [],
                                             previousWindow: target.previousWindowSnapshot)
        XCTAssertEqual(summary.stable, "")
        XCTAssertEqual(summary.volatile, "")
        let saved = try XCTUnwrap(ModelContext(db).fetch(FetchDescriptor<Conversation>()).first { $0.id == target.id })
        XCTAssertEqual(saved.previousWindowSnapshotData, bytes)
        XCTAssertNil(saved.previousWindowSnapshot?.invalid)
        XCTAssertEqual(saved.previousWindowSnapshot?.messages.map(\.nodeId), ["preview-a"])
    }

    func testFreezeAndInvalidateCopiesDoNotWriteMessages() throws {
        let context = ModelContext(try container())
        let src = window("src", context, stamp: Date(timeIntervalSince1970: 100))
        node("u1", "user", "第一句", parent: nil, in: src, context)
        src.currentNodeId = "u1"
        let target = window("new", context)
        try context.save()
        PreviousWindowPicker.freeze(target, context: context)
        XCTAssertEqual(target.memoryWindowChoices, MemoryWindowChoices.defaults(profileId: pid))
        XCTAssertEqual(target.previousWindowId, "src")
        XCTAssertEqual(target.previousWindowSnapshot?.messages.map(\.text), ["第一句"])
        var changed = MemoryWindowChoices.allOff
        changed.timeline = true
        target.memoryWindowChoices = changed
        PreviousWindowPicker.freeze(target, context: context)
        XCTAssertEqual(target.memoryWindowChoices, changed, "冻结过的不重来")
        let tid = target.id
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == tid })), 0,
                       "上个窗口不变成新窗消息")
        PreviousWindowPicker.invalidateCopies(of: ["src"], context: context)
        XCTAssertEqual(target.previousWindowSnapshot?.invalid, .deleted)
        XCTAssertEqual(target.previousWindowSnapshot?.messages, [])
    }

    /// E2-7b D：后台抓出来的快照必须和同步旧路径逐字相等（同一 `now`，否则 capturedAt 不同）
    @MainActor
    func testBackgroundCaptureMatchesSynchronousFreeze() async throws {
        let db = try container()
        let context = ModelContext(db)
        let src = window("bg-src", context, stamp: Date(timeIntervalSince1970: 100))
        node("u1", "user", "岚舟准备布展", parent: nil, in: src, context, at: 1)
        node("a1", "assistant", "星砚排好了展位", parent: "u1", in: src, context, at: 2)
        src.currentNodeId = "a1"
        let syncTarget = window("bg-sync", context)
        let asyncTarget = window("bg-async", context)
        try context.save()

        let now = Date(timeIntervalSince1970: 1_000)
        PreviousWindowPicker.freeze(syncTarget, context: context, now: now)
        let plan = try XCTUnwrap(PreviousWindowPicker.prepareFreeze(asyncTarget, context: context))
        let captured = await PreviousWindowPicker.captureInBackground(plan, container: db, now: now)
        let snapshot = try XCTUnwrap(captured)
        XCTAssertEqual(snapshot, syncTarget.previousWindowSnapshot)
        XCTAssertEqual(snapshot.messages.map(\.nodeId), ["u1", "a1"])
    }

    /// E2-7b D：冻结中划掉上个窗口 → 取消后台任务，结果不晚写
    @MainActor
    func testCancelledFreezeLeavesNoSnapshot() async throws {
        let context = ModelContext(try container())
        let original = window("cancel-src", context, stamp: Date(timeIntervalSince1970: 200))
        node("u1", "user", "岚舟准备布展", parent: nil, in: original, context)
        original.currentNodeId = "u1"
        try context.save()
        let vm = ConversationViewModel()
        vm.selectedConversation = original
        vm.startNewConversation(profileId: pid, fresh: true, cards: nil, explicit: true, context: context)
        let draft = try XCTUnwrap(vm.selectedConversation)
        XCTAssertTrue(vm.isFreezing(draft.id))
        var choices = try XCTUnwrap(draft.memoryWindowChoices)
        choices.previousWindow = false
        vm.confirmOpenWindowNote(choices)
        await vm.awaitPreviousWindowFreeze(draft.id)
        XCTAssertFalse(vm.isFreezing(draft.id))
        XCTAssertNil(draft.previousWindowId)
        XCTAssertNil(draft.previousWindowSnapshot, "冻结中划掉上个窗口，后台结果不晚写")
    }

    /// E2-7b D：冻结中目标窗被删 → 结果丢弃（不写已删对象）
    @MainActor
    func testFreezeResultDiscardedWhenTargetWindowIsGone() async throws {
        let context = ModelContext(try container())
        let src = window("gone-src", context, stamp: Date(timeIntervalSince1970: 100))
        node("u1", "user", "岚舟准备布展", parent: nil, in: src, context)
        src.currentNodeId = "u1"
        let target = window("gone-target", context)
        try context.save()
        let vm = ConversationViewModel()
        vm.selectedConversation = target
        vm.freezePreviousWindow(target, context: context)
        XCTAssertTrue(vm.isFreezing(target.id))
        context.delete(target)
        try context.save()
        await vm.awaitPreviousWindowFreeze("gone-target")
        XCTAssertFalse(vm.isFreezing("gone-target"))
        XCTAssertNil(target.previousWindowSnapshot, "迟到的后台结果不写已删对象")
        XCTAssertNil(try context.fetch(FetchDescriptor<Conversation>()).first { $0.id == "gone-target" }, "已删窗不复活")
    }

    /// E2-7b r4 M1：抓取挂起期间源窗进回收站 → 迟到的正文不能有效落盘（恢复源窗也不复活）
    @MainActor
    func testLateFreezeResultInvalidatesWhenSourceTrashedMeanwhile() async throws {
        let db = try container()
        let context = ModelContext(db)
        let src = window("m1-src", context, stamp: Date(timeIntervalSince1970: 100))
        node("m1-u1", "user", "岚舟收好图纸", parent: nil, in: src, context)
        src.currentNodeId = "m1-u1"
        let target = window("m1-target", context)
        try context.save()
        PreviousWindowPicker.debugCaptureDelay = .milliseconds(500)
        defer { PreviousWindowPicker.debugCaptureDelay = nil }
        let vm = ConversationViewModel()
        vm.freezePreviousWindow(target, context: context)
        XCTAssertTrue(vm.isFreezing(target.id))
        // 冻结挂起期：源窗进回收站；这时还没有快照，invalidateCopies 会跳过这份
        src.isTrashed = true
        try context.save()
        PreviousWindowPicker.invalidateCopies(of: [src.id], context: context)
        XCTAssertNil(target.previousWindowSnapshot)
        await vm.awaitPreviousWindowFreeze(target.id)
        XCTAssertFalse(vm.isFreezing(target.id))
        XCTAssertEqual(target.previousWindowSnapshot?.invalid, .deleted)
        XCTAssertEqual(target.previousWindowSnapshot?.messages, [])
        let saved = try XCTUnwrap(ModelContext(db).fetch(FetchDescriptor<Conversation>()).first { $0.id == target.id })
        XCTAssertEqual(saved.previousWindowSnapshot?.invalid, .deleted)
        // 恢复源窗也不复活：失效写在快照里，发送侧 validate 原样放行
        src.isTrashed = false
        try context.save()
        XCTAssertEqual(PreviousWindowPicker.validate(try XCTUnwrap(target.previousWindowSnapshot),
                                                     profileId: pid, context: context).invalid, .deleted)
    }

    /// E2-7b r4 M2：落库后 / 快照回写前进程退出 → 发送前按已存上窗 id 补冻，结果与同步 capture 一致
    @MainActor
    func testResumePreviousWindowFreezeAfterRestart() async throws {
        let db = try container()
        let context = ModelContext(db)
        let src = window("resume-src", context, stamp: Date(timeIntervalSince1970: 100))
        node("resume-u1", "user", "岚舟收好图纸", parent: nil, in: src, context, at: 1)
        node("resume-a1", "assistant", "星砚记下了", parent: "resume-u1", in: src, context, at: 2)
        src.currentNodeId = "resume-a1"
        let target = window("resume-target", context)
        target.memoryWindowChoices = MemoryWindowChoices.defaults(profileId: pid)
        target.previousWindowId = src.id
        try context.save()
        XCTAssertNil(target.previousWindowSnapshot, "模拟重启后：choices / 上窗 id 在，快照没了")
        let vm = ConversationViewModel()
        vm.resumePreviousWindowFreezeIfNeeded(target, context: context)
        XCTAssertTrue(vm.isFreezing(target.id), "补冻要重新登记后台抓取")
        await vm.awaitPreviousWindowFreeze(target.id)
        XCTAssertFalse(vm.isFreezing(target.id))
        let expected = PreviousWindowPicker.capture(src, count: RecallTuningStore.load(profileId: pid).previousWindowMessages,
                                                    context: context)
        XCTAssertEqual(target.previousWindowSnapshot?.messages, expected.messages)
        XCTAssertEqual(target.previousWindowSnapshot?.sourceId, src.id)
        XCTAssertNil(target.previousWindowSnapshot?.invalid)
        let saved = try XCTUnwrap(ModelContext(db).fetch(FetchDescriptor<Conversation>()).first { $0.id == target.id })
        XCTAssertEqual(saved.previousWindowSnapshot?.messages, expected.messages)
    }

    /// E2-7b r4 M2：源窗已经不存在 / 进回收站 → 补冻直接落不可逆占位（不回退成「没有快照」）
    @MainActor
    func testResumeFreezeWritesDeletedPlaceholderWhenSourceGone() throws {
        let db = try container()
        let context = ModelContext(db)
        let missing = window("resume-gone", context)
        missing.memoryWindowChoices = MemoryWindowChoices.defaults(profileId: pid)
        missing.previousWindowId = "no-such-window"
        let trashedSrc = window("resume-trashed-src", context, stamp: Date(timeIntervalSince1970: 100))
        trashedSrc.isTrashed = true
        let trashed = window("resume-trashed", context)
        trashed.memoryWindowChoices = MemoryWindowChoices.defaults(profileId: pid)
        trashed.previousWindowId = trashedSrc.id
        try context.save()
        let vm = ConversationViewModel()
        vm.resumePreviousWindowFreezeIfNeeded(missing, context: context)
        vm.resumePreviousWindowFreezeIfNeeded(trashed, context: context)
        for target in [missing, trashed] {
            XCTAssertEqual(target.previousWindowSnapshot?.invalid, .deleted)
            XCTAssertEqual(target.previousWindowSnapshot?.messages, [])
        }
        XCTAssertEqual(missing.previousWindowSnapshot?.sourceId, "no-such-window")
        let saved = try XCTUnwrap(ModelContext(db).fetch(FetchDescriptor<Conversation>()).first { $0.id == missing.id })
        XCTAssertEqual(saved.previousWindowSnapshot?.invalid, .deleted, "占位要落库，重启后不再重试")
        XCTAssertFalse(vm.isFreezing(missing.id))
    }

    /// E2-7b r4 M3：划掉上个窗口 = 取消任务 + 清登记，等待者立刻返回，不再等已取消任务跑完
    @MainActor
    func testCancelPreviousWindowFreezeReleasesWaiterImmediately() async throws {
        let context = ModelContext(try container())
        let src = window("m3-src", context, stamp: Date(timeIntervalSince1970: 100))
        node("m3-u1", "user", "岚舟收好图纸", parent: nil, in: src, context)
        src.currentNodeId = "m3-u1"
        let target = window("m3-target", context)
        try context.save()
        PreviousWindowPicker.debugCaptureDelay = .seconds(5)
        defer { PreviousWindowPicker.debugCaptureDelay = nil }
        let vm = ConversationViewModel()
        vm.freezePreviousWindow(target, context: context)
        XCTAssertTrue(vm.isFreezing(target.id))
        let started = ContinuousClock.now
        vm.cancelPreviousWindowFreeze(target.id)
        await vm.awaitPreviousWindowFreeze(target.id)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500), "取消后等待者立刻返回")
        XCTAssertFalse(vm.isFreezing(target.id))
        XCTAssertNil(target.previousWindowSnapshot, "取消后迟到结果不写")
    }

    // MARK: Z7 渲染与进 system 段

    func testBudgetKeepsNewestWholeMessagesAndAccountsForEnvelope() {
        let snap = PreviousWindowSnapshot(sourceId: "s", sourceTitle: "合成展览", leafId: "u2", capturedAt: .distantPast,
                                          messages: [.init(nodeId: "u1", role: "user", createTime: nil, text: String(repeating: "早", count: 400)),
                                                     .init(nodeId: "a1", role: "assistant", createTime: nil, text: "展位排好了"),
                                                     .init(nodeId: "u2", role: "user", createTime: nil, text: "那就这样")])
        let full = snap.render(user: "岚舟", assistant: "星砚", budget: .max)
        var newest = snap
        newest.messages = Array(snap.messages.suffix(2))
        let tail = newest.render(user: "岚舟", assistant: "星砚", budget: .max)
        let budget = (full.tokens + tail.tokens) / 2
        let tight = snap.render(user: "岚舟", assistant: "星砚", budget: budget)
        XCTAssertEqual(full.count, 3)
        XCTAssertEqual(tight.count, 2)
        XCTAssertTrue(tight.text.contains("岚舟：那就这样"))
        XCTAssertTrue(tight.text.contains("星砚：展位排好了"))
        XCTAssertFalse(tight.text.contains(String(repeating: "早", count: 400)))
        XCTAssertLessThanOrEqual(Memory.estimateTokens(tight.text), budget)

        newest.messages = Array(snap.messages.suffix(1))
        let single = newest.render(user: "岚舟", assistant: "星砚", budget: .max)
        let minimum = Memory.estimateTokens(single.text)
        XCTAssertEqual(newest.render(user: "岚舟", assistant: "星砚", budget: minimum).count, 1)
        XCTAssertEqual(newest.render(user: "岚舟", assistant: "星砚", budget: minimum - 1).count, 0)
    }

    func testRecallSelectionPutsPreviousWindowInStableOnlyWhenGiven() {
        let snap = PreviousWindowSnapshot(sourceId: "s", sourceTitle: "合成展览", leafId: "u1", capturedAt: Date(),
                                          messages: [.init(nodeId: "u1", role: "user", createTime: nil, text: "那就这样")])
        func run(_ previous: PreviousWindowSnapshot?, enabled: Bool = true) -> RecallMemoryLayers {
            var inputs = MemoryInjector.RoundInputs(memories: [], selfMemory: nil, archiveBudget: 1_000, wiki: .init(pages: []))
            inputs.rootIndex = false
            inputs.previousWindow = previous
            return RecallSelection.prepare(profile: profile(), conversationId: "w", turnId: "u", branchAnchor: "b", text: "今天做什么",
                                           state: .init(), existingDecision: nil, inputs: inputs, recentMessages: [],
                                           now: Date(timeIntervalSince1970: 1_800_000_000), tuning: RecallTestTuning.make(),
                                           enabled: enabled).layers
        }
        XCTAssertEqual(run(nil).stable, "")
        XCTAssertTrue(run(snap).stable.hasPrefix("[上一个窗口]"))
        XCTAssertTrue(run(snap).stable.contains("岚舟：那就这样"))
        XCTAssertEqual(run(snap, enabled: false).stable, "")
    }

    func testPreviousWindowNeitherUsesArchiveRemainderNorCrowdsOutRecall() {
        UserDefaults.standard.set(2_000, forKey: "mem_inject_budget")
        let snapshot = PreviousWindowSnapshot(sourceId: "s", sourceTitle: "云桥城", leafId: "a", capturedAt: .distantPast,
            messages: [.init(nodeId: "a", role: "assistant", createTime: nil, text: String(repeating: "航", count: 600))])
        let own = SelfMemoryInjection.Built(text: "[我的记忆]\n" + String(repeating: "岚", count: 1_900),
                                            tokens: 1_900, fullCount: 1, indexCount: 0, fullSlugs: ["map"])
        let page = WikiInjectionSnapshot.Page(path: "人/林栖", title: "林栖", triggers: ["林栖"], hook: "", now: "在云桥城绘图", validUntil: nil)
        func run(previous: PreviousWindowSnapshot?, budget: Int) -> (decision: RecallTurnDecision, layers: RecallMemoryLayers) {
            let inputs = MemoryInjector.RoundInputs(memories: [], selfMemory: own, archiveBudget: budget,
                                                    wiki: .init(pages: [page]), rootIndex: false, previousWindow: previous)
            return RecallSelection.prepare(profile: profile(), conversationId: "w", turnId: "u", branchAnchor: "u",
                text: "林栖在云桥城绘图的计划怎样了", state: .init(), existingDecision: nil, inputs: inputs, recentMessages: [],
                now: Date(timeIntervalSince1970: 1_800_000_000), tuning: RecallTestTuning.make())
        }
        XCTAssertTrue(run(previous: snapshot, budget: 0).layers.stable.contains("星砚：" + String(repeating: "航", count: 600)))
        let allowance = snapshot.render(user: "岚舟", assistant: "星砚", budget: MemoryInjector.tokenBudget).tokens
        let baseline = run(previous: nil, budget: allowance)
        XCTAssertEqual(baseline.decision.selected.map(\.source.path), ["人/林栖"])
        let withPrevious = run(previous: snapshot, budget: allowance)
        XCTAssertTrue(withPrevious.layers.stable.contains("星砚：" + String(repeating: "航", count: 600)))
        XCTAssertEqual(withPrevious.decision.selected, baseline.decision.selected)
        XCTAssertEqual(withPrevious.layers.volatile, baseline.layers.volatile)
    }

    func testShareIsPercentOfCheckedItems() {
        let rows = [MemoryNotePreviewRow(item: .timeline, summary: "", tokens: 300),
                    MemoryNotePreviewRow(item: .pending, summary: "", tokens: 100),
                    MemoryNotePreviewRow(item: .pinned, summary: "", tokens: 600)]
        var choices = MemoryWindowChoices.allOff
        choices.timeline = true
        choices.pending = true
        let share = MemoryNotePreview.share(rows, choices: choices)
        XCTAssertEqual(share.total, 400)
        XCTAssertEqual(share.percent[.timeline], 75)
        XCTAssertEqual(share.percent[.pending], 25)
        XCTAssertNil(share.percent[.pinned], "不带的不算占比")
        XCTAssertEqual(MemoryNotePreview.share(rows, choices: .allOff).total, 0)
    }

    /// E2-7b：纸条在后台冻结没落定时显示「正在读取上个窗口…」，落定后回到真实摘要
    func testPreviewPreviousWindowRowShowsPendingUntilSnapshotLands() throws {
        let db = try container()
        let context = ModelContext(db)
        func previousSummary(pending: Bool) -> String? {
            MemoryNotePreview.rows(profile: profile(), conversationId: "target", snapshot: nil,
                                   store: SwiftDataMemoryStore(), context: context, wiki: nil,
                                   previousPending: pending)
                .first { $0.item == .previousWindow }?.summary
        }
        XCTAssertEqual(previousSummary(pending: true), "正在读取上个窗口…")
        XCTAssertEqual(previousSummary(pending: false), "没有上一个窗口")
    }

    // MARK: ④-4 已有窗口的菜单纸条

    @MainActor
    func testEditingExistingWindowPersistsOnlyTargetWithoutCreatingDraft() throws {
        let db = try container()
        let context = ModelContext(db)
        context.autosaveEnabled = false
        let current = window("current", context)
        let target = window("menu-target", context)
        current.memoryWindowChoices = .allOff
        target.memoryWindowChoices = MemoryWindowChoices.defaults(profileId: pid)
        try context.save()
        let defaults = MemoryWindowChoices.defaults(profileId: pid)
        let vm = ConversationViewModel()
        vm.selectedConversation = current
        vm.editOpenWindowNote(for: target)
        var edited = MemoryWindowChoices.allOff
        edited.pending = true
        edited.pinned = true
        vm.confirmOpenWindowNote(edited)

        XCTAssertNil(vm.openWindowNote)
        XCTAssertEqual(vm.selectedConversation?.id, current.id, "列表右键编辑别窗也不切走当前窗")
        XCTAssertFalse(vm.isDraftConversation)
        let reader = ModelContext(db)
        let windows = try reader.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(Set(windows.map(\.id)), ["current", "menu-target"], "编辑不生成新窗口")
        XCTAssertEqual(windows.first { $0.id == target.id }?.memoryWindowChoices, edited, "确认立即落库")
        XCTAssertEqual(windows.first { $0.id == current.id }?.memoryWindowChoices, .allOff)
        XCTAssertEqual(MemoryWindowChoices.defaults(profileId: pid), defaults, "本窗选择不回写楼层默认")
    }

    @MainActor
    func testConfirmingUntouchedLegacyNoteDoesNotFreezeAndArchiveShowsTrigger() throws {
        let db = try container()
        let context = ModelContext(db)
        let target = window("legacy", context)
        try context.save()
        let vm = ConversationViewModel()
        for root in [false, true] {
            MemoryOpenWindowStore.save(.c, root, profileId: pid)
            RecallTuningStore.save(RecallTestTuning.make(), profileId: pid)
            vm.editOpenWindowNote(for: target)
            let shown = try XCTUnwrap(vm.openWindowNote).initialChoices
            XCTAssertTrue(shown.archive, "老窗触发开时档案行显示开")
            vm.confirmOpenWindowNote(shown, initialChoices: shown)
            XCTAssertNil(target.memoryWindowChoicesData)
            let saved = try XCTUnwrap(ModelContext(db).fetch(FetchDescriptor<Conversation>()).first)
            XCTAssertNil(saved.memoryWindowChoicesData)
            vm.editOpenWindowNote(for: target)
            vm.confirmOpenWindowNote(MemoryWindowChoices.legacy(profileId: pid))
            XCTAssertNil(target.memoryWindowChoicesData, "传原 legacy 值也不把老窗冻结成新窗")
        }
        MemoryOpenWindowStore.save(.c, false, profileId: pid)
        vm.editOpenWindowNote(for: target)
        let initial = try XCTUnwrap(vm.openWindowNote).initialChoices
        var changed = initial
        changed.archive = false
        vm.confirmOpenWindowNote(changed, initialChoices: initial)
        XCTAssertEqual(target.memoryWindowChoices?.archive, false, "主动划掉档案必须关掉老窗触发")
    }

    @MainActor
    func testCancelAndDismissExistingNotePreserveSelectionAndFrozenSnapshot() throws {
        let context = ModelContext(try container())
        let current = window("current", context)
        current.memoryWindowChoices = .allOff
        let snapshot = PreviousWindowSnapshot(sourceId: "earlier", sourceTitle: "云桥城布展", leafId: "a1",
                                             capturedAt: Date(timeIntervalSince1970: 100),
                                             messages: [.init(nodeId: "a1", role: "assistant", createTime: nil, text: "星砚排好了展位")])
        current.previousWindowId = snapshot.sourceId
        current.previousWindowSnapshot = snapshot
        try context.save()
        let vm = ConversationViewModel()
        vm.selectedConversation = current
        vm.editOpenWindowNote(for: current)
        vm.cancelOpenWindowNote(context: context)
        XCTAssertNil(vm.openWindowNote)
        XCTAssertEqual(vm.selectedConversation?.id, current.id)
        XCTAssertFalse(vm.isDraftConversation)
        XCTAssertEqual(current.memoryWindowChoices, .allOff)
        XCTAssertEqual(current.previousWindowSnapshot, snapshot)

        vm.editOpenWindowNote(for: current)
        vm.dismissOpenWindowNote()
        XCTAssertNil(vm.openWindowNote)
        XCTAssertEqual(vm.selectedConversation?.id, current.id)
        XCTAssertEqual(current.memoryWindowChoices, .allOff)
        XCTAssertEqual(current.previousWindowSnapshot, snapshot, "下滑关编辑纸条不按新建确认清掉未勾选的副本")
    }

    @MainActor
    func testEnablingPreviousWindowInExistingNoteDoesNotCaptureNow() throws {
        let context = ModelContext(try container())
        let source = window("source", context, stamp: Date(timeIntervalSince1970: 300))
        node("source-a", "assistant", "源窗现在有一段新话", parent: nil, in: source, context)
        source.currentNodeId = "source-a"
        let target = window("target", context)
        try context.save()
        let vm = ConversationViewModel()
        vm.selectedConversation = target
        vm.editOpenWindowNote(for: target)
        XCTAssertEqual(EffectiveMemoryParticipation.resolve(profileId: pid, conversation: target, preset: nil).choices,
                       MemoryWindowChoices.legacy(profileId: pid).participationChoices)
        var edited = MemoryWindowChoices.allOff
        edited.previousWindow = true
        vm.confirmOpenWindowNote(edited)
        XCTAssertTrue(target.memoryWindowChoices?.previousWindow == true)
        XCTAssertNil(target.previousWindowId)
        XCTAssertNil(target.previousWindowSnapshot, "开窗时没抓到，后来勾选也不能抓当前的上窗")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageNode>()), 1, "上窗不写进本窗消息")
    }

    @MainActor
    func testEditingAnotherWindowDoesNotCommitOrDiscardCurrentDraft() async throws {
        let context = ModelContext(try container())
        let target = window("existing", context)
        try context.save()
        MemoryWindowChoices.setDefault(.previousWindow, false, profileId: pid)
        target.lastRealChatAt = Date(timeIntervalSince1970: 100)
        node("existing-a", "assistant", "星砚接上话头", parent: nil, in: target, context)
        target.currentNodeId = "existing-a"
        try context.save()
        let vm = ConversationViewModel()
        vm.startNewConversation(profileId: pid, fresh: true, cards: nil, explicit: true, context: context)
        let draft = try XCTUnwrap(vm.selectedConversation)
        // E2-7b：正文在后台抓，等它落定再读快照
        await vm.awaitPreviousWindowFreeze(draft.id)
        XCTAssertEqual(draft.previousWindowSnapshot?.messages.map(\.nodeId), ["existing-a"])
        vm.dismissOpenWindowNote()
        XCTAssertNil(draft.previousWindowId)
        XCTAssertNil(draft.previousWindowSnapshot, "新建下滑按默认关上窗，清除为纸条预抓的副本")
        vm.editOpenWindowNote(for: target)
        vm.cancelOpenWindowNote(context: context)
        XCTAssertEqual(vm.selectedConversation?.id, draft.id)
        XCTAssertTrue(vm.isDraftConversation)
        vm.editOpenWindowNote(for: target)
        vm.confirmOpenWindowNote(.allOff)
        XCTAssertEqual(vm.selectedConversation?.id, draft.id)
        XCTAssertTrue(vm.isDraftConversation)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Conversation>()).map(\.id), ["existing"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MessageNode>()).map(\.id), ["existing-a"])
    }

    @MainActor
    func testNewNoteFreezesOnceAndCancelReturnsWithoutPersistingDraft() async throws {
        let context = ModelContext(try container())
        let original = window("original", context, stamp: Date(timeIntervalSince1970: 200))
        node("u1", "user", "岚舟准备布展", parent: nil, in: original, context)
        original.currentNodeId = "u1"
        try context.save()
        let vm = ConversationViewModel()
        vm.selectedConversation = original
        vm.startNewConversation(profileId: pid, fresh: true, cards: nil, explicit: true, context: context)
        let draft = try XCTUnwrap(vm.selectedConversation)
        await vm.awaitPreviousWindowFreeze(draft.id)
        let frozen = try XCTUnwrap(draft.previousWindowSnapshot)
        XCTAssertEqual(frozen.messages.map(\.nodeId), ["u1"])
        node("a1", "assistant", "源窗后来续聊", parent: "u1", in: original, context)
        original.currentNodeId = "a1"
        vm.startNewConversation(profileId: pid, cards: nil, explicit: true, context: context)
        XCTAssertEqual(vm.selectedConversation?.id, draft.id)
        XCTAssertEqual(draft.previousWindowSnapshot, frozen)
        vm.cancelOpenWindowNote(context: context)
        for _ in 0..<200 where vm.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.openWindowNote)
        XCTAssertEqual(vm.selectedConversation?.id, original.id)
        XCTAssertFalse(vm.isDraftConversation)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Conversation>()).map(\.id), ["original"])
    }

    @MainActor
    func testCancelNewNoteWithoutReturnOrWithDeletedReturnClearsUnselectedSnapshot() async throws {
        let context = ModelContext(try container())
        let source = window("cancel-source", context, stamp: Date(timeIntervalSince1970: 100))
        node("cancel-a", "assistant", "星砚接着聊", parent: nil, in: source, context)
        source.currentNodeId = "cancel-a"
        MemoryWindowChoices.setDefault(.previousWindow, false, profileId: pid)
        try context.save()
        let vm = ConversationViewModel()
        vm.startNewConversation(profileId: pid, fresh: true, cards: nil, explicit: true, context: context)
        let noReturn = try XCTUnwrap(vm.selectedConversation)
        await vm.awaitPreviousWindowFreeze(noReturn.id)
        XCTAssertNotNil(noReturn.previousWindowSnapshot)
        vm.cancelOpenWindowNote(context: context)
        XCTAssertTrue(vm.isDraftConversation)
        XCTAssertNil(noReturn.previousWindowId)
        XCTAssertNil(noReturn.previousWindowSnapshot)

        vm.loadConversation(source, context: context)
        for _ in 0..<200 where vm.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(vm.isLoading)
        vm.startNewConversation(profileId: pid, fresh: true, cards: nil, explicit: true, context: context)
        let deletedReturn = try XCTUnwrap(vm.selectedConversation)
        await vm.awaitPreviousWindowFreeze(deletedReturn.id)
        XCTAssertNotNil(deletedReturn.previousWindowSnapshot)
        source.isTrashed = true
        vm.cancelOpenWindowNote(context: context)
        XCTAssertEqual(vm.selectedConversation?.id, deletedReturn.id)
        XCTAssertNil(deletedReturn.previousWindowId)
        XCTAssertNil(deletedReturn.previousWindowSnapshot)
    }

    @MainActor
    func testVMSoftAndPermanentDeleteClearOtherWindowCopies() throws {
        let schema = ProfileManager.makeFullSchema()
        let db = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(db)
        let vm = ConversationViewModel()
        for permanent in [false, true] {
            let source = window(permanent ? "permanent-source" : "soft-source", context)
            let sourceId = source.id
            node(source.id + "-a", "assistant", "星砚的源窗正文", parent: nil, in: source, context)
            source.currentNodeId = source.id + "-a"
            let target = window(source.id + "-copy", context)
            target.previousWindowId = source.id
            try context.save()
            target.previousWindowSnapshot = PreviousWindowPicker.capture(source, count: 6, context: context)
            let moved = window(source.id + "-moved-copy", context, profileId: pid + "-other")
            moved.previousWindowId = source.id
            moved.previousWindowSnapshot = target.previousWindowSnapshot
            try context.save()
            if permanent { vm.permanentlyDeleteConversation(source, context: context) }
            else { vm.softDeleteConversation(source) }
            XCTAssertEqual(target.previousWindowSnapshot?.invalid, .deleted)
            XCTAssertEqual(target.previousWindowSnapshot?.messages, [])
            XCTAssertEqual(moved.previousWindowSnapshot?.invalid, .deleted)
            XCTAssertEqual(moved.previousWindowSnapshot?.messages, [])
            let saved = try XCTUnwrap(ModelContext(db).fetch(FetchDescriptor<Conversation>()).first { $0.id == target.id })
            XCTAssertEqual(saved.previousWindowSnapshot?.invalid, .deleted)
            XCTAssertEqual(saved.previousWindowSnapshot?.messages, [])
            let persisted = try ModelContext(db).fetch(FetchDescriptor<Conversation>())
            let savedMoved = try XCTUnwrap(persisted.first { $0.id == moved.id })
            XCTAssertEqual(savedMoved.previousWindowSnapshot?.invalid, .deleted)
            XCTAssertEqual(savedMoved.previousWindowSnapshot?.messages, [])
            if permanent {
                XCTAssertFalse(persisted.contains { $0.id == sourceId })
            } else {
                XCTAssertTrue(try XCTUnwrap(persisted.first { $0.id == sourceId }).isTrashed)
            }
            if !permanent {
                vm.restoreConversation(source)
                XCTAssertEqual(PreviousWindowPicker.validate(try XCTUnwrap(saved.previousWindowSnapshot), profileId: pid, context: context).invalid, .deleted)
            }
        }
    }

    @MainActor
    func testProfileDeletionClearsMovedCopiesWithoutClearingOtherSources() throws {
        let schema = ProfileManager.makeFullSchema()
        let db = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(db)
        let deleted = profile()
        let kept = Profile(id: pid + "-kept", name: "星港", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "xctest-profile-delete-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let manager = ProfileManager(container: db, profiles: [deleted, kept], currentProfile: kept,
                                     loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let source = window("floor-source", context)
        node("floor-a", "assistant", "源楼层正文", parent: nil, in: source, context)
        source.currentNodeId = "floor-a"
        let moved = window("moved-copy", context, profileId: kept.id)
        moved.previousWindowId = source.id
        try context.save()
        moved.previousWindowSnapshot = PreviousWindowPicker.capture(source, count: 6, context: context)
        let otherSource = window("kept-source", context, profileId: kept.id)
        node("kept-a", "assistant", "保留的正文", parent: nil, in: otherSource, context)
        otherSource.currentNodeId = "kept-a"
        let otherCopy = window("kept-copy", context, profileId: kept.id)
        otherCopy.previousWindowId = otherSource.id
        try context.save()
        let unchanged = PreviousWindowPicker.capture(otherSource, count: 6, context: context)
        otherCopy.previousWindowSnapshot = unchanged
        try context.save()

        manager.deleteProfile(deleted, deleteData: true)

        let persisted = try ModelContext(db).fetch(FetchDescriptor<Conversation>())
        XCTAssertFalse(persisted.contains { $0.profileId == deleted.id })
        let saved = try XCTUnwrap(persisted.first { $0.id == moved.id })
        XCTAssertEqual(saved.previousWindowSnapshot?.invalid, .deleted)
        XCTAssertEqual(saved.previousWindowSnapshot?.messages, [])
        XCTAssertEqual(try XCTUnwrap(persisted.first { $0.id == otherCopy.id }).previousWindowSnapshot, unchanged)
    }

    func testImportRemovalClearsCopiesInTheDeletionTransaction() throws {
        let schema = ProfileManager.makeFullSchema()
        let db = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(db)
        context.autosaveEnabled = false
        let source = window("import-source", context, provider: "sillytavern")
        node("import-a", "assistant", "撤回的源正文", parent: nil, in: source, context)
        source.currentNodeId = "import-a"
        let target = window("import-copy", context)
        target.previousWindowId = source.id
        try context.save()
        target.previousWindowSnapshot = PreviousWindowPicker.capture(source, count: 6, context: context)
        try context.save()

        try deleteConversationArtifacts(conversationId: source.id, profileId: pid, in: context)
        try context.save()

        let persisted = try ModelContext(db).fetch(FetchDescriptor<Conversation>())
        XCTAssertFalse(persisted.contains { $0.id == "import-source" })
        let saved = try XCTUnwrap(persisted.first { $0.id == target.id })
        XCTAssertEqual(saved.previousWindowSnapshot?.invalid, .deleted)
        XCTAssertEqual(saved.previousWindowSnapshot?.messages, [])
        XCTAssertEqual(try ModelContext(db).fetchCount(FetchDescriptor<MessageNode>()), 0)
    }

    @MainActor
    func testProfileSwitchDismissesNoteBeforeOldModelsAreReleased() throws {
        let context = ModelContext(try container())
        let target = window("old-floor", context)
        let vm = ConversationViewModel()
        vm.selectedConversation = target
        vm.editOpenWindowNote(for: target)
        NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
        XCTAssertNil(vm.openWindowNote)
        XCTAssertNil(vm.selectedConversation)
        vm.confirmOpenWindowNote(.allOff)
        XCTAssertNil(target.memoryWindowChoices, "旧楼层纸条不能在切层后迟到写回")
    }

    func testCalendarSlotAppliesAllFourTimelinePendingChoicesAndMasterGate() throws {
        let dir = TimelineStore.dir(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        defer { try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-600)
        let entry = TimelineEntry(start: start, end: now, conversationId: "window-岚舟", title: "云桥城布展",
                                  text: "- 星砚排完合成展位", pending: "写布展清单", day: MemoryDay.key(start), lastNodeId: "old-a")
        try TimelineStore.seedLegacy(entry, in: dir)
        for timeline in [false, true] {
            for pending in [false, true] {
                var choices = MemoryWindowChoices.allOff
                choices.timeline = timeline
                choices.pending = pending
                let slot = CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid, choices: choices))
                XCTAssertEqual(slot.timeline?.contains("星砚排完合成展位") ?? false, timeline)
                XCTAssertEqual(slot.timeline?.contains("写布展清单") ?? false, pending)
                XCTAssertEqual(slot.units.isEmpty, !timeline)
            }
        }
        UserDefaults.standard.set(false, forKey: "mem_master")
        var choices = MemoryWindowChoices.allOff
        choices.timeline = true
        choices.pending = true
        let off = CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid, choices: choices))
        XCTAssertNil(off.timeline)
        XCTAssertTrue(off.units.isEmpty)
    }

    /// P2：关参与（master / 本窗）整段不带，含纪念日；只划掉 timeline / pending 一项时纪念日照带（两项都划才不带）
    func testCalendarSlotFollowsParticipationAndAnniversaryGate() throws {
        let dir = TimelineStore.dir(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        let anniversaryRoot = AnniversaryStore.forProfile(pid).root
        defer {
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
            try? FileManager.default.removeItem(at: anniversaryRoot)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-600)
        try TimelineStore.seedLegacy(TimelineEntry(start: start, end: now, conversationId: "window-岚舟", title: "云桥城布展",
                                                   text: "- 星砚排完合成展位", pending: "写布展清单", day: MemoryDay.key(start), lastNodeId: "old-a"),
                                     in: dir)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let soon = "云桥城周年"
        try AnniversaryStore.forProfile(pid).save(Anniversary(title: soon, kind: .countdown,
                                                              date: formatter.string(from: Date().addingTimeInterval(2 * 86400)),
                                                              remindDays: 5))

        let open = CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid))
        XCTAssertTrue(open.text?.contains("星砚排完合成展位") ?? false)
        XCTAssertTrue(open.text?.contains("写布展清单") ?? false)
        XCTAssertTrue(open.text?.contains(soon) ?? false, "开参与：纪念日照带")

        let windowOff = CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid, window: false))
        XCTAssertNil(windowOff.text, "本窗关参与：时间轴 / 待续 / 纪念日都不带")
        let masterOff = CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid, master: false))
        XCTAssertNil(masterOff.text, "master 关：整段不带")

        var bothOff = MemoryWindowChoices.allOff
        bothOff.timeline = false
        bothOff.pending = false
        XCTAssertNil(CalendarInjection.timelineSlot(profileId: pid, now: now,
                                                    participation: .testValue(profileId: pid, choices: bothOff)).text,
                     "两项都划掉：纪念日也不带")

        var pendingOnly = MemoryWindowChoices.allOff
        pendingOnly.pending = true
        let pendingSlot = CalendarInjection.timelineSlot(profileId: pid, now: now,
                                                         participation: .testValue(profileId: pid, choices: pendingOnly))
        XCTAssertTrue(pendingSlot.text?.contains("写布展清单") ?? false)
        XCTAssertTrue(pendingSlot.text?.contains(soon) ?? false, "只划一项：纪念日照带")

        var timelineOnly = MemoryWindowChoices.allOff
        timelineOnly.timeline = true
        let timelineSlot = CalendarInjection.timelineSlot(profileId: pid, now: now,
                                                          participation: .testValue(profileId: pid, choices: timelineOnly))
        XCTAssertTrue(timelineSlot.text?.contains("星砚排完合成展位") ?? false)
        XCTAssertTrue(timelineSlot.text?.contains(soon) ?? false, "只划一项：纪念日照带")
    }

    /// Opus 建议 3（有意变化，钉住）：老窗（choices nil）开参与时纪念日跟楼层 A4（legacy timeline = pending）。
    /// A4 不勾 → 时间轴 / 待续 / 纪念日都不带；A4 勾 → 纪念日带上
    func testLegacyWindowAnniversaryFollowsFloorA4() throws {
        let anniversaryRoot = AnniversaryStore.forProfile(pid).root
        defer { try? FileManager.default.removeItem(at: anniversaryRoot) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let soon = "老窗周年"
        try AnniversaryStore.forProfile(pid).save(Anniversary(title: soon, kind: .countdown,
                                                              date: formatter.string(from: Date().addingTimeInterval(2 * 86400)),
                                                              remindDays: 5))

        MemoryOpenWindowStore.save(.a4, false, profileId: pid)
        let a4Off = CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid))
        XCTAssertFalse(a4Off.text?.contains(soon) ?? false, "A4 不勾：纪念日也不带（老窗开参与）")
        XCTAssertNil(a4Off.text, "时间轴 / 待续 / 纪念日整段为空")

        MemoryOpenWindowStore.save(.a4, true, profileId: pid)
        let a4On = CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid))
        XCTAssertTrue(a4On.text?.contains(soon) ?? false, "A4 勾：老窗照样带纪念日")
    }
}

/// 两楼层同 id 的窗口在 SwiftData 里存不下（`Conversation.id` / `MessageNode.id` 都是 unique，静默 upsert），
/// 用只实现 `nodes` 的固定源验证 `capture` 把 `window.profileId` 带到了协议上。
private enum FixedSourceFailure: Error {
    case boom
}

private struct FixedSource: ConversationSource {
    let nodesByFloor: [String: [ConversationMessage]]
    var throwing = false

    func windows(profileId: String, updatedSince: Date?, includeTrashed: Bool) throws -> [ConversationWindow] { [] }
    func window(profileId: String, idOrPrefix: String) throws -> ConversationWindow? { nil }
    func nodes(profileId: String, conversationId: String) throws -> [ConversationMessage] {
        if throwing { throw FixedSourceFailure.boom }
        return (nodesByFloor[profileId] ?? []).filter { $0.conversationId == conversationId }
    }
    func messages(profileId: String, ids: [String]) throws -> [ConversationMessage] { [] }
    func search(profileId: String, text: String, conversationId: String?) throws -> [ConversationMessage] { [] }
    func titles(profileId: String, ids: [String]) throws -> [String: String] { [:] }
}
