#if os(iOS)
import SwiftUI

/// 断桥的三种情况分开说（审计 T01 / T07 的 App 侧）。stream_session 不在这里——它不是故障。
enum TerminalBridgeIssue: Equatable {
    /// 从没配过对：外人第一次打开
    case notPaired
    /// 配过对，但现在连不上
    case disconnected
    /// 桥好好的，这个窗口的 tmux 没了（hub 回 session_not_found）
    case sessionGone
}

/// 盖在终端区上的卡片（照 rootshell 重连卡小样）
struct TerminalBridgeCard: View {
    let issue: TerminalBridgeIssue
    /// .disconnected 时为什么连不上（`BridgeDisconnectWording`，审计 T09）；nil 用通用那句
    var reason: String? = nil
    /// 第三行小提示（「在外面？要开 Tailscale」）
    var hint: String? = nil
    /// 按了「重新连接」、还没连上：按钮变「连接中…」且不能再按（T05）
    var busy = false
    let primary: () -> Void
    let secondary: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .regular))
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
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.apricot)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                HStack(spacing: 10) {
                    Button(action: primary) {
                        Text(busy ? "连接中…" : primaryLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(TerminalChrome.background)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.mint.opacity(busy ? 0.6 : 1)))
                    }
                    .disabled(busy)
                    if issue == .disconnected {
                        Button(action: secondary) {
                            Text("连接设置")
                                .font(.system(size: 13))
                                .foregroundColor(TerminalChrome.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.18)))
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 18)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.227, green: 0.208, blue: 0.196).opacity(0.94)))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .padding(.horizontal, 22)
        }
    }

    private var icon: String {
        switch issue {
        case .notPaired: return "laptopcomputer.and.iphone"
        case .disconnected: return "arrow.counterclockwise"
        case .sessionGone: return "rectangle.dashed"
        }
    }

    private var title: String {
        switch issue {
        case .notPaired: return "这里能连到你的电脑"
        case .disconnected: return "连不上我的电脑"
        case .sessionGone: return "这个窗口已经不在了"
        }
    }

    private var subtitle: String {
        switch issue {
        case .notPaired: return "在 Mac 上装记忆花园，打开「让手机连这台 Mac」，再用这里扫码"
        case .disconnected: return reason ?? "电脑睡着了、hub 没在跑，或者网络不通"
        case .sessionGone: return "电脑上的这个窗口已经结束了"
        }
    }

    private var primaryLabel: String {
        switch issue {
        case .notPaired: return "连接我的电脑"
        case .disconnected: return "重新连接"
        case .sessionGone: return "重新开一个"
        }
    }
}

/// 键盘收着时底部那条很淡的「点这里输入」（D7 / T30）。22% 输入区规则不变，这条只是让人看得见那块在哪；
/// 不吃点击，点击照旧落到终端自己的 tap 上。
struct TerminalInputHint: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
            Text("点这里输入")
                .font(.system(size: 11))
        }
        .foregroundColor(Color.white.opacity(0.22))
        .padding(.bottom, 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
