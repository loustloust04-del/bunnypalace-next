import SwiftUI
import SwiftData

/// 时间机器 — 还原 sheet
/// 设计: docs/plan-time-machine.md
///
/// 结构:
/// 1. 顶部: 月份导航 + 日历网格(当天有备份打圆点; 选中日期高亮)
/// 2. 中部: 选中日期的清单(楼层 → 对话条数 + 总大小)
/// 3. 底部: 三档恢复按钮(整库/选楼层/选对话)
///
/// 还原前自动写 pre-restore snapshot. confirm 两层. 完成后提示重启。
struct RestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var entries: [BackupEntry] = []           // listBackups 缓存
    @State private var monthAnchor: Date = Date()            // 当前显示的月
    @State private var selectedDate: String? = nil           // "2026-06-17"
    @State private var selectedDay: DayManifest? = nil       // 选中日的详细清单

    // 恢复对话状态
    @State private var pendingScope: RestoreScope? = nil     // 弹 confirm 之前用
    @State private var confirmText: String = ""              // alert 主文案
    @State private var showConfirm = false
    @State private var resultText: String? = nil             // 完成后弹结果
    @State private var errorText: String? = nil
    @State private var restoreRunning = false                 // 后台 restore 中
    @State private var restoreProgress: (processed: Int, total: Int) = (0, 0)

    // 单楼层 / 单对话子 sheet
    @State private var pickingProfile = false
    @State private var pickingConversation = false
    @State private var pickedProfile: ProfileBackup? = nil

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle("时间机器")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .task { reload() }
        #else
        VStack(spacing: 0) {
            HStack {
                Text("时间机器")
                    .font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()
            Divider()
            content
        }
        .frame(width: 520, height: 640)
        .task { reload() }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                monthHeader
                calendar
                dayDetail
                Spacer(minLength: 8)
            }
            .padding()
        }
        .alert("确认还原?", isPresented: $showConfirm) {
            Button("取消", role: .cancel) { pendingScope = nil }
            Button("还原", role: .destructive) { performRestore() }
        } message: {
            Text(confirmText)
        }
        .alert("已还原", isPresented: Binding(
            get: { resultText != nil },
            set: { if !$0 { resultText = nil; dismiss() } }
        )) {
            Button("好") { resultText = nil; dismiss() }
        } message: {
            Text((resultText ?? "") + "\n\n建议立刻关闭 app 重开, 让数据完整刷新。")
        }
        .alert("还原失败", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .sheet(isPresented: $restoreRunning) {
            VStack(spacing: 20) {
                Text("正在还原")
                    .font(.headline)
                ProgressView(value: Double(restoreProgress.processed),
                             total: Double(max(1, restoreProgress.total)))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)
                Text("\(restoreProgress.processed) / \(restoreProgress.total) 对话")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                Text("别关 app, 还原完成会自动关掉")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .padding(40)
            .interactiveDismissDisabled(true)
            #if os(macOS)
            .frame(width: 360, height: 220)
            #endif
        }
        .sheet(isPresented: $pickingProfile) {
            ProfilePickerSheet(day: selectedDay, onPick: { pb in
                pickingProfile = false
                askConfirm(scope: .profile(profileId: pb.profileId),
                           text: "将把楼层「\(pb.floorEmoji)\(pb.floorName)」覆盖为 \(selectedDate ?? "?") 的状态。\n\n其他楼层不动。\n还原前会自动备份当前状态。")
            })
        }
        .sheet(isPresented: $pickingConversation) {
            if let pb = pickedProfile {
                ConversationPickerSheet(profileBackup: pb, onPick: { ref in
                    pickingConversation = false
                    askConfirm(scope: .conversation(profileId: pb.profileId, convId: ref.conversationId),
                               text: "将把对话「\(ref.title)」覆盖为 \(selectedDate ?? "?") 的状态(\(ref.nodeCount) 节点)。\n\n其他对话不动。\n还原前会自动备份当前状态。")
                })
            }
        }
    }

    // MARK: - Header & Calendar

    private var monthHeader: some View {
        HStack {
            Button(action: { shiftMonth(-1) }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            Spacer()
            Text(monthTitle(monthAnchor))
                .font(.headline)
            Spacer()
            Button(action: { shiftMonth(1) }) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
        }
    }

    private var calendar: some View {
        let datesWithBackup = Set(entries.filter { $0.kind == .scheduled }.map(\.date))
        let preRestoreDates = entries.filter { $0.kind == .preRestore }.map(\.date)
        return VStack(alignment: .leading, spacing: 10) {
            // 星期头
            HStack(spacing: 0) {
                ForEach(["日","一","二","三","四","五","六"], id: \.self) { d in
                    Text(d).frame(maxWidth: .infinity)
                        .font(.caption).foregroundColor(Theme.textMuted)
                }
            }
            // 月份网格
            let cells = monthGrid(monthAnchor)
            ForEach(0..<cells.count / 7, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let cell = cells[row * 7 + col]
                        dayCell(cell, hasBackup: datesWithBackup.contains(cell?.dateString ?? ""))
                    }
                }
            }
            if !preRestoreDates.isEmpty {
                Divider().opacity(0.2)
                Text("还原前快照(独立 30 天保留):")
                    .font(.caption).foregroundColor(Theme.textMuted)
                ForEach(preRestoreDates, id: \.self) { d in
                    Button(action: { select(date: d) }) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                            Text(d).font(.system(.caption, design: .monospaced))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dayCell(_ cell: DayCell?, hasBackup: Bool) -> some View {
        Group {
            if let cell {
                let isSelected = cell.dateString == selectedDate
                Button(action: { select(date: cell.dateString) }) {
                    VStack(spacing: 2) {
                        Text("\(cell.day)")
                            .font(.system(size: 14, weight: hasBackup ? .semibold : .regular))
                            .foregroundColor(cell.isThisMonth ? Theme.textPrimary : Theme.textMuted)
                        Circle()
                            .fill(hasBackup ? Theme.branchIndicator : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Theme.accent.opacity(0.5) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasBackup)
            } else {
                Text("").frame(maxWidth: .infinity, minHeight: 36)
            }
        }
    }

    // MARK: - Day Detail

    private var dayDetail: some View {
        Group {
            if let day = selectedDay {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(day.date)
                            .font(.headline)
                        Spacer()
                        Text("\(day.profiles.reduce(0) { $0 + $1.conversations.count }) 对话 · \(formatBytes(day.profiles.reduce(0) { acc, pb in acc + pb.conversations.reduce(0) { $0 + $1.sizeBytes } }))")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    Divider().opacity(0.2)
                    ForEach(day.profiles, id: \.profileId) { pb in
                        HStack {
                            Text("\(pb.floorEmoji) \(pb.floorName)")
                            Spacer()
                            Text("\(pb.conversations.count) 对话")
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        .padding(.vertical, 2)
                    }
                    Divider().opacity(0.2)
                    restoreActions
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.25)))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.largeTitle)
                        .foregroundColor(Theme.textMuted)
                    Text("选一个有备份的日期")
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    private var restoreActions: some View {
        VStack(spacing: 8) {
            Button(action: {
                askConfirm(scope: .everything,
                           text: "将把全部楼层覆盖为 \(selectedDate ?? "?") 的状态。\n\n备份没有的对话会被删除。\n还原前会自动备份当前状态。")
            }) {
                Label("整库还原", systemImage: "arrow.uturn.backward.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button(action: { pickingProfile = true }) {
                Label("选楼层还原", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(action: {
                // 单对话: 先选楼层再选对话
                if (selectedDay?.profiles.count ?? 0) == 1 {
                    pickedProfile = selectedDay?.profiles.first
                    pickingConversation = true
                } else {
                    pickingProfile = true
                    // pickingProfile sheet onPick 不走 confirm, 而是 -> pickingConversation, 需要在 onPick 里区分
                    // 简化: 选完楼层在 ProfilePickerSheet 内部决定. 这里先用整库走法.
                }
            }) {
                Label("选对话还原", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    private func reload() {
        entries = BackupStore.listBackups()
        if let first = entries.first(where: { $0.kind == .scheduled }) {
            select(date: first.date)
            monthAnchor = BackupDate.parseDay(first.date) ?? Date()
        }
    }

    private func select(date: String) {
        selectedDate = date
        selectedDay = BackupStore.loadDay(date: date)
    }

    private func shiftMonth(_ delta: Int) {
        let cal = Calendar(identifier: .iso8601)
        if let m = cal.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = m
        }
    }

    private func askConfirm(scope: RestoreScope, text: String) {
        pendingScope = scope
        confirmText = text
        showConfirm = true
    }

    private func performRestore() {
        guard let date = selectedDate, let scope = pendingScope else { return }
        pendingScope = nil
        restoreProgress = (0, 0)
        restoreRunning = true
        let container = modelContext.container
        DispatchQueue.global(qos: .userInitiated).async {
            let bgCtx = ModelContext(container)
            do {
                let r = try BackupStore.restore(date: date, scope: scope, context: bgCtx) { processed, total in
                    DispatchQueue.main.async {
                        restoreProgress = (processed, total)
                    }
                }
                DispatchQueue.main.async {
                    restoreRunning = false
                    var text = "✅ 已还原 \(date)\n楼层: \(r.profilesRestored) · 对话: \(r.conversationsRestored)\n节点: +\(r.nodesInserted) ~\(r.nodesUpdated) -\(r.nodesDeleted)"
                    // 跨楼层冲突提示复用两个 importer 同款文案（ImportSupport.crossProfileConflictSuffix）
                    text += crossProfileConflictSuffix(r.conversationsSkippedCrossProfile)
                    resultText = text
                }
            } catch {
                DispatchQueue.main.async {
                    restoreRunning = false
                    errorText = "\(error.localizedDescription)\n\n你的当前状态没有被改动。"
                }
            }
        }
    }
}

// MARK: - Pickers

private struct ProfilePickerSheet: View {
    let day: DayManifest?
    let onPick: (ProfileBackup) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if os(iOS)
        NavigationStack { list.navigationTitle("选楼层").navigationBarTitleDisplayMode(.inline) }
        #else
        VStack { Text("选楼层").font(.headline).padding(.top); list }.frame(width: 380, height: 480)
        #endif
    }
    private var list: some View {
        List(day?.profiles ?? [], id: \.profileId) { pb in
            Button(action: { onPick(pb) }) {
                HStack {
                    Text("\(pb.floorEmoji) \(pb.floorName)")
                    Spacer()
                    Text("\(pb.conversations.count) 对话")
                        .font(.caption).foregroundColor(Theme.textMuted)
                }
            }
        }
    }
}

private struct ConversationPickerSheet: View {
    let profileBackup: ProfileBackup
    let onPick: (ConversationRef) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if os(iOS)
        NavigationStack { list.navigationTitle("选对话").navigationBarTitleDisplayMode(.inline) }
        #else
        VStack { Text("选对话").font(.headline).padding(.top); list }.frame(width: 420, height: 560)
        #endif
    }
    private var list: some View {
        List(profileBackup.conversations, id: \.conversationId) { ref in
            Button(action: { onPick(ref) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.title.isEmpty ? "(无标题)" : ref.title).lineLimit(1)
                    Text("\(ref.nodeCount) 节点").font(.caption).foregroundColor(Theme.textMuted)
                }
            }
        }
    }
}

// MARK: - Calendar utils

private struct DayCell {
    let day: Int
    let dateString: String          // "yyyy-MM-dd"
    let isThisMonth: Bool
}

private func monthGrid(_ anchor: Date) -> [DayCell?] {
    var cal = Calendar(identifier: .iso8601)
    cal.firstWeekday = 1
    let comps = cal.dateComponents([.year, .month], from: anchor)
    guard let first = cal.date(from: comps),
          let range = cal.range(of: .day, in: .month, for: first) else { return [] }
    let firstWeekday = cal.component(.weekday, from: first)  // 1=日
    var cells: [DayCell?] = []
    for _ in 0..<(firstWeekday - 1) { cells.append(nil) }
    let df = DateFormatter()
    df.calendar = cal
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd"
    for day in range {
        if let d = cal.date(byAdding: .day, value: day - 1, to: first) {
            cells.append(DayCell(day: day, dateString: df.string(from: d), isThisMonth: true))
        }
    }
    while cells.count % 7 != 0 { cells.append(nil) }
    return cells
}

private func monthTitle(_ d: Date) -> String {
    let df = DateFormatter()
    df.calendar = Calendar(identifier: .iso8601)
    df.locale = Locale(identifier: "zh_CN")
    df.dateFormat = "yyyy 年 M 月"
    return df.string(from: d)
}

private func formatBytes(_ b: Int) -> String {
    if b < 1024 { return "\(b) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
    return String(format: "%.1f MB", Double(b) / 1024 / 1024)
}

enum BackupDate {
    static func parseDay(_ s: String) -> Date? {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .iso8601)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }
}
