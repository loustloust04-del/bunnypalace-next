#if DEBUG && canImport(UIKit)
import UIKit

/// 帧间隔探针（iu0901）：CADisplayLink 相邻回调 >20ms（120Hz 掉 ≥2 帧 / 60Hz 掉 1 帧）即打一行，
/// 附上最近一次 mark 及距今毫秒，用 console 定位「换行那一下」是掉帧还是列表/输入条不同步。DEBUG only。
enum HitchProbe {
    private static var link: CADisplayLink?
    private static var lastTick: CFTimeInterval = 0
    private static var lastMark = "-"
    private static var lastMarkAt: CFTimeInterval = 0

    static func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: Ticker.shared, selector: #selector(Ticker.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    static func mark(_ s: @autoclosure () -> String) {
        lastMark = s()
        lastMarkAt = CACurrentMediaTime()
    }

    final class Ticker: NSObject {
        static let shared = Ticker()
        @objc func tick(_ l: CADisplayLink) {
            let now = l.timestamp
            if lastTick > 0 {
                let gap = now - lastTick
                if gap > 0.020 {
                    let line = String(format: "[HITCH] gap=%.0fms last=%@ +%.0fms", gap * 1000, lastMark, (now - lastMarkAt) * 1000)
                    print(line)
                    KBProbe.log(line)   // 落盘：不挂 console 也能事后从设备拉
                }
            }
            lastTick = now
        }
    }
}
#endif
