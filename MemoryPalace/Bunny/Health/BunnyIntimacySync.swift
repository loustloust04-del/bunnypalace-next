import Foundation
import SwiftData
import CryptoKit

// MARK: - [Bunny] 刻痕（亲密记录）同步：网关 /api/intimacy ↔ 上游 IntimacyEntry
//
// 网关这份是大肥兔「刻痕」与 Caelum intimacy_* 工具共用的数据：按日期一条，含他写的 note、她写的 myNote、
// tags、milestone。上游 IntimacyEntry 只有「日期 + 备注」，不改上游 schema，所以：
//   网关 → 本地（主方向）：每个日期一条本地记录，备注 = 里程碑 / 标签 / 他写的 / 我写的 拼成的可读文本。
//     只覆盖「由同步写入、且之后没在本地改过」的记录（用上次写入内容的摘要判断）；本地改过的不动。
//   本地 → 网关：网关上没有的日期（她在新兔里新记的），把备注作为 myNote 推上去（Caelum 能看到）。
//     同步来的记录在本地被改过，不回推——避免拼接文本覆盖网关里分好字段的原文。
// 不同步删除。上游的亲密记录隐私开关默认关闭，数据会写入但要她自己打开才显示。

@MainActor
enum BunnyIntimacySync {
    static var lastRunAt: Date? { UserDefaults.standard.object(forKey: "bunny.intimacy.lastRunAt") as? Date }

    static func runIfDue(context: ModelContext, profileId: String, minInterval: TimeInterval = 10 * 60) async {
        guard BunnyGateway.isConfigured, !profileId.isEmpty else { return }
        if let last = lastRunAt, Date().timeIntervalSince(last) < minInterval { return }
        _ = await run(context: context, profileId: profileId)
    }

    private struct Remote: Decodable {
        let date: String
        let note: String?
        let myNote: String?
        let tags: [String]?
        let milestone: String?
        let updatedAt: String?
    }
    private struct Payload: Decodable { let entries: [String: Remote] }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 本地展示文本
    static func compose(_ r: Remote) -> String {
        var parts: [String] = []
        if let m = r.milestone?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { parts.append("✦ \(m)") }
        if let t = r.tags, !t.isEmpty { parts.append(t.map { "#\($0)" }.joined(separator: " ")) }
        if let n = r.note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { parts.append(n) }
        if let n = r.myNote?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { parts.append("—— 我写的：\n\(n)") }
        return parts.joined(separator: "\n\n")
    }

    @discardableResult
    static func run(context: ModelContext, profileId pid: String) async -> String {
        guard let data = try? await BunnyGateway.get("/api/intimacy", timeout: 60),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return "❌ 拿不到网关刻痕数据" }
        UserDefaults.standard.set(Date(), forKey: "bunny.intimacy.lastRunAt")
        let key = "bunny.intimacy.synced.\(pid)"
        var synced = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]   // 日期 → 上次写入内容的摘要
        let cal = Calendar.current
        var locals = (try? context.fetch(FetchDescriptor<IntimacyEntry>(predicate: #Predicate { $0.profileId == pid }))) ?? []
        func localFor(_ day: String) -> IntimacyEntry? {
            locals.first { dayFmt.string(from: $0.date) == day }
        }

        var created = 0, updated = 0, keptLocal = 0, pushed = 0
        for (day, r) in payload.entries {
            guard let date = dayFmt.date(from: day) else { continue }
            let text = compose(r)
            if let local = localFor(day) {
                if local.note == text { synced[day] = digest(text); continue }
                if let last = synced[day], last == digest(local.note) {
                    local.note = text                         // 同步写入、本地没改过 → 跟着网关更新
                    synced[day] = digest(text)
                    updated += 1
                } else {
                    keptLocal += 1                            // 本地自己写的或改过的，不覆盖
                }
            } else {
                let e = IntimacyEntry(profileId: pid, date: cal.startOfDay(for: date), note: text)
                context.insert(e)
                locals.append(e)
                synced[day] = digest(text)
                created += 1
            }
        }

        // 本地新记的日期 → 网关（作为她写的 myNote）
        for e in locals {
            let day = dayFmt.string(from: e.date)
            guard payload.entries[day] == nil, synced[day] == nil else { continue }
            let note = e.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? await BunnyGateway.post("/api/intimacy", json: ["date": day, "myNote": note])) != nil {
                synced[day] = digest(e.note)
                pushed += 1
            }
        }
        UserDefaults.standard.set(synced, forKey: key)
        if created + updated > 0 { try? context.save() }
        return "✅ 网关 \(payload.entries.count) 天；新建 \(created)、更新 \(updated)、保留本地改动 \(keptLocal)；推上网关 \(pushed)"
    }
}
