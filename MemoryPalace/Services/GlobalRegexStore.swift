import Foundation
import Observation

/// 全局正则（卡库 ⑤b，plan §1.1）：有序 `[RegexScript]`，UserDefaults 独立 key 存 JSON，和 `savedPresets` 同一存法。
/// 执行链里排第一（`RegexPipeline.scripts` → `resolve(global:)`）；进全局备份（GlobalExporter / PendingImportApplier）。
@Observable
final class GlobalRegexStore {
    static let storageKey = "globalRegexScripts_v1"
    static let shared = GlobalRegexStore()

    private(set) var scripts: [RegexScript]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadError: Error?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            scripts = try defaults.data(forKey: Self.storageKey).map { try JSONDecoder().decode([RegexScript].self, from: $0) } ?? []
        } catch {
            scripts = []
            loadError = error
            NSLog("全局正则读取失败，保留原数据并阻止覆盖：%@", error.localizedDescription)
        }
    }

    /// 写入成功后才发布；读取失败过就拒绝写，不拿空列表盖掉原数据
    func save(_ next: [RegexScript]) throws {
        if let loadError { throw loadError }
        defaults.set(try JSONEncoder().encode(next), forKey: Self.storageKey)
        scripts = next
    }
}
