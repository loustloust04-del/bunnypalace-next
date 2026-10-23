//
//  SandboxSettingsTab.swift
//  设置 → 手机里的小电脑（原「ish沙箱」）。只 iOS：macOS 的 run_command 跑在真机器上，没有沙箱可看可重置。
//
//  T6a 之前这段藏在「文件库」页最底下，粟粟实测翻到底才找到；现在提到设置根列表，
//  跟文件库同一坨。#045 T2 起顶上多一个「打开终端」。
//

#if os(iOS)

import SwiftUI

struct SandboxSettingsTab: View {
    /// 「打开终端」：调用方负责收起自己（设置页 / 终端里的 sheet）再开新终端。nil = 不显示
    var onOpenTerminal: (() -> Void)? = nil
    /// 从终端里打开的那份不露红色重置（审计 T41）
    var showsReset = true

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var showResetConfirm = false
    @State private var didReset = false
    @State private var resetError: String?

    var body: some View {
        ScrollView { content }
            .background(Theme.sidebarBg)
            .navigationTitle("手机里的小电脑")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let onOpenTerminal { openTerminalSection(onOpenTerminal) }
            statusSection
            if showsReset {
                resetSection
            } else {
                Text("重置在 设置 › 手机里的小电脑")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 打开终端（#045）

    private func openTerminalSection(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.branchIndicator)
                VStack(alignment: .leading, spacing: 2) {
                    Text("打开终端")
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("直接在小电脑里敲命令，断网也能用")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("状态")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            statusRow("小电脑", RootfsManager.shared.isInstalled ? "已装好" : "还没装")
            let terminals = ISHTerminalSessionStore.shared.sessions.count
            if terminals > 0 { statusRow("开着的终端", "\(terminals) 个") }
            VStack(alignment: .leading, spacing: 2) {
                Text("当前楼层的文件库")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                Text(SandboxStatusText.library(libraryState))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }

            Text("AI 和终端都在这台手机里的小电脑上运行命令。它碰不到手机上的其他东西，只看得见自己里面的文件和接进来的楼层文件库。第一次用时自动装好。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))
                .padding(.top, 2)

            Text("Alpine Linux · iSH · rootfs \(rootfsVersionText)")
                .font(.system(size: Theme.F.caption, design: .monospaced))
                .foregroundColor(Theme.textMuted.opacity(0.5))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
    }

    /// 「这次打开后接进来几个楼层」那个进程内计数冷启动永远是 0，看着像没挂上（T38）——改说当前楼层的实情
    private var libraryState: SandboxStatusText.Library {
        let rootfs = RootfsManager.shared
        if rootfs.didResetWhileBooted || didReset { return .resetPending }
        guard rootfs.isInstalled else { return .notInstalled }
        if FileLibraryStore.iCloudEnabled, FileLibraryStore.iCloudFloorsRoot() != nil { return .iCloud }
        guard let profileId = profileManager?.currentProfile.id else { return .notInstalled }
        if let path = SandboxMount.currentMounts[profileId] { return .mounted(guestPath: path) }
        if let problem = SandboxMount.problem(profileId: profileId) { return .problem(problem) }
        return .notYet(guestPath: SandboxMount.guestPath(for: profileId))
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
        }
    }

    /// 磁盘上那份 `.rootfs-version`；没装或读不到就如实说，不假装
    private var rootfsVersionText: String {
        guard RootfsManager.shared.isInstalled,
              let raw = try? String(contentsOf: RootfsManager.shared.rootfsPath
                  .appendingPathComponent(".rootfs-version"), encoding: .utf8) else { return "—" }
        return "v" + raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 重置（T4 落在文件库页，T6a 整段搬过来）

    private var resetMessage: String {
        SandboxStatusText.resetMessage(openTerminals: ISHTerminalSessionStore.shared.sessions.count)
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("重置小电脑") { showResetConfirm = true }
                .foregroundColor(.red.opacity(0.8))
                .font(.system(size: Theme.F.label))
                .buttonStyle(.plain)

            Text(SandboxStatusText.resetMessage(openTerminals: 0))
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))

            if didReset {
                Text("已重置，请重启 app。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.branchIndicator)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
        .alert("重置小电脑？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive, action: reset)
        } message: {
            Text(resetMessage)
        }
        .alert("重置失败", isPresented: .constant(resetError != nil)) {
            Button("好") { resetError = nil }
        } message: {
            Text(resetError ?? "")
        }
    }

    /// 重置屏障（sol 实现审 #5）：先挡住新开、结束全部终端并等它们真收干净，再删 rootfs
    private func reset() {
        let store = ISHTerminalSessionStore.shared
        store.beginReset {
            do {
                try RootfsManager.shared.reset()
                didReset = true
            } catch {
                store.finishReset()
                resetError = error.localizedDescription
            }
        }
    }
}

#endif
