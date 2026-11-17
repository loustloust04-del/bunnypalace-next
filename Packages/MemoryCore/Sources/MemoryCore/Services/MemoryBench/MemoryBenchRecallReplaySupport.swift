import Foundation

/// 本地重放的纯函数部分（执行壳留在 app：`MemoryBenchLocalExecutor` 扩展）。
public enum MemoryBenchLocalExecutor {
    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static func preferencesSuite(named name: String) -> String {
        #if os(macOS)
        // Explicit file domains avoid cfprefsd recreating an empty named suite after unlink.
        return FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        #else
        return name
        #endif
    }

    public static func removePreferences(_ defaults: UserDefaults, suite: String) {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        #if os(macOS)
        if suite.hasPrefix("/") {
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        #else
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: library.appendingPathComponent("Preferences/\(suite).plist"))
        }
        #endif
    }

    public static func resolve(_ value: MemoryBenchJSON, previous: RecallTool.ExecResult?) throws -> MemoryBenchJSON {
        switch value {
        case .string(let reference) where reference.hasPrefix("$prev"):
            guard let previous else { throw Failure("$prev 没有前一结果") }
            if reference == "$prev.cursor", let cursor = previous.cursor { return .string(cursor) }
            let pattern = #"^\$prev\.targets\[(\d+)\](?:\.(.+))?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: reference, range: NSRange(reference.startIndex..., in: reference)),
                  let range = Range(match.range(at: 1), in: reference), let index = Int(reference[range]), previous.targets.indices.contains(index) else {
                throw Failure("无效引用：\(reference)")
            }
            var result = try MemoryBench.decoder.decode(MemoryBenchJSON.self, from: RecallTool.encoder.encode(previous.targets[index]))
            if let field = Range(match.range(at: 2), in: reference) {
                for key in reference[field].split(separator: ".").map(String.init) {
                    guard case .object(let object) = result, let next = object[key] else { throw Failure("引用字段不存在：\(reference)") }
                    result = next
                }
            }
            return result
        case .array(let values): return .array(try values.map { try resolve($0, previous: previous) })
        case .object(let values): return .object(try values.mapValues { try resolve($0, previous: previous) })
        default: return value
        }
    }

    public static func position(_ cursor: RecallTool.Cursor?) -> [Int] {
        guard let cursor else { return [0, 0, 0, 0, 0] }
        let wiki = cursor.wiki.flatMap { try? MemoryBenchJSON.from($0) }
        var p = 0, o = 0
        if case .object(let fields) = wiki {
            if case .number(let value) = fields["position"] { p = Int(value) }
            if case .number(let value) = fields["offset"] { o = Int(value) }
        }
        return [Int((cursor.day ?? "").replacingOccurrences(of: "-", with: "")) ?? 0, cursor.position, cursor.offset, p, o]
    }
}
