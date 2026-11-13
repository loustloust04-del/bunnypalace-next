import MemoryCore
import SwiftUI

struct MemoryRecallBenchPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var builtIn: [MemoryBenchSet] = []
    @State private var floor: [MemoryBenchSet] = []
    @State private var runs: [MemoryBenchRun] = []
    @State private var loaded = false
    @State private var composing = false

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var names: EffectiveCharacterContext {
        if let profile = profileManager?.currentProfile { return EffectiveCharacterContext(profile: profile) }
        return EffectiveCharacterContext(charName: "", userName: "")
    }

    var body: some View {
        List {
            section("内置", sets: builtIn)
            section("本楼层", sets: floor)
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if loaded && builtIn.isEmpty && floor.isEmpty {
                MemoryEmptyState(title: "还没有测试集", message: "点右上角「出题」，把想测的句子留下来")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MemoryRecallBenchHeading(title: "召回测试台") {
                Button("出题") { composing = true }.disabled(profileId.isEmpty)
            }
        }
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .navigationDestination(isPresented: $composing) {
            MemoryRecallBenchComposer(profileId: profileId)
        }
        .task(id: profileId) { await reload() }
    }

    private func section(_ title: String, sets: [MemoryBenchSet]) -> some View {
        Section {
            ForEach(sets) { set in
                NavigationLink {
                    MemoryRecallBenchSetPage(set: set, profileId: profileId, names: names)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(names.expand(set.name)).foregroundStyle(Theme.textPrimary)
                        let last = runs.first { $0.set.id == set.id && $0.status == .done }
                        Text("\(set.cases.count) 题 · \(last.map { MemoryRecallBenchDisplay.main($0) } ?? "还没跑")")
                            .font(.caption).foregroundStyle(Theme.textMuted)
                    }
                }
                .panelRowBackground()
            }
            if sets.isEmpty {
                Text(title == "本楼层" ? "还没出题" : "没有内置测试集")
                    .foregroundStyle(Theme.textMuted).panelRowBackground()
            }
        } header: { Text(title).foregroundStyle(Theme.textSecondary) }
    }

    private func reload() async {
        let pid = profileId
        let data = await Task.detached(priority: .utility) {
            let store = MemoryBenchStore.forMemoryRoot(FileLibraryStore.memoryRoot(profileId: pid))
            return (MemoryBenchStore.builtInSets().filter { $0.writer == "recall" },
                    store.floorSets().filter { $0.writer == "recall" }, store.runs(writer: "recall"))
        }.value
        guard !Task.isCancelled, pid == profileId else { return }
        (builtIn, floor, runs) = data
        loaded = true
    }
}

struct MemoryRecallBenchSetPage: View {
    let set: MemoryBenchSet
    let profileId: String
    let names: EffectiveCharacterContext
    @State private var running = false
    @State private var progress = 0
    @State private var runTask: Task<Void, Never>?
    @State private var result: MemoryBenchRun?
    @State private var showingResult = false
    @State private var history: [MemoryBenchRun] = []
    @State private var error: String?

    static let floorUnavailable = "本楼层快照还没接上，先用内置 24 题"
    @State private var isFloor = false
    @State private var availabilityLoaded = false
    @State private var timeZoneNotice: String?

    var body: some View {
        List {
            Section {
                Text("现行 · 按本楼层现在的翻记忆设置")
                    .font(.caption).foregroundStyle(Theme.textMuted).panelRowBackground()
                if isFloor {
                    Text(Self.floorUnavailable).font(.caption).foregroundStyle(Theme.textMuted).panelRowBackground()
                }
                if let timeZoneNotice {
                    Text(timeZoneNotice).font(.caption).foregroundStyle(Theme.textMuted).panelRowBackground()
                }
                if running {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("\(progress) / \(set.cases.count)").monospacedDigit()
                    }.foregroundStyle(Theme.textSecondary).panelRowBackground()
                }
                if let error { Text(error).foregroundStyle(Theme.danger).panelRowBackground() }
            }
            Section {
                ForEach(set.cases) { testCase in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(names.expand(testCase.title)).foregroundStyle(Theme.textPrimary)
                        if let input = try? testCase.input.decode(MemoryBenchRecallInput.self), let turn = input.turns.first {
                            Text(names.expand(turn.text)).font(.callout).foregroundStyle(Theme.textSecondary)
                        }
                        Text("\(testCase.labels.count) 个标签").font(.caption).foregroundStyle(Theme.textMuted)
                    }.padding(.vertical, 4).panelRowBackground()
                }
            } header: { Text("题目").foregroundStyle(Theme.textSecondary) }
            if !history.isEmpty {
                Section {
                    ForEach(history) { run in
                        NavigationLink {
                            MemoryRecallBenchResultPage(run: run, set: set, profileId: profileId, names: names)
                        } label: { MemoryRecallBenchRunRow(run: run) }
                        .disabled(running)
                        .panelRowBackground()
                    }
                } header: { Text("历次成绩").foregroundStyle(Theme.textSecondary) }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if set.cases.isEmpty { MemoryEmptyState(title: "还没有题目", message: "在测试集列表点「出题」") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MemoryRecallBenchHeading(title: names.expand(set.name)) {
                Button("跑一次", action: start)
                    .disabled(running || !availabilityLoaded || isFloor || timeZoneNotice != nil || set.cases.isEmpty || profileId.isEmpty)
            }
        }
        #if os(iOS)
        .navigationTitle(names.expand(set.name))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .navigationDestination(isPresented: $showingResult) {
            if let result {
                MemoryRecallBenchResultPage(run: result, set: set, profileId: profileId, names: names)
            }
        }
        .task {
            if !availabilityLoaded {
                isFloor = set.source == .floor || set.cases.contains {
                    (try? $0.input.decode(MemoryBenchRecallInput.self))?.snapshot == "floor"
                }
                timeZoneNotice = isFloor ? nil : Self.timeZoneNotice(for: set, current: Calendar.current.timeZone.identifier)
                availabilityLoaded = true
            }
            let pid = profileId, setId = set.id
            let old = await Task.detached(priority: .utility) {
                MemoryBenchStore.forMemoryRoot(FileLibraryStore.memoryRoot(profileId: pid)).runs(writer: "recall", setId: setId)
            }.value
            guard !Task.isCancelled else { return }
            history = old
        }
        .onDisappear { runTask?.cancel() }
    }

    static func timeZoneNotice(for set: MemoryBenchSet, current: String) -> String? {
        guard let input = set.cases.first.flatMap({ try? $0.input.decode(MemoryBenchRecallInput.self) }),
              input.profile.timeZone != current else { return nil }
        return "内置题按 \(input.profile.timeZone) 出的，这台设备是 \(current)，先不能跑"
    }

    private func start() {
        guard !running, availabilityLoaded, !isFloor, timeZoneNotice == nil else { return }
        running = true
        progress = 0
        error = nil
        let reader = MemoryBenchWriters.recallReader(profileId: profileId)
        let recipes = reader.builtInRecipes(defaults: .standard)
        let pid = profileId
        runTask = Task {
            defer { running = false; runTask = nil }
            do {
                guard let recipe = recipes.first else { throw MemoryBenchLocalExecutor.Failure("现行配方不可用") }
                let store = await Task.detached(priority: .utility) { MemoryBenchStore.forMemoryRoot(FileLibraryStore.memoryRoot(profileId: pid)) }.value
                try Task.checkCancellation()
                let run = try await MemoryBenchRunner.run(writer: reader, set: set, recipes: [recipe],
                    models: [.init(credentialId: "local", modelId: "recall", name: "本地离线", local: true)],
                    store: store, profileId: profileId,
                    caller: { _, _ in throw MemoryBenchLocalExecutor.Failure("离线测试不调用模型") },
                    onProgress: { done, _ in Task { @MainActor in progress = max(progress, done) } })
                guard !Task.isCancelled else { return }
                history.insert(run, at: 0)
                result = run
                showingResult = true
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

struct MemoryRecallBenchHeading<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            #if os(macOS)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            #endif
            Spacer(minLength: 0)
            actions().buttonStyle(.plain).foregroundStyle(Theme.branchIndicator)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .toolPageBackground()
    }
}

struct MemoryRecallBenchRunRow: View {
    let run: MemoryBenchRun
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.at, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(Theme.textSecondary)
                if run.status != .done {
                    Text(MemoryRecallBenchDisplay.status(run.status)).font(.caption).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
            Text(MemoryRecallBenchDisplay.main(run)).monospacedDigit().foregroundStyle(Theme.textPrimary)
        }
    }
}

enum MemoryRecallBenchDisplay {
    static func main(_ run: MemoryBenchRun) -> String {
        run.scores.first?.main.map { String(format: "%.2f", $0) } ?? "—"
    }

    static func comparison(_ run: MemoryBenchRun, previous: [MemoryBenchRun]) -> String {
        guard let last = previous.first(where: { $0.status == .done }) else { return "这是第一次跑" }
        guard let main = run.scores.first?.main, let old = last.scores.first?.main else { return "和上次比：没有可比较的主分" }
        let delta = String(format: "%+.2f", main - old)
        return "和上次比：\(delta)"
            + (last.set.revision == run.set.revision ? "" : "（题目已变）")
            + (last.recipes.first?.params == run.recipes.first?.params ? "" : "（设置已变）")
    }

    static func status(_ status: MemoryBenchRun.Status) -> String {
        switch status {
        case .running: return "还在跑，当前成绩不完整"
        case .cancelled: return "中途停下，只保留已完成的题"
        case .failed: return "写盘失败，当前成绩不完整"
        case .interrupted: return "上次跑到一半被打断"
        case .done: return "已完成"
        }
    }
}
