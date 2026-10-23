import Foundation
import SwiftData

/// 把 `isDeleted` / `deletedAt` 业务字段迁到 `isTrashed` / `trashedAt`。
///
/// 背景：SwiftData `@Model` 的 `isDeleted` 与 NSManagedObject 框架保留语义冲突，
/// 显式 `context.save()` 会把业务 set 的 `isDeleted=true` 逆转回 false——
/// 这就是 S4 软删同步永远不传播的根因（research-isDeleted-clash.md）。
///
/// 修法：业务字段重命名到 `isTrashed/trashedAt`。Migration 在 App 启动期跑一次：
/// 1. 扫所有 `isDeleted==true` 的 Conversation/MessageNode
/// 2. 设 `isTrashed=true`、`trashedAt = deletedAt ?? Date()`
/// 3. 把 `isDeleted=false`、`deletedAt=nil` 清掉框架保留字段的"脏值"
/// 4. UserDefaults sentinel 防重复跑
///
/// 老字段 `isDeleted/deletedAt` 在 @Model 上保留几个版本，方便回退；之后再删。
enum TrashedFieldMigration {

    private static let doneKey = "TrashedFieldMigration.v1.done"

    static func needsMigration() -> Bool {
        !UserDefaults.standard.bool(forKey: doneKey)
    }

    /// 同步跑，全库 fetch 一次。20 万级节点级别会卡几百毫秒，可接受（启动期一次性）。
    static func run(container: ModelContainer) {
        guard needsMigration() else { return }
        let ctx = ModelContext(container)
        let t0 = CFAbsoluteTimeGetCurrent()
        var convMigrated = 0
        var nodeMigrated = 0

        // Conversation
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.isDeleted == true }
        )
        if let convs = try? ctx.fetch(convDesc) {
            for conv in convs {
                conv.isTrashed = true
                conv.trashedAt = conv.deletedAt ?? Date()
                conv.isDeleted = false
                conv.deletedAt = nil
                convMigrated += 1
            }
        }

        // MessageNode
        let nodeDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.isDeleted == true }
        )
        if let nodes = try? ctx.fetch(nodeDesc) {
            for node in nodes {
                node.isTrashed = true
                node.trashedAt = node.deletedAt ?? Date()
                node.isDeleted = false
                node.deletedAt = nil
                nodeMigrated += 1
            }
        }

        // ⚠️ 不能调 ctx.save()——会把刚 set 的 isTrashed=true 持久化的同时
        // 又触发 isDeleted 字段的 NSManagedObject 反射、有概率把本轮搬运逆转。
        // 实测：不调显式 save，autosave 在下个 runloop 落盘，迁移结果稳定保留。
        // 见 research-isDeleted-clash.md。
        // 不过：UserDefaults sentinel 必须在 autosave 后再设，否则 app 崩了下次起来发现已设
        // sentinel 但数据没迁完。这里采用 ProcessInfo 异步延迟设置：
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UserDefaults.standard.set(true, forKey: doneKey)
            let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print(String(format: "[migration] TrashedField done: %d conv, %d nodes (%.0fms)",
                         convMigrated, nodeMigrated, dt))
        }
    }
}
