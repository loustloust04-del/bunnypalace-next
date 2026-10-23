import XCTest
import SwiftData
@testable import 记忆花园

/// A4 存储整理特征测试：内联段迁移成 ref / 孤儿清理 / 二次扫描幂等 / 缓存清理计字节。
/// in-memory ModelContainer + 固定测试楼层 id，tearDown 删整个楼层目录（抄 DuplicateConversationTests 范式）。
final class StorageMaintenanceTests: XCTestCase {

    let pid = "xctest-storage-sweep"
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Conversation.self, MessageNode.self,
            configurations: config
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        container = nil
        super.tearDown()
    }

    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5, 6])

    @MainActor
    func testSweepMigratesInlineAndDeletesOrphans() async throws {
        MainThreadIO.allowMainThreadInThisTest()   // #033：测试体直接调 store / 工具，测试自己站主线程
        let conv = Conversation(
            id: "conv-sweep-1", title: "测试对话", createTime: Date(),
            updateTime: Date(), currentNodeId: "n1", provider: "api", profileId: pid
        )
        context.insert(conv)
        let node = MessageNode(
            id: "n1", role: "user", content: "带图消息", contentType: "segmented",
            createTime: Date(), parentId: nil, childrenIds: [],
            conversationId: conv.id, profileId: pid
        )
        // 直写 segmentsData 模拟老内联数据（绕过 setSegments 的外置化）
        let inline: [MessageSegment] = [.text("hi"), .image(name: "老图", type: nil, data: pngBytes)]
        node.segmentsData = try JSONEncoder().encode(inline)
        context.insert(node)
        try context.save()

        // 孤儿：另一个不存在的对话名下放一个没人引用的文件
        _ = try AttachmentStore.save(
            fileName: "orphan.png", data: pngBytes,
            conversationId: "deadbeef9999", conversationTitle: "鬼", profileId: pid
        )

        let result = await StorageMaintenance.sweepMedia(context: context) { _ in }

        XCTAssertEqual(result.conversationsScanned, 1)
        XCTAssertEqual(result.nodesMigrated, 1, "内联节点应被迁移")
        guard case .imageRef(let name, _, let path)? = node.segments?.last else {
            XCTFail("迁移后应为 imageRef"); return
        }
        XCTAssertEqual(name, "老图.png", "无扩展名应按 magic bytes 补 .png")
        XCTAssertEqual(AttachmentStore.read(path, profileId: pid), pngBytes, "落盘字节应一致")
        XCTAssertGreaterThanOrEqual(result.orphansDeleted, 1, "孤儿应被删")
        XCTAssertFalse(FileLibraryStore.exists("attachments/deadbeef-鬼/orphan.png", profileId: pid))

        // 二次扫描幂等：没有新迁移、被引用的文件不被误删
        let again = await StorageMaintenance.sweepMedia(context: context) { _ in }
        XCTAssertEqual(again.nodesMigrated, 0)
        XCTAssertEqual(again.orphansDeleted, 0)
        XCTAssertNotNil(FileLibraryStore.absoluteURL(path, profileId: pid), "被引用文件不能被当孤儿删掉")
    }

    func testCleanSystemCachesReportsBytes() throws {
        let fm = FileManager.default
        let tmpFile = fm.temporaryDirectory
            .appendingPathComponent("storage-test-\(UUID().uuidString).bin")
        try Data(count: 4096).write(to: tmpFile)
        // 非自有前缀的文件必须保留（macOS tmp 是用户级共享目录，整清是事故）
        let stranger = fm.temporaryDirectory
            .appendingPathComponent("not-ours-\(UUID().uuidString).bin")
        try Data(count: 16).write(to: stranger)
        defer { try? fm.removeItem(at: stranger) }

        let freed = StorageMaintenance.cleanSystemCaches()

        XCTAssertGreaterThanOrEqual(freed, 4096, "释放字节应至少包含刚写入的自有临时文件")
        XCTAssertFalse(fm.fileExists(atPath: tmpFile.path), "自有前缀临时件应被清")
        XCTAssertTrue(fm.fileExists(atPath: stranger.path), "非自有文件绝不能动")
    }
}
