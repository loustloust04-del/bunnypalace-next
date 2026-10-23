import Foundation

// MARK: - Debug render modes
//
// 用于调查 iOS wallpaper 在 safe area 漏白 + 页码点飘位置的真正根因。
// 每个模式对应 docs/research-ios-wallpaper-safearea-root-cause-2026-04-19.md 里的一条候选 fix。
// 粟粟在「设置 → 开发调试」里切换，肉眼对比哪个组合真修好。
// 上架前全部删除（本文件 + SettingsView 那个 tab + ThemeBackgroundView/ContentView 里的 switch）。

enum DebugThemeBackgroundMode: String, CaseIterable, Identifiable {
    /// 当前实现：GeometryReader + 内层 .frame(width:height:) + .clipped()。Bug 所在。
    case original
    /// A. 去掉 GeometryReader，ZStack 自己用 .frame(maxWidth/maxHeight: .infinity) 撑满。
    case noGeometryReader
    /// B. GeometryReader 自己加 .ignoresSafeArea()，proxy.size 全屏，ZStack 按 proxy.size 撑。
    case grIgnoresSafeArea
    /// C. 改成 ContentView ZStack 底层 layer（不再走 .background），避免 background 的 parent-size 约束。
    case zstackLayer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "原版（GeometryReader + frame + clipped）"
        case .noGeometryReader: "A. 不用 GeometryReader"
        case .grIgnoresSafeArea: "B. GR 自己 ignoresSafeArea"
        case .zstackLayer: "C. ZStack 底层 layer"
        }
    }
}

enum DebugRenderSettings {
    static let themeBackgroundModeKey = "debug.themeBackgroundMode"
}
