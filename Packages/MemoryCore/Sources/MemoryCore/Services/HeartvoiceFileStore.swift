import Foundation

// MARK: - 心声文件店：memory/heartvoice/{yyyy-MM-dd-HHmm}.md

public enum HeartvoiceFileStore {}

public extension HeartvoiceFileStore {
    private static func dir(memoryRoot: URL) -> URL {
        let d = memoryRoot
            .appendingPathComponent("heartvoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func save(text: String, reason: String, convId: String, memoryRoot: URL) {
        let content = FrontmatterCodec.render(meta: [
            ("time", FrontmatterCodec.dateFormatter.string(from: Date())),
            ("convId", convId),
            ("reason", reason.replacingOccurrences(of: "\n", with: " ")),
        ], body: text)
        let url = dir(memoryRoot: memoryRoot).appendingPathComponent("\(nameFormatter.string(from: Date())).md")
        do { try Data(content.utf8).write(to: url, options: .atomic) }
        catch { MemoryLogging.shared.log("💭 心声: ❌ 写盘失败 — \(error.localizedDescription)") }
    }

    /// 最近 N 条心声（资料卡碎碎念用）：按文件名倒序取 N 再解析（文件名即时间戳，不全量读），新→旧
    static func recentVoices(memoryRoot: URL, limit: Int) -> [(time: Date, text: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(memoryRoot: memoryRoot).path)) ?? []
        var out: [(Date, String)] = []
        for n in names.filter({ $0.hasSuffix(".md") }).sorted(by: >) {
            guard out.count < limit else { break }
            let url = dir(memoryRoot: memoryRoot).appendingPathComponent(n)
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let (_, body) = FrontmatterCodec.parse(raw), !body.isEmpty,
                  let t = nameFormatter.date(from: String(n.dropLast(3))) else { continue }
            out.append((t, body))
        }
        return out
    }

    /// 某天的全部心声（日记收割用）：(HH:mm, 正文)，按时间序
    static func voices(on day: String, memoryRoot: URL) -> [(time: String, text: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(memoryRoot: memoryRoot).path)) ?? []
        var out: [(String, String)] = []
        for n in names.sorted() where n.hasPrefix(day) && n.hasSuffix(".md") {
            let url = dir(memoryRoot: memoryRoot).appendingPathComponent(n)
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let (_, body) = FrontmatterCodec.parse(raw), !body.isEmpty else { continue }
            let hhmm = String(n.dropLast(3).suffix(4))
            let t = hhmm.count == 4 ? "\(hhmm.prefix(2)):\(hhmm.suffix(2))" : "??:??"
            out.append((t, body))
        }
        return out
    }
}
