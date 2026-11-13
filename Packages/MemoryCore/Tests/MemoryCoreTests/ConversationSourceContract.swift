import XCTest
import MemoryCore

/// 六操作合同用例：`SnapshotConversationSource`（本刀）与 E2-2 的 SwiftData 实现共跑同一套。
/// 夹具是一份 schema 2 的 `FloorSnapshot`；期望值按夹具直接算，不从被测实现推导。
enum ConversationSourceContract {
    static let profileId = "contract-p1"
    static let otherProfileId = "contract-p2"
    static let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    static let alpha = "alpha-window-0001"
    static let beta = "beta-window-0002"
    static let gamma = "gamma-window-0003"
    static let cafeA = "cafe1234-alpha"
    static let cafeB = "cafe1234-beta"
    static let delta = "delta-window-0004"

    /// `crossFloorDuplicate == false`：SwiftData 的 `MessageNode.id` 是 `@Attribute(.unique)`，
    /// 两个楼层同 id 在真实库里不存在（只有快照能表示），所以那条用例只给快照腿跑。
    static func floor(crossFloorDuplicate: Bool = true) -> FloorSnapshot {
        func at(_ offset: TimeInterval) -> Date { anchor.addingTimeInterval(offset) }
        return FloorSnapshot(windows: [
            .init(id: alpha, title: "甲窗", current: "a4", memoryEnabled: true, trashed: false,
                  nodes: [
                    .init(id: "a0", role: "user", text: "灯塔与星砂", at: at(-600)),
                    .init(id: "a1", role: "assistant", text: "Lighthouse Keeper 回应", at: at(-590), parent: "a0"),
                    .init(id: "a2", role: "user", text: "隐藏的星砂", at: at(-580), parent: "a1", hidden: true),
                    .init(id: "a3", role: "assistant", text: "已删的星砂", at: at(-570), parent: "a2", deleted: true),
                    .init(id: "a4", role: "user", text: "收尾的星砂", at: at(-500), parent: "a3"),
                    .init(id: "shared-node", role: "user", text: "甲层同 id 正文", at: at(-550)),
                  ],
                  profileId: profileId, updateTime: at(-500)),
            .init(id: beta, title: "乙窗", current: "b2", memoryEnabled: true, trashed: false,
                  nodes: [
                    .init(id: "b-root", role: "user", text: "合成根星砂", at: at(-410), isSyntheticRoot: true),
                    .init(id: "b0", role: "user", text: "LIGHTHOUSE 大写", at: at(-400), parent: "b-root"),
                    .init(id: "b1", role: "assistant", text: "", at: at(-390), parent: "b0", segments: [.audioRef]),
                    .init(id: "b2", role: "assistant", text: "第三条", at: at(-380), parent: "b1"),
                  ],
                  profileId: profileId, updateTime: at(-380)),
            .init(id: gamma, title: "丙窗", current: "c0", memoryEnabled: true, trashed: true,
                  nodes: [
                    .init(id: "c0", role: "user", text: "回收站星砂", at: at(-700), deleted: true),
                  ],
                  profileId: profileId, updateTime: at(-700)),
            .init(id: cafeA, title: "前缀甲", current: "ca0", memoryEnabled: true, trashed: false,
                  nodes: [.init(id: "ca0", role: "user", text: "前缀甲正文", at: at(-800))],
                  profileId: profileId, updateTime: at(-800)),
            .init(id: cafeB, title: "前缀乙", current: "cb0", memoryEnabled: true, trashed: false,
                  nodes: [.init(id: "cb0", role: "user", text: "前缀乙正文", at: at(-810))],
                  profileId: profileId, updateTime: at(-810)),
            .init(id: delta, title: "别层窗", current: "d0", memoryEnabled: true, trashed: false,
                  nodes: [
                    .init(id: "d0", role: "user", text: "另一楼层的星砂", at: at(-900)),
                  ] + (crossFloorDuplicate ? [.init(id: "shared-node", role: "user", text: "乙层同 id 正文", at: at(-890))] : []),
                  profileId: otherProfileId, updateTime: at(-900)),
        ])
    }

    static func check(_ source: ConversationSource, crossFloorDuplicate: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        // ① 列窗口：楼层隔离 + 回收站 + updateTime
        let open = try source.windows(profileId: profileId, updatedSince: nil, includeTrashed: false)
        XCTAssertEqual(Set(open.map(\.id)), [alpha, beta, cafeA, cafeB], "① 未删窗口", file: file, line: line)
        let all = try source.windows(profileId: profileId, updatedSince: nil, includeTrashed: true)
        XCTAssertEqual(Set(all.map(\.id)), [alpha, beta, gamma, cafeA, cafeB], "① 含回收站", file: file, line: line)
        let since = try source.windows(profileId: profileId, updatedSince: anchor.addingTimeInterval(-450), includeTrashed: false)
        XCTAssertEqual(Set(since.map(\.id)), [beta], "① updatedSince", file: file, line: line)
        let other = try source.windows(profileId: otherProfileId, updatedSince: nil, includeTrashed: true)
        XCTAssertEqual(Set(other.map(\.id)), [delta], "① 楼层过滤", file: file, line: line)

        // ② 取窗口：精确 / 8 位前缀 / 短前缀 / 歧义 / 回收站 / 别层
        XCTAssertEqual(try source.window(profileId: profileId, idOrPrefix: alpha)?.id, alpha, "② 精确", file: file, line: line)
        XCTAssertEqual(try source.window(profileId: profileId, idOrPrefix: "alpha-wi")?.id, alpha, "② 8 位前缀", file: file, line: line)
        XCTAssertNil(try source.window(profileId: profileId, idOrPrefix: "alpha"), "② 短前缀不猜", file: file, line: line)
        XCTAssertNil(try source.window(profileId: profileId, idOrPrefix: "gamma-wi"), "② 回收站窗口", file: file, line: line)
        XCTAssertNil(try source.window(profileId: profileId, idOrPrefix: delta), "② 别层窗口", file: file, line: line)
        XCTAssertThrowsError(try source.window(profileId: profileId, idOrPrefix: "cafe1234"), "② 前缀歧义", file: file, line: line)

        // ③ 全量节点：含已删 / 源隐藏
        let nodes = try source.nodes(profileId: profileId, conversationId: alpha)
        XCTAssertEqual(Set(nodes.map(\.id)), ["a0", "a1", "a2", "a3", "a4", "shared-node"], "③ 含已删", file: file, line: line)
        XCTAssertTrue(try source.nodes(profileId: otherProfileId, conversationId: alpha).isEmpty, "③ 楼层过滤", file: file, line: line)

        // ④ 批量取消息：带 profileId，含已删，顺序不保证
        let batch = try source.messages(profileId: profileId, ids: ["a0", "a3", "c0", "d0", "missing"])
        XCTAssertEqual(Set(batch.map(\.id)), ["a0", "a3", "c0"], "④ 批量 + 楼层过滤", file: file, line: line)
        let missingMixed = try source.messages(profileId: profileId, ids: ["missing", "a2"])
        XCTAssertEqual(missingMixed.map(\.id), ["a2"], "④ 不存在 id 混入不报错", file: file, line: line)
        // 两楼层同 message id：各取各的（回归：不许先全局按 id 建字典）
        if crossFloorDuplicate {
            let mine = try source.messages(profileId: profileId, ids: ["shared-node"])
            XCTAssertEqual(mine.map(\.content), ["甲层同 id 正文"], "④ 同 id 取本层", file: file, line: line)
            XCTAssertEqual(mine.map(\.conversationId), [alpha], "④ 同 id 归属本层", file: file, line: line)
            let theirs = try source.messages(profileId: otherProfileId, ids: ["shared-node"])
            XCTAssertEqual(theirs.map(\.content), ["乙层同 id 正文"], "④ 同 id 取别层", file: file, line: line)
        } else {
            let mine = try source.messages(profileId: profileId, ids: ["shared-node"])
            XCTAssertEqual(mine.map(\.content), ["甲层同 id 正文"], "④ 同 id 取本层", file: file, line: line)
            XCTAssertEqual(mine.map(\.conversationId), [alpha], "④ 同 id 归属本层", file: file, line: line)
        }

        // ⑤ 全文搜：大小写不敏感、createTime 倒序、过滤隐藏 / 合成根 / 已删 / 非 user-assistant
        let stars = try source.search(profileId: profileId, text: "星砂", conversationId: nil)
        XCTAssertEqual(stars.map(\.id), ["a4", "a0"], "⑤ 倒序 + 过滤", file: file, line: line)
        let lighthouse = try source.search(profileId: profileId, text: "lighthouse", conversationId: nil)
        XCTAssertEqual(lighthouse.map(\.id), ["b0", "a1"], "⑤ 大小写不敏感", file: file, line: line)
        let scoped = try source.search(profileId: profileId, text: "星砂", conversationId: alpha)
        XCTAssertEqual(scoped.map(\.id), ["a4", "a0"], "⑤ 可限窗口", file: file, line: line)
        XCTAssertTrue(try source.search(profileId: otherProfileId, text: "星砂", conversationId: nil).map(\.id) == ["d0"],
                      "⑤ 楼层过滤", file: file, line: line)

        // ⑥ 批量标题：不过滤回收站
        let titles = try source.titles(profileId: profileId, ids: [alpha, gamma, cafeA, delta])
        XCTAssertEqual(titles, [alpha: "甲窗", gamma: "丙窗", cafeA: "前缀甲"], "⑥ 标题不过滤回收站", file: file, line: line)
        XCTAssertTrue(try source.titles(profileId: profileId, ids: []).isEmpty, "⑥ 空 ids", file: file, line: line)
        XCTAssertTrue(try source.titles(profileId: profileId, ids: ["missing", delta]).isEmpty,
                      "⑥ 不存在 id / 别层 id 不返回", file: file, line: line)
        XCTAssertEqual(try source.titles(profileId: otherProfileId, ids: [delta, alpha]), [delta: "别层窗"],
                       "⑥ 楼层隔离", file: file, line: line)
    }
}
