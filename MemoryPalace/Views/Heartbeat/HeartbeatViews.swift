#if os(iOS)
import MemoryCore
import SwiftData
import SwiftUI

/// 人页 heartbeat（plan-wake-heartbeat §1）：一级 = 这个 AI 的任务；二级 = 任务 + 每次执行摘要；三级 = 一次执行的每一步 + 截图。
/// 读的都是每人 memory/heartbeat/ 下的小文件；引擎有变化（revision）就重读

// MARK: 一级：人页里的几段

struct HeartbeatSections: View {
    let profileId: String
    @State private var engine = WakeEngine.shared
    @State private var tasks: [WakeTask] = []
    @State private var showDone = false

    private var tz: TimeZone { engine.timeZone(profileId: profileId) }
    private var active: [WakeTask] { tasks.filter { !$0.done }.sorted { ($0.enabled ? 0 : 1, $0.nextRunAt ?? .distantFuture) < ($1.enabled ? 0 : 1, $1.nextRunAt ?? .distantFuture) } }
    private var done: [WakeTask] { tasks.filter(\.done) }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { engine.personEnabled(profileId) }, set: { engine.setPersonEnabled(profileId, $0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自己醒来做事")
                        .foregroundColor(Theme.textPrimary)
                    Text(statusLine)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .tint(Theme.branchIndicator)
            .disabled(!engine.settings.enabled)
            if let running = engine.running, running.profileId == profileId {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在跑：\(running.title)")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button("停") { engine.stop() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .listRowBackground(Theme.mainBg)

        Section("任务") {
            if active.isEmpty {
                Text("还没有任务——在聊天里跟 TA 说「以后每天早上给我做个早报」，或者点下面新建")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
            }
            ForEach(active) { task in
                NavigationLink { HeartbeatTaskPage(profileId: profileId, taskId: task.id) } label: { HeartbeatTaskRow(task: task, tz: tz) }
            }
            NavigationLink { HeartbeatTaskEditPage(profileId: profileId, task: nil) } label: {
                Label("新任务", systemImage: "plus")
                    .foregroundColor(Theme.branchIndicator)
            }
            if !done.isEmpty {
                DisclosureGroup("已完成（\(done.count)）", isExpanded: $showDone) {
                    ForEach(done) { task in
                        NavigationLink { HeartbeatTaskPage(profileId: profileId, taskId: task.id) } label: { HeartbeatTaskRow(task: task, tz: tz) }
                    }
                }
                .foregroundColor(Theme.textSecondary)
            }
        }
        .listRowBackground(Theme.mainBg)
        .task(id: engine.revision) { tasks = engine.store(profileId: profileId).tasks() }
    }

    private var statusLine: String {
        guard engine.settings.enabled else { return "设置 › 自己醒来 的总开关关着" }
        guard engine.personEnabled(profileId) else { return "关着：到点也不醒" }
        guard let next = active.filter(\.isActive).compactMap({ t in t.nextRunAt.map { (t, $0) } }).min(by: { $0.1 < $1.1 }) else {
            return "没有排着的任务"
        }
        return "下次：\(WakeText.dateTime(next.1, tz: tz)) · \(next.0.title)"
    }
}

private struct HeartbeatTaskRow: View {
    let task: WakeTask
    let tz: TimeZone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.schedule.isOnce ? "bell" : "sun.max")
                .foregroundColor(task.enabled ? Theme.branchIndicator : Theme.textMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .foregroundColor(task.enabled || task.done ? Theme.textPrimary : Theme.textMuted)
                    .lineLimit(1)
                Text(WakeText.schedule(task.schedule, tz: tz))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 6)
            Text(lastLine)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(task.lastStatus == .failed ? Color.red.opacity(0.8) : Theme.textSecondary)
        }
    }

    private var lastLine: String {
        if !task.enabled, !task.done { return task.failureStreak >= WakeSettings.failureStop ? "连败 3 次，已停" : "停了" }
        guard let last = task.lastRunAt else { return "没跑过" }
        let mark: String
        switch task.lastStatus {
        case .ok: mark = "✓"
        case .failed: mark = "✗"
        case .skipped: mark = "跳过"
        case .interrupted: mark = "打断"
        case nil: mark = ""
        }
        return "\(mark) \(WakeText.dateTime(last, tz: tz))"
    }
}

// MARK: 二级：任务 + 每次执行

struct HeartbeatTaskPage: View {
    let profileId: String
    let taskId: String
    @State private var engine = WakeEngine.shared
    @State private var task: WakeTask?
    @State private var runs: [WakeRun] = []

    private var tz: TimeZone { engine.timeZone(profileId: profileId) }
    private var isRunning: Bool { engine.running?.taskId == taskId }

    var body: some View {
        List {
            if let task {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.title)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("\(WakeText.schedule(task.schedule, tz: tz)) · \(creator(task))")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textSecondary)
                        Text(notifyLine(task))
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textSecondary)
                        Text(task.instruction)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.top, 2)
                        if let note = task.note, !note.isEmpty {
                            Text("给下次的自己：\(note)")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .padding(.vertical, 4)
                    Button {
                        engine.runNow(taskId: taskId, profileId: profileId)
                    } label: {
                        HStack {
                            if isRunning { ProgressView().controlSize(.small) }
                            Text(isRunning ? "正在跑…" : "现在跑一次")
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }
                    .disabled(engine.running != nil)
                    if isRunning {
                        Button("停", role: .destructive) { engine.stop() }
                    }
                }
                .listRowBackground(Theme.mainBg)
            }

            Section("每次执行") {
                if runs.isEmpty {
                    Text("还没跑过")
                        .foregroundColor(Theme.textMuted)
                }
                ForEach(runs) { run in
                    NavigationLink { HeartbeatRunPage(profileId: profileId, run: run) } label: { HeartbeatRunRow(run: run, tz: tz) }
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let task {
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink("编辑") { HeartbeatTaskEditPage(profileId: profileId, task: task) }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .task(id: engine.revision) {
            let store = engine.store(profileId: profileId)
            task = store.task(taskId)
            runs = store.runs(taskId: taskId, limit: 60)
        }
    }

    private func creator(_ task: WakeTask) -> String {
        if case .ai = task.createdBy { return "TA 在聊天里建的" }
        return "你建的"
    }

    private func notifyLine(_ task: WakeTask) -> String {
        switch task.notify {
        case .conversation(_, let push): return "做完：发到对话\(push ? " + 推通知" : "")"
        case .heartbeatOnly: return "做完：只记在这里"
        case .mainSession(let push): return "做完：发到 main session\(push ? " + 推通知" : "")"
        }
    }
}

private struct HeartbeatRunRow: View {
    let run: WakeRun
    let tz: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(WakeText.dateTime(run.startedAt, tz: tz))
                    .foregroundColor(Theme.textPrimary)
                Text(statusMark)
                    .foregroundColor(run.status == .ok ? Theme.branchIndicator : run.status == .failed ? Color.red.opacity(0.8) : Theme.textMuted)
                Spacer()
                if let usd = run.usd, usd > 0 {
                    Text(HeartbeatRunText.cost(usd))
                        .font(.system(size: Theme.F.caption).monospacedDigit())
                        .foregroundColor(Theme.textMuted)
                }
            }
            Text(HeartbeatRunText.summaryLine(run))
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            if let text = run.summary ?? run.statusNote {
                Text(text)
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusMark: String {
        switch run.status {
        // 跑成了但没发（「先安静」）：和失败分开
        case .ok: return run.deliveredMessageId == nil && run.message == nil ? "✓ 没发" : "✓"
        case .failed: return "✗"
        case .skipped: return "跳过"
        case .interrupted: return "打断"
        }
    }
}

enum HeartbeatRunText {
    /// 「看了 9 个来源 · 搜索×4 读网页×9 · 1 分 40 秒」
    static func summaryLine(_ run: WakeRun) -> String {
        var parts: [String] = []
        if !run.sources.isEmpty { parts.append("看了 \(run.sources.count) 个来源") }
        if !run.tools.isEmpty { parts.append(toolCounts(run.tools)) }
        if let d = run.duration, d >= 1 {
            let s = Int(d)
            parts.append(s >= 60 ? "\(s / 60) 分 \(s % 60) 秒" : "\(s) 秒")
        }
        if run.trigger == .catchUp { parts.append("补跑") }
        if run.trigger == .manual { parts.append("手动") }
        return parts.isEmpty ? "没用工具" : parts.joined(separator: " · ")
    }

    /// 同一个人话名的合在一起（打开 / 看这页 / 点 都算「花园浏览器」）
    static func toolCounts(_ tools: [WakeToolCount]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for t in tools {
            if counts[t.label] == nil { order.append(t.label) }
            counts[t.label, default: 0] += t.count
        }
        return order.map { "\($0)×\(counts[$0] ?? 0)" }.joined(separator: " ")
    }

    /// 「$0.08」；不到一分写「不到 1 分」
    static func cost(_ usd: Double) -> String {
        usd < 0.01 ? "不到 1 分" : String(format: "$%.2f", usd)
    }
}

// MARK: 三级：一次执行

struct HeartbeatRunPage: View {
    let profileId: String
    let run: WakeRun
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(\.modelContext) private var modelContext
    @State private var zoomed: URL?

    private var tz: TimeZone { WakeEngine.shared.timeZone(profileId: profileId) }
    private var store: WakeStore { WakeEngine.shared.store(profileId: profileId) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(WakeText.dateTime(run.startedAt, tz: tz)) · \(HeartbeatRunText.summaryLine(run))")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textSecondary)
                    if let summary = run.summary {
                        Text(summary)
                            .font(.system(size: Theme.F.body, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                    }
                    if let note = run.statusNote {
                        Text(note)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(run.status == .failed ? Color.red.opacity(0.8) : Theme.textSecondary)
                    }
                    if let usd = run.usd, usd > 0 {
                        Text("花了 \(HeartbeatRunText.cost(usd)) · \(run.rounds) 轮")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
                if let message = run.message {
                    Text(message)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                if let id = run.deliveredConversationId, let viewModel {
                    Button {
                        _ = MemoryConversationLink.open(id, profileId: profileId, context: modelContext, viewModel: viewModel)
                    } label: {
                        Label("去这个对话里看", systemImage: "arrow.right.circle")
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
            }
            .listRowBackground(Theme.mainBg)

            if !run.sources.isEmpty {
                Section("来源（\(run.sources.count)）") {
                    ForEach(run.sources, id: \.url) { source in
                        Button {
                            if let url = URL(string: source.url) { GardenBrowser.present(url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if let title = source.title, !title.isEmpty {
                                    Text(title).foregroundColor(Theme.textPrimary).lineLimit(1)
                                }
                                Text(WakeTools.shortURL(source.url))
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.mainBg)
            }

            if !run.withheldTools.isEmpty {
                Section {
                    Text("这次没给：\(run.withheldTools.joined(separator: "、"))（要你当面点头的工具，醒来时没人点。想让它用，在权限里设成自动允许）")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
            }

            Section("每一步") {
                if run.steps.isEmpty {
                    Text("没有用工具").foregroundColor(Theme.textMuted)
                }
                ForEach(Array(run.steps.enumerated()), id: \.offset) { i, step in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1)")
                                .font(.system(size: Theme.F.caption).monospacedDigit())
                                .foregroundColor(Theme.textMuted)
                                .frame(width: 18, alignment: .trailing)
                            Text(step.action)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: step.ok ? "checkmark" : "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(step.ok ? Theme.branchIndicator : Color.red.opacity(0.8))
                        }
                        if !step.ok {
                            Text(step.result)
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Color.red.opacity(0.8))
                                .lineLimit(3)
                        }
                        if let shot = step.shot {
                            let url = store.shotURL(runId: run.id, name: shot)
                            if let image = UIImage(contentsOfFile: url.path) {
                                Button { zoomed = url } label: {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        } else if step.url != nil {
                            Text("这一步没有截图")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                        if let link = step.url, let url = URL(string: link) {
                            Button("打开这一页") { GardenBrowser.present(url) }
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.branchIndicator)
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle(run.taskTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { zoomed.map(ZoomedShot.init) }, set: { zoomed = $0?.url })) { shot in
            ZoomedShotView(url: shot.url)
        }
    }
}

private struct ZoomedShot: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ZoomedShotView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                }
            }
            .background(Theme.sidebarBg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
            }
        }
    }
}

// MARK: 新建 / 编辑

struct HeartbeatTaskEditPage: View {
    let profileId: String
    let task: WakeTask?
    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @State private var title = ""
    @State private var instruction = ""
    /// "" = 跟对话 / 人页
    @State private var modelId = ""
    @State private var kind = 0   // 0 每天 1 每周 2 一次
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var onceAt = Date().addingTimeInterval(3600)
    /// 0 mainsession（默认）· 1 原来那个对话（老任务 / AI 指定发回当前对话的）· 2 只记在 heartbeat
    @State private var destination = 0
    @State private var conversationId: String?
    @State private var push = true
    @State private var enabled = true
    @State private var loaded = false
    @State private var confirmDelete = false

    private var engine: WakeEngine { WakeEngine.shared }
    private var tz: TimeZone { engine.timeZone(profileId: profileId) }
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    var body: some View {
        Form {
            Section("叫什么") {
                TextField("AI 早报", text: $title)
            }
            Section {
                TextEditor(text: $instruction)
                    .frame(minHeight: 120)
            } header: {
                Text("醒来要做什么")
            } footer: {
                Text("写给醒来的 TA：要做什么、怎么做、做成什么样。比如「搜一下今天 AI 圈的新进展，挑三件最重要的，每件两句话讲清楚」")
            }
            Section("什么时候") {
                Picker("", selection: $kind) {
                    Text("每天").tag(0)
                    Text("每周").tag(1)
                    Text("一次").tag(2)
                }
                .pickerStyle(.segmented)
                if kind == 2 {
                    DatePicker("时间", selection: $onceAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, tz)
                } else {
                    DatePicker("几点", selection: $time, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, tz)
                }
                if kind == 1 {
                    HStack {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                            let on = weekdays.contains(day)
                            Button(["日", "一", "二", "三", "四", "五", "六"][day - 1]) {
                                if on { weekdays.remove(day) } else { weekdays.insert(day) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(Circle().fill(on ? Theme.branchIndicator.opacity(0.2) : Color.clear))
                            .foregroundColor(on ? Theme.branchIndicator : Theme.textSecondary)
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section {
                Picker("用哪个模型", selection: $modelId) {
                    Text("跟对话 / 人页").tag("")
                    ForEach(toolCards, id: \.id) { card in
                        Section(card.name) {
                            ForEach(card.models) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                    }
                    // 选过的模型现在停用了：留一行显示原名，运行时照旧跟对话 / 人页
                    if !modelId.isEmpty, !toolCards.contains(where: { $0.models.contains { $0.id == modelId } }) {
                        Text("（已停用的模型）").tag(modelId)
                    }
                }
            } header: {
                Text("用哪个模型")
            } footer: {
                Text("醒来做事要调工具，只列能用工具的模型。选了停用的模型，到时候跟对话 / 人页的模型。")
            }
            Section {
                Picker("发到哪", selection: $destination) {
                    Text(MainSession.title).tag(0)
                    if conversationId != nil { Text("原来那个对话").tag(1) }
                    Text("只记在这里").tag(2)
                }
                if destination != 2 { Toggle("再推一条通知", isOn: $push) }
            } header: {
                Text("做完怎么告诉你")
            } footer: {
                Text("发到 main session 的，别的对话里 TA 也知道自己做了什么。没什么值得说的时候 TA 可以不发。")
            }
            if task != nil {
                Section {
                    Toggle("开着", isOn: $enabled)
                    Button("删除这个任务", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .tint(Theme.branchIndicator)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle(task == nil ? "新任务" : "编辑任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || instruction.trimmingCharacters(in: .whitespaces).isEmpty
                              || (kind == 1 && weekdays.isEmpty))
            }
        }
        .alert("删除「\(task?.title ?? "")」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let task { engine.delete(task.id, profileId: profileId) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("以前的执行记录会留着，60 天后自动删。")
        }
        .onAppear(perform: load)
    }

    /// 开着、能用工具的网络卡（醒来做事靠工具；本机模型、Claude Code / Codex 桥卡不走这条循环）
    private var toolCards: [APICredential] {
        (providerManager?.enabledProviders ?? []).filter {
            [.openaiCompatible, .anthropic, .chatgptOAuth].contains($0.type) && $0.toolsSupported != false && !$0.models.isEmpty
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let task else { return }
        title = task.title
        instruction = task.instruction
        enabled = task.enabled
        modelId = task.modelId ?? ""
        switch task.schedule {
        case .daily(let h, let m, let days):
            kind = days == nil ? 0 : 1
            weekdays = Set(days ?? [2, 3, 4, 5, 6])
            time = cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? time
        case .once(let d):
            kind = 2
            onceAt = d
        }
        switch task.notify {
        case .mainSession(let p):
            destination = 0
            push = p
        case .conversation(let id, let p):
            destination = 1
            conversationId = id
            push = p
        case .heartbeatOnly:
            destination = 2
        }
    }

    private func save() {
        let schedule: WakeSchedule = kind == 2
            ? .once(onceAt)
            : .daily(hour: cal.component(.hour, from: time), minute: cal.component(.minute, from: time),
                     weekdays: kind == 1 ? weekdays.sorted() : nil)
        var t = task ?? WakeTask(title: "", instruction: "", schedule: schedule, createdBy: .user, notify: .heartbeatOnly)
        t.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        t.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.schedule != schedule { t.done = false }
        t.schedule = schedule
        t.enabled = enabled
        t.modelId = modelId.isEmpty ? nil : modelId
        if enabled { t.failureStreak = 0 }
        switch destination {
        case 1 where conversationId != nil: t.notify = .conversation(id: conversationId!, push: push)
        case 2: t.notify = .heartbeatOnly
        default: t.notify = .mainSession(push: push)
        }
        engine.save(engine.scheduled(t, profileId: profileId), profileId: profileId)
        dismiss()
    }
}
#endif
