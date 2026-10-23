import Foundation
import Observation

/// 操作面包屑：全局轨迹环形缓冲（最近 80 条），开发者调试用。
/// 上架版反馈不再带出（保护用户隐私）；本地仅作调试日志。
/// UserDefaults 持久化，跨重启保留"重启前的轨迹"（崩溃排查锚点）。
/// 可从任意线程调 add()；修改一律在主线程串行执行。
@Observable
final class BreadcrumbLog {
    static let shared = BreadcrumbLog()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let time: Date
        let icon: String
        let text: String
    }

    private(set) var entries: [Entry] = []

    private static let capacity = 80
    private static let storeKey = "breadcrumbLog"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ icon: String, _ text: String) {
        // 备份等后台队列也会调 add：对 live 数组的修改统一回主线程（astra R2 B1，原有竞态）
        guard Thread.isMainThread else {
            let time = Date()
            DispatchQueue.main.async { self.append(Entry(time: time, icon: icon, text: text)) }
            return
        }
        append(Entry(time: Date(), icon: icon, text: text))
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        // perf-flash：编码 80 条 + 写偏好挪到串行后台队列（翻页 / 开对话 / 启动都在主线程调 add）；
        // 立即派发不攒批，尽力而为——崩溃瞬间队列里还没落盘的几条可能丢
        let snapshot = entries
        Self.writeQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.storeKey)
            }
        }
    }

    private static let writeQueue = DispatchQueue(label: "com.susu.MemoryPalace.breadcrumb", qos: .utility)

    /// 反馈快照用：时间序文本块
    func formattedDump() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return entries.map { "\(formatter.string(from: $0.time)) \($0.icon) \($0.text)" }
            .joined(separator: "\n")
    }
}
