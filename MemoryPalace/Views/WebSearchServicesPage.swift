import SwiftUI

/// 搜索服务管理页：list + add/edit/delete + 单选活跃 + 测试连接
struct WebSearchServicesPage: View {
    @StateObject private var settings = WebSearchSettings.shared
    @State private var editing: WebSearchServiceOptions? = nil
    @State private var testingId: String? = nil
    @State private var lastTestResult: (id: String, ok: Bool, msg: String)? = nil

    var body: some View {
        List {
            servicesSection
            addSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("搜索服务")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $editing) { opts in
            NavigationStack {
                WebSearchProviderEditSheet(initial: opts) { updated in
                    if settings.providers.contains(where: { $0.id == updated.id }) {
                        settings.update(updated)
                    } else {
                        settings.add(updated)
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
            #endif
        }
    }

    @ViewBuilder
    private var servicesSection: some View {
        Section {
            if settings.providers.isEmpty {
                Text("还没有搜索服务，下方添加一个")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.mainBg)
            } else {
                ForEach(settings.providers, id: \.id) { opts in
                    serviceRow(opts)
                        .listRowBackground(Theme.mainBg)
                }
                .onDelete { idx in
                    let ids = idx.map { settings.providers[$0].id }
                    for id in ids { settings.remove(id: id) }
                }
            }
        } header: {
            Text("已配置")
        }
    }

    @ViewBuilder
    private func serviceRow(_ opts: WebSearchServiceOptions) -> some View {
        HStack(spacing: 10) {
            Button {
                settings.select(id: opts.id)
            } label: {
                Image(systemName: settings.selectedId == opts.id ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(settings.selectedId == opts.id ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(opts.displayLabel)
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(Theme.textPrimary)
                if let r = lastTestResult, r.id == opts.id {
                    Text(r.ok ? "测试通过" : "测试失败：\(r.msg)")
                        .font(.system(size: 10))
                        .foregroundColor(r.ok ? Theme.branchIndicator : .red)
                        .lineLimit(1)
                } else {
                    Text(opts.kind.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
            }

            Spacer()

            if testingId == opts.id {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await testConnection(opts) }
                } label: {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("测试连接")
            }

            Button {
                editing = opts
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help("编辑")
        }
        .contentShape(Rectangle())
    }

    private var addSection: some View {
        Section {
            Menu {
                ForEach(WebSearchProviderKind.allCases) { kind in
                    Button(kind.displayName) {
                        let opts = WebSearchServiceOptions.makeDefault(kind: kind)
                        editing = opts
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(Theme.branchIndicator)
                    Text("添加搜索服务")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .listRowBackground(Theme.mainBg)
        }
    }

    @MainActor
    private func testConnection(_ opts: WebSearchServiceOptions) async {
        testingId = opts.id
        defer { testingId = nil }
        do {
            let provider = try WebSearchProviderFactory.make(for: opts)
            let r = try await provider.search(
                query: "hello world",
                common: WebSearchCommonOptions(resultSize: 1, timeoutMs: 8000),
                options: opts
            )
            lastTestResult = (opts.id, !r.items.isEmpty, r.items.isEmpty ? "空结果" : "")
        } catch {
            lastTestResult = (opts.id, false, error.localizedDescription)
        }
    }
}
