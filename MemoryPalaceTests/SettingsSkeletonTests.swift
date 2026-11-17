import MemoryCore
import XCTest
@testable import 记忆花园

/// 设置 → 记忆 的骨架按粟粟 11-15 批的排法锁住（写按 ABC、读按 Z / X / Y；没做完的去开发调试）；挪走的行老位置没有
final class SettingsSkeletonTests: XCTestCase {

    typealias Row = MemoryPageLayout.Row

    func testSectionTitlesInHerOrder() {
        XCTAssertEqual(MemoryPageLayout.sections.map(\.title),
                       ["", "写 · A 纪录片", "写 · B 日记", "写 · C 活档案", "读 · Z 每轮都带", "读 · X 自动推送", "读 · Y {助手}主动翻", "接口", ""])
        XCTAssertEqual(MemoryPageLayout.title(MemoryPageLayout.sections[6], assistant: "星砚"), "读 · Y 星砚主动翻", "助手名用楼层变量")
    }

    func testTopBlock() {
        XCTAssertEqual(MemoryPageLayout.sections[0].rows, [.master, .startDay, .extractModel, .writeBudget],
                       "总开关 / 起点 / 默认模型 / 写入预算；复杂度删了")
    }

    func testWritersOneRowEachInCodeOrder() {
        XCTAssertEqual(MemoryPageLayout.sections[1].rows.compactMap(\.writer), [.a2, .a3, .a4])
        XCTAssertEqual(MemoryPageLayout.sections[2].rows.compactMap(\.writer), [.b1, .b4])
        XCTAssertEqual(MemoryPageLayout.sections[3].rows.compactMap(\.writer), [.c2, .c3])
        let writers = MemoryPageLayout.sections.flatMap(\.rows).compactMap(\.writer)
        XCTAssertTrue(writers.allSatisfy { SettingsRoute.memoryWriter($0) != nil }, "一级页上的都能点进二级页")
        XCTAssertFalse(writers.contains { $0.isTodo }, "还没做的去开发调试 › 记忆 · 没做完的")
        XCTAssertFalse(writers.contains(.c), "C 档案那行删了（列表在记忆页里）")
    }

    func testReadAndInterfaceAndBottom() {
        XCTAssertEqual(MemoryPageLayout.sections[4].rows, [.openWindow, .injectBudget])
        XCTAssertEqual(MemoryPageLayout.sections[5].rows, [.archiveTrigger], "一轮最多几页 / 冷却进聊到才带的二级页")
        XCTAssertEqual(MemoryPageLayout.sections[6].rows, [.convHistory])
        XCTAssertEqual(MemoryPageLayout.sections[7].rows, [.ccMemorySync, .recall])
        XCTAssertEqual(MemoryPageLayout.sections[8].rows, [.auditSettings, .explainer])
    }

    func testDisplayNames() {
        XCTAssertEqual(MemoryWriterID.c2.displayTitle(assistant: "星砚"), "原子事实")
        XCTAssertEqual(MemoryWriterID.c3.displayTitle(assistant: "星砚"), "wiki 整理")
        XCTAssertEqual(MemoryWriterID.b4.displayTitle(assistant: "星砚"), "星砚的记忆")
        XCTAssertEqual(MemoryWriterID.c2.title(assistant: ""), "碎片池", "写进写入日志 md 给助手 / CC 读的老名字不动")
        XCTAssertEqual(RecallTuning.Field.Page.archiveTrigger.rawValue, "系统推送给助手")
    }

    func testMovedRowsNotOnMainPage() {
        let names = Set(Row.allCases.map(\.rawValue))
        for gone in ["dream", "profile", "portrait", "profileInject", "extractPrompt", "extractInterval", "advanced", "facts", "heartvoice",
                     "summary", "timeline", "selfRecent", "selfDailyLimit",
                     "complexity", "writerB2", "writerB3", "writerC", "audit", "pending", "trash",
                     "everyRound", "automatic", "browse", "seen", "oldFragments", "maximumPages", "cooldown",
                     "injectFull", "injectKeyword", "injectVector", "injectGraph"] {
            XCTAssertFalse(names.contains(gone), "\(gone) 不该还在主页上")
        }
        let all = MemoryPageLayout.sections.flatMap(\.rows)
        XCTAssertEqual(all.count, 19)
        XCTAssertEqual(all.count, Set(all).count, "一行只出现一次")
        XCTAssertEqual(Set(all), Set(Row.allCases), "每一行都有位置")
    }

    func testOpenWindowRows() {
        XCTAssertEqual(MemoryOpenWindow.rows, [.a2, .a4, .b4, .c], "A3 不注入、B1 是工具，都不列")
    }

    /// 一级页「勾了 N 项」= 二级页上勾着的圈数：四项 + 待续 / 上一个窗口 / 钉住的 + 原子事实每轮全带（以前只数前四项）
    func testOpenWindowCheckedCountMatchesPage() throws {
        let suite = "xctest-open-window-count-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let pid = "xctest-open-window-count"
        XCTAssertEqual(MemoryOpenWindow.checkedCount(profileId: pid, defaults: d), 6, "没动过：A2 A4 B4 + 三勾")
        MemoryOpenWindow.setEveryRound(true, profileId: pid, defaults: d)
        MemoryOpenWindowStore.save(.c, true, profileId: pid, defaults: d)
        XCTAssertEqual(MemoryOpenWindow.checkedCount(profileId: pid, defaults: d), 8, "全勾 = 八个圈")
        MemoryWindowChoices.setDefault(.pinned, false, profileId: pid, defaults: d)
        MemoryOpenWindowStore.save(.a2, false, profileId: pid, defaults: d)
        XCTAssertEqual(MemoryOpenWindow.checkedCount(profileId: pid, defaults: d), 6)
    }

    func testSearchAnchorsForNewRows() {
        let anchors = Set(SettingsSearchEntry.all.compactMap(\.anchor))
        for a in ["leaf-mem-writebudget", "leaf-mem-openwindow", "leaf-mem-extractmodel", "leaf-mem-ccsync", "leaf-mem-auditsettings",
                  "leaf-mem-explainer", "leaf-mem-c2-organize", "leaf-mem-maximumpages", "leaf-mem-cooldown"]
            + [MemoryWriterID.a2, .a3, .a4, .b1, .b4, .c2, .c3].map({ "leaf-mem-w-\($0.rawValue)" }) {
            XCTAssertTrue(anchors.contains(a), "设置搜索少了 \(a)")
        }
        for gone in ["leaf-mem-userprofile", "leaf-mem-dream", "leaf-mem-advanced", "leaf-mem-advanced-session", "leaf-mem-extractprompt",
                     "leaf-mem-hygiene", "leaf-mem-complexity", "leaf-mem-pending", "leaf-mem-audit", "leaf-mem-w-c",
                     "leaf-mem-content", "leaf-mem-inject",
                     // 11-15 删小字：翻记忆页那几行只读数字
                     "leaf-mem-readcharacters", "leaf-mem-datepage", "leaf-mem-windowpage", "leaf-mem-searchpage",
                     "leaf-mem-wikipage", "leaf-mem-originalpage"] {
            XCTAssertFalse(anchors.contains(gone), "\(gone) 该删")
            XCTAssertFalse(SettingsSearchEntry.all.contains { $0.id == gone }, "\(gone) 该删")
        }
        for moved in ["leaf-mem-w-b2", "leaf-mem-w-b3", "leaf-mem-injectvector",
                      "leaf-mem-injectgraph", "leaf-debug-memory-unfinished"] {
            let entry = SettingsSearchEntry.all.first { $0.id == moved }
            XCTAssertEqual(entry?.tab, .debug, "\(moved) 搬去开发调试")
        }
    }

    /// 11-15：全量注入变成开窗口页里的「原子事实每轮全带」，关键词命中退掉；档案根索引改叫 wiki 目录。旧名字还搜得到
    func testEveryRoundAndWikiDirectoryRows() {
        for gone in ["leaf-mem-injectfull", "leaf-mem-injectkeyword"] {
            XCTAssertFalse(SettingsSearchEntry.all.contains { $0.id == gone }, "\(gone) 该删")
        }
        let every = SettingsSearchEntry.all.first { $0.id == "leaf-mem-everyround" }
        XCTAssertEqual(every?.title, "原子事实每轮全带")
        XCTAssertEqual(every?.tab, .memory)
        XCTAssertEqual(every?.subtitle, "记忆 › 开窗口带什么")
        XCTAssertTrue(every?.keywords.contains("全量注入") == true && every?.keywords.contains("关键词命中") == true)
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-everyround"), .memoryOpenWindow)
        let root = SettingsSearchEntry.all.first { $0.id == "leaf-mem-rootindex" }
        XCTAssertEqual(root?.title, "wiki 目录")
        XCTAssertTrue(root?.keywords.contains("档案根索引") == true)
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-rootindex"), .memoryOpenWindow)
        XCTAssertFalse(SettingsSearchEntry.all.contains { $0.title == "全量注入" || $0.title == "关键词命中" || $0.title == "档案根索引" })
    }

    func testMovedRowsSearchLandsOnTheirNewPage() {
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-maximumpages"), .memoryArchiveTrigger)
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-cooldown"), .memoryArchiveTrigger)
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-ccmemory"), .memoryCCSync)
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-garden-to-cc"), .memoryCCSync)
        XCTAssertEqual(SettingsSearchEntry.memorySubpage(for: "leaf-mem-c2-organize"), .memoryAuditSettings)
        XCTAssertNil(SettingsSearchEntry.memorySubpage(for: "leaf-mem-ccsync"), "一级页上那一行本身不推页")
    }
}
