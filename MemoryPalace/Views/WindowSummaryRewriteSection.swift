import MemoryCore
import SwiftUI
import SwiftData

struct WindowSummaryRewriteSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_master") private var master = true
    @AppStorage("mem_write_a3") private var enabled = true
    @State private var preparing = false
    @State private var estimate: WindowSummaryRewrite.Survey?
    @State private var confirm = false
    @State private var last: String?
    @State private var status: String?

    private var job: WindowSummaryRewriteJob { .shared }
    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        Section {
            Button("用新格式重写所有窗口总结") { prepare() }
                .searchAnchor("leaf-mem-a3-rewrite")
                .disabled(preparing || job.task != nil || MemoryMaintenance.shared.holder != nil
                          || !master || !enabled || profileId.isEmpty || providerManager == nil)
            if let last {
                Text(last).font(m.caption).foregroundColor(Theme.textMuted)
            }
            if preparing { Text("正在清点旧窗口总结…").font(m.caption).foregroundColor(Theme.textMuted) }
            if job.profileId == profileId, let note = job.note {
                HStack {
                    Text(note).font(m.caption).foregroundColor(Theme.textMuted)
                    if job.task != nil { Button("停下") { job.cancel() } }
                }
            } else if let status {
                Text(status).font(m.caption).foregroundColor(Theme.textMuted)
            }
        } footer: {
            Text("只重写旧格式，先备份窗口总结；失败的窗口原样保留。不会重写上下文摘要。")
                .font(m.caption)
        }
        .panelRowBackground()
        .alert("重写窗口总结？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button("重写") { run() }
        } message: {
            Text("旧格式共 \(estimate?.windows ?? 0) 个窗口，其中 \(estimate?.longWindows ?? 0) 个超过 8 段（只给标题、原话和关键词）。不到 6 条消息的跳过。会调用上面选定的模型并产生花费，备份成功后才开始。")
        }
        .task(id: profileId) {
            confirm = false
            estimate = nil
            status = nil
            last = WindowSummaryRewrite.lastText(profileId: profileId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            last = WindowSummaryRewrite.lastText(profileId: profileId)
        }
    }

    private func prepare() {
        guard !preparing, job.task == nil else { return }
        let pid = profileId
        let container = modelContext.container
        let startDay = MemoryStartDay.current
        preparing = true
        status = nil
        Task {
            let survey = await Task.detached(priority: .utility) {
                WindowSummaryRewrite.survey(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), startDay: startDay) { cid in
                    SessionCloseout.currentPath(cid, profileId: pid, source: SwiftDataConversationSource(container: container))
                        .map { .init(title: $0.title, messages: $0.messages, isCC: $0.isCC) }
                }
            }.value
            preparing = false
            guard profileId == pid else { return }
            estimate = survey
            if survey.windows == 0 { status = "没有旧格式窗口总结需要重写" } else { confirm = true }
        }
    }

    private func run() {
        guard let profile = profileManager?.currentProfile, let providers = providerManager else { return }
        let pid = profile.id
        let container = modelContext.container
        let startDay = MemoryStartDay.current
        var context = SessionCloseoutTrigger.context(profile: profile, providers: providers)
        context.manual = true
        let ctx = context
        job.start(profileId: pid) {
            let result = await MemoryMaintenance.shared.exclusive("重写窗口总结", keepAwake: true) { () async -> String in
                let work = Task.detached(priority: .utility) { () -> String in
                    do {
                        let report = try await WindowSummaryRewrite.run(
                            profileId: pid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid),
                            persona: ctx.persona, speakers: ctx.speakers, startDay: startDay, modelName: ctx.model(.window).name,
                            source: { cid in
                                SessionCloseout.currentPath(cid, profileId: pid, source: SwiftDataConversationSource(container: container))
                                    .map { .init(title: $0.title, messages: $0.messages, isCC: $0.isCC) }
                            }, caller: { cid in
                                SessionCloseout.gated(.window, SessionCloseout.modelCaller(.window, ctx: ctx,
                                    providerManager: providers, conversationId: cid))
                            }, progress: { text in await MainActor.run { WindowSummaryRewriteJob.shared.note = text } })
                        return report.text
                    } catch is CancellationError {
                        return "已停下，未开始重写"
                    } catch {
                        return "重写未完成：\(error.localizedDescription)；查看记忆日志"
                    }
                }
                return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            }
            let text = MemoryMaintenance.text(result)
            if case .failure = result {
                MemoryWriteLog.record(writer: .a3, profileId: pid, ok: false, note: "A3 新格式重写 · " + text, model: "", cost: 0, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
            }
            return text
        }
    }
}
