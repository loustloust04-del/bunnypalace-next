import SwiftUI
import WebKit

/// 网页登录态管理页：列出 default datastore 里所有 cookie 按 domain 聚合，
/// 让粟粟看到 AI 能用哪些站的登录态、能撤销某站登录。
/// 顶部"添加新登录"按钮弹 WebLoginSheet 让用户主动登一个新站。
struct WebLoginStatusPage: View {
    @State private var groups: [DomainGroup] = []
    @State private var loading = true
    @State private var showLoginSheet = false

    struct DomainGroup: Identifiable {
        let domain: String
        let cookieCount: Int
        let earliestExpire: Date?
        var id: String { domain }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showLoginSheet = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.branchIndicator)
                        Text("添加新登录")
                            .font(.system(size: Theme.SettingsFont.body))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .listRowBackground(Theme.mainBg)
            } footer: {
                Text("在内置浏览器里登录站点后，关闭浏览器，AI 调 browse_url 同域时会自动带上登录态——能读到付费/私域内容。仅 MP 内有效，不影响 Safari。")
                    .font(.system(size: Theme.SettingsFont.caption))
            }

            Section {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("读取中…").foregroundColor(Theme.textMuted) }
                        .listRowBackground(Theme.mainBg)
                } else if groups.isEmpty {
                    Text("还没有登录过任何站点")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                        .listRowBackground(Theme.mainBg)
                } else {
                    ForEach(groups) { g in
                        row(g)
                            .listRowBackground(Theme.mainBg)
                    }
                }
            } header: {
                Text("已登录站点")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("网页登录态")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await reload() }
        .sheet(isPresented: $showLoginSheet, onDismiss: { Task { await reload() } }) {
            NavigationStack {
                WebLoginSheet { showLoginSheet = false }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 560)
            #endif
        }
    }

    @ViewBuilder
    private func row(_ g: DomainGroup) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(g.domain)
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(Theme.textPrimary)
                let expireText: String = {
                    guard let d = g.earliestExpire else { return "\(g.cookieCount) 条 cookie" }
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    return "\(g.cookieCount) 条 cookie · 最早 \(formatter.string(from: d)) 过期"
                }()
                Text(expireText)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer()
            Button {
                Task { await revoke(domain: g.domain) }
            } label: {
                Text("撤销登录")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - data

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        var byDomain: [String: (count: Int, earliest: Date?)] = [:]
        for c in all {
            // 去 leading dot
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            let prev = byDomain[d] ?? (0, nil)
            let earliest: Date? = {
                guard let exp = c.expiresDate else { return prev.earliest }
                guard let p = prev.earliest else { return exp }
                return exp < p ? exp : p
            }()
            byDomain[d] = (prev.count + 1, earliest)
        }
        groups = byDomain.map { DomainGroup(domain: $0.key, cookieCount: $0.value.count, earliestExpire: $0.value.earliest) }
            .sorted { $0.domain < $1.domain }
    }

    @MainActor
    private func revoke(domain: String) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        // 删该 domain 所有 cookie + localStorage / indexedDB 等持久数据
        for c in all {
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            if d == domain || d.hasSuffix("." + domain) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    store.delete(c) { cont.resume() }
                }
            }
        }
        let types: Set<String> = [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeWebSQLDatabases,
        ]
        let records = await WKWebsiteDataStore.default().dataRecords(ofTypes: types)
        let matched = records.filter { $0.displayName == domain || $0.displayName.hasSuffix("." + domain) }
        if !matched.isEmpty {
            await WKWebsiteDataStore.default().removeData(ofTypes: types, for: matched)
        }
        await reload()
    }
}
