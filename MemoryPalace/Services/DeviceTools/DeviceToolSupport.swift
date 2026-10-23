import Foundation

/// 设备工具公共件（plan-设备工具 §1）：envelope / 参数与日期解析 / 超时 / 系统授权串行队列。
/// envelope 约定（从 Minis 抄）：成功 `{"ok":true,"data":{…}}`，失败 `{"ok":false,"error":{"code","message"}}`；
/// 给模型的是紧凑单行 JSON。超时必须产生显式 error（Minis 老代码把超时当空结果是反面教材）。

struct DeviceToolExec {
    let text: String
    let isError: Bool
}

enum DeviceToolIO {
    static func args(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// `card` = 给渲染层的结构化卡片描述（plan-设备工具 §-0.5）。
    /// 只加字段不改协议：模型看到的仍是同一份 JSON（卡片字段对它是无害噪声，也可作复述素材）；
    /// 渲染层看到 card 就出卡，看不到就维持折叠行——老对话天然兼容，不需要任何迁移。
    static func ok(_ data: [String: Any], card: [String: Any]? = nil) -> DeviceToolExec {
        var payload: [String: Any] = ["ok": true, "data": data]
        if let card { payload["card"] = card }
        return DeviceToolExec(text: compact(payload), isError: false)
    }

    /// 卡片描述构造器。type 决定渲染形状；deeplink 由渲染层按白名单校验后打开。
    static func card(type: String, title: String, subtitle: String? = nil, detail: String? = nil,
                     icon: String, deeplink: String? = nil, imagePath: String? = nil,
                     eventId: String? = nil, occurrence: Date? = nil) -> [String: Any] {
        var c: [String: Any] = ["type": type, "title": title, "icon": icon]
        if let subtitle { c["subtitle"] = subtitle }
        if let detail { c["detail"] = detail }
        if let deeplink { c["deeplink"] = deeplink }
        if let imagePath { c["image_path"] = imagePath }
        // event_id 给渲染层开**系统原生事件卡**（EKEventViewController）用；deeplink 是没有它时的回落
        if let eventId { c["event_id"] = eventId }
        if let occurrence { c["occurrence"] = iso(occurrence) }
        return c
    }

    /// 系统 app 深链：日历按天定位用 `calshow:` + 参考日期秒数（2001-01-01 起）。
    static func calendarDeeplink(for date: Date) -> String {
        "calshow:\(Int(date.timeIntervalSinceReferenceDate))"
    }
    static let remindersDeeplink = "x-apple-reminderkit://"

    /// code 固定集合：missing_param / invalid_param / authorization_denied / timeout / not_found / not_available / failed
    static func fail(_ code: String, _ message: String) -> DeviceToolExec {
        DeviceToolExec(text: compact(["ok": false, "error": ["code": code, "message": message]]), isError: true)
    }

    static func compact(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{\"ok\":false}" }
        return s
    }

    static func str(_ a: [String: Any], _ k: String) -> String? {
        (a[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    static func int(_ a: [String: Any], _ k: String) -> Int? {
        if let i = a[k] as? Int { return i }
        if let d = a[k] as? Double { return Int(d) }
        if let s = a[k] as? String { return Int(s) }
        return nil
    }
    static func bool(_ a: [String: Any], _ k: String) -> Bool? {
        if let b = a[k] as? Bool { return b }
        if let s = a[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) ? true : (["false", "0", "no"].contains(s.lowercased()) ? false : nil) }
        return nil
    }

    // MARK: 日期（Minis 约定：ISO 8601 / 相对 -7d +2h +30m / today tomorrow；无时区按设备本地；输出本地 ISO）

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoLocal: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()
    private static let isoLocalMinute: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; return f
    }()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let outFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"; return f   // 带秒+时区：自家 parser（isoFull）可回读
    }()

    static func parseDate(_ raw: String?, now: Date = Date()) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let cal = Calendar.current
        switch s.lowercased() {
        case "now": return now
        case "today": return cal.startOfDay(for: now)
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        default: break
        }
        // 相对：[+-]N[mhdw]
        if let m = s.range(of: #"^([+-])(\d+)([mhdw])$"#, options: .regularExpression) {
            let body = String(s[m])
            let sign: Double = body.hasPrefix("-") ? -1 : 1
            let n = Double(body.dropFirst().dropLast()) ?? 0
            let unit: Double = switch body.last! { case "m": 60; case "h": 3600; case "d": 86400; default: 604800 }
            return now.addingTimeInterval(sign * n * unit)
        }
        if let d = isoFull.date(from: s) { return d }
        if let d = isoLocal.date(from: s) { return d }
        if let d = isoLocalMinute.date(from: s) { return d }
        if let d = dayOnly.date(from: s) { return d }
        return nil
    }

    static func iso(_ d: Date) -> String { outFormatter.string(from: d) }

    // MARK: 超时

    /// 超时返回 nil——调用方必须把 nil 转成显式 timeout error，不能当空结果。
    static func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 系统授权串行队列（Minis Calendar/Photos/HealthKit 同款纪律）：一次只让一个系统授权 sheet 出现，
/// 每次完成留 0.5s 让系统授权 VC 消失；单次授权等待上限 30s，超时视为未授权（不落任何持久状态）。
actor SystemAuthQueue {
    static let shared = SystemAuthQueue()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ op: @escaping @Sendable () async -> T) async -> T? {
        if busy {
            await withCheckedContinuation { c in waiters.append(c) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        let result = await DeviceToolIO.withTimeout(seconds: 30, op)
        try? await Task.sleep(nanoseconds: 500_000_000)
        return result
    }
}
