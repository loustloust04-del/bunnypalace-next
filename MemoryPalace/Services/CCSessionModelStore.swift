import Foundation
import Observation

/// hub 的 `session_model` 帧：某个 CC / codex 会话实际在用的模型。
/// model = 短名（opus-4.6-1m），model_id = 全名（claude-opus-4-6[1m]）。app 报到时 hub 补发已知的全部，之后变了才推。
/// model 是 null = hub 不知道了（codex 换了新会话还没第一轮…）：清掉后缀
struct CCSessionModel: Equatable {
    let sessionName: String
    /// nil = 清掉
    let model: String?
    let modelId: String?

    /// 缺 session_name、缺 model 字段 / 空串 → nil（整帧忽略）；model 是 null → 清掉
    init?(frame: [String: Any]) {
        guard let session = frame["session_name"] as? String, !session.isEmpty else { return nil }
        if frame["model"] is NSNull {
            self.sessionName = session
            self.model = nil
            self.modelId = nil
            return
        }
        guard let model = frame["model"] as? String, !model.isEmpty else { return nil }
        self.sessionName = session
        self.model = model
        self.modelId = frame["model_id"] as? String ?? model
    }
}

/// 一个会话的模型：每个会话一个稳定对象，胶囊只读当前会话这一项——别的会话换模型不连带它重算。
/// 写之前比值：Observation 的 setter 不比较，写同值也会让读它的视图重算（hub 每次重连都补发一遍）。
@Observable
final class CCSessionModelEntry {
    /// 短名；hub 还没告诉过 / 清掉了 = nil（胶囊只显示卡名）
    private(set) var model: String?

    func update(_ model: String?) {
        if self.model != model { self.model = model }
    }
}

/// session_name → 模型。索引本身不是 Observable：读的时候没有就建一个空的（只动这张不被观察的表，不让任何视图重算），
/// 帧来了写进对应那一项。有界（审查 R1-9）：最多 maxEntries 项、ttl 没碰过的清掉，先清最久没碰过的；
/// 胶囊每次重算都会读一下当前会话那项，正在看的不会被清。只在 main 上用
@MainActor
final class CCSessionModelStore {
    static let shared = CCSessionModelStore()
    static let maxEntries = 256
    static let ttl: TimeInterval = 7 * 24 * 3600

    private var entries: [String: CCSessionModelEntry] = [:]
    private var touchedAt: [String: Date] = [:]

    var count: Int { entries.count }

    func entry(for sessionName: String, now: Date = Date()) -> CCSessionModelEntry {
        touchedAt[sessionName] = now
        if let e = entries[sessionName] { return e }
        prune(now: now, keep: sessionName)
        let e = CCSessionModelEntry()
        entries[sessionName] = e
        return e
    }

    func apply(_ m: CCSessionModel, now: Date = Date()) {
        entry(for: m.sessionName, now: now).update(m.model)
    }

    private func prune(now: Date, keep: String) {
        for (name, at) in touchedAt where name != keep && now.timeIntervalSince(at) > Self.ttl {
            entries[name] = nil
            touchedAt[name] = nil
        }
        guard entries.count >= Self.maxEntries else { return }
        let oldest = entries.keys.filter { $0 != keep }
            .sorted { (touchedAt[$0] ?? .distantPast) < (touchedAt[$1] ?? .distantPast) }
            .prefix(entries.count - Self.maxEntries + 1)
        for name in oldest {
            entries[name] = nil
            touchedAt[name] = nil
        }
    }

    /// 底部胶囊的字：「cc-opus-4.6-1m」（粟粟 10-11：卡名-模型名）；不知道模型就只有卡名
    nonisolated static func capsuleTitle(cardName: String, model: String?) -> String {
        guard let model, !model.isEmpty else { return cardName }
        return "\(cardName)-\(model)"
    }
}
