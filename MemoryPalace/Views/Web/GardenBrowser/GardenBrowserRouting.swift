import Foundation

/// 花园浏览器的两项设置（⋯ › 浏览器设置，iOS 设置 › 联网搜索 也有「链接打开方式」）
enum GardenBrowserSettings {
    static let layoutKey = "gardenBrowser.toolbarLayout"
    static let linkOpenModeKey = "gardenBrowser.linkOpenMode"

    static var linkOpenMode: GardenLinkOpenMode {
        GardenLinkOpenMode(rawValue: UserDefaults.standard.string(forKey: linkOpenModeKey) ?? "") ?? .inApp
    }
}

/// 底栏：紧凑 = 一行（左圆钮 / 地址胶囊 / ⋯），两行 = 地址胶囊 + 按钮排（iOS 26 Safari 同款两种）
enum GardenBrowserToolbarLayout: String, CaseIterable, Identifiable {
    case compact, twoRow
    var id: String { rawValue }
    var label: String { self == .compact ? "紧凑" : "两行" }
}

enum GardenLinkOpenMode: String, CaseIterable, Identifiable {
    case inApp, safari
    var id: String { rawValue }
    var label: String { self == .inApp ? "app 内" : "Safari" }
}

enum GardenBrowserRouting {
    enum Destination: Equatable { case inApp, system }

    /// App Store / TestFlight 链接在网页里打不开商店，交给系统
    static let systemHosts: Set<String> = ["apps.apple.com", "itunes.apple.com", "testflight.apple.com"]

    static func destination(for url: URL, mode: GardenLinkOpenMode) -> Destination {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .system }
        if let host = url.host()?.lowercased(), systemHosts.contains(host) { return .system }
        return mode == .inApp ? .inApp : .system
    }
}

/// 地址栏输入 → 要打开的网址；不像网址的当关键词用 Google 搜
enum AddressInput {
    enum Kind: Equatable { case url, search }

    static func kind(of raw: String) -> Kind? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains(where: \.isWhitespace) { return .search }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: s)?.host() == nil ? .search : .url }
        // 有中日韩字符又没写协议：多半是搜索词（「什么是.net」）
        if s.unicodeScalars.contains(where: { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }) { return .search }
        let host = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
        if hostOnly == "localhost" || isIPv4(hostOnly) { return .url }
        let labels = hostOnly.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return .search }
        return .url
    }

    static func url(for raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind(of: s) {
        case nil:
            return nil
        case .url:
            let lower = s.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: s) }
            let host = lower.split(separator: "/").first.map(String.init) ?? lower
            let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
            let scheme = hostOnly == "localhost" || isIPv4(hostOnly) ? "http://" : "https://"
            return URL(string: scheme + s)
        case .search:
            var c = URLComponents(string: "https://www.google.com/search")
            c?.queryItems = [URLQueryItem(name: "q", value: s)]
            return c?.url
        }
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
