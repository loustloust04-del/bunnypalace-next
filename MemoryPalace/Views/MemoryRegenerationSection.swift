#if DEBUG
import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// 三代搬迁的真实接线（plan-memory-migrate-3gen，只在 DEBUG 构建）：取楼层人设 / 各写手的模型和价、从库里查要搬的窗口、
/// 读每个窗口的主线消息（日常写手停手 / 放开由 `MemoryMaintenance` 管）
@MainActor
enum MemoryRegenerationRunner {
    struct Setup {
        let profileId: String
        let floorName: String
        let writers: MemoryMigration.Writers
        let models: [SessionCloseout.Writer: String]
        let price: MemoryMigration.Price
    }

    static func setup(profile: Profile, providerManager: ProviderManager) -> Setup {
        // 各写手用自己选的模型、记自己的账（M5）；手动搬迁不看写入预算（同「现在写」，v5 Q10），全局预算闸照查
        var ctx = SessionCloseoutTrigger.context(profile: profile, providers: providerManager)
        ctx.manual = true
        let c = ctx
        var models: [SessionCloseout.Writer: String] = [:]
        for w in SessionCloseout.Writer.allCases { models[w] = c.model(w).name }
        let price: MemoryMigration.Price = { w, input, output in
            let model = c.model(w)
            guard let provider = providerManager.provider(for: model) else { return 0 }
            return BudgetCalculator.actualCost(provider: provider, modelId: model.modelId,
                                               usage: TokenUsage(inputTokens: input, outputTokens: output))
        }
        let writers = MemoryMigration.Writers(persona: c.persona, speakers: c.speakers) { w, cid in
            SessionCloseout.modelCaller(w, ctx: c, providerManager: providerManager, conversationId: cid)
        }
        return Setup(profileId: profile.id, floorName: profile.name, writers: writers, models: models, price: price)
    }

    /// 起点以后动过、开着记忆参与、没进回收站的窗口（没有起点 = 没有）
    nonisolated static func candidates(profileId: String, since: Date?, container: ModelContainer) -> [String] {
        guard let since else { return [] }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let convs = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.profileId == profileId && $0.isTrashed == false && $0.updateTime >= since
        }))) ?? []
        return convs.filter(\.memoryEnabled).map(\.id)
    }

    /// 一个窗口的主线消息（和收尾巡检同一个求法）；删了 / 进废纸篓 / 关了记忆参与 = nil（不搬）
    nonisolated static func source(_ conversationId: String, profileId: String, container: ModelContainer) -> MemoryRegeneration.Source? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let cid = conversationId
        guard let conv = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.id == cid && $0.profileId == profileId
        })).first, !conv.isTrashed, conv.memoryEnabled else { return nil }
        let nodes = SessionCloseout.mainPathNodes(conv, profileId: profileId, context: context)
        return .init(title: conv.title, messages: nodes.map(SessionCloseout.message), isCC: SessionCloseout.isCCPath(nodes))
    }
}

/// 跑着的那一趟：进度行 +〔停下〕取消的是这个任务
@MainActor
@Observable
final class MemoryMigrationJob {
    var progress: MemoryMigration.Progress?
    /// 还没搬到第一个窗口时进度行的字（在等后台记忆任务 / 在备份，10-16）
    var note: String?
    /// 整趟（10-16：等后台写手那段也能〔停下〕）
    var task: Task<Void, Never>?
    /// 这一趟的编号：迟到的进度回调只认自己那趟，结束作废（10-16 astra #5）
    var runID: UUID?
}

/// 搬迁 / 恢复全局同时只一趟、互斥（astra #6）：mac 设置页和记忆面板两个入口共用这一个。拿到资格的那一趟负责让日常写手停手、
/// iOS 常亮，结束 / 停下 / 出错都由它统一放开（body 不抛错，放开一定走到）
@MainActor
@Observable
final class MemoryMaintenance {
    static let shared = MemoryMaintenance()
    static let busyText = "另一处正在搬或恢复，等它做完再点"
    static let waitingText = "在等后台记忆任务写完…"

    /// 没跑成的原因（10-16）
    enum Refusal: Error, Equatable {
        /// 已经有一趟在跑
        case held
        /// 等够了日常写手还在写（在写的那几个）
        case writersBusy([String])
        /// 等的时候点了停下
        case cancelled

        var text: String {
            switch self {
            case .held: return MemoryMaintenance.busyText
            case .writersBusy(let jobs): return "后台还有记忆任务在写（\(jobs.joined(separator: "、"))），稍后再试"
            case .cancelled: return "点了停下，什么都没动"
            }
        }
    }

    static func text(_ r: Result<String, Refusal>) -> String {
        switch r {
        case .success(let s): return s
        case .failure(let f): return f.text
        }
    }

    /// 正在跑的那一趟（「搬迁」/「恢复」）；nil = 空着
    private(set) var holder: String?

    /// 拿不到资格 / 日常写手 idleTimeout 秒内没停手 / 等的时候被取消 = failure，body 不跑。
    /// 10-16：等写手有上限、可取消；不管哪条路出去，日常写手都放开、资格都还回去（waitUntilIdle 和 body 都不抛，放开一定走到）
    func exclusive<T>(_ what: String, keepAwake: Bool = false, idleTimeout: TimeInterval = SessionCloseout.idleWaitTimeout,
                      _ body: () async -> T) async -> Result<T, Refusal> {
        guard holder == nil else { return .failure(.held) }
        holder = what
        if keepAwake { Self.setIdleTimerDisabled(true) }
        defer {
            if keepAwake { Self.setIdleTimerDisabled(false) }
            holder = nil
        }
        // A4 一天一条也停手（c2c3-v2 第 7 段 astra #4）：新的一趟不进；在途那趟后面的提交在月文件锁里看纪元，作废
        TimelineDaily.gate.pause()
        defer { TimelineDaily.gate.resume() }
        await SessionCloseout.shared.setRegenerating(true)
        let result: Result<T, Refusal>
        switch await SessionCloseout.shared.waitUntilIdle(timeout: idleTimeout) {
        case .idle where Task.isCancelled: result = .failure(.cancelled)   // 10-16 astra #1：等到了也先看一眼停下
        case .idle: result = .success(await body())
        case .timedOut(let jobs): result = .failure(.writersBusy(jobs))
        case .cancelled: result = .failure(.cancelled)
        }
        await SessionCloseout.shared.setRegenerating(false)
        return result
    }

    /// iOS：跑的时候屏幕常亮（切走 App 请求会断，U3）
    private static func setIdleTimerDisabled(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

/// 设置 → 记忆 最底下「高级 · 整理旧记忆（调试）」：「搬成新样子…」「从备份恢复…」。只在 DEBUG 构建里出现；
/// 总开关关着时搬迁置灰，A2 / A3 / A4 单项关着照样能搬（Q5）
struct MemoryRegenerationSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_master") private var memMaster = true

    @State private var pending: PendingRun?
    @State private var backups: [URL] = []
    @State private var showBackups = false
    @State private var pendingRestore: URL?
    @State private var running = false
    @State private var status: String?
    @State private var job = MemoryMigrationJob()

    private var gate: MemoryMaintenance { .shared }

    private struct PendingRun: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Section {
            Button("搬成新样子…") { prepare() }
                .disabled(!memMaster || running || gate.holder != nil)
            Button("从备份恢复…") { listBackups() }
                .disabled(running || gate.holder != nil)
            if let line = job.progress.map(MemoryMigration.progressText) ?? job.note {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if job.task != nil {
                        Button("停下") { job.task?.cancel() }
                    }
                }
            }
            if let status {
                Text(status)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
            }
        } header: {
            Text("高级 · 整理旧记忆（调试）")
        } footer: {
            Text(memMaster ? "把以前三种写法的上下文摘要、窗口总结、时间轴搬成现在的样子，先整份备份"
                           : "记忆总开关关着：先打开总开关再搬")
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
        .alert("搬成新样子？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { _ in
            Button("备份并开始") { run() }
            Button("取消", role: .cancel) { pending = nil }
        } message: { p in
            Text(p.text)
        }
        .confirmationDialog("从哪份备份恢复", isPresented: $showBackups, titleVisibility: .visible) {
            ForEach(backups, id: \.self) { url in
                Button(url.lastPathComponent) { pendingRestore = url }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(backups.isEmpty ? "还没有备份" : "现在的文件会先挪进「记忆备份/回滚前-…」，再把选中的那份拷回去")
        }
        .alert("恢复这份备份？", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
               presenting: pendingRestore) { url in
            Button("恢复", role: .destructive) { restore(url) }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: { url in
            Text(restoreText(url))
        }
    }

    private static let folderNames = [SessionSummaryStore.folder: "上下文摘要", WindowSummaryStore.folder: "窗口总结",
                                      TimelineStore.folder: "时间轴", PendingStore.folder: "待续", SummaryFileStore.folder: "老摘要"]

    private func restoreText(_ url: URL) -> String {
        let covered = MemoryRegeneration.manifest(of: url)?.coveredFolders ?? MemoryRegeneration.folders
        let names = covered.map { Self.folderNames[$0] ?? $0 }.joined(separator: "、")
        return "恢复「\(url.lastPathComponent)」：\(names)换成备份里的，备份以后新写的也一起撤回"
    }

    /// 先算（不调模型、不花钱）：没有要搬的直接说，有就弹确认框
    private func prepare() {
        guard let pm = profileManager, let providers = providerManager else { return }
        let setup = MemoryRegenerationRunner.setup(profile: pm.currentProfile, providerManager: providers)
        let container = modelContext.container
        let startDay = MemoryStartDay.current
        let off = [MemoryWriterID.a2, .a3, .a4].filter { !MemoryWriterSettings.isOn($0) }
        running = true
        status = "正在算要搬多少…"
        Task {
            let s = await Task.detached(priority: .userInitiated) {
                MemoryMigration.survey(profileId: setup.profileId, startDay: startDay, now: Date(), persona: setup.writers.persona,
                                       speakers: setup.writers.speakers, price: setup.price,
                                       candidates: { MemoryRegenerationRunner.candidates(profileId: setup.profileId, since: $0, container: container) },
                                       source: { MemoryRegenerationRunner.source($0, profileId: setup.profileId, container: container) })
            }.value
            running = false
            guard !s.windows.isEmpty else {
                status = "没有要搬的：\(s.skipped) 个窗口已经是新样子" + (s.short > 0 ? "，\(s.short) 个太短跳过" : "")
                return
            }
            status = nil
            let folder = MemoryRegeneration.backupFolderName + "/" + MemoryMigration.backupPrefix + "<时间>/"
            pending = PendingRun(text: MemoryMigration.confirmText(s, floor: setup.floorName, models: setup.models, off: off, backupFolder: folder))
        }
    }

    private func run() {
        pending = nil
        guard let pm = profileManager, let providers = providerManager else { return }
        let setup = MemoryRegenerationRunner.setup(profile: pm.currentProfile, providerManager: providers)
        let container = modelContext.container
        let startDay = MemoryStartDay.current
        let job = job
        status = nil
        job.note = MemoryMaintenance.waitingText
        let runID = UUID()
        job.runID = runID
        job.task = Task {
            let result = await MemoryMaintenance.shared.exclusive("搬迁", keepAwake: true) { () async -> String in
                job.note = "正在备份、清点要搬的窗口…"
                let work = Task.detached(priority: .userInitiated) { () -> String in
                    do {
                        let r = try await MemoryMigration.run(
                            profileId: setup.profileId, startDay: startDay, now: Date(), writers: setup.writers, price: setup.price,
                            candidates: { MemoryRegenerationRunner.candidates(profileId: setup.profileId, since: $0, container: container) },
                            source: { MemoryRegenerationRunner.source($0, profileId: setup.profileId, container: container) },
                            progress: { p in Task { @MainActor in if job.runID == runID { job.progress = p } } })
                        return MemoryMigration.resultText(r)
                    } catch {
                        return "没做成，原文件没动：\(error.localizedDescription)"
                    }
                }
                // 〔停下〕取消的是整趟：传给搬迁那个任务
                return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            }
            job.runID = nil
            job.task = nil
            job.note = nil
            job.progress = nil
            status = MemoryMaintenance.text(result)
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
    }

    private func listBackups() {
        guard let pid = profileManager?.currentProfile.id else { return }
        Task {
            backups = await Task.detached { MemoryRegeneration.backups(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }.value
            showBackups = true
        }
    }

    private func restore(_ url: URL) {
        pendingRestore = nil
        guard let pid = profileManager?.currentProfile.id else { return }
        job.note = MemoryMaintenance.waitingText
        Task {
            let result = await MemoryMaintenance.shared.exclusive("恢复") { () async -> String in
                job.note = nil
                return await Task.detached {
                    do {
                        try MemoryRegeneration.restore(backup: url, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), now: Date(),
                                                       profileId: pid)
                        return "已恢复「\(url.lastPathComponent)」"
                    } catch {
                        return "恢复失败：\(error.localizedDescription)"
                    }
                }.value
            }
            job.note = nil
            status = MemoryMaintenance.text(result)
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
    }
}
#endif
