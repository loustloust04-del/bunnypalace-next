import SwiftUI

struct UsageReconciliationSection: View {
    let records: [UsageRecord]
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @State private var expanded = false
    @State private var provider: BillingProvider = .openRouter
    @State private var credentialId = ""
    @State private var adminKey = ""
    @State private var report: BillingReport?
    @State private var reportDate = Date()
    @State private var status = ""
    @State private var loading = false
    @State private var generation = 0
    @State private var selectedKeyIdentity: String?

    private var routerCards: [APICredential] {
        providerManager?.credentials.filter { $0.type == .openaiCompatible && APIUsageParser.isOpenRouter($0.baseURL) } ?? []
    }

    private var billingScope: BillingScope {
        let since = BillingReconciliation.calendar.date(byAdding: .day, value: -6,
            to: BillingReconciliation.calendar.startOfDay(for: reportDate))!
        if provider == .openRouter {
            guard let identity = selectedKeyIdentity else { return BillingScope(records: [], verified: false) }
            return BillingScope.openRouter(records: records, identity: identity, since: since)
        }
        let host = provider == .anthropic ? "api.anthropic.com" : "api.openai.com"
        let ids = Set((providerManager?.credentials ?? []).filter {
            URL(string: $0.baseURL)?.host?.lowercased() == host
                && $0.type == (provider == .anthropic ? .anthropic : .openaiCompatible)
        }.map(\.id))
        return BillingScope(records: records.filter { ids.contains($0.providerId) }, verified: false)
    }

    var body: some View {
        Section {
            DisclosureGroup("对账", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("供应商", selection: $provider) {
                        ForEach(BillingProvider.allCases) { Text($0.label).tag($0) }
                    }
                    if provider == .openRouter {
                        Picker("聊天卡片", selection: $credentialId) {
                            Text("选择卡片").tag("")
                            ForEach(routerCards) { Text($0.name).tag($0.id) }
                        }
                        if routerCards.isEmpty {
                            Text("先在 API 设置添加 OpenRouter 卡片")
                                .font(m.caption).foregroundColor(Theme.textMuted)
                        }
                    } else {
                        SecureField("Admin key（独立存入钥匙串）", text: $adminKey)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("保存 Admin key") {
                                let saved = BillingAdminKeys.set(adminKey, provider: provider)
                                status = saved ? "已保存到钥匙串" : "钥匙串保存失败"
                                if saved { adminKey = "" }
                            }
                            .disabled(adminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("删除 Admin key") {
                                status = BillingAdminKeys.set("", provider: provider) ? "已删除 Admin key" : "删除失败"
                                adminKey = ""
                                report = nil
                            }
                        }
                        Text("本机账本按当前直连卡片汇总；组织报表可能包含其他应用 / 项目的费用。已删除卡片无法确认所属组织。")
                            .font(m.caption).foregroundColor(Theme.textMuted)
                    }
                    HStack {
                        Button(loading ? "读取中…" : "读取最近 7 天") { Task { await refresh() } }
                            .buttonStyle(.bordered).disabled(loading)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    if !status.isEmpty { Text(status).font(m.caption).foregroundColor(Theme.textSecondary) }
                    if let report {
                        if !billingScope.verified || !report.scopeVerified {
                            Text("范围不一致，不判定差额")
                                .font(m.caption).foregroundColor(Theme.textSecondary)
                        }
                        dayTable(report)
                        if let note = report.note { Text(note).font(m.caption).foregroundColor(Theme.textMuted) }
                        Text("只读核对，不修改账本；金额单位 USD。当天数据可能尚未结算。")
                            .font(m.caption).foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.vertical, 6)
            }
            .searchAnchor("leaf-usage-reconciliation")
        }
        .listRowBackground(Theme.mainBg)
        .onChange(of: provider) { _, _ in resetReport() }
        .onChange(of: credentialId) { _, _ in resetReport() }
    }

    private func dayTable(_ report: BillingReport) -> some View {
        var scopedReport = report
        scopedReport.scopeVerified = report.scopeVerified && billingScope.verified
        return VStack(spacing: 7) {
            HStack {
                Text("日期 UTC").frame(maxWidth: .infinity, alignment: .leading)
                Text("账本").frame(maxWidth: .infinity, alignment: .trailing)
                Text("供应商").frame(maxWidth: .infinity, alignment: .trailing)
                Text("差额 %").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .foregroundColor(Theme.textMuted)
            ForEach(BillingReconciliation.days(now: reportDate, records: billingScope.records, report: scopedReport)) { day in
                HStack {
                    Text(dayLabel(day.date))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.4f", day.ledgerUSD)).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(day.supplierUSD.map { String(format: "%.4f", $0) } ?? "未提供")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(day.differencePercent.map { $0.isFinite ? String(format: "%+.2f%%", $0) : "∞" } ?? "—")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .foregroundColor(day.mismatched ? .red : Theme.textSecondary)
            }
        }
        .font(m.caption).monospacedDigit()
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func resetReport() {
        generation += 1
        report = nil
        status = ""
        adminKey = ""
        selectedKeyIdentity = nil
        loading = false
    }

    @MainActor private func refresh() async {
        let key: String?
        if provider == .openRouter { key = providerManager?.apiKey(for: credentialId) }
        else { key = BillingAdminKeys.get(provider) }
        guard let key, !key.isEmpty else { status = provider == .openRouter ? "请选择已有聊天 key 的卡片" : "请先保存 Admin key"; return }
        generation += 1
        let current = generation
        let selected = provider
        let now = Date()
        selectedKeyIdentity = selected == .openRouter ? BillingKeyIdentity.hash(key, host: "openrouter.ai") : nil
        loading = true
        status = ""
        do {
            let loaded = try await BillingReconciliation().load(provider: selected, key: key, now: now)
            guard current == generation else { return }
            report = loaded
            reportDate = loaded.reportDate ?? now
        } catch {
            guard current == generation else { return }
            status = "账单读取失败，请检查 key 权限或网络（\(error.localizedDescription)）"
        }
        if current == generation { loading = false }
    }
}
