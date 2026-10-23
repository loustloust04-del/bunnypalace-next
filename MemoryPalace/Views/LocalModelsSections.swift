import SwiftUI

// MARK: - 新建 / 编辑 API 卡 › 提供商选「本机模型」时的那几段（plan-小芽-v3 D2，粟粟 09-26：放在提供商里选）
// 从小芽设置搬过来的下载 / 删除；装好的模型可以点星收藏，收藏了就出现在聊天的模型选择器里。
// 只出 Section，嵌在 APICredentialEditor 的 List 里。

struct LocalModelsSections: View {
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @State private var models = AssistantModelStore.shared
    @State private var confirmDelete: AssistantLocalModel?

    var body: some View {
        Group {
            ForEach(AssistantLocalModel.catalog) { model in
                Section {
                    row(model)
                } header: {
                    HStack {
                        Text(model.title)
                        Spacer()
                        if models.state(model) == .installed, let pm = providerManager {
                            let id = "\(APICredential.localId)/\(model.id)"
                            Button {
                                pm.toggleFavoriteModel(id: id)
                            } label: {
                                Image(systemName: pm.isFavoriteModel(id: id) ? "star.fill" : "star")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(pm.isFavoriteModel(id: id) ? "取消收藏" : "收藏")
                        }
                    }
                } footer: {
                    Text(model.detail).foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
            }
            Section {
                Label("不联网也能聊，不花 API 的钱；手机上比云端慢", systemImage: "leaf")
                Label("聊天里用本机模型时不带工具（联网 / 文件库 / MCP），上下文最多约 6000 字", systemImage: "info.circle")
                Label("模型放在 app 自己的目录里、不进 iCloud 备份，默认只用 Wi-Fi 下载", systemImage: "externaldrive")
            }
            .font(.system(size: Theme.F.secondary))
            .foregroundColor(Theme.textSecondary)
            .listRowBackground(Theme.mainBg)
        }
        .onChange(of: models.states) { old, new in
            // 刚下完的自动收藏一次，不然选择器里看不见
            guard let pm = providerManager else { return }
            for (id, state) in new where state == .installed && old[id] != .installed {
                let combined = "\(APICredential.localId)/\(id)"
                if !pm.isFavoriteModel(id: combined) { pm.toggleFavoriteModel(id: combined) }
            }
        }
        .confirmationDialog("删掉本机模型？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { model in
            Button("删除 \(model.title)", role: .destructive) {
                LocalLLMService.shared.unload()
                models.delete(model)
                providerManager?.resolveStaleSelectedModel()
            }
            Button("算了", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ model: AssistantLocalModel) -> some View {
        let fmt: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        switch models.state(model) {
        case .notInstalled:
            Button("下载（\(fmt(model.totalBytes))）") { models.download(model) }
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                HStack {
                    Text("正在下载 · \(fmt(received)) / \(fmt(total))").font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
                    Spacer()
                    Button("暂停") { models.pause(model) }.buttonStyle(.borderless)
                }
            }
        case .paused(let received, let total):
            HStack {
                Text("已下 \(fmt(received)) / \(fmt(total))").font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
                Spacer()
                Button("继续") { models.download(model) }.buttonStyle(.borderless)
            }
        case .waitingForWiFi(let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                Text("现在在用流量，默认只走 Wi-Fi（已下 \(fmt(received)) / \(fmt(total))）")
                    .font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
                Button("用流量下载（还剩 \(fmt(total - received))）") { models.download(model, allowCellular: true) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.system(size: Theme.F.secondary)).foregroundColor(Theme.danger)
                Button("重试") { models.download(model) }
            }
        case .installed:
            HStack {
                Label("已装好", systemImage: "checkmark.circle").foregroundColor(Theme.textSecondary)
                Spacer()
                Button("删除", role: .destructive) { confirmDelete = model }.buttonStyle(.borderless)
            }
        }
    }
}
