#if os(macOS)
import SwiftUI

/// 远程主机（N4，Wake Settings → Remote hosts）：通过 SSH 把别的机器上的会话按白名单镜像到本地缓存，只读。一行一台——名字、同步状态
/// （失败标红，停用时不标红）、`…`（立即同步 / 移除）、开关（停用 = 该主机的会话出清、缓存保留，重开即收编）；顶部立即同步 / 添加主机。
/// 状态文案在这里现算（库里只存事实：会话数、上次成功时间、上次错误）
struct CodingRemoteHostsPane: View {
    let onDone: () -> Void
    @State private var rows: [CodingSessionLibrary.RemoteHostRow] = []
    @State private var showAdd = false
    @State private var pendingRemove: String?

    private var library: CodingSessionLibrary { .shared }
    private var syncing: Bool { !library.syncingHosts.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if rows.isEmpty {
                        Text("还没有远程主机。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider().opacity(0.5) }
                                hostRow(row)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.textMuted.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.textMuted.opacity(0.18), lineWidth: 0.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: library.syncingHosts) { _, _ in reload() }
        .onChange(of: library.isScanning) { _, scanning in if !scanning { reload() } }
        .sheet(isPresented: $showAdd) {
            CodingRemoteHostForm { reload() }
        }
        .confirmationDialog(pendingRemove.map { "移除 \($0)？" } ?? "", isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let name = pendingRemove { library.removeRemoteHost(name) }
                pendingRemove = nil
                reload()
            }
        } message: {
            Text("它的会话会移出索引，本地缓存删除；远端主机上什么都不动。")
        }
    }

    private func reload() {
        rows = library.remoteHostRows()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("远程主机")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("通过 SSH 镜像其他机器上的编程 agent 会话。只读：远端上的东西一概不写。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 12)
            if !rows.isEmpty {
                Button {
                    library.syncRemoteHosts()
                } label: {
                    Label(syncing ? "同步中…" : "立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(syncing)
            }
            Button {
                showAdd = true
            } label: {
                Label("添加主机", systemImage: "plus")
            }
            Button("完成", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func status(_ row: CodingSessionLibrary.RemoteHostRow) -> String {
        if let error = row.lastSyncError { return "同步失败：\(error)" }
        if let at = row.lastSyncAt { return "\(row.count) 个会话 · \(CodingSessionFormat.relative(at))同步" }
        return "\(row.count) 个会话 · 从未同步"
    }

    private func hostRow(_ row: CodingSessionLibrary.RemoteHostRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(row.enabled ? Theme.textPrimary : Theme.textMuted)
                    .lineLimit(1)
                Text(status(row))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(row.lastSyncError != nil && row.enabled ? Theme.danger : Theme.textMuted)
                    .lineLimit(2)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Menu {
                Button("立即同步") { library.syncRemoteHosts([row.name]) }
                    .disabled(syncing || !row.enabled)
                Divider()
                Button("移除…", role: .destructive) { pendingRemove = row.name }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(Theme.textMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Toggle("", isOn: Binding(get: { row.enabled }, set: { enabled in
                library.setRemoteHostEnabled(row.name, enabled: enabled)
                reload()
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(Theme.branchIndicator)
            .help(row.enabled ? "停用这台主机" : "启用这台主机")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// 添加远程主机（Wake Add host 表单）：单字段；有输入才能添加，格式不对留在表单上改
private struct CodingRemoteHostForm: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    @State private var name = ""
    @State private var error: String?

    private var library: CodingSessionLibrary { .shared }
    private var dirty: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加远程主机")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            HStack(spacing: 8) {
                Text("主机")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 40, alignment: .leading)
                TextField("~/.ssh/config 里的别名，或 user@host", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            Text("需要免交互的 SSH（密钥已在 ssh-agent 里），两端都装了 rsync；先在终端里连一次、信任主机指纹。启动、刷新和立即同步时会拉取会话。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 48)
            if let error {
                Text(error)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 48)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加", action: save)
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

    private func save() {
        guard dirty else { return }
        if let message = library.addRemoteHost(name) {
            error = message
            return
        }
        onSaved()
        dismiss()
    }
}
#endif
