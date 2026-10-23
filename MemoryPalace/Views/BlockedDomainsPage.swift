import SwiftUI

/// 黑名单管理页：AI 通过 browse_url 永远不读这些域。
/// 后缀子域匹配——加 `example.com` 拦 `*.example.com`，但不拦 `notexample.com`。
struct BlockedDomainsPage: View {
    @StateObject private var settings = WebSearchSettings.shared
    @State private var addingDomain: String = ""
    @State private var showAddAlert = false

    var body: some View {
        List {
            Section {
                Button {
                    settings.importRecommendedBlocklist()
                } label: {
                    HStack {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundColor(Theme.branchIndicator)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("导入推荐黑名单")
                                .font(.system(size: Theme.SettingsFont.body))
                                .foregroundColor(Theme.textPrimary)
                            Text("支付/银行/邮箱 9 个常见敏感域")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)

                Button {
                    addingDomain = ""
                    showAddAlert = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.branchIndicator)
                        Text("添加域名")
                            .font(.system(size: Theme.SettingsFont.body))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
            } footer: {
                Text("匹配规则：后缀子域。加 example.com 会拦截 example.com 和 *.example.com，但不会拦 notexample.com。AI 调 browse_url 命中黑名单时直接报错。")
                    .font(.system(size: Theme.SettingsFont.caption))
            }

            Section {
                if settings.blockedDomains.isEmpty {
                    Text("黑名单为空")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                        .listRowBackground(Theme.mainBg)
                } else {
                    ForEach(settings.blockedDomains, id: \.self) { d in
                        Text(d)
                            .font(.system(size: Theme.SettingsFont.body))
                            .foregroundColor(Theme.textPrimary)
                            .listRowBackground(Theme.mainBg)
                    }
                    .onDelete { idx in
                        let names = idx.map { settings.blockedDomains[$0] }
                        for n in names { settings.removeBlocked(n) }
                    }
                }
            } header: {
                Text("当前黑名单（\(settings.blockedDomains.count)）")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("黑名单（AI 不读）")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("添加黑名单域名", isPresented: $showAddAlert) {
            TextField("如 example.com", text: $addingDomain)
                #if os(iOS)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                #endif
            Button("取消", role: .cancel) {}
            Button("添加") {
                let d = addingDomain.trimmingCharacters(in: .whitespaces)
                if !d.isEmpty { settings.addBlocked(d) }
            }
        } message: {
            Text("不要带 http(s):// 和路径；只填域名")
                .font(.system(size: Theme.SettingsFont.caption))
        }
    }
}
