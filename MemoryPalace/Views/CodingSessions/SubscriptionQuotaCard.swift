#if os(macOS)
import SwiftUI

/// 订阅额度卡（research-magpie §2.2）：每家一行——名字 + 套餐，两条进度条（Claude 5 小时 / 7 天；Codex primary / secondary）
/// 各带「x 小时后重置」。可独立嵌入（用量页插槽、菜单栏快看）；数据来自 `SubscriptionQuotaStore`，出现时先给缓存、后台再刷，
/// 显示期间每分钟刷一次（服务自己有 1 分钟缓存，不会多打接口）
struct SubscriptionQuotaCard: View {
    var store: SubscriptionQuotaStore = .shared
    /// 紧凑版（菜单栏）：去掉外框和标题
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            if !compact {
                HStack {
                    Text("订阅额度")
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    if store.isLoading { ProgressView().controlSize(.small) }
                }
            }
            if store.quotas.isEmpty {
                Text(store.loaded ? "没找到已登录的 Claude Code / Codex" : "正在读取额度…")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(store.quotas) { quota in
                    SubscriptionQuotaRow(quota: quota)
                }
            }
        }
        .padding(compact ? 0 : 14)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 10).fill(Theme.textPrimary.opacity(0.04))
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
}

/// 一家的一行
struct SubscriptionQuotaRow: View {
    let quota: SubscriptionQuota

    private var agent: CodingAgent { quota.provider == .claude ? .claudeCode : .codex }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(CodingSessionFormat.color(agent)).frame(width: 7, height: 7)
                    Text(quota.title)
                        .font(.system(size: Theme.F.caption, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if let plan = quota.plan {
                        Text(plan)
                            .font(.system(size: Theme.F.caption - 1))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 5)
                            .overlay(Capsule().stroke(Theme.textMuted.opacity(0.5), lineWidth: 0.6))
                    }
                    Spacer(minLength: 0)
                }
                ForEach(Array(quota.primaryWindows.enumerated()), id: \.offset) { _, window in
                    QuotaBar(window: window, now: context.date, dimmed: quota.status != .ok)
                }
                if let status = quota.statusText {
                    Text(quota.windows.isEmpty ? status : "\(status)（显示的是上次的数据）")
                        .font(.system(size: Theme.F.caption - 1))
                        .foregroundColor(quota.status == .needsLogin ? .orange : Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 一条进度条：标签 · 条 · 百分比，下面一行重置时间
struct QuotaBar: View {
    let window: QuotaWindow
    let now: Date
    var dimmed = false

    private var fraction: Double { min(max(window.usedPercent / 100, 0), 1) }

    private var tint: Color {
        if window.usedPercent >= 95 { return .red }
        if window.usedPercent >= 80 { return .orange }
        return Theme.branchIndicator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(window.label)
                    .font(.system(size: Theme.F.caption - 1))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 72, alignment: .leading)
                    .lineLimit(1)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.textPrimary.opacity(0.08))
                        Capsule().fill(tint.opacity(dimmed ? 0.45 : 1))
                            .frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * fraction))
                    }
                }
                .frame(height: 5)
                Text(SubscriptionQuotaParser.percentText(window.usedPercent))
                    .font(.system(size: Theme.F.caption - 1, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 36, alignment: .trailing)
            }
            if let reset = SubscriptionQuotaParser.resetText(window.resetsAt, now: now) {
                Text(reset)
                    .font(.system(size: Theme.F.caption - 2))
                    .foregroundColor(Theme.textMuted)
                    .padding(.leading, 80)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
