import XCTest
@testable import 记忆花园

/// 对话菜单合一（plan-chat-menus）：列表长按 / 聊天页 ⋯ 吐的行和顺序
final class ConversationMenuTests: XCTestCase {

    private func titles(_ specs: [MenuActionSpec]) -> [String] { specs.map(\.title) }
    private func child(_ specs: [MenuActionSpec], _ title: String) -> [MenuActionSpec] {
        specs.first { $0.title == title }?.children ?? []
    }

    func testListMenuIsQuickRowPlusFourRows() {
        let specs = ConversationMenu.specs(place: .list, state: .init(folders: [.init(id: "f", name: "学堂")]), handlers: .init())
        XCTAssertEqual(specs.filter { $0.quickLabel != nil }.map(\.quickLabel), ["Rename", "Copy", "Pin", "Star", "Delete"])
        XCTAssertEqual(titles(specs.filter { $0.quickLabel == nil }), ["换成气泡", "移到文件夹", "记忆", "更多"])
    }

    func testChatMenuAddsSearchAndBranchMapInArticleMode() {
        let specs = ConversationMenu.specs(place: .chat(branchCount: 3), state: .init(), handlers: .init())
        XCTAssertEqual(titles(specs.filter { $0.quickLabel == nil }), ["在对话中查找", "分支地图（3）", "换成气泡", "记忆", "更多"])
    }

    /// Mac 没有对话内查找
    func testChatMenuWithoutSearch() {
        let specs = ConversationMenu.specs(place: .chat(branchCount: 0, canSearch: false), state: .init(), handlers: .init())
        XCTAssertFalse(titles(specs).contains("在对话中查找"))
    }

    /// 系统菜单（Mac / 宽屏）：图标排那几项在前，删除垫底，中间分隔
    func testSystemMenuOrderPutsDeleteLast() {
        let specs = MenuActionSpec.systemMenuOrder(ConversationMenu.specs(place: .list, state: .init(), handlers: .init()))
        XCTAssertEqual(titles(specs), ["重命名", "复制对话", "置顶对话", "收藏整个对话", "换成气泡", "记忆", "更多", "删除"])
        XCTAssertTrue(specs[3].dividerAfter)
        XCTAssertTrue(specs[6].dividerAfter)
    }

    func testBranchMapHiddenInBubbleModeOrWithoutBranches() {
        let bubble = ConversationMenu.specs(place: .chat(branchCount: 3), state: .init(isBubble: true), handlers: .init())
        XCTAssertFalse(titles(bubble).contains { $0.hasPrefix("分支地图") })
        XCTAssertTrue(titles(bubble).contains("换成文章"))
        let none = ConversationMenu.specs(place: .chat(branchCount: 0), state: .init(), handlers: .init())
        XCTAssertFalse(titles(none).contains { $0.hasPrefix("分支地图") })
    }

    func testFolderSubmenuHasLeaveOnlyWhenInAFolder() {
        let folders: [ConversationMenu.Choice] = [.init(id: "a", name: "学堂"), .init(id: "b", name: "旅行")]
        let outside = ConversationMenu.specs(place: .list, state: .init(folders: folders), handlers: .init())
        XCTAssertEqual(titles(child(outside, "移到文件夹")), ["学堂", "旅行"])
        let inside = ConversationMenu.specs(place: .list, state: .init(folderId: "b", folders: folders), handlers: .init())
        XCTAssertEqual(titles(child(inside, "移到文件夹")), ["学堂", "旅行", "移出文件夹"])
        XCTAssertEqual(child(inside, "移到文件夹")[1].systemImage, "checkmark")
        let noFolders = ConversationMenu.specs(place: .list, state: .init(), handlers: .init())
        XCTAssertFalse(titles(noFolders).contains("移到文件夹"))
    }

    func testMemorySubmenu() {
        let off = ConversationMenu.specs(place: .chat(branchCount: 0), state: .init(memoryEnabled: false, memoryWriteEnabled: false), handlers: .init())
        let memory = child(off, "记忆")
        XCTAssertEqual(titles(memory), ["开启记忆参与", "这个窗口带什么", "窗口总结", "上下文摘要", "现在写记忆"])
        XCTAssertTrue(memory[4].isDisabled)
        let running = ConversationMenu.specs(place: .chat(branchCount: 0), state: .init(rerecord: ("正在重新记 · 第 1 / 3 批", true)), handlers: .init())
        XCTAssertEqual(child(running, "记忆").last?.title, "正在重新记 · 第 1 / 3 批")
        XCTAssertEqual(child(running, "记忆").last?.isDisabled, true)
    }

    /// astra 审 11-16：「现在写」「重新记」对打开着的那条才有意义，列表长按不出
    func testListMemorySubmenuHasNoWriteNowOrRerecord() {
        let specs = ConversationMenu.specs(place: .list, state: .init(rerecord: ("重新记这个窗口", false)), handlers: .init())
        XCTAssertEqual(titles(child(specs, "记忆")), ["关闭记忆参与", "这个窗口带什么", "窗口总结", "上下文摘要"])
    }

    func testMoreSubmenuWithPersonasAndCC() {
        let cc = [MenuActionSpec(title: "终端 · s1", systemImage: "terminal") {}]
        let specs = ConversationMenu.specs(
            place: .list,
            state: .init(personaId: "p2", personas: [.init(id: "p1", name: "粟粟"), .init(id: "p2", name: "")]),
            cc: cc, handlers: .init())
        let more = child(specs, "更多")
        XCTAssertEqual(titles(more), ["重新生成标题", "收藏到标签…", "身份", "导出为 Markdown", "终端 · s1"])
        let personas = child(more, "身份")
        XCTAssertEqual(titles(personas), ["跟随楼层", "粟粟", "（没名字）"])
        XCTAssertEqual(personas[2].systemImage, "checkmark")
    }

    func testHandlersAreWired() {
        var hit: [String] = []
        var h = ConversationMenu.Handlers()
        h.togglePin = { hit.append("pin") }
        h.moveToFolder = { hit.append("folder:\($0 ?? "nil")") }
        h.setPersona = { hit.append("persona:\($0 ?? "nil")") }
        let specs = ConversationMenu.specs(place: .list,
                                           state: .init(folderId: "a", folders: [.init(id: "a", name: "学堂")],
                                                        personas: [.init(id: "p", name: "粟粟")]),
                                           handlers: h)
        specs.first { $0.quickLabel == "Pin" }?.handler()
        child(specs, "移到文件夹").last?.handler()
        child(child(specs, "更多"), "身份").first?.handler()
        XCTAssertEqual(hit, ["pin", "folder:nil", "persona:nil"])
    }
}
