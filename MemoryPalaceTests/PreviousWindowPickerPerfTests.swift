#if DEBUG
import SwiftData
import XCTest
import MemoryCore
@testable import 记忆花园

/// E2-7b 量 ⌘N 开窗耗时：冻结拆两段——
/// ① 主线程同步部分 `prepareFreeze`（选择 + `latest` + 写 id），5000 节点必须 < 16 ms（一帧，硬闸）；
/// ② 后台 `captureInBackground`（取整窗节点 + visiblePath + 倒序凑够），只打印不断言；
/// ③ 后台落定后回主线程的「快照 JSON 编码 + save」，只打印不断言（另一帧，最坏几 ms）。
/// 功能断言保证测的是真抓取（不是选错窗 / 默认值变了之后的空跑）。
final class PreviousWindowPickerPerfTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    func testFreezeLatencyLargeAndSmallWindow() async throws {
        let large = try await measureFreeze(label: "5000", mainCount: 4000, branchCount: 10, branchLength: 100)
        let small = try await measureFreeze(label: "500", mainCount: 400, branchCount: 10, branchLength: 10)
        print("[PREVWIN-PERF] small/sync=\(format(small.sync))ms background=\(format(small.background))ms")
        print("[PREVWIN-PERF] large/sync=\(format(large.sync))ms background=\(format(large.background))ms")
        XCTAssertLessThan(large.sync, 16, "主线程同步部分（prepareFreeze）5000 节点必须在一帧内")
    }

    /// 两组都：内存库 + 源窗（主线 + 旁支，`branchSelection` 指主线）+ 6 个目标窗（1 warm + 5 测量）
    private func measureFreeze(label: String, mainCount: Int, branchCount: Int, branchLength: Int) async throws -> (sync: Double, background: Double) {
        let profileId = "perf-prevwin-\(label)-\(UUID().uuidString)"
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let sourceId = "perf-src-\(label)"
        let mainIds = (0..<mainCount).map { _ in UUID().uuidString }
        let branchIds = (0..<branchCount).map { _ in
            (0..<branchLength).map { _ in UUID().uuidString }
        }
        var selection: [String: String] = [:]
        var contentSeed = 0

        for index in 0..<mainCount {
            var children: [String] = []
            if index + 1 < mainCount { children.append(mainIds[index + 1]) }
            if index < branchCount {
                // 每个分叉点先挂旁支，`branchSelection` 明确选主线那条
                children.append(branchIds[index][0])
                selection[mainIds[index]] = mainIds[index + 1]
            }
            context.insert(MessageNode(id: mainIds[index], role: index.isMultiple(of: 2) ? "user" : "assistant",
                                       content: body(contentSeed), contentType: "text",
                                       createTime: start.addingTimeInterval(Double(index) * 60),
                                       parentId: index == 0 ? nil : mainIds[index - 1], childrenIds: children,
                                       conversationId: sourceId, profileId: profileId))
            contentSeed += 1
        }
        for branch in 0..<branchCount {
            let parentIndex = branch
            for step in 0..<branchLength {
                let id = branchIds[branch][step]
                context.insert(MessageNode(id: id, role: step.isMultiple(of: 2) ? "user" : "assistant",
                                           content: body(contentSeed), contentType: "text",
                                           createTime: start.addingTimeInterval(Double(parentIndex) * 60 + Double(step) + 0.5),
                                           parentId: step == 0 ? mainIds[parentIndex] : branchIds[branch][step - 1],
                                           childrenIds: step == branchLength - 1 ? [] : [branchIds[branch][step + 1]],
                                           conversationId: sourceId, profileId: profileId))
                contentSeed += 1
            }
        }
        let tailBody = body(mainCount - 1)
        let source = Conversation(id: sourceId, title: "性能源窗-\(label)", createTime: start,
                                  updateTime: start.addingTimeInterval(Double(mainCount) * 60),
                                  currentNodeId: mainIds[mainCount - 1], provider: "api", profileId: profileId)
        source.memoryEnabled = true
        source.lastRealChatAt = start.addingTimeInterval(Double(mainCount) * 60)
        source.branchSelectionData = BranchSelection.encode(selection)
        context.insert(source)

        var targets: [Conversation] = []
        for index in 0..<6 {
            let target = Conversation(id: "perf-dst-\(label)-\(index)", title: "目标-\(index)",
                                      createTime: start.addingTimeInterval(10_000), updateTime: start.addingTimeInterval(10_000),
                                      currentNodeId: "", provider: "api", profileId: profileId)
            target.memoryEnabled = true
            context.insert(target)
            targets.append(target)
        }
        try context.save()

        // 功能断言：每次 freeze 都真抓到默认 6 条，最后一条是主线末叶（选错窗 / 默认值变了会在这里红）
        func assertCaptured(_ target: Conversation) {
            let snapshot = target.previousWindowSnapshot
            XCTAssertEqual(snapshot?.messages.count, 6, "\(label) \(target.id)：freeze 必须抓到默认 6 条")
            XCTAssertEqual(snapshot?.messages.last?.nodeId, mainIds.last, "\(label) \(target.id)：最后一条是主线末叶")
            XCTAssertEqual(snapshot?.messages.last?.text, tailBody, "\(label) \(target.id)：最后一条是主线末叶正文")
        }

        // warm（第一次还要解 5000 条节点，不进样本）
        if let plan = PreviousWindowPicker.prepareFreeze(targets[0], context: context) {
            let snapshot = await PreviousWindowPicker.captureInBackground(plan, container: container)
            targets[0].previousWindowSnapshot = try XCTUnwrap(snapshot)
        }
        assertCaptured(targets[0])

        var plans: [PreviousWindowPicker.FreezePlan] = []
        var syncSamples: [Double] = []
        for target in targets.dropFirst() {
            let begin = DispatchTime.now().uptimeNanoseconds
            let plan = PreviousWindowPicker.prepareFreeze(target, context: context)
            let end = DispatchTime.now().uptimeNanoseconds
            syncSamples.append(Double(end - begin) / 1_000_000)
            XCTAssertEqual(target.previousWindowId, sourceId, "\(label) \(target.id)：同步部分必须选到源窗")
            plans.append(try XCTUnwrap(plan))
        }

        var backgroundSamples: [Double] = []
        var completionSamples: [Double] = []
        for (target, plan) in zip(targets.dropFirst(), plans) {
            let begin = DispatchTime.now().uptimeNanoseconds
            let captured = await PreviousWindowPicker.captureInBackground(plan, container: container)
            let end = DispatchTime.now().uptimeNanoseconds
            backgroundSamples.append(Double(end - begin) / 1_000_000)
            let snapshot = try XCTUnwrap(captured)
            // 完成回调在主线程干的活：快照 JSON 编码（setter 里）+ save。只打印，不进闸
            let commitBegin = DispatchTime.now().uptimeNanoseconds
            target.previousWindowSnapshot = snapshot
            try context.save()
            let commitEnd = DispatchTime.now().uptimeNanoseconds
            completionSamples.append(Double(commitEnd - commitBegin) / 1_000_000)
            assertCaptured(target)
        }
        let sync = median(syncSamples)
        let background = median(backgroundSamples)
        // 同步部分里 `latest` 占多少（选窗本身要查库；拆开才知道 16 ms 门槛压在谁身上）
        var latestSamples: [Double] = []
        for target in targets.dropFirst() {
            let begin = DispatchTime.now().uptimeNanoseconds
            _ = PreviousWindowPicker.latest(profileId: profileId, excluding: target.id, context: context)
            let end = DispatchTime.now().uptimeNanoseconds
            latestSamples.append(Double(end - begin) / 1_000_000)
        }
        // `latest` 的 256 条节点扫描本身值多少毫秒（同步部分真正的成本；只打印）
        var nodeScanSamples: [Double] = []
        for _ in 0..<5 {
            let pid = profileId
            var scan = FetchDescriptor<MessageNode>(
                predicate: #Predicate { $0.profileId == pid && $0.role == "assistant" && $0.isTrashed == false },
                sortBy: [SortDescriptor(\.createTime, order: .reverse)])
            scan.fetchLimit = 256
            let begin = DispatchTime.now().uptimeNanoseconds
            _ = try? context.fetch(scan).map { $0.content.isEmpty }
            let end = DispatchTime.now().uptimeNanoseconds
            nodeScanSamples.append(Double(end - begin) / 1_000_000)
        }
        print("[PREVWIN-PERF] nodes=\(mainCount + branchCount * branchLength) sync=\(format(sync))ms background=\(format(background))ms"
              + " completion=\(format(median(completionSamples)))ms"
              + " latest=\(format(median(latestSamples)))ms latestNodes=\(format(median(nodeScanSamples)))ms"
              + " syncSamples=" + syncSamples.map(format).joined(separator: ",")
              + " bgSamples=" + backgroundSamples.map(format).joined(separator: ","))

        // 分段计时（后台 capture 内部）：① 每次单开 context 取整窗节点（同 capture 的取法）② 对拿到的 nodes 跑 visiblePath
        let sourceWindow = SwiftDataConversationSource.window(source)
        var nodeSamples: [Double] = []
        var nodes: [ConversationMessage] = []
        for _ in 0..<5 {
            let begin = DispatchTime.now().uptimeNanoseconds
            nodes = try SwiftDataConversationSource(container: container)
                .nodes(profileId: profileId, conversationId: sourceId)
            let end = DispatchTime.now().uptimeNanoseconds
            nodeSamples.append(Double(end - begin) / 1_000_000)
        }
        XCTAssertEqual(nodes.count, mainCount + branchCount * branchLength, "\(label)：分段计时必须拿到整窗节点")
        var pathSamples: [Double] = []
        for _ in 0..<5 {
            let begin = DispatchTime.now().uptimeNanoseconds
            _ = visiblePath(window: sourceWindow, nodes: nodes)
            let end = DispatchTime.now().uptimeNanoseconds
            pathSamples.append(Double(end - begin) / 1_000_000)
        }
        print("[PREVWIN-PERF] breakdown nodes=\(format(median(nodeSamples)))ms"
              + " visiblePath=\(format(median(pathSamples)))ms"
              + " sync=\(format(sync))ms background=\(format(background))ms")
        return (sync, background)
    }

    private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    private func format(_ ms: Double) -> String { String(format: "%.1f", ms) }

    /// 200–800 个中文字符（确定性，不依赖随机源）
    private func body(_ seed: Int) -> String {
        let pool = Array("星砚楼里云桥城的航图收在第七根灯柱下面雾岚和林栖在石桥边等两艘船载着琉璃灯沿着河道回来")
        let length = 200 + (seed * 137) % 601
        var text = ""
        text.reserveCapacity(length)
        for index in 0..<length { text.append(pool[(seed + index * 7) % pool.count]) }
        return text
    }
}
#endif
