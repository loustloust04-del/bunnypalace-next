#if os(iOS)
import SwiftUI

/// 手机里的小电脑的一个 shell（#045 T2）。视图宿主和 controller 都归会话持有：
/// 这块视图消失（切 tab / 翻走）不 detach、不结束，回来挂的是同一个 SwiftTerm。
struct TerminalLocalSessionPane: View {
    let session: ISHTerminalSession
    let model: TerminalPanelModel

    @State private var showToolbarSettings = false

    var body: some View {
        // 这两个闭包会被会话持有的 Coordinator 存住：只捕获 model（弱）和 Binding，不捕获整个 pane，
        // 否则 会话 → 宿主 → Coordinator → pane → 会话 成环，结束后整套 SwiftTerm 放不掉（sol 实现审 #7）
        let showSettings = $showToolbarSettings
        TerminalRepresentable(
            controller: session.controller,
            onOpenWindowSwitcher: { [weak model] in
                model?.panelExpandsClosed = false
                model?.showWindowPanel = true
            },
            onOpenSettings: { showSettings.wrappedValue = true },
            host: session.host
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { stateCard }
        .animation(.easeInOut(duration: 0.2), value: session.state)
        .padding(.bottom, 10)
        .onAppear {
            // 第一次：attach 由 sizeChanged 拿真实尺寸负责；2s 兜底防 layout 异常没 fire
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak controller = session.controller] in
                controller?.attachIfNotYet(cols: 80, rows: 24)
            }
        }
        .sheet(isPresented: $showToolbarSettings) {
            NavigationStack { TerminalSettingsTab() }
                .presentationBackground(Theme.sidebarBg)
        }
    }

    @ViewBuilder
    private var stateCard: some View {
        switch session.state {
        case .starting:
            ZStack {
                Color.black.opacity(0.35)
                HStack(spacing: 10) {
                    ProgressView().tint(TerminalChrome.ink)
                    Text("正在启动小电脑…")
                        .font(.system(size: 13))
                        .foregroundColor(TerminalChrome.ink)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TerminalChrome.selected))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        case .failed(let reason):
            TerminalLocalCard(icon: "exclamationmark.triangle", title: "小电脑没起来", subtitle: reason,
                              primary: ("小电脑状态…", { model.showSandbox = true }),
                              secondary: ("关掉", { model.endLocal(session.id) }))
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.55))
                .transition(.opacity)
        case .exited(let code):
            VStack {
                Spacer()
                TerminalLocalCard(icon: "power", title: code.map { "shell 已退出（退出码 \($0)）" } ?? "shell 已结束",
                                  subtitle: "小电脑里的文件都还在",
                                  primary: ("再开一个", reopen),
                                  secondary: ("关掉", { model.endLocal(session.id) }))
                    .padding(.bottom, 24)
            }
            .transition(.opacity)
        case .running:
            EmptyView()
        }
    }

    /// 关掉这个、在原地开一个新的（先关再开，满 4 个时也开得出来）
    private func reopen() {
        ISHTerminalSessionStore.shared.end(session.id)
        model.openLocal()
    }
}

/// 小电脑那几张卡（样子照断桥卡 `TerminalBridgeCard`）
private struct TerminalLocalCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(Palette.apricot)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TerminalChrome.ink)
                .padding(.top, 10)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(TerminalChrome.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button(action: primary.1) {
                    Text(primary.0)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(TerminalChrome.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.mint))
                }
                Button(action: secondary.1) {
                    Text(secondary.0)
                        .font(.system(size: 13))
                        .foregroundColor(TerminalChrome.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.18)))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 18)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(TerminalChrome.selected.opacity(0.96)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        .padding(.horizontal, 22)
    }
}
#endif
