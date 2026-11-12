#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI

/// 屏幕时间 · 分 App 二级界面（控制台屏幕卡点开）。
/// 数据来自网关 /api/screentime（app_open 事件聚合，无需 FamilyControls 授权）。
/// 逐 App 用时排行条 + 今日总时长/社交时长。
struct ScreenTimeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var data: ScreenTimeResponse?
    @State private var loading = true

    init(initial: ScreenTimeResponse? = nil) {
        _data = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    if loading && data == nil {
                        ProgressView().padding(.vertical, 50)
                    } else if let d = data, !d.apps.isEmpty {
                        summaryCard(d)
                        appsCard(d)
                    } else {
                        Text("今日还没有屏幕使用数据\n（数据由 App 切换事件聚合而来）")
                            .font(.system(size: 13.5))
                            .foregroundColor(ConsoleView.textFaint)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 60)
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("屏幕时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
        .task {
            if let d = await ScreenTimeClient.fetch() { data = d }
            loading = false
        }
    }

    private func summaryCard(_ d: ScreenTimeResponse) -> some View {
        HStack(spacing: 0) {
            summaryCell("总时长", d.total_minutes, ConsoleView.greenDeep)
            Rectangle().fill(ConsoleView.line).frame(width: 1).padding(.vertical, 4)
            summaryCell("社交", d.social_minutes, ConsoleView.gold)
            Rectangle().fill(ConsoleView.line).frame(width: 1).padding(.vertical, 4)
            VStack(spacing: 3) {
                Text("\(d.apps.count)").font(.system(size: 25, weight: .semibold)).foregroundColor(ConsoleView.textPrimary)
                Text("个 App").font(.system(size: 10.5)).foregroundColor(ConsoleView.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func summaryCell(_ label: String, _ minutes: Double, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(hoursText(minutes)).font(.system(size: 25, weight: .semibold)).foregroundColor(color)
            Text(label).font(.system(size: 10.5)).foregroundColor(ConsoleView.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func appsCard(_ d: ScreenTimeResponse) -> some View {
        let maxMin = d.apps.map { $0.minutes }.max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            Text("分 App 用时")
                .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            ForEach(d.apps, id: \.app) { app in
                VStack(spacing: 5) {
                    HStack {
                        Text(app.app).font(.system(size: 14, weight: .medium)).foregroundColor(ConsoleView.textPrimary)
                        Spacer()
                        Text(durationText(app.minutes)).font(.system(size: 13, weight: .medium)).foregroundColor(ConsoleView.textSub)
                        Text("· \(app.sessions) 次").font(.system(size: 10.5)).foregroundColor(ConsoleView.textFaint)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ConsoleView.sink)
                            Capsule().fill(ConsoleView.green)
                                .frame(width: max(3, g.size.width * CGFloat(app.minutes / max(maxMin, 1))))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    // MARK: - helpers

    private func hoursText(_ minutes: Double) -> String {
        let h = minutes / 60.0
        return h >= 1 ? String(format: "%.1f", h) + "h" : "\(Int(minutes.rounded()))分"
    }
    private func durationText(_ minutes: Double) -> String {
        if minutes >= 60 {
            let h = Int(minutes) / 60, m = Int(minutes) % 60
            return m > 0 ? "\(h)h\(m)" : "\(h)h"
        }
        return "\(Int(minutes.rounded()))分"
    }
}
#endif
