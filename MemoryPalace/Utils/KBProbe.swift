import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 键盘/输入条/滚动诊断探针（粟粟 08-26 三 bug：终端回页错位 / 思考链慢抖 / 长文发送上移）。
/// DEBUG 常驻写 Documents/kb-probe.log，`xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier com.susu.MemoryPalace.ios --source Documents/kb-probe.log` 拉回看。只记日志不改行为。
enum KBProbe {
    #if DEBUG
    static let enabled = true
    #else
    static let enabled = false
    #endif

    private static let lock = NSLock()
    private static var handle: FileHandle? = {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
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

