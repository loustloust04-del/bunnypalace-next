#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI
import SwiftData

/// 睡眠手动打卡 — 控制台睡眠卡点开进入（没有 Apple Watch 时手动记）。
/// 直接写今日 DailyContext.sleepStart/sleepEnd，保存后立刻上报网关（Caelum 会知道你睡得好不好）。
struct SleepSheet: View {
    let context: DailyContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var sleepStart: Date
    @State private var sleepEnd: Date
    @State private var startOn: Bool
    @State private var endOn: Bool

    init(context: DailyContext) {
        self.context = context
        let cal = Calendar.current
        let now = Date()
        let today0 = cal.startOfDay(for: now)
        let dEnd = cal.date(bySettingHour: 7, minute: 30, second: 0, of: today0) ?? now
        let dStart = cal.date(byAdding: .hour, value: -8, to: dEnd) ?? now
        _sleepStart = State(initialValue: context.sleepStart ?? dStart)
        _sleepEnd = State(initialValue: context.sleepEnd ?? dEnd)
        _startOn = State(initialValue: context.sleepStart != nil)
        _endOn = State(initialValue: context.sleepEnd != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    summaryCard
                    editCard
                    Button(role: .destructive) { clearAll() } label: {
                        Text("清除今日睡眠记录")
                            .font(.system(size: 13.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(ConsoleView.textSub)
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("睡眠")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundColor(ConsoleView.textSub)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }

    // MARK: - 摘要

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(durationHeadline)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(durationValid ? ConsoleView.greenDeep : ConsoleView.textFaint)
            if startOn || endOn {
                HStack {
                    Text("入睡").font(.system(size: 13)).foregroundColor(ConsoleView.textMuted)
                    Spacer()
                    Text(startOn ? timeText(sleepStart) : "未记").font(.system(size: 13, weight: .medium)).foregroundColor(ConsoleView.textSub)
                }
                HStack {
                    Text("起床").font(.system(size: 13)).foregroundColor(ConsoleView.textMuted)
                    Spacer()
                    Text(endOn ? timeText(sleepEnd) : "未记").font(.system(size: 13, weight: .medium)).foregroundColor(ConsoleView.textSub)
                }
            } else {
                Text("还没记录今天的睡眠，下面填一下吧")
                    .font(.system(size: 13)).foregroundColor(ConsoleView.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    // MARK: - 编辑

    private var editCard: some View {
        VStack(spacing: 16) {
            timeRow(title: "入睡时间", icon: "bed.double.fill", on: $startOn, date: $sleepStart)
            Divider().background(ConsoleView.line)
            timeRow(title: "起床时间", icon: "sun.max.fill", on: $endOn, date: $sleepEnd)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func timeRow(title: String, icon: String, on: Binding<Bool>, date: Binding<Date>) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(ConsoleView.green).frame(width: 20)
                Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(ConsoleView.textPrimary)
                Spacer()
                Toggle("", isOn: on).labelsHidden().tint(ConsoleView.greenDeep)
            }
            if on.wrappedValue {
                HStack {
                    DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Spacer()
                    Button {
                        date.wrappedValue = Date()
                    } label: {
                        Text("现在").font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(ConsoleView.sink))
                            .foregroundColor(ConsoleView.greenDeep)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 计算 / 保存

    private var durationValid: Bool {
        startOn && endOn && sleepEnd.timeIntervalSince(sleepStart) > 0
    }
    private var durationHeadline: String {
        guard startOn && endOn else { return "—" }
        let secs = sleepEnd.timeIntervalSince(sleepStart)
        guard secs > 0 else { return "起床要晚于入睡" }
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return m > 0 ? "共睡 \(h) 小时 \(m) 分" : "共睡 \(h) 小时"
    }
    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    private func save() {
        context.sleepStart = startOn ? sleepStart : nil
        context.sleepEnd = endOn ? sleepEnd : nil
        try? modelContext.save()
        let ctx = context
        Task { await HealthBridgeClient.report(from: ctx, force: true) }
        dismiss()
    }

    private func clearAll() {
        context.sleepStart = nil
        context.sleepEnd = nil
        try? modelContext.save()
        startOn = false
        endOn = false
    }
}
#endif
