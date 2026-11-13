import Foundation

public enum FragmentPool {
    /// 「2026-10-22」：四位年 - 两位月 - 两位日、日历上真有这天（2-30 这种不算）
    public static func validDay(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), t.count == 10,
              t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = MemoryDay.date(ofKey: t) else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) == t ? t : nil
    }

    /// 整包正好一个 JSON 对象，只容一层 ```json（或 ```）围栏；别的字一律不合格。返回去掉围栏的对象文本。
    /// 开头那一块 `<think>…</think>`（模型开了思考）先剥掉再按上面的规则判；没收尾的不合格
    public static func strictObjectText(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<think>") {
            guard let end = t.range(of: "</think>") else { return nil }
            t = t[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.hasPrefix("```") {
            guard t.hasSuffix("```"), t.count >= 6 else { return nil }
            t = String(t.dropFirst(3).dropLast(3))
            if t.hasPrefix("json") { t = String(t.dropFirst(4)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("```") { return nil }
        }
        guard t.hasPrefix("{"), t.hasSuffix("}") else { return nil }
        return t
    }
}
