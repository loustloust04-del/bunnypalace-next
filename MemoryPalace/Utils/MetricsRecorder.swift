#if DEBUG || PERF_BENCH
import Foundation
import MetricKit
import CryptoKit

/// MetricKit 订阅（plan-perf-watch §3.1）：日报 / 诊断 payload 原样（jsonRepresentation）落盘到
/// Application Support/MemoryPalace/Metrics/，不上网、不接 SDK；host 用 scripts/perf/metrics-pull.sh 拉走。
/// 只进 Debug + PERF 包（粟粟 09-28 拍板 Q3）。测试宿主与 PERF 测量进程不订阅。
final class MetricsRecorder: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsRecorder()
    private let queue = DispatchQueue(label: "com.susu.MemoryPalace.metrics", qos: .utility)
    private let maxFiles = 400
    private let maxBytes = 20 * 1024 * 1024

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/Metrics", isDirectory: true)
    }

    func start() {
        let env = ProcessInfo.processInfo.environment
        let measuring = ["MP_PERF_RUN", "MP_PERF_OBSERVE", "MP_PERF_SEED", "MP_PERF_RESTORE"].contains { env[$0] != nil }
        guard env["XCTestConfigurationFilePath"] == nil, !measuring else { return }
        let manager = MXMetricManager.shared
        manager.add(self)
        let metrics = manager.pastPayloads.map { $0.jsonRepresentation() }
        let diagnostics = manager.pastDiagnosticPayloads.map { $0.jsonRepresentation() }
        queue.async {
            metrics.forEach { self.save($0, kind: "metric", via: "past") }
            diagnostics.forEach { self.save($0, kind: "diagnostic", via: "past") }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let data = payloads.map { $0.jsonRepresentation() }
        queue.async { data.forEach { self.save($0, kind: "metric", via: "callback") } }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let data = payloads.map { $0.jsonRepresentation() }
        queue.async { data.forEach { self.save($0, kind: "diagnostic", via: "callback") } }
    }

    private func save(_ data: Data, kind: String, via: String) {
        let fm = FileManager.default
        let dir = Self.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard !existing.contains(where: { $0.hasSuffix("-\(hash.prefix(12)).json") }) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "\(kind)-\(stamp)-\(hash.prefix(12)).json"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("[MetricsRecorder] write failed: \(error)")
            return
        }
        let info = Bundle.main.infoDictionary
        let receipt: [String: Any] = [
            "file": name, "sha256": hash, "kind": kind, "via": via,
            "receivedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
            "appBuild": info?["CFBundleVersion"] as? String ?? "",
        ]
        if let line = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
            let url = dir.appendingPathComponent("receipts.jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line + Data("\n".utf8))
                try? handle.close()
            } else {
                try? (line + Data("\n".utf8)).write(to: url)
            }
        }
        prune(dir)
    }

    private func prune(_ dir: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var files = urls.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = files.reduce(0) { $0 + $1.2 }
        while files.count > maxFiles || total > maxBytes, let oldest = files.popLast() {
            try? fm.removeItem(at: oldest.0)
            total -= oldest.2
        }
    }
}
#endif
