import Foundation

/// 考古语料索引（CR-3 P3）。语料 = `Resources/vocab-corpus/%04d-{word}.md`，
/// xcodegen 平铺进 bundle root（与 ngsl 同款行为），按文件名 pattern 过滤建索引。
/// 增量语料由 cc-bridge 续写触发器夜跑写 repo，随下次装包到达设备。
enum VocabCorpusStore {

    /// word（小写）→ 语料 URL。首次访问构建一次（几百条，枚举 + 文件名解析，毫秒级）。
    /// ⚠️ urls(forResourcesWithExtension:subdirectory:) 对不存在的子目录返回**空数组不是 nil**，
    /// `??` 回落永不触发——上线起 index 一直是空的（"abolish 看不见"07-10 事故），显式判空回落。
    private static let index: [String: URL] = {
        var urls = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: "vocab-corpus") ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        }
        var map: [String: URL] = [:]
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            // 语料命名 %04d-word（word 可含连字符）；bundle 里其他 md 不匹配自然排除
            let parts = name.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 4, Int(parts[0]) != nil else { continue }
            map[String(parts[1]).lowercased()] = url
        }
        print("[PROBE] vocab corpus index: \(map.count) entries")
        return map
    }()

    static func markdown(for word: String) -> String? {
        // R3-3 live 覆盖层优先：考古按钮产物即刻可见，装包后 bundle 追上
        for url in liveURLs(for: word) {
            if let live = try? String(contentsOf: url, encoding: .utf8), !live.isEmpty {
                return live
            }
        }
        guard let url = index[word.lowercased()] else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    static func hasCorpus(for word: String) -> Bool {
        index[word.lowercased()] != nil
            || liveURLs(for: word).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - R3-3 live 覆盖层（考古按钮回投落地）

    /// iOS = 沙盒 Documents；macOS 没沙盒，Documents 是用户的「文稿」，#054 起写 Application Support（App 自己的目录）
    private static var liveDir: URL {
        #if os(macOS)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("vocab-corpus-live", isDirectory: true)
        #else
        let dir = documentsLiveDir
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var documentsLiveDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vocab-corpus-live", isDirectory: true)
    }

    private static func fileName(for word: String) -> String {
        let safe = word.lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).md"
    }

    private static func liveURL(for word: String) -> URL {
        liveDir.appendingPathComponent(fileName(for: word))
    }

    /// 读：新目录优先；macOS 再看 #054 之前写在 ~/Documents 的旧篇（只读，不搬不删）
    private static func liveURLs(for word: String) -> [URL] {
        #if os(macOS)
        [liveURL(for: word), documentsLiveDir.appendingPathComponent(fileName(for: word))]
        #else
        [liveURL(for: word)]
        #endif
    }

    @discardableResult
    static func saveLive(word: String, markdown: String) -> Bool {
        do {
            try Data(markdown.utf8).write(to: liveURL(for: word), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
