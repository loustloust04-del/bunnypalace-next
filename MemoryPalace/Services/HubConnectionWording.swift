import Foundation

/// 终端错误行的人话（审计 T07）。hub 的 `terminal_error.reason` 是给程序看的英文，原文收进长按「复制原因」。
enum TerminalErrorWording {
    /// 这两种不是「错误行」：stream_session 是无终端模式（单独一句说明），session_not_found 走断桥卡
    static let notAnErrorLine: Set<String> = ["stream_session", "session_not_found"]

    static func humanize(_ reason: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasPrefix("send-keys") { return "刚才那下没发出去" }
        if r.hasPrefix("capture failed") || r.hasPrefix("attach failed") { return "画面没拉下来 · 点重新绘制" }
        if r.hasPrefix("session_not_found") { return "电脑上的这个窗口已经结束了" }
        // hub 自己给的人话（自动恢复起不来：「电脑上没装 tmux（brew install tmux）」之类）原样给她看
        if r.hasPrefix("电脑上") { return r }
        return "电脑那边出了点问题"
    }
}

/// 断桥卡 / 「我的电脑」页上「为什么连不上」那一行（审计 T09）。输入是 WS client 的 `lastError`。
enum BridgeDisconnectWording {
    /// nil = 没有可说的原因（刚开始连 / 手动断开）
    static func humanize(_ lastError: String?) -> String? {
        guard let raw = lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        // hub 鉴权失败：ws.close(1008, "auth") / "bundle"（hub.ts wss.on("connection")）
        if lower == "auth" { return "口令不对：重新扫码配对一次" }
        if lower == "bundle" { return "电脑上的 hub 不认这个 App" }
        if raw.hasPrefix("探测全败") { return "找不到电脑：所有地址都连不上" }
        if lower.contains("timeout") || lower.contains("timed out") || raw.contains("超时") {
            return "等了太久没回应：电脑可能睡着了"
        }
        if lower.contains("refused") || lower.contains("could not connect") || raw.contains("未能连接") || raw.contains("拒绝") {
            return "电脑拒绝了连接：hub 可能没在跑"
        }
        if lower.contains("offline") || raw.contains("似乎已断开") || lower.contains("not connected to the internet") {
            return "手机没联网"
        }
        return "连接断了"
    }

    /// 探测全败且候选里有 Tailscale 地址 → 多半是人在外面、手机没开 Tailscale
    static func tailscaleHint(lastError: String?, candidateHosts: [String]) -> String? {
        guard lastError?.hasPrefix("探测全败") == true, candidateHosts.contains(where: NetworkRoute.isTailscale) else { return nil }
        return "在外面？要开 Tailscale"
    }
}

/// 当前连的地址走的哪条路：本机 / 局域网 / Tailscale
enum NetworkRoute: Equatable {
    case local
    case lan
    case tailscale

    static func classify(_ host: String) -> NetworkRoute {
        if isTailscale(host) { return .tailscale }
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return .local }
        return .lan
    }

    /// Tailscale：100.64.0.0/10（CGNAT 段）或 MagicDNS 的 *.ts.net
    static func isTailscale(_ host: String) -> Bool {
        if host.lowercased().hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    var label: String {
        switch self {
        case .local: return "本机"
        case .lan: return "局域网"
        case .tailscale: return "Tailscale"
        }
    }
}
