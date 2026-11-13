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
        .sheet(isPresented: $showCCMemoryBrowser) {
            MemoryTreeBrowserSheet(profileId: ccMemoryProfileId, onlyFolder: CCMemorySync.subdir)
        }
        .onAppear(perform: refreshCCMemoryStatus)
        .onReceive(NotificationCenter.default.publisher(for: CCMemorySync.didChange)) { _ in refreshCCMemoryStatus() }
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
