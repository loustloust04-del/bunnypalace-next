#if DEBUG
import SwiftUI
import SwiftData

/// 重新生成的真实接线（plan-memory-v4-1 §九，只在 DEBUG 构建）：取楼层人设 / 记忆模型、从库里读每个窗口的主线消息，
/// 跑之前让日常写手停手，跑完放开
@MainActor
enum MemoryRegenerationRunner {
    struct Setup {
        let profileId: String
        let memoryRoot: URL
        let model: ProviderModel
        let writers: MemoryRegeneration.Writers
    }

    static func setup(profile: Profile, providerManager: ProviderManager) -> Setup {
        let chat = providerManager.resolveModel(conversationModelId: nil, globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        let model = ConversationViewModel.memoryModel(providerManager: providerManager, fallback: chat)
        let ctx = SessionCloseout.Context(profile: profile, model: model)
        let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: providerManager, conversationId: "", profileId: profile.id)
        return Setup(profileId: profile.id, memoryRoot: FileLibraryStore.memoryRoot(profileId: profile.id), model: model,
                     writers: .init(persona: ctx.persona, speakers: ctx.speakers, caller: caller))
    }

    /// 一个窗口的主线消息（和收尾巡检同一个求法）；删了 / 进废纸篓 = nil
    nonisolated static func source(_ conversationId: String, profileId: String, container: ModelContainer) -> MemoryRegeneration.Source? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let cid = conversationId
        guard let conv = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.id == cid && $0.profileId == profileId
        })).first, !conv.isTrashed else { return nil }
        let nodes = SessionCloseout.mainPathNodes(conv, profileId: profileId, context: context)
        return .init(title: conv.title, messages: nodes.map(SessionCloseout.message), isCC: SessionCloseout.isCCPath(nodes))
    }
}

/// 设置 → 记忆 → 高级最底下：「按新规则重写…」「从备份恢复…」。只在 DEBUG 构建里出现；总开关关着时重写置灰
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

    private struct PendingRun: Identifiable {
        let id = UUID()
        let estimate: MemoryRegeneration.Estimate
        let modelName: String
        let backupPath: String
    }

    var body: some View {
        Section {
            Button("按新规则重写…") { prepare() }
                .disabled(!memMaster || running)
            Button("从备份恢复…") { listBackups() }
                .disabled(running)
            if let status {
                Text(status)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
            }
        } header: {
            Text("高级 · 重新生成（调试）")
        } footer: {
            Text(memMaster ? "把「记忆从哪天开始」以后的上下文摘要、窗口总结、时间轴按新规则重写一遍，先整份备份"
                           : "记忆总开关关着：先打开总开关再重写")
        }
        .panelRowBackground()
        .listRowSeparator(.hidden)
        .alert("按新规则重写？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button("备份并重写") { run(p) }
            Button("取消", role: .cancel) { pending = nil }
        } message: { p in
            Text(confirmText(p))
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
            Text("恢复「\(url.lastPathComponent)」：上下文摘要、窗口总结、时间轴三个文件夹换成备份里的")
        }
    }

    private func confirmText(_ p: PendingRun) -> String {
        let e = p.estimate
        guard let start = e.scopeStart else { return "没找到要重写的（还没有第三刀写的段）" }
        var s = "从 \(MemoryStartDay.format(start)) 起，\(e.windows) 个窗口，大概 \(e.calls) 次模型调用（格式不对的会多一次），用「\(p.modelName)」。"
        if e.goneWindows > 0 { s += "\n另有 \(e.goneWindows) 个窗口已经删了，旧时间轴条目原样保留。" }
        s += "\n先整份备份到 \(p.backupPath)。"
        return s
    }

    private func prepare() {
        guard let pm = profileManager, let providers = providerManager else { return }
        let setup = MemoryRegenerationRunner.setup(profile: pm.currentProfile, providerManager: providers)
        let container = modelContext.container
        let startDay = MemoryStartDay.current
        running = true
        status = "正在算要重写多少…"
        Task {
            let e = await Task.detached(priority: .userInitiated) {
                MemoryRegeneration.estimate(startDay: startDay, memoryRoot: setup.memoryRoot, now: Date()) {
                    MemoryRegenerationRunner.source($0, profileId: setup.profileId, container: container)
                }
            }.value
            running = false
            status = nil
            let folder = MemoryRegeneration.backupRoot(memoryRoot: setup.memoryRoot)
            pending = PendingRun(estimate: e, modelName: setup.model.name,
                                 backupPath: "\(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent)/v4-1-<时间>/")
        }
    }

    private func run(_ p: PendingRun) {
        pending = nil
        guard p.estimate.scopeStart != nil, let pm = profileManager, let providers = providerManager else { return }
        let setup = MemoryRegenerationRunner.setup(profile: pm.currentProfile, providerManager: providers)
        let container = modelContext.container
        let startDay = MemoryStartDay.current
        running = true
        status = "正在重写…（别关 App）"
        Task {
            await SessionCloseout.shared.setRegenerating(true)
            await SessionCloseout.shared.waitUntilIdle()
            let result: String = await Task.detached(priority: .userInitiated) {
                do {
                    let r = try await MemoryRegeneration.run(
                        memoryRoot: setup.memoryRoot, startDay: startDay, now: Date(), writers: setup.writers,
                        legacySeed: { SessionSummaryStore.legacySeed(conversationId: $0, profileId: setup.profileId) },
                        source: { MemoryRegenerationRunner.source($0, profileId: setup.profileId, container: container) })
                    var s = "重写完了：\(r.windows) 个窗口。备份在 \(r.backup.lastPathComponent)。"
                    s += r.failures.isEmpty ? "全部写成。" : "\n没写成的：\n" + r.failures.joined(separator: "\n")
                    return s
                } catch {
                    return "没做成，原文件没动：\(error.localizedDescription)"
                }
            }.value
            await SessionCloseout.shared.setRegenerating(false)
            running = false
            status = result
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
        running = true
        Task {
            await SessionCloseout.shared.setRegenerating(true)
            await SessionCloseout.shared.waitUntilIdle()
            let result: String = await Task.detached {
                do {
                    try MemoryRegeneration.restore(backup: url, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), now: Date())
                    return "已恢复「\(url.lastPathComponent)」"
                } catch {
                    return "恢复失败：\(error.localizedDescription)"
                }
            }.value
            await SessionCloseout.shared.setRegenerating(false)
            running = false
            status = result
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
    }
}
#endif
