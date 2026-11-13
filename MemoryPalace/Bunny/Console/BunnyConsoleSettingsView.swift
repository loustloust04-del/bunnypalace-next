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
    @State private var showFullSettings = false
    @AppStorage("settings.proMode") private var proMode = false
    @State private var stallCopied = false
    @State private var cycleText: String?
    @State private var cycleSyncing = false
    @State private var intimacyText: String?
    @State private var intimacySyncing = false
    @State private var medsText: String?
    @State private var medsSyncing = false

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        Form {
            Section {
                Text("网关连接与推特同步").font(.subheadline).foregroundStyle(.secondary)
            }

            Section {
                Button { showFullSettings = true } label: {
                    Label("打开完整设置（全部设置 + 搜索）", systemImage: "gearshape.2")
                }
            } footer: {
                Text("粟粟新版把设置分到了几处（左上字标 →「我」、右上头像胶囊 → 人页、桌面「设置」App）。这里直接打开原来那棵完整的设置树，带搜索。")
            }

            Section {
                Toggle("Pro 模式（显示全部功能与设置）", isOn: $proMode)
            } footer: {
                Text("和完整设置右上角的「简洁 / Pro」是同一个开关。")
            }

            #if os(iOS) && PERSONAL_APPS
            if SkinState.shared.unlocked {
                Section {
                    Toggle("兔兔皮肤", isOn: Binding(get: { SkinState.shared.enabled },
                                                   set: { SkinState.shared.enabled = $0 }))
                } footer: {
                    Text("和「App 设置 › caelumbunny」里的总开关是同一个；关掉当场回到普通皮肤，再打开不用重输暗号。")
                }
            }
            #endif

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
                        medsText = await BunnyMedsSync.runInBackground(container: modelContext.container, profileId: profileId)
                        medsSyncing = false
                    }
                }
                .disabled(medsSyncing || !BunnyGateway.isConfigured)
                if let medsText { Text(medsText).font(.caption).foregroundStyle(.secondary) }
                Button(cycleSyncing ? "同步中…" : "立即同步经期") {
                    cycleSyncing = true
                    Task {
                        cycleText = await BunnyCycleSync.runInBackground(container: modelContext.container, profileId: profileId)
                        cycleSyncing = false
                    }
                }
                .disabled(cycleSyncing || !BunnyGateway.isConfigured)
                if let cycleText { Text(cycleText).font(.caption).foregroundStyle(.secondary) }
                Button(intimacySyncing ? "同步中…" : "立即同步刻痕") {
                    intimacySyncing = true
                    Task {
                        intimacyText = await BunnyIntimacySync.runInBackground(container: modelContext.container, profileId: profileId)
                        intimacySyncing = false
                    }
                }
                .disabled(intimacySyncing || !BunnyGateway.isConfigured)
                if let intimacyText { Text(intimacyText).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("CARE · 药品柜 / 经期 / 刻痕")
            } footer: {
                Text("粟粟的「药物」↔ 网关药品柜（Caelum 看的就是这份）。打卡双向同步；库存与补货仍由网关管。经期按「这一次从哪天到哪天」同步；刻痕以网关为准拉回来，新兔里新记的日子会推给网关。回到桌面时会自动同步。粟粟的经期、亲密记录默认隐藏，要在健康设置里打开。")
            }
            Section {
                let rec = BunnyStallWatch.recent()
                Text(rec.count == 0 ? "还没有记录到卡死" : "记录到 \(rec.count) 次卡死").font(.subheadline)
                Button("复制最近的记录") {
                    #if os(iOS)
                    UIPasteboard.general.string = rec.text
                    #else
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rec.text, forType: .string)
                    #endif
                    stallCopied = true
                }
                .disabled(rec.text.isEmpty)
                if stallCopied { Text("已复制，可以粘贴发给 Claude").font(.caption).foregroundStyle(.secondary) }
                Button("清空记录", role: .destructive) { BunnyStallWatch.clear(); stallCopied = false }
            } header: {
                Text("卡死黑匣子")
            } footer: {
                Text("App 连续 4 秒没反应时，会记下当时卡在哪段代码（只有函数名，不含聊天内容）。卡死后划掉重开，回到这里复制记录。")
            }
        }
        .navigationTitle("Console 设置")
        .sheet(isPresented: $showFullSettings) { SettingsView() }   // [Bunny] 完整设置树的统一入口
        .task {
            if let msg = await BunnyTwitterSync.runIfDue(profileId: profileId, context: modelContext) { syncText = msg }
        }
    }

    private func sync(full: Bool) {
        syncing = true
        syncText = nil
        Task {
            do { syncText = try await BunnyTwitterSync.runInBackground(container: modelContext.container, profileId: profileId, full: full) }
            catch { syncText = "❌ \(error.localizedDescription)" }
            syncing = false
        }
    }
}
