import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 键盘/输入条/滚动诊断探针（粟粟 08-26 三 bug：终端回页错位 / 思考链慢抖 / 长文发送上移）。
/// mac 默认关，显式开启后串行后台写；iOS DEBUG 常驻写 Documents/kb-probe.log，`xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier com.susu.MemoryPalace.ios --source Documents/kb-probe.log` 拉回看。只记日志不改行为。
#if os(macOS)
final class KBProbe: @unchecked Sendable {
    private static let shared = KBProbe(url: logURL(documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)))
    static func logURL(documents: [URL]) -> URL? {
        guard let directory = documents.first else { return nil }
        return AppPaths.checked(directory.appendingPathComponent("kb-probe.log"))
    }
    static var enabled: Bool { shared.isEnabled }

    private let isEnabled: Bool
    private let url: URL?
    private let queue: DispatchQueue?
    private let lock = NSLock()
    private lazy var handle: FileHandle? = {
        guard let url else { return nil }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 50_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    init(url: URL?, defaults: UserDefaults = .standard) {
        self.url = url
        #if DEBUG
        let stanch = defaults.object(forKey: "mp.stanch.P1") as? Bool ?? true
        isEnabled = !stanch || defaults.bool(forKey: "mp.kbProbe.enabled")
        queue = isEnabled && stanch ? DispatchQueue(label: "mp.kb-probe", qos: .utility) : nil
        #else
        isEnabled = false
        queue = nil
        #endif
    }

    static func log(_ message: @autoclosure () -> String) { shared.record(message()) }

    func record(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = String(format: "%.3f ", CFAbsoluteTimeGetCurrent()) + message() + "\n"
        if let queue { queue.async { self.append(line) } } else { append(line) }
    }

    private func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if let data = line.data(using: .utf8) { try? handle?.write(contentsOf: data) }
    }

    static func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }
}
#else
enum KBProbe {
    #if DEBUG
    static let enabled = true
    #else
    static let enabled = false
    #endif

    private static let lock = NSLock()
    private static var handle: FileHandle? = {
        let directory = TestHostIsolation.active
            ? TestHostIsolation.home?.appendingPathComponent("Documents", isDirectory: true)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let docs = directory else { return nil }
        let url = docs.appendingPathComponent("kb-probe.log")
        // 09-19：她手机上这个文件已经 220MB+（devicectl 拉取封顶 220,000,000 字节，新行永远拉不到）；超 50MB 启动时截断
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 50_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func log(_ msg: @autoclosure () -> String) {
        guard enabled else { return }
        let line = String(format: "%.3f ", CFAbsoluteTimeGetCurrent()) + msg() + "\n"
        lock.lock(); defer { lock.unlock() }
        if let d = line.data(using: .utf8) { try? handle?.write(contentsOf: d) }
    }

    #if canImport(UIKit)
    static func firstResponderName(in root: UIView?) -> String {
        guard let root else { return "-" }
        if root.isFirstResponder { return String(describing: type(of: root)) }
        for sub in root.subviews {
            let n = firstResponderName(in: sub)
            if n != "-" { return n }
        }
        return "-"
    }
    #endif

    static func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }
}
#endif

