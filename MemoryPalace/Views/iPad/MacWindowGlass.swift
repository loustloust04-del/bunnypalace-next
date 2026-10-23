import SwiftUI

#if os(macOS)
import AppKit

/// 窗口玻璃（plan-mac-glass-chrome）：停靠壳正文卡以外的地方透出桌面，像 Otty 的 glass 主题。
/// 色偏只由窗底那一层上，壳内各层一律清空（`ShellStyle.chrome`），不各自叠半透明。
@MainActor
@Observable
final class MacGlass {
    static let shared = MacGlass()
    static let enabledKey = "macWindowGlass"
    static let tintKey = "macWindowGlassTint"
    static let defaultTint = 0.25

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    /// 0 = 纯玻璃，越高越接近 sidebarBg 实底
    var tint: Double {
        didSet { UserDefaults.standard.set(tint, forKey: Self.tintKey) }
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
        tint = d.object(forKey: Self.tintKey) as? Double ?? Self.defaultTint
    }
}

/// 整扇窗的底：开 → macOS 26 `NSGlassEffectView` / 15 `NSVisualEffectView(.behindWindow)` + 一层 sidebarBg 色偏；
/// 关 → sidebarBg 实底（= 改之前的桌布）。窗口透明与否由 `WindowConfigurator` 跟着同一个开关切。
struct MacWindowBackdrop: NSViewRepresentable {
    let enabled: Bool
    let tint: Double
    let color: NSColor

    func makeNSView(context: Context) -> BackdropView { BackdropView() }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.apply(enabled: enabled, tint: tint, color: color)
    }

    final class BackdropView: NSView {
        private var effect: NSView?
        private let tintLayer = NSView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            tintLayer.wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }


        func apply(enabled: Bool, tint: Double, color: NSColor) {
            if !enabled {
                effect?.removeFromSuperview(); effect = nil
                tintLayer.removeFromSuperview()
                layer?.backgroundColor = color.cgColor
                return
            }
            layer?.backgroundColor = nil
            let tinted = color.withAlphaComponent(tint)
            if #available(macOS 26.0, *) {
                let glass = (effect as? NSGlassEffectView) ?? install(NSGlassEffectView())
                glass.cornerRadius = 0
                glass.tintColor = tinted
            } else {
                let vibrancy = (effect as? NSVisualEffectView) ?? install(NSVisualEffectView())
                vibrancy.blendingMode = .behindWindow
                vibrancy.material = .sidebar
                vibrancy.state = .followsWindowActiveState
                if tintLayer.superview == nil { addSubview(tintLayer, positioned: .above, relativeTo: vibrancy) }
                tintLayer.frame = bounds
                tintLayer.autoresizingMask = [.width, .height]
                tintLayer.layer?.backgroundColor = tinted.cgColor
            }
        }

        private func install<V: NSView>(_ view: V) -> V {
            effect?.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: nil)
            effect = view
            return view
        }
    }
}
#endif
