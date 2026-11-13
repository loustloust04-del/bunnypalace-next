import MemoryCore
import Foundation
import Observation

/// 只由设置按钮启动；不写 A2，不沿用旧 A3 的消息水位拦截。
enum WindowSummaryRewrite {
    static let backupPrefix = "A3新格式前-"

    struct Survey: Equatable {
        var windows = 0
        var longWindows = 0
    }

    struct Report: Equatable {
        var written = 0
        var skipped = 0
        var failed = 0
        var cancelled = false

        var text: String {
            "\(cancelled ? "已停下" : "重写结束")：\(written) 个窗口写好，\(skipped) 个跳过，\(failed) 个失败（原样保留）"
        }
    }

    static func needsRewrite(_ summary: SessionSummary) -> Bool {
        guard !summary.segments.isEmpty else { return false }
        guard let a3 = WindowSummaryReader.a3(summary) else { return true }
        return a3.format < 2 || a3.kind != .window
    }

    static func candidates(memoryRoot: URL) -> [SessionSummary] {
        SessionSummaryStore.all(in: WindowSummaryStore.dir(root: memoryRoot)).filter(needsRewrite)
            .sorted { $0.conversationId < $1.conversationId }
    }

    static func survey(memoryRoot: URL, startDay: Date?, source: (String) -> MemoryRegeneration.Source?) -> Survey {
        let old = candidates(memoryRoot: memoryRoot).filter {
            guard let src = source($0.conversationId), !SessionCloseout.skipsSummary(messageCount: src.messages.count) else { return false }
            return MemoryStartDay.firstAllowedIndex(src.messages.map(\.date), startDay: startDay) < src.messages.count
        }
        let long = old.filter {
            let context = SessionSummaryStore.load(conversationId: $0.conversationId, in: SessionSummaryStore.dir(root: memoryRoot))
            return WindowSummaryReader.contextSegments(context?.segments ?? []).count > WindowSummaryWriter.fullInputSegmentLimit
        }.count
        return Survey(windows: old.count, longWindows: long)
    }

    static func lastKey(_ profileId: String) -> String { "mem_a3_rewrite_last_" + profileId }

    static func lastText(profileId: String, defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.dictionary(forKey: lastKey(profileId)), let date = value["time"] as? Date,
              let count = value["windows"] as? Int else { return nil }
        return "上次：\(date.formatted(date: .abbreviated, time: .shortened)) · \(count) 个窗口"
    }

    static func run(profileId: String, memoryRoot: URL, persona: String, speakers: SessionSegmentWriter.Speakers,
                    startDay: Date?, modelName: String, now: Date = Date(), defaults: UserDefaults = .standard,
                    copy: MemoryRegeneration.FileOp = MemoryRegeneration.copy,
                    write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                    source: (String) -> MemoryRegeneration.Source?,
                    caller: @escaping (String) -> SessionSegmentWriter.Caller,
                    progress: (String) async -> Void = { _ in }) async throws -> Report {
        func log(_ note: String, ok: Bool = true, cost: Double? = 0) {
            MemoryWriteLog.record(writer: .a3, profileId: profileId, ok: ok, note: "A3 新格式重写 · " + note,
                                  model: modelName, cost: cost, memoryRoot: memoryRoot)
        }
        var report = Report()
        await progress("正在备份窗口总结…")
        guard !Task.isCancelled else {
            report.cancelled = true
            log(report.text)
            return report
        }
        do {
            _ = try MemoryRegeneration.makeBackup(memoryRoot: memoryRoot,
                name: backupPrefix + MemoryRegeneration.stamp(now), folders: [WindowSummaryStore.folder], copy: copy)
        } catch {
            log("备份失败，未开始：\(error.localizedDescription)", ok: false)
            throw error
        }
        let old = candidates(memoryRoot: memoryRoot)
        log("备份完成，准备重写 \(old.count) 个窗口")
        for (index, saved) in old.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            let cid = saved.conversationId
            let note = "\(index + 1)/\(old.count) · 窗口「\(SessionSummaryStore.oneLine(saved.title))」"
            await progress("正在写 \(note)")
            log("正在写 \(note)")
            await SessionCloseoutStatus.set(running: cid, profileId: profileId, title: saved.title)
            do {
                try await MemoryWriteLog.metered {
                    guard let current = try WindowSummaryStore.loadStrict(conversationId: cid, in: memoryRoot),
                          current.conversationId == cid, needsRewrite(current), let src = source(cid),
                          !SessionCloseout.skipsSummary(messageCount: src.messages.count) else {
                        report.skipped += 1
                        log("跳过 \(note)（已是新格式、来源不可用或不到 6 条）")
                        return
                    }
                    let notBefore = MemoryStartDay.firstAllowedIndex(src.messages.map(\.date), startDay: startDay)
                    guard notBefore < src.messages.count else {
                        report.skipped += 1
                        log("跳过 \(note)（早于记忆起点）")
                        return
                    }
                    let context = try SessionSummaryStore.loadStrict(conversationId: cid, in: SessionSummaryStore.dir(root: memoryRoot))
                        ?? SummaryFileStore.loadStrict(conversationId: cid, memoryRoot: memoryRoot)
                            .flatMap { SessionSummaryStore.legacySeed(from: $0, conversationId: cid) }
                        ?? SessionSummary(conversationId: cid, title: src.title, compressedCount: 0, segments: [], updatedAt: .distantPast)
                    guard context.conversationId == cid else { throw MemoryWriterError.format("A2 窗口身份不符") }
                    let cancellable: SessionSegmentWriter.Caller = { system, user in
                        try Task.checkCancellation()
                        let raw = try await caller(cid)(system, user)
                        try Task.checkCancellation()
                        return raw
                    }
                    guard let result = try await SessionCloseout.recompressWindow(
                        context: context, messages: src.messages, title: src.title, notBefore: notBefore,
                        persona: persona, speakers: speakers, caller: cancellable, profileId: profileId, memoryRoot: memoryRoot) else {
                        report.failed += 1
                        log("未写成 \(note)（空输出，原样保留）", ok: false, cost: nil)
                        return
                    }
                    try Task.checkCancellation()
                    // 原位原子替换：失败时连旧文件名也不移动。
                    guard let target = SessionSummaryStore.fileURL(conversationId: cid, in: WindowSummaryStore.dir(root: memoryRoot)) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try write(Data(SessionSummaryStore.render(result).utf8), target)
                    report.written += 1
                    log("写好 \(note)", cost: nil)
                }
            } catch is CancellationError {
                report.cancelled = true
            } catch {
                if Task.isCancelled {
                    report.cancelled = true
                } else {
                    report.failed += 1
                    log("失败 \(note)，原样保留：\(error.localizedDescription)", ok: false, cost: nil)
                }
            }
            await SessionCloseoutStatus.set(running: nil)
            if report.cancelled { break }
        }
        report.cancelled = report.cancelled || Task.isCancelled
        defaults.set(["time": now, "windows": report.written], forKey: lastKey(profileId))
        log(report.text, ok: report.failed == 0)
        await progress(report.text)
        return report
    }
}

/// 两端所有 A3 设置页共用一趟，离开页面不会丢失取消入口。
@MainActor
@Observable
final class WindowSummaryRewriteJob {
    static let shared = WindowSummaryRewriteJob()
    private(set) var task: Task<Void, Never>?
    private(set) var profileId = ""
    var note: String?

    @discardableResult
    func start(profileId: String, operation: @escaping () async -> String) -> Bool {
        guard task == nil, MemoryMaintenance.shared.holder == nil else { return false }
        self.profileId = profileId
        note = MemoryMaintenance.waitingText
        task = Task {
            note = await operation()
            task = nil
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
        return true
    }

    func cancel() { task?.cancel() }
}
