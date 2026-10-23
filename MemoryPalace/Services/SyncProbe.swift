import Foundation

/// 同步链路探针（诡异 bug 早点加探针——老教训）。
/// 每跳带毫秒时间戳写 Caches/MemoryPalace/sync-probe.log，iOS 可 devicectl 拉取，Mac 直接读。
enum SyncProbe {
    private static let queue = DispatchQueue(label: "sync.probe")
    private static let maxBytes = 512 * 1024

    private static var logURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync-probe.log")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    #if os(macOS)
    private static let platform = "mac"
    #else
    private static let platform = "ios"
    #endif

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date())) [\(platform)] \(message)\n"
        print("[SYNC-PROBE] \(line)", terminator: "")
        queue.async {
            let url = logURL
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
