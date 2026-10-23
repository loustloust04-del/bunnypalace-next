import SwiftUI
import UniformTypeIdentifiers

/// 整包导入 / 撤回 / 恢复进行中（界面层）：卡墙、世界书、正则页据此停写入入口。
/// 提交本身在主线程同步跑，这个开关覆盖「遮罩已挂、提交还没开始 / 刚结束」的空档。
@Observable
final class SillyTavernImportGate {
    static let shared = SillyTavernImportGate()
    var isBusy = false
}

/// 用 app 里注入的那几个管理器本身拼导入环境（不新建实例，写进去的东西卡墙 / 楼层列表立刻看得到）
@MainActor
struct SillyTavernImportManagers {
    let profiles: ProfileManager?
    let presets: PresetManager?
    let cards: CharacterCardManager?
    let globalBooks: GlobalWorldBookManager?

    var environment: SillyTavernImportCommitter.Environment? {
        guard let profiles, let presets, let globalBooks, let cards = cards ?? profiles.characterCardManager else { return nil }
        return SillyTavernImportCommitter.liveEnvironment(profiles: profiles, presets: presets, cards: cards, globalBooks: globalBooks)
    }
}

/// 全屏进度遮罩：挡住所有点按（提交在主线程跑，转圈不会动，靠文字说明）
struct SillyTavernBusyOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(text).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.textPrimary)
                Text("别切走，几秒就好").font(.system(size: 12)).foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
    }
}

/// 小样 09：① 选文件 → ② 盘点 → ③ 完成（报告）。卡墙「＋」和卡库设置「酒馆整包」共用。
struct SillyTavernImportFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(GlobalWorldBookManager.self) private var globalBooks: GlobalWorldBookManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    private typealias P = SillyTavernImportPresentation

    private enum Stage { case choose, inventorying, inventory, report }

    @State private var stage: Stage = .choose
    @State private var pickedURL: URL?
    @State private var showPicker = false
    @State private var pickerTypes: [UTType] = [.zip]
    @State private var plan: SillyTavernPackagePlan?
    @State private var excludable: [P.Excludable] = []
    @State private var excludedKeys: Set<String> = []
    @State private var sources: [ImportSource] = []
    /// "new" 或已有来源 id
    @State private var sourceSelection = "new"
    @State private var newSourceName = ""
    @State private var busyText: String?
    @State private var failure: P.FailureText?
    @State private var inventoryError: String?
    @State private var recoveryMessage: String?
    @State private var pendingBatch = false
    @State private var report: SillyTavernImportReport?
    @State private var closed = false

    private var managers: SillyTavernImportManagers {
        SillyTavernImportManagers(profiles: profileManager, presets: presetManager, cards: cardManager, globalBooks: globalBooks)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if stage == .report, let report {
                        CalendarTicket {
                            steps
                            SillyTavernImportReportContent(report: report)
                            Color.clear.frame(height: 12)
                        }
                        Button { goToWall(report) } label: { primaryLabel("去卡墙看看") }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                    } else {
                        CalendarTicket {
                            steps
                            if pendingBatch { pendingBanner }
                            chooseSection
                            if stage == .inventorying {
                                TicketNotch()
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("正在盘点（复制一份快照，不动原文件）…").font(.system(size: 14)).foregroundColor(Theme.textMuted)
                                }
                                .padding(.horizontal, IOSCal.pad).frame(minHeight: 56)
                            }
                            if let inventoryError {
                                TicketNotch()
                                errorBlock(inventoryError, retry: pickedURL == nil ? nil : ("重新盘点", { runInventory() }))
                            }
                            if stage == .inventory, let plan { inventorySections(plan) }
                            Color.clear.frame(height: 12)
                        }
                        if stage == .inventory, plan != nil {
                            Button { runCommit() } label: { primaryLabel("导入") }
                                .buttonStyle(.plain)
                                .disabled(!canCommit)
                                .opacity(canCommit ? 1 : 0.45)
                                .padding(.horizontal, 8)
                                .accessibilityHint("把盘点到的资料一次导入")
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            // 进报告页换一个滚动视图：从顶上看起，不沿用盘点页滚到底的位置
            .id(stage == .report)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.sidebarBg)
            .navigationTitle(stage == .report ? "导入报告" : "导入酒馆整包")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if stage == .report {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { close() }.foregroundColor(Theme.branchIndicator)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { close() }.foregroundColor(Theme.textMuted)
                    }
                }
            }
        }
        .overlay { if let busyText { SillyTavernBusyOverlay(text: busyText) } }
        .interactiveDismissDisabled(busyText != nil || stage == .inventorying)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: pickerTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pickedURL = url
                runInventory()
            case .failure(let error):
                inventoryError = error.localizedDescription
            }
        }
        .alert("没有导入", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            if failure?.needsRecovery == true {
                Button("去恢复") { failure = nil; runRecovery() }
                Button("先不", role: .cancel) { failure = nil }
            } else {
                Button("好的") { failure = nil }
            }
        } message: { Text(failure?.message ?? "") }
        .alert("恢复", isPresented: Binding(get: { recoveryMessage != nil }, set: { if !$0 { recoveryMessage = nil } })) {
            Button("好的") { recoveryMessage = nil }
        } message: { Text(recoveryMessage ?? "") }
        .onAppear {
            sources = ImportSourceStore.shared.sources
            pendingBatch = (try? ImportSourceStore.shared.pendingBatch()) != nil
        }
        .onDisappear {
            closed = true
            closeStaging()
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 680)
        #endif
    }

    // MARK: 步骤条

    private var steps: some View {
        let current = switch stage {
        case .choose: 0
        case .inventorying, .inventory: 1
        case .report: 2
        }
        return HStack(spacing: 6) {
            ForEach(Array(["① 选文件", "② 盘点", "③ 完成"].enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Rectangle().fill(Theme.accent).frame(height: 1).frame(maxWidth: 18)
                }
                Text(title)
                    .font(.system(size: 13, weight: index == current ? .semibold : .regular))
                    .foregroundColor(index == current ? Theme.branchIndicator : Theme.textMuted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(index == current ? Theme.accent : Color.clear, in: Capsule())
                    .accessibilityAddTraits(index == current ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    // MARK: ① 选文件

    private var chooseSection: some View {
        VStack(spacing: 0) {
            IOSSubLabel(text: pickedURL == nil ? "选文件" : "选文件 · 已选择酒馆整包")
            HStack(spacing: 10) {
                chooseButton("选择压缩包", icon: "doc.zipper", types: [.zip])
                chooseButton("选择文件夹", icon: "folder", types: [.folder])
            }
            .padding(.horizontal, IOSCal.pad)
            .padding(.top, 8)
            if let pickedURL {
                HStack(spacing: 8) {
                    Image(systemName: "doc").font(.system(size: 13)).foregroundColor(Theme.textMuted)
                    Text(pickedURL.lastPathComponent).font(.system(size: 15)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    if stage == .inventory {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.branchIndicator)
                            .accessibilityLabel("已盘点")
                    }
                }
                .padding(.horizontal, IOSCal.pad)
                .frame(minHeight: 44)
            }
            note("支持「下载全部数据」的压缩包，或 data/default-user 文件夹。")
        }
        .disabled(stage == .inventorying)
    }

    private func chooseButton(_ title: String, icon: String, types: [UTType]) -> some View {
        Button {
            pickerTypes = types
            showPicker = true
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.branchIndicator)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.accent.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: ② 盘点

    @ViewBuilder
    private func inventorySections(_ plan: SillyTavernPackagePlan) -> some View {
        TicketNotch()
        IOSSubLabel(text: "盘点结果 · 尚未导入")
        let counts = P.counts(plan.summary)
        ForEach(counts) { row in
            valueRow(row.title, row.value)
            if row.title == "聊天" { note(P.messageNote(plan.summary)) }
        }
        IOSSubLabel(text: "需要注意")
        ForEach(P.attention(plan)) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 15)).foregroundColor(item.isProblem ? Theme.danger : Theme.textPrimary)
                Text(item.detail).font(.system(size: 12)).foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IOSCal.pad).padding(.vertical, 8)
            IOSHairline()
        }
        if !excludable.isEmpty {
            IOSSubLabel(text: "有问题的文件 · 关掉就不导入")
            ForEach(excludable) { item in excludeRow(item) }
            note("关掉的文件只保存原件，不建角色 / 聊天 / 书；报告里会写明排除原因。")
        }
        TicketNotch()
        IOSSubLabel(text: "导入到哪个来源")
        sourcePicker
        TicketNotch()
        note("先关掉酒馆再导。导入用的是刚才盘点时复制的快照；如果之后酒馆又改了数据，点「重新盘点」。")
        note("原始资料全部保留，聊天按所属角色归入楼层；不会切换你当前的楼层。")
        Button { runInventory() } label: {
            Text("重新盘点").font(.system(size: 14)).foregroundColor(Theme.branchIndicator)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func excludeRow(_ item: P.Excludable) -> some View {
        let included = !excludedKeys.contains(item.key)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.key).font(.system(size: 14)).foregroundColor(included ? Theme.textPrimary : Theme.textMuted)
                        .lineLimit(2).truncationMode(.middle)
                    Text(item.reason + (item.paths.count > 1 ? "（\(item.paths.count) 个文件）" : ""))
                        .font(.system(size: 11)).foregroundColor(Theme.textMuted).lineLimit(3)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { included }, set: { on in
                    if on { excludedKeys.remove(item.key) } else { excludedKeys.insert(item.key) }
                }))
                .labelsHidden().toggleStyle(.switch).tint(Theme.branchIndicator)
                .accessibilityLabel("导入 \(item.key)")
            }
            .padding(.horizontal, IOSCal.pad).padding(.vertical, 6)
            .frame(minHeight: 52)
            IOSHairline()
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        if !sources.isEmpty {
            Picker("来源", selection: $sourceSelection) {
                Text("新来源").tag("new")
                ForEach(sources) { source in Text("\(source.name)（重新导入）").tag(source.id) }
            }
            #if os(iOS)
            .pickerStyle(.menu)
            #endif
            .tint(Theme.branchIndicator)
            .padding(.horizontal, IOSCal.pad)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        if sourceSelection == "new" {
            HStack(spacing: 8) {
                Text("名字").font(.system(size: 16)).foregroundColor(Theme.textPrimary)
                TextField("比如：我的酒馆", text: $newSourceName)
                    .textFieldStyle(.plain).font(.system(size: 16)).multilineTextAlignment(.trailing)
                    .accessibilityLabel("来源名字")
            }
            .padding(.horizontal, IOSCal.pad).frame(minHeight: 44)
            IOSHairline()
            note("第一次导入起个名字；以后同一个酒馆再导，选它就只导新的，一样的文件自动跳过。")
        } else {
            note("同一来源再导：一样的文件跳过，内容变了只保留新版原件、不覆盖已导入的东西。")
        }
    }

    private var pendingBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("上次导入没收尾").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.danger)
            Text("先恢复：没写完的那批清掉，已写好的收尾。恢复前不能再导入。")
                .font(.system(size: 12)).foregroundColor(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            Button("去恢复") { runRecovery() }.font(.system(size: 14, weight: .medium)).tint(Theme.branchIndicator)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, IOSCal.pad).padding(.top, 12)
    }

    private var canCommit: Bool {
        guard plan != nil, !pendingBatch else { return false }
        return sourceSelection != "new" || !newSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 动作

    private func runInventory() {
        guard let url = pickedURL else { return }
        closeStaging()
        inventoryError = nil
        excludedKeys = []
        stage = .inventorying
        Task { @MainActor in
            let result = await Self.inventory(url: url)
            guard !closed else {
                if case .success(let plan) = result { plan.snapshot.removeStaging() }
                return
            }
            switch result {
            case .success(let next):
                plan = next
                excludable = P.excludable(next)
                sources = ImportSourceStore.shared.sources
                switch P.defaultSource(fileName: url.lastPathComponent, sources: sources) {
                case .new(let name):
                    sourceSelection = "new"
                    newSourceName = name
                case .existing(let id):
                    sourceSelection = id
                    newSourceName = ""
                }
                stage = .inventory
            case .failure(let error):
                inventoryError = P.failure(error).message
                stage = .choose
            }
        }
    }

    /// 安全作用域：开始访问 → 复制快照 + 解析 → 立刻释放。不在主线程跑
    private nonisolated static func inventory(url: URL) async -> Result<SillyTavernPackagePlan, Error> {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sillytavern-staging", isDirectory: true)
        return Result {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            return try SillyTavernPackageImporter.inventory(source: url, stagingParent: parent)
        }
    }

    private func runCommit() {
        guard let plan else { return }
        guard let env = managers.environment else { failure = .init(message: "卡库还没准备好，稍后再试。", needsRecovery: false); return }
        let choice: SillyTavernImportCommitter.SourceChoice = sourceSelection == "new"
            ? .new(name: newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)) : .existing(id: sourceSelection)
        let excluded = P.excludedPaths(excludable, excludedKeys: excludedKeys)
        busyText = "正在导入"
        SillyTavernImportGate.shared.isBusy = true
        Task { @MainActor in
            // 先让遮罩画出来，再在主线程同步提交
            try? await Task.sleep(for: .milliseconds(150))
            defer {
                busyText = nil
                SillyTavernImportGate.shared.isBusy = false
            }
            do {
                let result = try SillyTavernImportCommitter.commit(plan: plan, source: choice, excluded: excluded, env: env)
                closeStaging()
                sources = ImportSourceStore.shared.sources
                report = result
                stage = .report
            } catch {
                failure = P.failure(error)
                pendingBatch = (try? ImportSourceStore.shared.pendingBatch()) != nil
            }
        }
    }

    private func runRecovery() {
        guard let env = managers.environment else { return }
        busyText = "正在恢复上次导入"
        SillyTavernImportGate.shared.isBusy = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            defer {
                busyText = nil
                SillyTavernImportGate.shared.isBusy = false
            }
            do {
                recoveryMessage = P.recoveryText(try SillyTavernImportCommitter.recover(env: env))
            } catch {
                recoveryMessage = "恢复没完成：\(error.localizedDescription)。下次打开 app 会再试。"
            }
            pendingBatch = (try? ImportSourceStore.shared.pendingBatch()) != nil
            sources = ImportSourceStore.shared.sources
        }
    }

    private func goToWall(_ report: SillyTavernImportReport) {
        let cardId = P.firstCardId(source: ImportSourceStore.shared.source(id: report.sourceId), batchId: report.batchId)
        // 只切到卡墙并定位，不切楼层
        navigator?.pendingTarget = .init(tool: "cardLibrary", id: cardId ?? "tab:characters")
        close()
    }

    private func close() {
        closeStaging()
        closed = true
        dismiss()
    }

    private func closeStaging() {
        plan?.snapshot.removeStaging()
        plan = nil
        excludable = []
    }

    // MARK: 零件

    private func valueRow(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 15)).monospacedDigit().foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, IOSCal.pad).frame(minHeight: 44)
            IOSHairline()
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IOSCal.pad).padding(.top, 6)
    }

    private func errorBlock(_ text: String, retry: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 14)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button(retry.0, action: retry.1).font(.system(size: 14, weight: .medium)).tint(Theme.branchIndicator).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, IOSCal.pad)
    }

    private func primaryLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }
}
