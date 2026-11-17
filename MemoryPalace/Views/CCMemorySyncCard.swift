import MemoryCore
import SwiftUI

// MARK: - CC 小克的记忆同步（plan-cc-memory-sync）

struct CCMemorySyncCard: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage(CCMemorySync.enabledKey) private var ccMemoryEnabled = false
    @AppStorage(CCMemorySync.profileKey) private var ccMemoryProfileId = ""
    @State private var ccMemoryStatus = ""
    @State private var showCCMemoryBrowser = false
    @Environment(\.modelContext) private var modelContext
    @AppStorage(GardenMemorySync.enabledKey) private var gardenToCC = false
    @State private var gardenToCCStatus = ""
    @State private var gardenWaiting: [GardenFolderInbox.Change] = []

    private func copyPointerLine() {
        #if os(iOS)
        UIPasteboard.general.string = GardenMemorySync.pointerLine
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GardenMemorySync.pointerLine, forType: .string)
        #endif
    }

    @ViewBuilder
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { ccMemoryEnabled }, set: { setCCMemorySync($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同步 CC 的记忆")
                            .font(m.rowTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text("把 Claude Code 那边的 memory 同步到所选楼层的 memory/cc/（只读），AI 用文件工具能翻到。日记相关的不同步。需要连着 Mac 上的桥。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)

                if ccMemoryEnabled {
                    HStack {
                        Text("同步到楼层")
                            .font(m.body)
                            .foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Picker("同步到楼层", selection: Binding(get: { ccMemoryProfileId }, set: { switchCCMemoryFloor(to: $0) })) {
                            ForEach(profileManager?.profiles ?? []) { p in
                                Text("\(p.emoji) \(p.name)").tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .tint(Theme.branchIndicator)
                    }
                    HStack {
                        Text(ccMemoryStatus)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        Spacer(minLength: 8)
                        Button("立即同步") { CCMemorySync.requestManifest() }
                            .font(m.secondary)
                            .foregroundColor(Theme.branchIndicator)
                            .buttonStyle(.plain)
                    }
                    // 文件库页不显示记忆树 → 这里给一个只读入口
                    Button {
                        showCCMemoryBrowser = true
                    } label: {
                        HStack {
                            Text("查看同步过来的文件")
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchAnchor("leaf-mem-ccmemory")
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { gardenToCC }, set: { setGardenToCC($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("和 CC 同步记忆文件夹")
                            .font(m.rowTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text("把这一层的记忆文件夹（C2 原子事实、助手自己的记忆、待续、wiki、时间轴等）和 Prompt 放到 Claude Code 家目录的 garden-memory/ 里，CC 直接读写那里的文件。CC 改的会送回这里，按「权限」里那一种记忆的档位落。记忆会以明文留在跑 CC 的那台电脑上。需要连着桥。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)

                if gardenToCC {
                    HStack {
                        Text(gardenToCCStatus)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        Spacer(minLength: 8)
                        Button("立即同步") { syncGardenToCC(force: true) }
                            .font(m.secondary)
                            .foregroundColor(Theme.branchIndicator)
                            .buttonStyle(.plain)
                    }
                    if !gardenWaiting.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CC 在电脑上改了 \(gardenWaiting.count) 处，等你点。在「权限」里把那一种记忆改成自动允许后点「立即同步」，等着的会一起落。")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                            ForEach(gardenWaiting) { change in
                                HStack(spacing: 10) {
                                    Text(change.what)
                                        .font(m.caption)
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(2)
                                    Spacer(minLength: 8)
                                    Button("Reject") { resolveGardenChange(change.id, allow: false) }
                                        .font(m.secondary)
                                        .foregroundColor(Theme.textSecondary)
                                        .buttonStyle(.plain)
                                    Button("Approve") { resolveGardenChange(change.id, allow: true) }
                                        .font(m.secondary)
                                        .foregroundColor(Theme.branchIndicator)
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("把下面这一行加进 CC 的 CLAUDE.md，它才知道去哪找：")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        Text(GardenMemorySync.pointerLine)
                            .font(m.caption)
                            .foregroundColor(Theme.textSecondary)
                            .textSelection(.enabled)
                        Button("拷贝这一行") { copyPointerLine() }
                            .font(m.secondary)
                            .foregroundColor(Theme.branchIndicator)
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchAnchor("leaf-mem-garden-to-cc")
        .onAppear(perform: refreshGardenToCCStatus)
        .onReceive(NotificationCenter.default.publisher(for: GardenMemorySync.didChange)) { _ in refreshGardenToCCStatus() }
        .onReceive(NotificationCenter.default.publisher(for: GardenFolderInbox.didChange)) { _ in gardenWaiting = GardenFolderInbox.waiting }
        .sheet(isPresented: $showCCMemoryBrowser) {
            MemoryTreeBrowserSheet(profileId: ccMemoryProfileId, onlyFolder: CCMemorySync.subdir)
        }
        .onAppear(perform: refreshCCMemoryStatus)
        .onReceive(NotificationCenter.default.publisher(for: CCMemorySync.didChange)) { _ in refreshCCMemoryStatus() }
    }

    private func setGardenToCC(_ on: Bool) {
        gardenToCC = on
        if on { syncGardenToCC(force: true) } else { GardenMemorySync.remove(profiles: profileManager?.profiles ?? []) }
        refreshGardenToCCStatus()
    }

    /// 她亲手点的：这一层在电脑上的文件夹改成跟这台设备；等着的修改按现在的档位重看一遍
    private func syncGardenToCC(force: Bool) {
        guard let profile = profileManager?.currentProfile else { return }
        GardenMemorySync.sync(profile: profile, container: modelContext.container, force: force, claim: true)
        let profiles = profileManager?.profiles ?? []
        Task { await GardenFolderInbox.recheck(profiles: profiles, context: modelContext) }
    }

    private func resolveGardenChange(_ id: String, allow: Bool) {
        let profiles = profileManager?.profiles ?? []
        Task { await GardenFolderInbox.resolve(id, allow: allow, profiles: profiles, context: modelContext) }
    }

    private func refreshGardenToCCStatus() {
        gardenWaiting = GardenFolderInbox.waiting
        let d = UserDefaults.standard
        if let problem = d.string(forKey: GardenMemorySync.problemKey) { gardenToCCStatus = problem; return }
        let at = d.double(forKey: GardenMemorySync.lastSyncKey)
        guard at > 0 else { gardenToCCStatus = "还没同步过"; return }
        let when = Date(timeIntervalSince1970: at).formatted(.dateTime.month().day().hour().minute())
        gardenToCCStatus = "上次同步：\(when) · \(d.integer(forKey: GardenMemorySync.lastCountKey)) 份文件"
    }

    private func setCCMemorySync(_ on: Bool) {
        if on {
            if ccMemoryProfileId.isEmpty {
                // D1 默认粟粟常用那层；这台设备上没有就用当前楼层
                let ids = (profileManager?.profiles ?? []).map(\.id)
                ccMemoryProfileId = ids.contains(CCMemorySync.defaultProfileId)
                    ? CCMemorySync.defaultProfileId
                    : (profileManager?.currentProfile.id ?? "")
            }
            ccMemoryEnabled = true
        } else {
            ccMemoryEnabled = false
            CCMemorySync.removeLocal(profileId: ccMemoryProfileId)
        }
        CCMemorySync.connected()
        refreshCCMemoryStatus()
    }

    private func switchCCMemoryFloor(to newId: String) {
        guard newId != ccMemoryProfileId else { return }
        CCMemorySync.removeLocal(profileId: ccMemoryProfileId)
        ccMemoryProfileId = newId
        CCMemorySync.requestManifest()
    }

    private func refreshCCMemoryStatus() {
        let d = UserDefaults.standard
        let at = d.double(forKey: CCMemorySync.lastSyncKey)
        guard at > 0 else { ccMemoryStatus = "还没同步过"; return }
        let when = Date(timeIntervalSince1970: at).formatted(.dateTime.month().day().hour().minute())
        ccMemoryStatus = "上次同步：\(when) · \(d.integer(forKey: CCMemorySync.lastCountKey)) 个文件"
    }
}
