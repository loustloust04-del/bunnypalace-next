import Foundation

// MARK: - [Bunny patch BP-008] 大肥兔旧写法聊天卡片 → 上游新结构
//
// Caelum（走 hub，不用 App 内的 card_guide 工具）照大肥兔时代的写法出卡；迁移来的历史消息里也全是旧卡。
// 上游 ChatCard 已升级（audit/chat-cards-compat.md），几种字段对不上会解析失败、不成卡。
// 这里只在认出「旧形状」时改写 JSON，新写法原样放行：
//   todo：items 是字符串数组 → [{text, done:false}]；只有 item → 包成一项
//   ask：q → question
//   dice：count / sides / picks / result:[Int] → dice:"NdS" / options / result:{rolls,total}
//   chart：labels + values 或 series[{name, values}] → series[{name, points:[[label,value]]}]；ring → donut；缺 type → bar
//   music：song_id / query（网易云）→ title / artist / link（网易云网页）；数字 id 去掉（上游 id 是字符串）

enum BunnyLegacyCardShim {
    static func normalize(language: String, code: String) -> String {
        let lang = language.lowercased()
        let kind = lang.hasPrefix("card-") ? String(lang.dropFirst(5)) : lang
        guard ["todo", "ask", "dice", "chart", "music"].contains(kind),
              let data = code.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return code }
        var changed = false

        switch kind {
        case "todo":
            if let items = o["items"] as? [Any], items.contains(where: { $0 is String }) {
                o["items"] = items.map { item -> Any in
                    if let s = item as? String { return ["text": s, "done": false] }
                    return item
                }
                changed = true
            } else if o["items"] == nil, let one = o["item"] as? String {
                o["items"] = [["text": one, "done": false]]
                changed = true
            }
            if changed, o["title"] == nil { o["title"] = "待办" }

        case "ask":
            if o["question"] == nil, let q = o["q"] as? String { o["question"] = q; changed = true }

        case "dice":
            let legacy = o["dice"] == nil && (o["count"] != nil || o["sides"] != nil || o["picks"] != nil || (o["result"] as? [Any]) != nil)
            if legacy {
                let count = max(1, min(6, (o["count"] as? Int) ?? 1))
                let sides = max(2, min(100, (o["sides"] as? Int) ?? 6))
                let picks = (o["picks"] as? [Any])?.map { "\($0)" } ?? []
                if picks.isEmpty { o["dice"] = "\(count)d\(sides)" } else { o["options"] = picks }
                if let r = (o["result"] as? [Any])?.compactMap({ ($0 as? Int) ?? Int("\($0)") }), !r.isEmpty, picks.isEmpty {
                    o["result"] = ["rolls": r, "total": r.reduce(0, +)]
                } else {
                    o.removeValue(forKey: "result")
                }
                for k in ["count", "sides", "picks"] { o.removeValue(forKey: k) }
                if (o["title"] as? String)?.isEmpty ?? true { o["title"] = picks.isEmpty ? "掷骰子" : "抽签" }
                changed = true
            }

        case "chart":
            let labels = (o["labels"] as? [Any])?.map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }
            func points(_ values: [Any]) -> [[Any]]? {
                guard let labels else { return nil }
                let vals = values.map { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") }
                var seen = Set<String>(), out: [[Any]] = []
                for (l, v) in zip(labels, vals) {
                    guard !l.isEmpty, let v, v.isFinite, !seen.contains(l) else { continue }
                    seen.insert(l); out.append([l, v])
                }
                return out.isEmpty ? nil : out
            }
            if let values = o["values"] as? [Any], o["series"] == nil, let pts = points(values) {
                o["series"] = [["name": "", "points": pts]]
                o.removeValue(forKey: "values"); changed = true
            } else if let series = o["series"] as? [[String: Any]], series.contains(where: { $0["values"] != nil }) {
                o["series"] = series.compactMap { s -> [String: Any]? in
                    guard let vals = s["values"] as? [Any], let pts = points(vals) else { return nil }
                    return ["name": (s["name"] as? String) ?? "", "points": pts]
                }
                changed = true
            }
            if changed {
                o.removeValue(forKey: "labels")
                let t = (o["type"] as? String)?.lowercased() ?? (o["kind"] as? String)?.lowercased() ?? "bar"
                o["type"] = t == "ring" ? "donut" : t
                o.removeValue(forKey: "kind")
                if o["unit"] == nil { o["unit"] = "" }
                if o["title"] == nil { o["title"] = "" }
            }

        case "music":
            let sid = o["song_id"] ?? ((o["id"] is String) ? nil : o["id"])
            if sid != nil || o["query"] != nil {
                if (o["title"] as? String)?.isEmpty ?? true { o["title"] = (o["query"] as? String) ?? "一首歌" }
                if o["artist"] == nil { o["artist"] = "" }
                if let sid, o["link"] == nil { o["link"] = "https://music.163.com/song?id=\(sid)" }
                o.removeValue(forKey: "song_id")
                o.removeValue(forKey: "query")
                if !(o["id"] is String) { o.removeValue(forKey: "id") }
                changed = true
            }

        default:
            break
        }

        guard changed, let out = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: out, encoding: .utf8) else { return code }
        return s
    }
}
