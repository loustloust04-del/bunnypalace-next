import XCTest
@testable import 记忆花园

/// v5 · A1：设置 → 记忆 的骨架按粟粟 10-15 拖好的顺序锁住；挪走的行老位置没有
final class SettingsSkeletonTests: XCTestCase {

    typealias Row = MemoryPageLayout.Row

    func testSectionTitlesInHerOrder() {
        XCTAssertEqual(MemoryPageLayout.sections.map(\.title),
                       ["", "写入 · 记什么", "整理 · 怎么管", "注入 · 塞什么进 prompt", "检索 · 怎么挑记忆（可叠加）"])
    }

    func testTopBlock() {
        XCTAssertEqual(MemoryPageLayout.sections[0].rows, [.master, .startDay, .extractModel, .writeBudget, .complexity],
                       "总开关 / 起点 / 提取模型（从「提取」节挪上来）/ 写入预算 / 复杂度")
    }

    func testWritersOneRowEachInCodeOrder() {
        let writers = MemoryPageLayout.sections[1].rows.compactMap(\.writer)
        XCTAssertEqual(writers, [.a2, .a3, .a4, .b1, .b2, .b3, .b4, .c, .c2, .c3])
        XCTAssertEqual(writers.filter(\.isTodo), [.b2, .b3], "还没做的照样列出")
        XCTAssertEqual(writers.filter { SettingsRoute.memoryWriter($0) != nil }, [.a2, .a3, .a4, .b1, .b4, .c, .c2, .c3], "做了的都能点进二级页")
    }

    func testOrganizeInjectRetrieve() {
        XCTAssertEqual(MemoryPageLayout.sections[2].rows, [.audit, .pending, .trash], "审计台第一行，顶掉老「整理记忆」")
        XCTAssertEqual(MemoryPageLayout.sections[3].rows, [.openWindow, .catalog, .recall, .feedback, .injectBudget])
        XCTAssertEqual(MemoryPageLayout.sections[4].rows, [.injectFull, .injectKeyword, .injectVector, .injectGraph, .convHistory],
                       "检索整节不动")
    }

    func testMovedRowsNotOnMainPage() {
        let names = Set(Row.allCases.map(\.rawValue))
        for gone in ["dream", "profile", "portrait", "profileInject", "extractPrompt", "extractInterval", "advanced", "facts", "heartvoice",
                     "summary", "timeline", "selfRecent", "selfDailyLimit"] {
            XCTAssertFalse(names.contains(gone), "\(gone) 不该还在主页上")
        }
        let all = MemoryPageLayout.sections.flatMap(\.rows)
        XCTAssertEqual(all.count, Set(all).count, "一行只出现一次")
        XCTAssertEqual(Set(all), Set(Row.allCases), "每一行都有位置")
    }

    func testOpenWindowRows() {
        XCTAssertEqual(MemoryOpenWindow.rows, [.a2, .a4, .b4, .c], "A3 不注入、B1 是工具，都不列")
    }

    func testSearchAnchorsForNewRows() {
        let anchors = Set(SettingsSearchEntry.all.compactMap(\.anchor))
        for a in ["leaf-mem-writebudget", "leaf-mem-complexity", "leaf-mem-pending", "leaf-mem-openwindow", "leaf-mem-extractmodel", "leaf-mem-audit"]
            + MemoryWriterID.allCases.map({ "leaf-mem-w-\($0.rawValue)" }) {
            XCTAssertTrue(anchors.contains(a), "设置搜索少了 \(a)")
        }
        for gone in ["leaf-mem-userprofile", "leaf-mem-dream", "leaf-mem-advanced", "leaf-mem-advanced-session", "leaf-mem-extractprompt",
                     "leaf-mem-hygiene"] {
            XCTAssertFalse(anchors.contains(gone), "\(gone) 该删")
        }
    }
}
