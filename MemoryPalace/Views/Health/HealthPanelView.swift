import SwiftUI
import SwiftData
import Charts

// MARK: - page2 tool「健康」（plan-health-module §3）
// P0：今日药卡（三态打卡）+ 体重卡（输入 + Charts 7/30 天）+ 最近流水。
// 现行 Theme 风格，等 page2-visual 上皮后统一换装。

/// 漏服/玫瑰态用色——app 已有的玫瑰语言（AI 划线同族），不引 JournalTheme 依赖。
private let healthRose = Color(red: 0xC9 / 255.0, green: 0x8A / 255.0, blue: 0x8A / 255.0)

struct HealthPanelView: View {
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    let profileId: String
    @Environment(\.modelContext) private var modelContext

    @Query private var meds: [Medication]
    @Query private var weights: [WeightEntry]
    @Query private var recentLogs: [MedicationLog]
    @Query private var cycleDays: [CycleDay]
    @Query private var intimacyDays: [IntimacyEntry]

    @State private var editingMed: Medication? = nil
    @State private var showNewMed = false
    @State private var activeDetail: HealthDetail? = nil
    @State private var weightInput = ""
    @State private var chartDays = 30
    @State private var intimacyNoteInput = ""
    // 设置-健康页改单位/亲密卡开关后面板即时刷新（⚙ sheet 已退役，改 @AppStorage 订阅）
    @AppStorage(WeightUnit.storageKey) private var weightUnitRaw = ""
    @AppStorage(HealthLogStore.intimacyShowKey) private var intimacyShowFlag = false

    init(profileId: String) {
        self.profileId = profileId
        _meds = Query(
            filter: #Predicate<Medication> { $0.profileId == profileId && !$0.isArchived },
            sort: \Medication.createdAt
        )
        _weights = Query(
            filter: #Predicate<WeightEntry> { $0.profileId == profileId },
            sort: \WeightEntry.date, order: .reverse
        )
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Calendar.current.startOfDay(for: Date())) ?? Date.distantPast
        _recentLogs = Query(
            filter: #Predicate<MedicationLog> { $0.profileId == profileId && $0.takenAt >= cutoff },
            sort: \MedicationLog.takenAt, order: .reverse
        )
        _cycleDays = Query(
            filter: #Predicate<CycleDay> { $0.profileId == profileId },
            sort: \CycleDay.date, order: .reverse
        )
        _intimacyDays = Query(
            filter: #Predicate<IntimacyEntry> { $0.profileId == profileId },
            sort: \IntimacyEntry.date, order: .reverse
        )
    }

    private var unit: WeightUnit {
        _ = weightUnitRaw
        return WeightUnit.current
    }

    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "health" else { return }
        desktopNavigator?.pendingTarget = nil
        // 「<类别>:<uuid>」来自全局搜索，按类别开明细；小组件发的 weight 等旧值照旧，认不出的退回体重（S3-4）
        let category = target.id.split(separator: ":").first.map(String.init) ?? target.id
        let detail = HealthDetail(rawValue: category) ?? .weight
        if detail == .intimacy && !showIntimacy { return }
        activeDetail = detail
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PanelSectionList {
                medsSection
                cycleSection
                weightSection
                if showIntimacy { intimacySection }
                recentSection
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
        }
        .toolPageBackground()
        .onAppear { consumeDesktopTarget() }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .sheet(item: $editingMed) { med in
            MedEditorSheet(profileId: profileId, med: med)
        }
        .sheet(isPresented: $showNewMed) {
            MedEditorSheet(profileId: profileId, med: nil)
        }
        .sheet(item: $activeDetail) { detail in
            switch detail {
            case .meds: MedDetailSheet(profileId: profileId)
            case .cycle: CycleDetailSheet(profileId: profileId)
            case .weight: WeightDetailSheet(profileId: profileId)
            case .intimacy: IntimacyDetailSheet(profileId: profileId)
            }
        }
    }

    /// 整卡可点（plan-health-card-details §一）：header 带小 chevron 进详情，卡内交互控件优先不受影响。
    private func detailHeader(_ title: String, _ detail: HealthDetail) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.textMuted.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture { activeDetail = detail }
    }

    private var header: some View {
        HStack {
            Text("健康")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: 今天的药

    private var medsSection: some View {
        Section {
            if meds.isEmpty {
                Text("还没有药。加一种，到点会提醒你。")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(meds) { med in
                    ForEach(med.timesOfDay.sorted(), id: \.self) { minute in
                        medTimeRow(med: med, minute: minute)
                    }
                }
            }
            Button {
                showNewMed = true
            } label: {
                Label("添加药物", systemImage: "plus.circle")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        } header: {
            detailHeader("今天的药", .meds)
        } footer: {
            if MedReminderScheduler.shared.authorizationDenied {
                Text("通知权限未开启，提醒不会响。到 系统设置 › 通知 里打开。")
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private func medTimeRow(med: Medication, minute: Int) -> some View {
        let state = HealthLogStore.medState(medication: med, minuteOfDay: minute, todayLogs: todayLogs, now: Date())
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(med.name)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if !med.dosage.isEmpty {
                    Text(med.dosage)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer()
            Text(HealthLogStore.timeText(minute))
                .font(.system(size: Theme.F.secondary, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            stateButton(state: state, med: med, minute: minute)
        }
        .contentShape(Rectangle())
        .onTapGesture { editingMed = med }
    }

    @ViewBuilder
    private func stateButton(state: MedTimeState, med: Medication, minute: Int) -> some View {
        Button {
            switch state {
            case .taken:
                HealthLogStore.undoIntake(context: modelContext, todayLogs: todayLogs, medication: med, minuteOfDay: minute)
            case .pending, .missed:
                HealthLogStore.logIntake(context: modelContext, profileId: profileId, medication: med, minuteOfDay: minute)
            }
        } label: {
            switch state {
            case .taken:
                Label("已服", systemImage: "checkmark.circle.fill")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            case .pending:
                Label("打卡", systemImage: "circle")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
            case .missed:
                Label("漏服", systemImage: "exclamationmark.circle")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(healthRose)
            }
        }
        .buttonStyle(.plain)
    }

    private var todayLogs: [MedicationLog] {
        let dayStart = Calendar.current.startOfDay(for: Date())
        return recentLogs.filter { $0.takenAt >= dayStart }
    }

    // MARK: 月经（plan-health-cycle：吃药卡下、体重卡上）

    private var cyclePeriods: [CyclePeriod] {
        HealthCycleStore.periods(days: cycleDays)
    }

    private var todayCycleFlow: CycleFlow? {
        let today = Calendar.current.startOfDay(for: Date())
        return cycleDays.first { $0.date == today }.flatMap { CycleFlow(rawValue: $0.flow) }
    }

    private var cycleSection: some View {
        Section {
            Group {
                if cycleDays.isEmpty {
                    Text("记录第一天经期，这里会开始懂你的周期。")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                } else {
                    Text(HealthCycleStore.statusLine(todayFlow: todayCycleFlow, periods: cyclePeriods, now: Date()))
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { activeDetail = .cycle }
            flowPickerRow
        } header: {
            detailHeader("月经", .cycle)
        } footer: {
            Text("预测仅供参考，不作为避孕或医疗依据。")
        }
        .listRowBackground(Theme.mainBg)
    }

    private var flowPickerRow: some View {
        HStack(spacing: 8) {
            Text("今天")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            ForEach(CycleFlow.allCases, id: \.self) { flow in
                let isOn = todayCycleFlow == flow
                Button {
                    HealthCycleStore.toggleToday(context: modelContext, profileId: profileId, flow: flow)
                } label: {
                    Text(flow.label)
                        .font(.system(size: Theme.F.secondary, weight: isOn ? .semibold : .regular))
                        .foregroundColor(isOn ? .white : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(isOn ? healthRose : Theme.sidebarBg))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: 体重

    private var weightSection: some View {
        Section {
            if let latest = weights.first {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", unit.fromKg(latest.weightKg)))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                    Text(unit.label)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Picker("", selection: $chartDays) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
            if chartWeights.count >= 2 {
                weightChart
                    .contentShape(Rectangle())
                    .onTapGesture { activeDetail = .weight }
            }
            weightInputRow
        } header: {
            detailHeader("体重", .weight)
        }
        .listRowBackground(Theme.mainBg)
    }

    private var chartWeights: [WeightEntry] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -chartDays, to: Calendar.current.startOfDay(for: Date())) else { return [] }
        return weights.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    private var weightChart: some View {
        Chart(chartWeights, id: \.id) { entry in
            LineMark(x: .value("日期", entry.date), y: .value("体重", unit.fromKg(entry.weightKg)))
                .foregroundStyle(Theme.branchIndicator)
                .interpolationMethod(.monotone)
            PointMark(x: .value("日期", entry.date), y: .value("体重", unit.fromKg(entry.weightKg)))
                .foregroundStyle(Theme.branchIndicator)
                .symbolSize(18)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 110)
        .padding(.vertical, 4)
    }

    private var weightInputRow: some View {
        HStack(spacing: 8) {
            TextField("今天：\(unit == .kg ? "52.3" : "115.0")", text: $weightInput)
                .font(.system(size: Theme.F.body))
                .textFieldStyle(.plain)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text(unit.label)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            Button("记一笔") {
                saveWeightInput()
            }
            .font(.system(size: Theme.F.secondary, weight: .medium))
            .foregroundColor(parsedInput == nil ? Theme.textMuted : Theme.branchIndicator)
            .buttonStyle(.plain)
            .disabled(parsedInput == nil)
        }
    }

    private var parsedInput: Double? {
        let normalized = weightInput.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0, value < 1000 else { return nil }
        return value
    }

    private func saveWeightInput() {
        guard let value = parsedInput else { return }
        HealthLogStore.upsertWeight(context: modelContext, profileId: profileId, date: Date(), weightKg: unit.toKg(value))
        weightInput = ""
    }

    // MARK: 亲密（plan-health-intimacy：显示开关开才渲染；体重下、流水上）

    private var showIntimacy: Bool { intimacyShowFlag }

    private var todayIntimacy: IntimacyEntry? {
        let today = Calendar.current.startOfDay(for: Date())
        return intimacyDays.first { $0.date == today }
    }

    private var intimacySection: some View {
        Section {
            HStack(spacing: 8) {
                Text("今天")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button {
                    let recorded = HealthLogStore.toggleIntimacyToday(context: modelContext, profileId: profileId)
                    if recorded { intimacyNoteInput = "" }
                } label: {
                    Image(systemName: todayIntimacy == nil ? "heart" : "heart.fill")
                        .font(.system(size: 18))
                        .foregroundColor(todayIntimacy == nil ? Theme.textMuted : healthRose)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { activeDetail = .intimacy }
            if todayIntimacy != nil {
                TextField("备注（可选）", text: $intimacyNoteInput)
                    .font(.system(size: Theme.F.secondary))
                    .textFieldStyle(.plain)
                    .onAppear { intimacyNoteInput = todayIntimacy?.note ?? "" }
                    .onSubmit {
                        HealthLogStore.upsertIntimacy(
                            context: modelContext, profileId: profileId, date: Date(),
                            note: intimacyNoteInput.trimmingCharacters(in: .whitespaces)
                        )
                    }
            }
        } header: {
            detailHeader("亲密", .intimacy)
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: 最近流水（14 天，按日聚合只读；swipe 删当日体重）
    // 亲密记录不进流水（隐私拍板 plan-health-intimacy：只活在自己卡里+AI 注入）——别在这加 IntimacyEntry

    private struct DayFlow: Identifiable {
        let id: Date          // startOfDay
        let weight: WeightEntry?
        let medParts: [String]
    }

    private var dayFlows: [DayFlow] {
        let cal = Calendar.current
        let medName = Dictionary(uniqueKeysWithValues: meds.map { ($0.id, $0.name) })
        var days: [Date: (weight: WeightEntry?, meds: [String])] = [:]
        for w in weights.prefix(30) {
            days[w.date, default: (nil, [])].weight = w
        }
        for log in recentLogs {
            let day = cal.startOfDay(for: log.takenAt)
            days[day, default: (nil, [])].meds.append(medName[log.medicationId] ?? "药")
        }
        return days
            .map { DayFlow(id: $0.key, weight: $0.value.weight, medParts: Array(Set($0.value.meds)).sorted()) }
            .sorted { $0.id > $1.id }
            .prefix(14)
            .map { $0 }
    }

    private var recentSection: some View {
        Section("最近") {
            if dayFlows.isEmpty {
                Text("记录会出现在这里。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(dayFlows) { flow in
                    dayFlowRow(flow)
                }
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private func dayFlowRow(_ flow: DayFlow) -> some View {
        var parts: [String] = []
        if let w = flow.weight {
            parts.append("体重 \(String(format: "%.1f", unit.fromKg(w.weightKg)))")
        }
        if !flow.medParts.isEmpty {
            parts.append(flow.medParts.map { "\($0) ✓" }.joined(separator: " "))
        }
        let f = DateFormatter()
        f.dateFormat = "M-d"
        return HStack(spacing: 8) {
            Text(f.string(from: flow.id))
                .font(.system(size: Theme.F.caption, design: .monospaced))
                .foregroundColor(Theme.textMuted)
                .frame(width: 40, alignment: .leading)
            Text(parts.joined(separator: " · "))
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteWeightButton(flow.weight) }
        // S1-3：mac 上横扫只有触控板能做、鼠标够不着，右键补同一条
        #if os(macOS)
        .contextMenu { deleteWeightButton(flow.weight) }
        #endif
    }

    /// 删体重。横扫和右键共用同一份（S1-3）；没有体重记录时两边都不出这一项
    @ViewBuilder
    private func deleteWeightButton(_ weight: WeightEntry?) -> some View {
        if let w = weight {
            Button(role: .destructive) {
                HealthLogStore.deleteWeight(context: modelContext, entry: w)
            } label: {
                Text("删体重")
            }
        }
    }
}

// MARK: - 药物编辑 sheet（原生结构样板：CharacterCardEditor 同款）

private struct MedEditorSheet: View {
    let profileId: String
    let med: Medication?          // nil = 新建

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String
    @State private var dosage: String
    @State private var times: [Date]
    @State private var reminderEnabled: Bool

    init(profileId: String, med: Medication?) {
        self.profileId = profileId
        self.med = med
        _name = State(initialValue: med?.name ?? "")
        _dosage = State(initialValue: med?.dosage ?? "")
        _reminderEnabled = State(initialValue: med?.reminderEnabled ?? true)
        let minutes = med?.timesOfDay.sorted() ?? [8 * 60]
        _times = State(initialValue: minutes.map {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval($0 * 60))
        })
    }

    var body: some View {
        NavigationStack {
            PanelSectionList {
                Section("药物") {
                    HStack {
                        Text("名称")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("比如：维生素 D", text: $name)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("剂量")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("比如：1 片", text: $dosage)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .listRowBackground(Theme.mainBg)

                Section {
                    ForEach(times.indices, id: \.self) { i in
                        HStack {
                            DatePicker("时刻 \(i + 1)", selection: $times[i], displayedComponents: .hourAndMinute)
                                .font(.system(size: Theme.F.body))
                            if times.count > 1 {
                                Button {
                                    times.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundColor(Theme.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if times.count < 4 {
                        Button {
                            times.append(Calendar.current.startOfDay(for: Date()).addingTimeInterval(21 * 3600))
                        } label: {
                            Label("添加时刻", systemImage: "plus.circle")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.branchIndicator)
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle(isOn: $reminderEnabled) {
                        Text("到点提醒")
                            .font(.system(size: Theme.F.body))
                    }
                    .tint(Theme.branchIndicator)
                } header: {
                    Text("每天什么时候吃")
                } footer: {
                    Text("提醒是本地通知，锁屏会显示药名和剂量。")
                }
                .listRowBackground(Theme.mainBg)

                if med != nil {
                    Section {
                        Button {
                            archive()
                        } label: {
                            Text("停药归档")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        Text("归档后不再出现在今日列表、不再提醒，历史打卡记录保留。")
                    }
                    .listRowBackground(Theme.mainBg)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .toolPageBackground()
            .panelSheetTitle(med == nil ? "添加药物" : "编辑药物")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(canSave ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !times.isEmpty
    }

    private var minutesOfDay: [Int] {
        let cal = Calendar.current
        let minutes = times.map { cal.component(.hour, from: $0) * 60 + cal.component(.minute, from: $0) }
        return Array(Set(minutes)).sorted()
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if let med {
            med.name = trimmedName
            med.dosage = dosage.trimmingCharacters(in: .whitespaces)
            med.timesOfDay = minutesOfDay
            med.reminderEnabled = reminderEnabled
        } else {
            modelContext.insert(Medication(
                profileId: profileId,
                name: trimmedName,
                dosage: dosage.trimmingCharacters(in: .whitespaces),
                timesOfDay: minutesOfDay,
                reminderEnabled: reminderEnabled
            ))
        }
        try? modelContext.save()
        resyncReminders()
        dismiss()
    }

    private func archive() {
        med?.isArchived = true
        try? modelContext.save()
        resyncReminders()
        dismiss()
    }

    private func resyncReminders() {
        let container = modelContext.container
        Task { @MainActor in
            await MedReminderScheduler.shared.resyncFromStore(container: container, profileId: profileId)
        }
    }
}
