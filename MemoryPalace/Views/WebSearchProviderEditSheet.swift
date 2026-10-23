import SwiftUI

/// 每家 backend 的字段编辑表单——动态按 kind 渲染。
/// 通用：name + apiKey（如果 kind.needsKey）；其他字段按 kind 派发。
struct WebSearchProviderEditSheet: View {
    let initial: WebSearchServiceOptions
    var onSave: (WebSearchServiceOptions) -> Void

    @Environment(\.dismiss) private var dismiss

    // 通用
    @State private var name: String = ""
    @State private var apiKey: String = ""

    // 各家特殊字段（按 kind 用）
    @State private var acceptLanguage: String = "zh-CN,zh;q=0.9,en;q=0.8"
    @State private var region: String = "wt-wt"
    @State private var customURL: String = ""
    @State private var fetchFullText: Bool = true
    @State private var country: String = ""
    @State private var allowedDomainsText: String = ""
    @State private var maxTokensPerPage: Int = 0
    @State private var depth: String = "standard"
    @State private var freshness: String = "noLimit"
    @State private var summary: Bool = true
    @State private var includeDomains: String = ""
    @State private var excludeDomains: String = ""
    @State private var engines: String = ""
    @State private var language: String = ""
    @State private var username: String = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("类型")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(initial.kind.displayName)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                TextField("自定义名称（可选）", text: $name)
                    .listRowBackground(Theme.mainBg)
                if initial.kind.needsKey {
                    SecureField("API Key", text: $apiKey)
                        .listRowBackground(Theme.mainBg)
                }
            }

            kindSpecificSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("编辑 \(initial.kind.displayName)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    let updated = buildOptions()
                    onSave(updated)
                    // API key 落 Keychain（apiKey 空 = remove）
                    let cloud = (UserDefaults.standard.object(forKey: "apiKeyCloudSync") as? Bool) ?? false
                    WebSearchSettings.shared.setAPIKey(apiKey.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKey,
                                                       for: updated, sync: cloud)
                    dismiss()
                }
            }
        }
        .onAppear { loadFields() }
    }

    // MARK: - 各家专属字段

    @ViewBuilder
    private var kindSpecificSection: some View {
        switch initial.kind {
        case .bingLocal:
            Section {
                TextField("Accept-Language", text: $acceptLanguage)
                    .listRowBackground(Theme.mainBg)
            } footer: {
                Text("Bing 抓页支持的语言头，留默认即可")
                    .font(.system(size: Theme.SettingsFont.caption))
            }
        case .duckduckgo:
            Section {
                TextField("Region（如 wt-wt / cn-zh / us-en）", text: $region)
                    .listRowBackground(Theme.mainBg)
            } footer: {
                Text("wt-wt = 不限地区；详见 DDG 文档")
                    .font(.system(size: Theme.SettingsFont.caption))
            }
        case .brave, .linkup, .jina, .zhipu, .metaso:
            EmptyView() // 仅需 apiKey + name（已在主 Section）
        case .tavily:
            Section {
                TextField("自定义端点（可选，默认 https://api.tavily.com/search）", text: $customURL)
                    .listRowBackground(Theme.mainBg)
            }
        case .exa:
            Section {
                TextField("自定义端点（可选）", text: $customURL)
                    .listRowBackground(Theme.mainBg)
                Toggle("获取网页全文", isOn: $fetchFullText)
                    .listRowBackground(Theme.mainBg)
            } footer: {
                Text("开启 = 请求 contents.text=true，结果含 snippet 之外的全文")
                    .font(.system(size: Theme.SettingsFont.caption))
            }
        case .perplexity:
            Section {
                TextField("国家代码（ISO 3166-1 alpha-2，留空=不限）", text: $country)
                    .listRowBackground(Theme.mainBg)
                TextField("允许域名（逗号分隔）", text: $allowedDomainsText)
                    .listRowBackground(Theme.mainBg)
                Stepper("每页最大 token：\(maxTokensPerPage)", value: $maxTokensPerPage, in: 0...10000, step: 100)
                    .listRowBackground(Theme.mainBg)
            }
        case .bocha:
            Section {
                Picker("时效", selection: $freshness) {
                    Text("不限").tag("noLimit")
                    Text("一天内").tag("day")
                    Text("一周内").tag("week")
                    Text("一月内").tag("month")
                    Text("一年内").tag("year")
                }
                .listRowBackground(Theme.mainBg)
                Toggle("返回摘要", isOn: $summary)
                    .listRowBackground(Theme.mainBg)
                TextField("包含域名（逗号分隔）", text: $includeDomains)
                    .listRowBackground(Theme.mainBg)
                TextField("排除域名（逗号分隔）", text: $excludeDomains)
                    .listRowBackground(Theme.mainBg)
            }
        case .searxng:
            Section {
                TextField("实例 URL（必填，如 https://searx.example.com）", text: $customURL)
                    .listRowBackground(Theme.mainBg)
                TextField("引擎（逗号分隔，留空=用 server 默认）", text: $engines)
                    .listRowBackground(Theme.mainBg)
                TextField("语言（留空=auto）", text: $language)
                    .listRowBackground(Theme.mainBg)
                TextField("Basic Auth 用户名（可选）", text: $username)
                    .listRowBackground(Theme.mainBg)
            } footer: {
                Text("如果实例开了 basic auth，密码用上方的 API Key 字段")
                    .font(.system(size: Theme.SettingsFont.caption))
            }
        case .ollama:
            Section {
                Text("Ollama 走云端搜索 API（ollama.com/api/web_search），不是本地 ollama runtime。在 API Key 字段填入 ollama.com 颁发的 key。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.mainBg)
            }
        }
    }

    // MARK: - load / build

    private func loadFields() {
        switch initial {
        case .bingLocal(let o):
            name = o.name; acceptLanguage = o.acceptLanguage
        case .duckduckgo(let o):
            name = o.name; region = o.region
        case .brave(let o):
            name = o.name
        case .tavily(let o):
            name = o.name; customURL = o.customURL
        case .exa(let o):
            name = o.name; customURL = o.customURL; fetchFullText = o.fetchFullText
        case .perplexity(let o):
            name = o.name; country = o.country
            allowedDomainsText = o.allowedDomains.joined(separator: ", ")
            maxTokensPerPage = o.maxTokensPerPage
        case .linkup(let o):
            name = o.name; depth = o.depth
        case .jina(let o):
            name = o.name
        case .zhipu(let o):
            name = o.name
        case .bocha(let o):
            name = o.name; freshness = o.freshness; summary = o.summary
            includeDomains = o.includeDomains; excludeDomains = o.excludeDomains
        case .metaso(let o):
            name = o.name
        case .searxng(let o):
            name = o.name; customURL = o.customURL; engines = o.engines
            language = o.language; username = o.username
        case .ollama(let o):
            name = o.name
        }
        apiKey = WebSearchSettings.shared.apiKey(for: initial) ?? ""
    }

    private func buildOptions() -> WebSearchServiceOptions {
        let id = initial.id
        let name = self.name.trimmingCharacters(in: .whitespaces)
        switch initial.kind {
        case .bingLocal:
            return .bingLocal(.init(id: id, name: name, acceptLanguage: acceptLanguage))
        case .duckduckgo:
            return .duckduckgo(.init(id: id, name: name, region: region))
        case .brave:
            return .brave(.init(id: id, name: name))
        case .tavily:
            return .tavily(.init(id: id, name: name, customURL: customURL))
        case .exa:
            return .exa(.init(id: id, name: name, customURL: customURL, fetchFullText: fetchFullText))
        case .perplexity:
            let domains = allowedDomainsText.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .perplexity(.init(id: id, name: name, country: country, allowedDomains: domains, maxTokensPerPage: maxTokensPerPage))
        case .linkup:
            return .linkup(.init(id: id, name: name, depth: depth))
        case .jina:
            return .jina(.init(id: id, name: name))
        case .zhipu:
            return .zhipu(.init(id: id, name: name))
        case .bocha:
            return .bocha(.init(id: id, name: name, freshness: freshness, summary: summary, includeDomains: includeDomains, excludeDomains: excludeDomains))
        case .metaso:
            return .metaso(.init(id: id, name: name))
        case .searxng:
            return .searxng(.init(id: id, name: name, customURL: customURL, engines: engines, language: language, username: username))
        case .ollama:
            return .ollama(.init(id: id, name: name))
        }
    }
}

extension WebSearchServiceOptions {
    /// Identifiable conformance for .sheet(item:) usage in WebSearchServicesPage
    /// 注：enum 已经实现 var id，这里只是给 sheet 用
}
