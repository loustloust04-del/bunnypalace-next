#if os(iOS) && (DEBUG || PERF_BENCH)
import UIKit

/// 有限诊断：只记录停靠/接近停靠及尺寸变化，不长期轮询页面。
@MainActor
enum PagingScreenFitProbe {
    private static let enabled = ProcessInfo.processInfo.environment["MP_SCREEN_FIT_PROBE"] == "1"
    private static var count = 0
    private static var lastKey = ""
    private static var lastBand = ""

    static func capture(root: UIView, stage: UIView, pages: [UIView], hosts: [UIView], current: Int, position: CGFloat) {
        guard enabled, count < 60, let window = root.window else { return }
        let distance = abs(position - position.rounded()) * root.bounds.width
        guard distance <= 60 else { return }
        let docked = abs(position - position.rounded()) <= 0.0001
        let band = "\(Int(floor(position))):\(Int((distance / 10).rounded()))"
        if !docked && band == lastBand { return }
        func rect(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        func info(_ view: UIView) -> [String: Any] {
            let t = view.layer.affineTransform()
            return ["bounds": rect(view.bounds), "windowRect": rect(view.convert(view.bounds, to: window)),
                    "presentationRadius": Double(view.layer.presentation()?.cornerRadius ?? view.layer.cornerRadius),
                    "presentationAvailable": view.layer.presentation() != nil,
                    "radius": Double(view.layer.cornerRadius), "transform": [Double(t.a), Double(t.d), Double(t.tx), Double(t.ty)],
                    "safeArea": [Double(view.safeAreaInsets.top), Double(view.safeAreaInsets.left), Double(view.safeAreaInsets.bottom), Double(view.safeAreaInsets.right)]]
        }
        var data: [String: Any] = ["page": current, "position": Double(position),
            "window": rect(window.bounds), "root": info(root), "stage": info(stage),
            "containers": pages.map(info), "hosts": hosts.map(info)]
        guard let keyData = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let key = String(data: keyData, encoding: .utf8), key != lastKey else { return }
        lastKey = key
        lastBand = band
        count += 1
        data["record"] = count
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let text = String(data: json, encoding: .utf8) else { return }
        print("SCREEN_FIT \(text)")
    }
}
#endif
