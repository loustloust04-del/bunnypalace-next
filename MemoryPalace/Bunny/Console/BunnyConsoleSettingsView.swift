import SwiftUI
import SwiftData

// MARK: - [Bunny] Caelum's Console · 设置页（网关连接 + 推特同步）
//
// 计划书 docs/bunny/PLAN-console-and-tools.md。P0 只放「网关连接」与「推特同步」，
// 后续各期把 CARE / LOG / DAILY / WITH YOU 的格子逐步加进来。

struct BunnyConsoleSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var baseURL = BunnyGateway.baseURL
    @State private var token = BunnyGateway.token
    @State private var pingText: String?
    @State private var pinging = false
    @State private var syncText: String?
    @State private var syncing = false
    @State private var medsText: String?
    @State private var medsSyncing = false

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        Form {
            Section {
                Text("网关连接与推特同步").font(.subheadline).foregroundStyle(.secondary)
            }

            Section {
                TextField("网关地址，如 https://example.com", text: $baseURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("口令", text: $token)
                Button(pinging ? "连接中…" : "保存并测试连接") {
                    BunnyGateway.save(baseURL: baseURL, token: token)
                    pinging = true
                    pingText = nil
                    Task {
                        do { try await BunnyGateway.ping(); pingText = "✅ 已连上网关" }
                        catch { pingText = "❌ \(error.localizedDescription)" }
                        pinging = false
                    }
                }
                .disabled(pinging)
                if let pingText { Text(pingText).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("网关连接")
            } footer: {
                Text("和大肥兔填的是同一个网关地址和口令。口令只存在这台手机的钥匙串里。")
            }

            Section {
                Button(syncing ? "同步中…" : "立即同步推特") { sync(full: false) }.disabled(syncing || !BunnyGateway.isConfigured)
                Button("整包重新同步") { sync(full: true) }.disabled(syncing || !BunnyGateway.isConfigured)
                if let syncText { Text(syncText).font(.caption).foregroundStyle(.secondary) }
                if let last = BunnyTwitterSync.lastRunAt {
                    Text("上次同步：\(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("To World · 推特")
            } footer: {
                Text("把网关同步到的推文放进「推特」App。重复同步不会出现重复推文；之后再导入官方存档，会自动补全原文、回复和图片。「整包重新同步」会先清掉从网关拉来的推文再重拉（导入过官方存档的不受影响）。")
            }
            Section {
                Button(medsSyncing ? "同步中…" : "立即同步药品柜") {
                    medsSyncing = true
                    Task {
                        medsText = await BunnyMedsSync.run(context: modelContext, profileId: profileId)
                        medsSyncing = false
                    }
                }
                .disabled(medsSyncing || !BunnyGateway.isConfigured)
                if let medsText { Text(medsText).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("CARE · 药品柜")
            } footer: {
                Text("粟粟的「药物」↔ 网关药品柜（Caelum 看的就是这份）。打卡双向同步；库存与补货仍由网关管。回到桌面时会自动同步。")
            }
        }
        .navigationTitle("Console 设置")
        .task {
            if let msg = await BunnyTwitterSync.runIfDue(profileId: profileId, context: modelContext) { syncText = msg }
        }
    }

    private func sync(full: Bool) {
        syncing = true
        syncText = nil
        Task {
            do { syncText = try await BunnyTwitterSync.run(profileId: profileId, context: modelContext, full: full) }
            catch { syncText = "❌ \(error.localizedDescription)" }
            syncing = false
        }
    }
}
