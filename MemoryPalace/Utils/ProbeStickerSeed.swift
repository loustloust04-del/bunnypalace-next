#if DEBUG && os(iOS)
import Foundation
import SwiftData

/// [PROBE 贴纸 seed] Debug-only 启动时注入 mock 对话 + 便签贴纸，
/// 用于 claude-code 在模拟器独立复现手势 regression。
///
/// 触发：`xcrun simctl launch <udid> <bundle> -- --sticker-probe-seed`
/// 或 Xcode scheme → Run → Arguments → "--sticker-probe-seed"
///
/// 执行一次就标记 UserDefaults key，防止每次 launch 重复 insert。
/// 把 NSLog 同时写到 app 的 Documents/probe.log，给 devicectl 拉真机日志用。
/// #028 F3：句柄常驻（以前每行开 / seek / 写 / 关一次）；写盘过串行队列 sync——保序、PROBE 返回即已写入（崩溃不丢尾行）。
@inline(__always)
func PROBE(_ msg: String) {
    NSLog(msg)
    ProbeLogFile.append(msg + "\n")
}

/// probe.log 的唯一写入口：句柄只在 queue 上碰（sync，多线程调用互斥），追加与启动清空保序。queue 内别再调 PROBE（sync 嵌套死锁）
private enum ProbeLogFile {
    static let queue = DispatchQueue(label: "com.susu.MemoryPalace.probe-log")
    nonisolated(unsafe) private static var handle: FileHandle?

    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("probe.log")
    }

    static func append(_ line: String) {
        queue.sync {
            if handle == nil { handle = open() }
            guard let h = handle else { return }
            do {
                try h.write(contentsOf: Data(line.utf8))
            } catch {   // 写失败：丢掉句柄，下一行按路径重开
                try? h.close()
                handle = nil
            }
        }
    }

    /// 启动清空：关旧句柄、按路径清空后重开
    static func reset() {
        queue.sync {
            try? handle?.close()
            handle = nil
            guard let url else { return }
            try? Data().write(to: url)
            handle = open()
        }
    }

    private static func open() -> FileHandle? {
        guard let url else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }
}

extension ProbeStickerSeed {
    /// app 启动时清空 probe.log（每次 launch 一份新的）
    static func resetLogFile() {
        ProbeLogFile.reset()
    }
}
#endif

#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import SwiftData

/// PERF_BENCH 包也编（UI 回归 S1 用，plan-perf-watch §1.2）；PROBE 日志仍只在 DEBUG 写盘
enum ProbeStickerSeed {
    static let markerKey = "probeStickerSeedDone_v1"
    static let convId = "probe-sticker-conv-1"

    /// 给 ConversationViewModel.onAppear 用：检查是否应自动选中 probe conversation
    static var shouldAutoSelectProbeConv: Bool {
        CommandLine.arguments.contains("--sticker-probe-seed")
    }

    /// 给 StickerCanvasLayer 用：是否应自动进编辑模式
    static var shouldAutoEnterEditMode: Bool {
        CommandLine.arguments.contains("--sticker-probe-seed")
    }

    static func injectIfNeeded(container: ModelContainer, profileId: String) {
        guard CommandLine.arguments.contains("--sticker-probe-seed") else { return }
        #if !DEBUG && !targetEnvironment(simulator)
        // PERF 包真机只准写测试楼层（UI 回归 S1；astra R2 M03）
        guard profileId == UIRegressionSeed.testProfileId else { return }
        #endif
        if UserDefaults.standard.bool(forKey: markerKey) {
            PROBE("[PROBE 贴纸 seed] already done, skip")
            return
        }

        let ctx = ModelContext(container)

        // 1. mock conversation
        let convId = "probe-sticker-conv-1"
        let now = Date()
        let conv = Conversation(
            id: convId,
            title: "[PROBE] 贴纸测试对话",
            createTime: now,
            updateTime: now,
            currentNodeId: "probe-msg-2",
            provider: "chatgpt",
            profileId: profileId
        )
        ctx.insert(conv)

        // 2. 2 条 mock message（user + assistant）
        let msg1 = MessageNode(
            id: "probe-msg-1",
            role: "user",
            content: "这是探针测试消息 1 — 粟粟你看不到这条",
            contentType: "text",
            createTime: now,
            parentId: nil,
            childrenIds: ["probe-msg-2"],
            conversationId: convId,
            profileId: profileId
        )
        let msg2 = MessageNode(
            id: "probe-msg-2",
            role: "assistant",
            content: "这是探针测试消息 2 — 贴纸应该在这条消息附近",
            contentType: "text",
            createTime: now,
            parentId: "probe-msg-1",
            childrenIds: [],
            conversationId: convId,
            profileId: profileId
        )
        ctx.insert(msg1)
        ctx.insert(msg2)

        // 3. 一个便签贴纸（不需要 asset 图片文件，noteContent 驱动）
        //    放在消息中部偏下，方便 cliclick drag
        let sticker = PlacedSticker(
            stickerAssetId: nil,
            conversationId: convId,
            nearestMessageId: "probe-msg-2",
            positionX: 180,
            positionY: 300,
            rotation: 0,
            scale: 1.0,
            zIndex: 1,
            noteContent: "PROBE\n贴纸\n拖我",
            noteStyle: "yellow_square",
            profileId: profileId
        )
        ctx.insert(sticker)

        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: markerKey)
            PROBE("[PROBE 贴纸 seed] injected conv=\(convId) + 2 msgs + 1 note sticker @ (180,300)")
        } catch {
            PROBE("[PROBE 贴纸 seed] FAILED: \(error)")
        }
    }

    /// Reset marker — 便于多轮测试清数据后重新 seed
    static func resetMarker() {
        UserDefaults.standard.removeObject(forKey: markerKey)
    }
}
#endif

#if !DEBUG && os(iOS)
/// Release iOS PROBE no-op stub。让 21 处 PROBE call site
/// （StickerCanvasLayer / StickerGestureOverlay）在 Release 编译期也能解析符号。
/// `@inline(__always)` + 空体 → -O 优化下完全消除，零运行时开销。
/// 必须跟 DEBUG 版同签名（`func PROBE(_ msg: String)`）以保 call site 零改动。
@inline(__always)
func PROBE(_ msg: String) {}
#endif
