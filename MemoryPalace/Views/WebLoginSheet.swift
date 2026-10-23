import SwiftUI

/// 添加新登录入口 sheet：4-5 个常用站快捷按钮 + 自定义 URL 输入栏。
/// 选中后 push 到 MiniBrowserView，用户在里面登录。
/// 关 sheet 时不做特殊清理——cookie 会自动落 WKWebsiteDataStore.default()，下次 browse_url 同域自动用。
struct WebLoginSheet: View {
    var onDone: () -> Void

    @State private var customURL: String = ""

    struct QuickSite: Identifiable {
        let id = UUID()
        let name: String
        let urlStr: String
        var url: URL? { URL(string: urlStr) }
    }

    private let quickSites: [QuickSite] = [
        QuickSite(name: "知乎", urlStr: "https://www.zhihu.com/signin"),
        QuickSite(name: "豆瓣", urlStr: "https://accounts.douban.com/passport/login"),
        QuickSite(name: "微博", urlStr: "https://passport.weibo.com/sso/signin"),
        QuickSite(name: "小红书", urlStr: "https://www.xiaohongshu.com"),
        QuickSite(name: "X / Twitter", urlStr: "https://x.com/login"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(quickSites) { site in
                    if let url = site.url {
                        NavigationLink {
                            MiniBrowserView(initialURL: url)
                        } label: {
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundColor(Theme.branchIndicator)
                                Text(site.name)
                                    .font(.system(size: Theme.SettingsFont.body))
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }
                        .listRowBackground(Theme.mainBg)
                    }
                }
            } header: {
                Text("常用站点")
            } footer: {
                Text("点击站点 → 浏览器里完成登录 → 返回。cookie 自动留下供 AI 用。")
                    .font(.system(size: Theme.SettingsFont.caption))
            }

            Section {
                HStack(spacing: 8) {
                    TextField("https://...", text: $customURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.SettingsFont.body))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        #endif
                    if let url = normalizedURL(customURL) {
                        NavigationLink {
                            MiniBrowserView(initialURL: url)
                        } label: {
                            Text("打开")
                                .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                                .foregroundColor(Theme.branchIndicator)
                        }
                    } else {
                        Text("打开")
                            .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                    }
                }
                .listRowBackground(Theme.mainBg)
            } header: {
                Text("自定义站点")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("添加登录")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { onDone() }
            }
        }
    }

    /// 用户输入兼容性：补 https://，trim
    private func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.contains(".") else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }
}
