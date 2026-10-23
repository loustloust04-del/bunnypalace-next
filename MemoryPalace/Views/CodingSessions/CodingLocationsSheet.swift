#if os(macOS)
import AppKit
import SwiftUI

/// 会话位置（N3-e，Wake Settings → Session locations）：按家分组列出每条真实数据根——会话数、开关（停用 = 暂时不读，已索引的会话
/// 下轮扫描出清，文件不动）、编辑 / 在访达中显示 / 移除（只有自定义位置能移除，默认位置用开关停）；添加位置、恢复默认。
/// 一条数据都没有的家收进底部「没找到数据」里
struct CodingLocationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [CodingSessionLibrary.LocationRow] = []
    @State private var form: LocationForm?
    @State private var showUnavailable = false

    private var library: CodingSessionLibrary { .shared }

    struct LocationForm: Identifiable {
        let id = UUID()
        var editing: CodingSessionLibrary.LocationRow?
        var agent: CodingAgent
        var path: String
    }

    private struct AgentGroup {
        var agent: CodingAgent
        var rows: [CodingSessionLibrary.LocationRow]
    }

    private var groups: [AgentGroup] {
        var out: [AgentGroup] = []
        for row in rows {
            if out.last?.agent == row.agent { out[out.count - 1].rows.append(row) } else { out.append(AgentGroup(agent: row.agent, rows: [row])) }
        }
        return out
    }

    private var available: [AgentGroup] { groups.filter { $0.rows.contains { $0.exists || $0.custom != nil } } }
    private var unavailable: [AgentGroup] { groups.filter { !$0.rows.contains { $0.exists || $0.custom != nil } } }

    var body: some View {
        VStack(spacing: 0) {
            // 本机位置 / 远程主机（N4，母 plan「同 sheet」）/ 接入（N6-d）：分段放顶部，后两页不塞在本机位置的页底
            Picker("", selection: Binding(get: { library.locationsTab }, set: { library.locationsTab = $0 })) {
                Text("本机位置").tag(CodingLocationsTab.local)
                Text("远程主机").tag(CodingLocationsTab.remote)
                Text("接入").tag(CodingLocationsTab.connect)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            if library.locationsTab == .remote {
                CodingRemoteHostsPane { dismiss() }
            } else if library.locationsTab == .connect {
                CodingConnectPane { dismiss() }
            } else {
                header
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(available, id: \.agent) { agentGroup($0) }
                        if !unavailable.isEmpty { unavailableSection }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 600)
        .background(Theme.mainBg)
        .onAppear(perform: reload)
        .onChange(of: library.isScanning) { _, scanning in if !scanning { reload() } }
        .sheet(item: $form) { item in
            CodingLocationFormView(form: item) { reload() }
        }
    }

    private func reload() {
        rows = library.locationRows()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("会话位置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("记忆花园从这些文件夹读取本机编程 agent 的会话。停用只是暂时不读，文件不会动。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 12)
            Button {
                form = LocationForm(editing: nil, agent: .claudeCode, path: "")
            } label: {
                Label("添加位置", systemImage: "plus")
            }
            Menu {
                Button("恢复默认") {
                    library.restoreDefaultLocations()
                    reload()
                }
                .disabled(!library.locationsDiverged)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func agentGroup(_ group: AgentGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(CodingSessionFormat.color(group.agent))
                    .frame(width: 7, height: 7)
                Text(group.agent.displayName)
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().opacity(0.5) }
                    locationRow(row)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.textMuted.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.textMuted.opacity(0.18), lineWidth: 0.5))
        }
    }

    private func locationRow(_ row: CodingSessionLibrary.LocationRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.display)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(row.enabled ? Theme.textPrimary : Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.path)
                Text(row.exists ? "\(row.count) 个会话" : "文件夹不存在")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Menu {
                Button("编辑…") {
                    form = LocationForm(editing: row, agent: row.agent, path: library.editPrefill(row))
                }
                if row.exists {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
                }
                if row.custom != nil {
                    Divider()
                    Button("移除", role: .destructive) {
                        library.removeLocation(row)
                        reload()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(Theme.textMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Toggle("", isOn: Binding(get: { row.enabled }, set: { enabled in
                library.setLocationEnabled(row, enabled: enabled)
                reload()
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(Theme.branchIndicator)
            .help(row.enabled ? "停用这个位置" : "启用这个位置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var unavailableSection: some View {
        DisclosureGroup(isExpanded: $showUnavailable) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(unavailable, id: \.agent) { agentGroup($0) }
            }
            .padding(.top, 10)
        } label: {
            Text("没找到数据的 \(unavailable.count) 家")
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textMuted)
        }
    }
}

/// 添加 / 编辑位置（Wake location 表单）：编程工具下拉 + 文件夹（可手输，~ 展开）+ 选择…；有改动才能保存，校验不过留在表单上改
private struct CodingLocationFormView: View {
    @Environment(\.dismiss) private var dismiss
    let form: CodingLocationsSheet.LocationForm
    let onSaved: () -> Void
    @State private var agent: CodingAgent
    @State private var path: String
    @State private var error: String?

    private var library: CodingSessionLibrary { .shared }

    init(form: CodingLocationsSheet.LocationForm, onSaved: @escaping () -> Void) {
        self.form = form
        self.onSaved = onSaved
        _agent = State(initialValue: form.agent)
        _path = State(initialValue: form.path)
    }

    private var dirty: Bool {
        (agent != form.agent || path != form.path) && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(form.editing == nil ? "添加位置" : "编辑位置")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            HStack(spacing: 8) {
                Text("编程工具")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 56, alignment: .leading)
                Menu {
                    ForEach(CodingAgent.allCases, id: \.self) { candidate in
                        Button {
                            agent = candidate
                        } label: {
                            if candidate == agent { Label(candidate.displayName, systemImage: "checkmark") } else { Text(candidate.displayName) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(CodingSessionFormat.color(agent))
                            .frame(width: 7, height: 7)
                        Text(agent.displayName)
                    }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                Text("文件夹")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 56, alignment: .leading)
                TextField("/绝对/文件夹/路径", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("选择…", action: browse)
            }
            if let error {
                Text(error)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 64)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(form.editing == nil ? "添加" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.branchIndicator)
                    .disabled(!dirty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.mainBg)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let current = CodingLocations.expandTilde(path.trimmingCharacters(in: .whitespacesAndNewlines))
        if current.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: current) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func save() {
        guard dirty else { return }
        if let message = library.commitLocation(editing: form.editing, agent: agent, path: path) {
            error = message
            return
        }
        onSaved()
        dismiss()
    }
}
#endif
