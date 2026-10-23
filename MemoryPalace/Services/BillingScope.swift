import Foundation
import CryptoKit

enum BillingKeyIdentity {
    static func hash(_ key: String, host: String) -> String {
        let data = Data((host.lowercased() + "\u{0}" + key).utf8)
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct BillingScope {
    let records: [UsageRecord]
    let verified: Bool

    static func openRouter(records: [UsageRecord], identity: String, since: Date) -> BillingScope {
        let recent = records.filter { $0.time >= since && $0.providerType == ProviderType.openaiCompatible.rawValue }
        // 旧行没有 key 身份，换 key / 删卡后不能用当前卡片反推历史归属。
        return BillingScope(records: recent.filter { $0.keyIdentity == identity },
                            verified: !recent.contains { $0.keyIdentity == nil && $0.requestSent != false && !$0.subscription && !$0.tokensOnly })
    }
}
