#if os(iOS)
import SwiftUI
import UIKit

/// perf-flash C3b：交互时才用的窗口坐标，由 UIKit 在用的那一刻现量（`convert(bounds, to: nil)`）。
/// 原来这几处用 `.onGeometryChange(... .frame(in: .global))` 持续订阅全局坐标——外层三页翻页每帧平移
/// page2 容器，全局坐标每帧都变，整页 SwiftUI 跟着逐帧更新（实测翻页动画期主线程 ~75ms / 次）。
/// 探针本身不进 SwiftUI 观察链，外层怎么平移都零成本。
final class WindowFrameProbe {
    fileprivate weak var view: UIView?
    /// 此刻在窗口里的位置；还没进窗口返回 nil
    var windowFrame: CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

/// 按 id 取探针（dock 每个图标一个），懒建、只增不减——id 是桌面条目 UUID，量级几十
final class WindowFrameProbeSet {
    private var probes: [UUID: WindowFrameProbe] = [:]
    func probe(for id: UUID) -> WindowFrameProbe {
        if let p = probes[id] { return p }
        let p = WindowFrameProbe()
        probes[id] = p
        return p
    }
    subscript(id: UUID) -> WindowFrameProbe? { probes[id] }
}

struct WindowFrameProbeView: UIViewRepresentable {
    let probe: WindowFrameProbe

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.accessibilityElementsHidden = true
        probe.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { probe.view = view }
}
#endif
