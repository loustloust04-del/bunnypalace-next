import MemoryCore
import Foundation
import Observation
import SwiftData

/// 手动 Rewrite：把一个窗口已有的 A2 段（原地，一段一段）和 A3 窗口总结用现在的写手、现在的模型重写；一段写坏了也能只重写那一段。
/// 不新增覆盖：每段盖哪几条、lastNodeId、尾段标记、compressedCount 原样不动，只换写出来的字（段里的待续留旧的——待续本子早搬过，不再搬一遍）。
/// 哪一段没写成，那一段和它后面的原样保留。重写前后各记一版（`FileVersionStore`），Undo = 把上一版的字放回还在的那些段；每一笔都进写入日志
enum SummaryRewrite {
    enum Target: Equatable {
        /// 这个窗口全部 A2 段 + A3
        case window
        /// 只 A3（用现在的 A2 重压）
        case a3
        /// 只一段 A2（按它盖到的最后一条消息认）
        case segment(lastNodeId: String)
    }

    enum Stop: Equatable {
        case done
        /// 写手没写（预算闸 / 开关关了 / 模型没回内容）
        case skipped(String)
        case failed(String)
        case cancelled
        /// 这一项关着
        case off(String)
        /// 没有能重写的
        case nothing
    }

    struct Report: Equatable {
        /// 写好的 A2 段数 / 打算写的
        var segments = 0
        var planned = 0
        /// 原文在现在这条主线上对不上（切过分支 / 删过消息 / 早于记忆起点），没动
        var unmatched = 0
        var a3 = false
        var stop: Stop = .done
    }

    struct Input {
        let conversationId: String
        let title: String
        let messages: [SessionSegmentWriter.Message]
        let profileId: String
        let persona: String
        let speakers: SessionSegmentWriter.Speakers
        let memoryRoot: URL
        var startDay: Date? = nil
        var a2On = true
        var a3On = true
        /// 记进日志和版本历史的模型名
        var a2Model = ""
        var a3Model = ""
        var versions: FileVersionStore = .shared
        let callers: (SessionCloseout.Writer) -> SessionSegmentWriter.Caller
        let saveA2: (SessionSummary) throws -> Void
    }

    static let actorPrefix = "Rewrite"

    /// 版本历史的 key：文件名跟着标题改，按对话 id 认
    static func versionKey(_ writer: SessionCloseout.Writer, conversationId: String, profileId: String) -> FileVersionStore.Key {
        .virtual("memory/\(writer == .window ? WindowSummaryStore.folder : SessionSummaryStore.folder)/\(conversationId)", profileId: profileId)
    }

    /// 能原地重写的 A2 段：正式段和尾段，带着它盖到的最后一条消息（改造前的第 0 段、老收尾段不行）
    static func rewritable(_ seg: SessionSegment) -> Bool {
        seg.lastNodeId != nil && (seg.kind == .rolling || (seg.kind == .closeout && seg.isTail))
    }

    /// 纯函数（可测）：这一段在现在这条主线上盖的是哪几条。末尾按 lastNodeId 认；开头得和段里记的开始时间对上（文件里时间只到秒），
    /// 先试「条数没变」的位置，不对再按时间找。对不上 = nil（不重写，免得盖的范围悄悄变了）
    static func range(of seg: SessionSegment, pathIds: [String], dates: [Date?]) -> Range<Int>? {
        guard rewritable(seg), let id = seg.lastNodeId, let last = pathIds.lastIndex(of: id) else { return nil }
        let end = last + 1
        func starts(_ i: Int) -> Bool {
            guard i >= 0, i < end, dates.indices.contains(i), let d = dates[i] else { return false }
            return abs(d.timeIntervalSince(seg.start)) < 1
        }
        let guess = end - (seg.to - seg.from)
        if starts(guess) { return guess..<end }
        return (0..<end).first(where: starts).map { $0..<end }
    }

    private static func cancellable(_ caller: @escaping SessionSegmentWriter.Caller) -> SessionSegmentWriter.Caller {
        { system, user in
            try Task.checkCancellation()
            let raw = try await caller(system, user)
            try Task.checkCancellation()
            return raw
        }
    }

    private static func log(_ writer: SessionCloseout.Writer, _ input: Input, ok: Bool, _ note: String, cost: Double? = nil) {
        MemoryWriteLog.record(writer: writer.id, profileId: input.profileId, ok: ok, note: "\(actorPrefix) · 窗口「\(SessionSummaryStore.oneLine(input.title))」· " + note,
                              model: writer == .window ? input.a3Model : input.a2Model, cost: cost, memoryRoot: input.memoryRoot)
    }

    /// 已经占住窗口、拿到现在的主线之后的那一趟（可测：模型、落盘、版本库都从 input 进）
    static func perform(_ target: Target, _ input: Input, progress: (String) async -> Void = { _ in }) async -> Report {
        var report = Report()
        switch target {
        case .segment(let id):
            guard input.a2On else { report.stop = .off("A2 上下文摘要关着，或这个窗口不写 A2"); return report }
            await rewriteA2(only: id, input, report: &report, progress: progress)
            if report.stop == .done, report.planned == 0 || report.segments == 0 { report.stop = .nothing }
        case .a3:
            guard input.a3On else { report.stop = .off("A3 窗口总结关着，或这个窗口不参与记忆"); return report }
            await rewriteA3(input, report: &report, progress: progress)
        case .window:
            guard input.a2On || input.a3On else { report.stop = .off("A2、A3 都关着，或这个窗口不参与记忆"); return report }
            if input.a2On { await rewriteA2(only: nil, input, report: &report, progress: progress) }
            if input.a3On, report.stop == .done { await rewriteA3(input, report: &report, progress: progress) }
            if report.stop == .done, report.segments == 0, !report.a3 { report.stop = .nothing }
        }
        return report
    }

    private static func rewriteA2(only: String?, _ input: Input, report: inout Report, progress: (String) async -> Void) async {
        let cid = input.conversationId
        var s: SessionSummary
        do {
            guard let loaded = try SessionSummaryStore.loadStrict(conversationId: cid, in: SessionSummaryStore.dir(root: input.memoryRoot)) else { return }
            s = loaded
        } catch {
            report.stop = .failed(error.localizedDescription)
            return
        }
        let ids = input.messages.map(\.id), dates = input.messages.map(\.date)
        let notBefore = MemoryStartDay.firstAllowedIndex(dates, startDay: input.startDay)
        let targets = s.segments.indices.filter { rewritable(s.segments[$0]) && (only == nil || s.segments[$0].lastNodeId == only) }
        report.planned = targets.count
        let shown = WindowSummaryReader.contextSegments(WindowSummaryReader.ordered(s.segments))
        let key = versionKey(.context, conversationId: cid, profileId: input.profileId)
        let before = SessionSummaryStore.render(s)
        var snapshotted = false
        for (k, i) in targets.enumerated() {
            if Task.isCancelled { report.stop = .cancelled; break }
            let old = s.segments[i]
            guard let r = range(of: old, pathIds: ids, dates: dates), r.lowerBound >= notBefore else {
                report.unmatched += 1
                continue
            }
            let number = shown.firstIndex { $0.lastNodeId == old.lastNodeId && $0.isTail == old.isTail }.map { WindowSummaryReader.number($0, in: shown) }
            let which = number.map { "第 \($0) 段" } ?? "一段"
            await progress(targets.count > 1 ? "A2 \(which)（\(k + 1) / \(targets.count)）" : "A2 \(which)")
            do {
                let skipped: String? = try await MemoryWriteLog.metered {
                    guard var seg = try await SessionSegmentWriter.write(
                        .init(messages: Array(input.messages[r]), kind: old.kind, from: r.lowerBound, persona: input.persona, speakers: input.speakers,
                              previous: s.segments[..<i].last(where: { $0.kind != .closeout }),
                              profileId: input.profileId, windowTitle: input.title, memoryRoot: input.memoryRoot),
                        caller: cancellable(input.callers(.context))) else { return MemoryWriteLog.meter?.skip ?? "模型没回内容" }
                    seg.isTail = old.isTail
                    seg.pending = old.pending
                    if !snapshotted {
                        _ = try? await input.versions.record(key: key, content: before, source: .external, actor: "A2 写手")
                        snapshotted = true
                    }
                    var next = s
                    next.segments[i] = seg
                    next.updatedAt = Date()
                    try input.saveA2(next)
                    s = next
                    log(.context, input, ok: true, "\(which)「\(SessionSummaryStore.oneLine(seg.title))」（原「\(SessionSummaryStore.oneLine(old.title))」）")
                    return nil
                }
                if let skipped { report.stop = .skipped(skipped); break }
                report.segments += 1
            } catch {
                if error is CancellationError || Task.isCancelled {
                    report.stop = .cancelled
                } else {
                    log(.context, input, ok: false, "\(which)没写成，原样保留：\(error.localizedDescription)")
                    report.stop = .failed(error.localizedDescription)
                }
                break
            }
        }
        if report.segments > 0 {
            _ = try? await input.versions.record(key: key, content: SessionSummaryStore.render(s), source: .autoSave,
                                                 actor: "\(actorPrefix) · \(input.a2Model)")
        }
    }

    private static func rewriteA3(_ input: Input, report: inout Report, progress: (String) async -> Void) async {
        let cid = input.conversationId
        let notBefore = MemoryStartDay.firstAllowedIndex(input.messages.map(\.date), startDay: input.startDay)
        guard notBefore < input.messages.count else { return }
        if Task.isCancelled { report.stop = .cancelled; return }
        await progress("A3 窗口总结")
        let key = versionKey(.window, conversationId: cid, profileId: input.profileId)
        do {
            let skipped: String? = try await MemoryWriteLog.metered {
                let context = try SessionSummaryStore.loadStrict(conversationId: cid, in: SessionSummaryStore.dir(root: input.memoryRoot))
                    ?? SessionSummaryStore.legacySeed(conversationId: cid, memoryRoot: input.memoryRoot)
                    ?? SessionSummary(conversationId: cid, title: input.title, compressedCount: 0, segments: [], updatedAt: .distantPast)
                let old = try WindowSummaryStore.loadStrict(conversationId: cid, in: input.memoryRoot)
                guard let w = try await SessionCloseout.recompressWindow(
                    context: context, messages: input.messages, title: input.title, notBefore: notBefore, persona: input.persona,
                    speakers: input.speakers, caller: cancellable(input.callers(.window)), profileId: input.profileId,
                    memoryRoot: input.memoryRoot) else { return MemoryWriteLog.meter?.skip ?? "模型没回内容" }
                if let old {
                    _ = try? await input.versions.record(key: key, content: SessionSummaryStore.render(old), source: .external, actor: "A3 写手")
                }
                try WindowSummaryStore.save(w, in: input.memoryRoot)
                _ = try? await input.versions.record(key: key, content: SessionSummaryStore.render(w), source: .autoSave,
                                                     actor: "\(actorPrefix) · \(input.a3Model)")
                log(.window, input, ok: true, "窗口总结「\(SessionSummaryStore.oneLine(w.segments.first?.title ?? ""))」")
                return nil
            }
            if let skipped { report.stop = .skipped(skipped) } else { report.a3 = true }
        } catch {
            if error is CancellationError || Task.isCancelled {
                report.stop = .cancelled
            } else {
                log(.window, input, ok: false, "窗口总结没写成，原样保留：\(error.localizedDescription)")
                report.stop = .failed(error.localizedDescription)
            }
        }
    }

    /// 跑完那句话（纯函数，可测）
    static func summary(_ r: Report) -> String {
        var done: [String] = []
        if r.planned > 0, r.segments > 0 || r.stop != .done { done.append("A2 写好 \(r.segments) / \(r.planned) 段") }
        if r.a3 { done.append("A3 写好") }
        if r.unmatched > 0 { done.append("\(r.unmatched) 段原文对不上（切过分支、删过消息或早于记忆起点），没动") }
        let wrote = r.segments > 0 || r.a3
        let tail = wrote ? "。不满意可以 Undo" : ""
        let body = done.joined(separator: "，")
        switch r.stop {
        case .done: return "Rewrite 完成：\(body)\(tail)"
        case .nothing: return body.isEmpty ? "没有能 Rewrite 的" : "没有 Rewrite：\(body)"
        case .off(let why): return "没有 Rewrite：\(why)"
        case .cancelled: return "已 Stop\(body.isEmpty ? "" : "：\(body)")，没写到的原样保留\(tail)"
        case .skipped(let why): return "停下了（\(why)）\(body.isEmpty ? "" : "：\(body)")，没写到的原样保留\(tail)"
        case .failed(let why): return "出错停下（\(why)）\(body.isEmpty ? "" : "：\(body)")，没写成的原样保留\(tail)"
        }
    }

    // MARK: - Undo / 退回某一版

    /// 纯函数（可测）：版本（新→旧）里 Undo 退回哪一版——最新一版是 Rewrite 写的才有，退回它前面那版；已经退过（最新是恢复）就没有
    static func undoTarget(_ versions: [FileVersionStore.Version]) -> FileVersionStore.Version? {
        guard versions.count > 1, versions[0].actor?.hasPrefix(actorPrefix) == true else { return nil }
        return versions[1]
    }

    /// 纯函数（可测）：把旧版本的字放回现在的文件。只换字（标题 / 正文 / 原话 / 关键词）：段盖的范围、水位线、待续、之后新写的段都照现在的；
    /// A2 按「同一种段 + 盖到同一条消息 + 条数一样」认段，认不出的不动。返回 nil = 没有一段能退回；changed = 换了几段
    static func merged(current: SessionSummary, old: SessionSummary, writer: SessionCloseout.Writer) -> (summary: SessionSummary, changed: Int)? {
        var out = current
        var changed = 0
        func put(_ o: SessionSegment, at i: Int) {
            var seg = out.segments[i]
            guard (seg.title, seg.story, seg.quotes, seg.keywords, seg.format) != (o.title, o.story, o.quotes, o.keywords, o.format) else { return }
            seg.title = o.title
            seg.story = o.story
            seg.quotes = o.quotes
            seg.keywords = o.keywords
            seg.format = o.format
            out.segments[i] = seg
            changed += 1
        }
        if writer == .window {
            guard WindowSummaryReader.a3(current) != nil, let o = WindowSummaryReader.a3(old), o.kind == current.segments[0].kind else { return nil }
            put(o, at: 0)
        } else {
            for i in out.segments.indices where rewritable(out.segments[i]) {
                let seg = out.segments[i]
                if let o = old.segments.first(where: {
                    $0.kind == seg.kind && $0.isTail == seg.isTail && $0.lastNodeId == seg.lastNodeId && $0.to - $0.from == seg.to - seg.from
                }) { put(o, at: i) }
            }
        }
        guard changed > 0 else { return nil }
        out.updatedAt = Date()
        return (out, changed)
    }

    /// 已经占住窗口：把这一版的字放回去、落盘、记一版「恢复」、写入日志记一行。what = 日志和提示里的动作名（Undo / Restore）
    static func restore(_ writer: SessionCloseout.Writer, versionText: String, what: String, conversationId cid: String, profileId: String,
                        memoryRoot: URL, versions: FileVersionStore = .shared, saveA2: (SessionSummary) throws -> Void) async -> String {
        let name = writer == .window ? "A3 窗口总结" : "A2 上下文摘要"
        guard let old = SessionSummaryStore.parse(versionText), old.conversationId == cid else { return "那一版读不出来，什么都没改" }
        do {
            let dir = writer == .window ? WindowSummaryStore.dir(root: memoryRoot) : SessionSummaryStore.dir(root: memoryRoot)
            guard let current = try SessionSummaryStore.loadStrict(conversationId: cid, in: dir) else { return "\(name)现在没有内容，什么都没改" }
            guard let (next, changed) = merged(current: current, old: old, writer: writer) else {
                return "没有能退回的：那一版和现在一样，或那些段之后已经换掉了"
            }
            let key = versionKey(writer, conversationId: cid, profileId: profileId)
            _ = try? await versions.record(key: key, content: SessionSummaryStore.render(current), source: .external, actor: nil)
            if writer == .window { try WindowSummaryStore.save(next, in: memoryRoot) } else { try saveA2(next) }
            _ = try? await versions.record(key: key, content: SessionSummaryStore.render(next), source: .restore)
            let note = writer == .window ? "退回了那一版" : "退回了 \(changed) 段"
            MemoryWriteLog.record(writer: writer.id, profileId: profileId, ok: true,
                                  note: "\(what) · 窗口「\(SessionSummaryStore.oneLine(current.title))」· \(name)\(note)", model: "", cost: 0, memoryRoot: memoryRoot)
            return "\(what) 完成：\(name)\(note)"
        } catch {
            return "\(what) 没做成，什么都没改：\(error.localizedDescription)"
        }
    }

    // MARK: - app 这一半：占窗口、取主线、接真模型

    static let busyText = "后台正在写这个窗口，稍后再点"

    static func run(_ target: Target, conversationId cid: String, ctx: SessionCloseout.Context, container: ModelContainer,
                    providers: ProviderManager, progress: @escaping (String) async -> Void) async -> String {
        guard MemoryFlags.masterEnabled else { return "没有 Rewrite：记忆总开关关着" }
        let pid = ctx.profileId
        let text = await SessionCloseout.shared.exclusive(cid, job: actorPrefix) { () -> String in
            guard let path = SessionCloseout.currentPath(cid, profileId: pid, source: SwiftDataConversationSource(container: container)),
                  !path.messages.isEmpty else { return "没有 Rewrite：这个窗口不参与记忆，或已经不在了" }
            let participation = SessionCloseout.windowParticipation(conversationId: cid, profileId: pid, container: container)
            await SessionCloseoutStatus.set(running: cid, profileId: pid, title: path.title)
            let input = Input(conversationId: cid, title: path.title, messages: path.messages, profileId: pid, persona: ctx.persona,
                              speakers: ctx.speakers, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), startDay: MemoryStartDay.current,
                              a2On: SessionCloseout.enabled && participation?.a2Write == true,
                              a3On: SessionCloseout.windowEnabled && participation?.participates == true,
                              a2Model: ctx.model(.context).name, a3Model: ctx.model(.window).name,
                              callers: { SessionCloseout.gated($0, SessionCloseout.modelCaller($0, ctx: ctx, providerManager: providers, conversationId: cid)) },
                              saveA2: { try SessionCloseout.saveA2($0, profileId: pid) })
            let report = await perform(target, input, progress: progress)
            await SessionCloseoutStatus.set(running: nil)
            return summary(report)
        }
        return text ?? busyText
    }

    static func canUndo(_ writer: SessionCloseout.Writer, conversationId: String, profileId: String, versions: FileVersionStore = .shared) async -> Bool {
        let list = (try? await versions.versions(key: versionKey(writer, conversationId: conversationId, profileId: profileId))) ?? []
        return undoTarget(list) != nil
    }

    /// versionText = nil：Undo（退回最近一次 Rewrite 之前那版）；给了 = 版本历史里挑的那一版
    static func undo(_ writer: SessionCloseout.Writer, versionText: String? = nil, conversationId cid: String, profileId pid: String,
                     versions: FileVersionStore = .shared) async -> String {
        let key = versionKey(writer, conversationId: cid, profileId: pid)
        var text = versionText
        if text == nil {
            guard let target = undoTarget((try? await versions.versions(key: key)) ?? []),
                  let content = try? await versions.content(key: key, id: target.id) else { return "没有能 Undo 的 Rewrite" }
            text = content
        }
        guard let text else { return "没有能 Undo 的 Rewrite" }
        let result = await SessionCloseout.shared.exclusive(cid, job: "Undo") {
            await restore(writer, versionText: text, what: versionText == nil ? "Undo" : "Restore", conversationId: cid, profileId: pid,
                          memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), versions: versions,
                          saveA2: { try SessionCloseout.saveA2($0, profileId: pid) })
        }
        return result ?? busyText
    }
}

/// Rewrite 的进度、Stop、结果（只给界面看）；窗口总结页、上下文摘要页、窗口列表共用一份
@MainActor
@Observable
final class SummaryRewriteStatus {
    static let shared = SummaryRewriteStatus()

    struct Running: Equatable {
        var text: String
        var stopping = false
    }

    private(set) var running: [String: Running] = [:]
    private(set) var results: [String: String] = [:]
    /// 每做完一笔加一（页面跟着重读、重查能不能 Undo）
    private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(_ target: SummaryRewrite.Target, conversationId cid: String, profile: Profile, providers: ProviderManager, container: ModelContainer) {
        guard running[cid] == nil else { return }
        guard MemoryMaintenance.shared.holder == nil else { results[cid] = MemoryMaintenance.busyText; return }
        var ctx = SessionCloseoutTrigger.context(profile: profile, providers: providers, container: container)
        ctx.manual = true
        let manual = ctx
        results[cid] = nil
        running[cid] = Running(text: "准备中…")
        tasks[cid] = Task {
            let work = Task.detached(priority: .userInitiated) {
                await SummaryRewrite.run(target, conversationId: cid, ctx: manual, container: container, providers: providers) { text in
                    await MainActor.run { SummaryRewriteStatus.shared.running[cid]?.text = text }
                }
            }
            let text = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            finish(cid, text)
        }
    }

    func stop(_ cid: String) {
        running[cid]?.stopping = true
        tasks[cid]?.cancel()
    }

    func undo(_ writer: SessionCloseout.Writer, versionText: String? = nil, conversationId cid: String, profileId: String) {
        guard running[cid] == nil else { return }
        guard MemoryMaintenance.shared.holder == nil else { results[cid] = MemoryMaintenance.busyText; return }
        running[cid] = Running(text: versionText == nil ? "Undo…" : "Restore…", stopping: true)
        tasks[cid] = Task {
            let text = await Task.detached(priority: .userInitiated) {
                await SummaryRewrite.undo(writer, versionText: versionText, conversationId: cid, profileId: profileId)
            }.value
            finish(cid, text)
        }
    }

    func dismissResult(_ cid: String) { results[cid] = nil }

    private func finish(_ cid: String, _ text: String) {
        running[cid] = nil
        tasks[cid] = nil
        results[cid] = text
        revision += 1
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }
}
