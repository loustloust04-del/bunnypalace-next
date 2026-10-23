import XCTest
@testable import 记忆花园

/// WikiLinkIndex 特征测试：扫描/反向查询/解析规则/失效重建。真盘测试楼层，tearDown 清目录。
final class WikiLinkIndexTests: XCTestCase {

    let pid = "xctest-wikilink-index"

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
        WikiLinkIndex.noteLibraryChanged(profileId: pid)
    }

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        WikiLinkIndex.noteLibraryChanged(profileId: pid)
        super.tearDown()
    }

    func testScanExtractsTargets() {
        let targets = WikiLinkIndex.scan("去 [[猫猫笔记]] 和 [[notes/深层/线索.md]]，空的[[ ]]不算，[单层]不算")
        XCTAssertEqual(targets, ["猫猫笔记", "notes/深层/线索.md"])
    }

    func testBacklinksAcrossResolutionRules() throws {
        try FileLibraryStore.write("a.md", content: "链 [[猫猫笔记]] 一下", profileId: pid)
        try FileLibraryStore.write("b.md", content: "路径式 [[notes/猫猫笔记.md]]", profileId: pid)
        try FileLibraryStore.write("c.md", content: "无关 [[别的]]", profileId: pid)
        try FileLibraryStore.write("notes/猫猫笔记.md", content: "我是目标", profileId: pid)
        WikiLinkIndex.noteLibraryChanged(profileId: pid)

        // basename 匹配（a 的 [[猫猫笔记]]）+ 精确路径（b）都应命中；c 不命中
        XCTAssertEqual(WikiLinkIndex.backlinks(of: "notes/猫猫笔记.md", profileId: pid), ["a.md", "b.md"])
        XCTAssertEqual(WikiLinkIndex.outgoingTargets(of: "a.md", profileId: pid), ["猫猫笔记"])
        XCTAssertTrue(WikiLinkIndex.backlinks(of: "c.md", profileId: pid).isEmpty)
    }

    func testInvalidationPicksUpEdits() throws {
        try FileLibraryStore.write("x.md", content: "[[目标]]", profileId: pid)
        try FileLibraryStore.write("目标.md", content: "", profileId: pid)
        WikiLinkIndex.noteLibraryChanged(profileId: pid)
        XCTAssertEqual(WikiLinkIndex.backlinks(of: "目标.md", profileId: pid), ["x.md"])

        // 链接删掉 + 失效 → backlinks 跟着消失
        try FileLibraryStore.write("x.md", content: "不链了", profileId: pid)
        WikiLinkIndex.noteLibraryChanged(profileId: pid)
        XCTAssertTrue(WikiLinkIndex.backlinks(of: "目标.md", profileId: pid).isEmpty)
    }

    func testSelfLinkExcluded() throws {
        try FileLibraryStore.write("self.md", content: "我链我自己 [[self]]", profileId: pid)
        WikiLinkIndex.noteLibraryChanged(profileId: pid)
        XCTAssertTrue(WikiLinkIndex.backlinks(of: "self.md", profileId: pid).isEmpty, "自链不算 backlink")
    }
}
