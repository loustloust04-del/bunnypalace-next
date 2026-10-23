import Foundation

/// API 卡 Base URL 的唯一规整规则（#092 A）。卡上存的就是规整后的地址，
/// 测试连接、拉模型、聊天都直接拼在它后面——以前测试 / 拉模型自己补 /v1、聊天不补，测试绿聊天 404。
enum BaseURLNormalizer {
    private static let endpointTails = ["/chat/completions", "/messages", "/models"]

    /// 只管 HTTP 协议的两种卡；ws 桥、ChatGPT 账号、本机模型原样返回。
    /// 1 去首尾空白和换行 2 没协议头补 https:// 3 剥掉粘进来的端点尾巴 4 去掉所有尾斜杠 5 只有域名的补 /v1
    static func normalize(_ raw: String, type: ProviderType) -> String {
        guard type == .openaiCompatible || type == .anthropic else { return raw }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("?") else { return s }
        if !s.contains("://") { s = "https://" + s }
        var stripped = true
        while stripped {
            stripped = false
            while s.hasSuffix("/") { s.removeLast() }
            for tail in endpointTails where s.lowercased().hasSuffix(tail) {
                s.removeLast(tail.count)
                stripped = true
            }
        }
        guard let comps = URLComponents(string: s), comps.host?.isEmpty == false else { return s }
        if comps.path.isEmpty { s += "/v1" }
        return s
    }

    /// 聊天实际打的完整地址（编辑器「实际请求」预览用）。
    static func chatEndpoint(base: String, type: ProviderType) -> String? {
        let b = normalize(base, type: type)
        guard !b.isEmpty else { return nil }
        switch type {
        case .openaiCompatible: return b + "/chat/completions"
        case .anthropic: return b + "/messages"
        default: return nil
        }
    }
}
