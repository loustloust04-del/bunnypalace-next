import Foundation

/// CC 桥连接探针（常驻，09-19 粟粟「戳一下才发过来」）：记 app 这一侧的连接生命周期和 reply 落地情况。
/// 写 Documents/bridge-probe.log，拉取：`xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier com.susu.MemoryPalace.ios --source Documents/bridge-probe.log --destination /tmp/bridge-probe.log`。
/// 只记日志不改行为；超 5MB 启动时截断。时间用本地墙钟，好跟 hub 的 /tmp/cc-hub.log 对。
enum BridgeProbe {
    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static var handle: FileHandle? = {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = docs.appendingPathComponent("bridge-probe.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func log(_ msg: @autoclosure () -> String) {
        let line = fmt.string(from: Date()) + " " + msg() + "\n"
        lock.lock(); defer { lock.unlock() }
        if let d = line.data(using: .utf8) { try? handle?.write(contentsOf: d) }
    }
}
