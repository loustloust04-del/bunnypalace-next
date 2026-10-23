import XCTest
@testable import 记忆花园

/// 词条笔记（文件库 vocab/ 目录）：路径安全 / 骨架幂等 / 读写 roundtrip / 图片过滤。
/// 用 xctest 专用 profileId，tearDown 清理（抄 ReadingSignalsTests 模式）。
final class VocabNoteStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
    }
    static let pid = "xctest-vocab-notes"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: Self.pid))
        super.tearDown()
    }

    func testNotePathKeepsPhraseReplacesSlash() {
        XCTAssertEqual(VocabNoteStore.notePath(word: "take off"), "vocab/take off.md")
        XCTAssertEqual(VocabNoteStore.notePath(word: "and/or"), "vocab/and-or.md")
        XCTAssertEqual(VocabNoteStore.notePath(word: "a:b"), "vocab/a-b.md")
    }

    func testEnsureNoteIdempotent() {
        VocabNoteStore.ensureNote(word: "ephemeral", profileId: Self.pid)
        XCTAssertEqual(VocabNoteStore.readNote(word: "ephemeral", profileId: Self.pid),
                       "# ephemeral\n\n")
        try? VocabNoteStore.writeNote(word: "ephemeral", content: "# ephemeral\n\n我的笔记",
                                      profileId: Self.pid)
        VocabNoteStore.ensureNote(word: "ephemeral", profileId: Self.pid)
        XCTAssertEqual(VocabNoteStore.readNote(word: "ephemeral", profileId: Self.pid),
                       "# ephemeral\n\n我的笔记", "已有内容不被骨架覆盖")
    }

    func testReadMissingReturnsNil() {
        XCTAssertNil(VocabNoteStore.readNote(word: "nonexistent", profileId: Self.pid))
    }

    // R2-2：旧 VocabProgress.note 迁移进 md（seed 只在 md 不存在时生效，幂等不覆盖）
    func testEnsureNoteSeedsLegacyNoteOnce() {
        VocabNoteStore.ensureNote(word: "brass", profileId: Self.pid, seed: "黄铜，记忆点：brass band 铜管乐队")
        XCTAssertEqual(VocabNoteStore.readNote(word: "brass", profileId: Self.pid),
                       "# brass\n\n黄铜，记忆点：brass band 铜管乐队\n")
        VocabNoteStore.ensureNote(word: "brass", profileId: Self.pid, seed: "另一段旧笔记")
        XCTAssertEqual(VocabNoteStore.readNote(word: "brass", profileId: Self.pid),
                       "# brass\n\n黄铜，记忆点：brass band 铜管乐队\n", "已有 md 不被 seed 覆盖")
    }

    // R2-3a：双链 markdown 变换（app 内笔记组件跳词卡的前半截）
    func testLinkifiedMarkdown() {
        XCTAssertEqual(VocabNoteStore.linkifiedMarkdown("见 [[brass]] 和 [[take off]]"),
                       "见 [brass](vocabnote://open/brass) 和 [take off](vocabnote://open/take%20off)")
        XCTAssertEqual(VocabNoteStore.linkifiedMarkdown("无双链原样"), "无双链原样")
        XCTAssertEqual(VocabNoteStore.linkifiedMarkdown("[[黄铜]]"),
                       "[黄铜](vocabnote://open/%E9%BB%84%E9%93%9C)")
    }

    func testImagePathsFiltersByWord() throws {
        try VocabNoteStore.addImage(word: "brass", data: Data([0x89, 0x50]), ext: "png",
                                    profileId: Self.pid)
        try VocabNoteStore.addImage(word: "brass", data: Data([0xFF, 0xD8]), ext: "jpg",
                                    profileId: Self.pid)
        try VocabNoteStore.addImage(word: "bow", data: Data([0x89, 0x50]), ext: "png",
                                    profileId: Self.pid)
        let brass = VocabNoteStore.imagePaths(word: "brass", profileId: Self.pid)
        XCTAssertEqual(brass.count, 2)
        XCTAssertTrue(brass.allSatisfy { $0.hasPrefix("vocab/img/brass-") })
        XCTAssertEqual(VocabNoteStore.imagePaths(word: "bow", profileId: Self.pid).count, 1)
    }
}
