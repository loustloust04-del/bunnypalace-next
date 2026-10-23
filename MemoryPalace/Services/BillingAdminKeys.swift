import Foundation

enum BillingProvider: String, CaseIterable, Identifiable, Sendable {
    case openRouter, anthropic, openAI
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

}

enum BillingAdminKeys {
    // 独立 service：不混入聊天 key 的缓存、导出或旧 account 清理。
    static let service = "com.susu.MemoryPalace.billing.admin"

    static func get(_ provider: BillingProvider) -> String? {
        guard provider != .openRouter else { return nil }
        return KeychainStore.get(account: provider.rawValue, service: service)
    }

    @discardableResult
    static func set(_ value: String, provider: BillingProvider) -> Bool {
        guard provider != .openRouter else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeychainStore.set(trimmed.isEmpty ? nil : trimmed, account: provider.rawValue, sync: false, service: service)
    }
}
