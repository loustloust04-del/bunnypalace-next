import SwiftUI

/// 设置 · Codex：codex 桥的门面页。codex 与 CC 共用同一条 hub 桥——
/// 这里的配对就是 hub 配对（扫一次两边通用），状态也读同一个 bridge 连接。
///
/// 一份 body 两端共用（plan-settings-merge 刀 2）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// 只剩 iOS 独有的「扫码配对」按钮 / `fullScreenCover` 与两端各一句的「连接」脚注是平台例外。
struct CodexSettingsTab: View {
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @State private var bridgeConnected = CCBridgeWebSocketClient.shared.isConnected
    #if os(iOS)
    @State private var showScanner = false
    @State private var pairResult: String?
    #endif

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                HStack {
                    Text("连接状态")
                    Spacer()
                    Text(bridgeConnected ? "已连接" : "未连接")
                        .foregroundColor(bridgeConnected ? Theme.branchIndicator : Theme.textMuted)
                }
                #if os(iOS)
                Button {
                    showScanner = true
                } label: {
                    Label("扫码配对", systemImage: "qrcode.viewfinder")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                if let note = pairResult {
                    Text(note).font(.system(size: 12)).foregroundColor(Theme.textMuted)
                }
                #endif
            } header: {
                Text("连接")
            } footer: {
                #if os(iOS)
                Text("Codex 与 Claude Code 共用同一条桥——配对一次两边通用。在 Mac 端记忆宫殿 设置 →「让手机连这台 Mac」打开配对二维码，扫一下自动填好地址和密钥。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                #else
                Text("Codex 与 Claude Code 共用同一条桥和配对（Mac 端本机直连，无需单独配置）。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                #endif
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                Text("侧栏新建按钮长按 → 「新建 Codex 对话」，会自动分配一个独立的 codex 会话（mp-codex-N）。对话历史与 Claude Code 互不影响，杀掉会话重开也会接着上次聊。")
                    .font(m.caption)
                    .foregroundColor(Theme.textSecondary)
            } header: {
                Text("怎么用")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("Codex")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) {
            CCPairScannerSheet { payload in applyPairing(payload) }
        }
        #endif
        .onAppear { bridgeConnected = CCBridgeWebSocketClient.shared.isConnected }
    }

    #if os(iOS)
    /// hub 配对是共享的（CC 和 Codex 是同一个 cc-bridge）
    private func applyPairing(_ p: CCPairPayload) {
        pairResult = CCPairingApply.apply(p, providerManager: providerManager)
        bridgeConnected = true
    }
    #endif
}
