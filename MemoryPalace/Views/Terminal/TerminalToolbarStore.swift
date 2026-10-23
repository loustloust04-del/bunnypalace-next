import Foundation
import Combine

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 工具条布局的持久化 + 实时同步（plan §C1）。设置页改布局 → 工具条经 Combine 即时重建。
///
/// 自己的 schema，**不跟 rootshell 的 UserDefaults 数据互通**（物料表 ASK6 裁决：没有导入场景）。
/// 跨平台无 UIKit 依赖 —— 单测 target 跑在 macOS 上。
final class TerminalToolbarStore: ObservableObject {
    static let shared = TerminalToolbarStore()

    enum Keys {
        static let layout = "terminalToolbarLayout"
        static let customKeys = "terminalToolbarCustomKeys"
        static let drawerToggleMode = "terminalToolbarDrawerToggleMode"
        /// 老的 8 键工具条。迁移读一次就不再写（迁移完成的标记 = `layout` 已落盘）。
        static let legacyKeys = "ccTerminalKeys"
    }

    @Published private(set) var layout: TerminalToolbarLayout
    @Published private(set) var customKeys: [TerminalCustomKey]
    /// 「…」的展开方式。缺省 stack（物料表 §6.2）。
    @Published var drawerToggleMode: TerminalDrawerToggleMode {
        didSet { defaults.set(drawerToggleMode.rawValue, forKey: Keys.drawerToggleMode) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.load(from: defaults)
        self.layout = loaded.layout
        self.customKeys = loaded.customKeys
        self.drawerToggleMode = (defaults.string(forKey: Keys.drawerToggleMode))
            .flatMap(TerminalDrawerToggleMode.init(rawValue:)) ?? .stack
        if loaded.needsPersist { persist() }
    }

    /// 抽屉行数 1-5（物料表 §6.1）。加行追加空行；减行时被删行的键并进最后一个保留行，不丢键。
    func setDrawerRowCount(_ count: Int) {
        let target = min(5, max(1, count))
        var rows = layout.drawerRows
        guard rows.count != target else { return }
        if rows.count < target {
            rows.append(contentsOf: Array(repeating: [], count: target - rows.count))
        } else {
            let dropped = rows[target...].flatMap { $0 }
            rows = Array(rows[..<target])
            rows[target - 1].append(contentsOf: dropped)
        }
        var next = layout
        next.drawerRows = rows
        setLayout(next)
    }

    // MARK: 读盘 / 迁移

    private struct Loaded {
        var layout: TerminalToolbarLayout
        var customKeys: [TerminalCustomKey]
        /// 首次迁移出来的结果要立刻落盘，否则每次启动都重迁一遍
        var needsPersist: Bool
    }

    private static func load(from defaults: UserDefaults) -> Loaded {
        let custom = (defaults.data(forKey: Keys.customKeys))
            .flatMap { try? JSONDecoder().decode([TerminalCustomKey].self, from: $0) } ?? []

        if let data = defaults.data(forKey: Keys.layout),
           let decoded = try? JSONDecoder().decode(TerminalToolbarLayout.self, from: data) {
            return Loaded(layout: decoded, customKeys: custom, needsPersist: false)
        }

        // 没有新布局 = 第一次跑新工具条 → 迁移老的 `ccTerminalKeys`
        let migrated = migrateLegacyKeys(from: defaults)
        var layout = TerminalToolbarLayout.default
        if !migrated.isEmpty {
            layout.drawerRows[0].append(contentsOf: migrated.map { .custom($0.id) })
        }
        return Loaded(layout: layout, customKeys: custom + migrated, needsPersist: true)
    }

    /// 老工具条的键（`{label, bytes}`）迁成 `CustomKey`，进 Drawer 0 末尾。
    /// 粟粟批注 §五-5：✅ 迁移保留。
    ///
    /// 跟老默认键同字节的跳过 —— 那些在新布局里已经有内建键（Esc/Tab/⇧Tab/四方向），
    /// 迁过来只会得到一排重复键。**⌃C 这类老默认里有、新内建里没有的照迁**
    /// （新模型里它是 Ctrl 粘滞 + c，但一键直发是粟粟的高频习惯，别弄丢）。
    static func migrateLegacyKeys(from defaults: UserDefaults) -> [TerminalCustomKey] {
        guard let data = defaults.data(forKey: Keys.legacyKeys),
              let old = try? JSONDecoder().decode([LegacyTerminalKey].self, from: data)
        else { return [] }

        let covered: Set<[UInt8]> = [
            [0x1B],                    // Esc
            [0x09],                    // Tab
            [0x1B, 0x5B, 0x5A],        // ⇧Tab = ESC[Z（新模型里 Shift 粘滞 + Tab 合成得到）
            [0x1B, 0x5B, 0x41],        // ↑
            [0x1B, 0x5B, 0x42],        // ↓
            [0x1B, 0x5B, 0x44],        // ←
            [0x1B, 0x5B, 0x43],        // →
        ]

        return old.compactMap { key -> TerminalCustomKey? in
            guard !covered.contains(key.bytes), !key.bytes.isEmpty else { return nil }
            guard let step = textStep(for: key.bytes) else { return nil }
            return TerminalCustomKey(label: key.label, sequence: [step])
        }
    }

    /// 老键的字节 → `.text` step。
    ///
    /// 老键的字节**全都 < 0x80**（默认集是 ESC/控制码/CSI 序列；设置页能造出来的只有
    /// `ascii & 0x1f` 的 Ctrl 组合和固定 specials 表 —— `TerminalSettingsTab.swift:107-123,191`），
    /// 而 < 0x80 的标量 UTF-8 编码就是它自己，所以 `.text` 往返无损，不用为迁移新造一种 step 类型。
    /// ≥ 0x80 的字节走不到（真出现就丢弃，别悄悄发出去一串被重编码的乱字节）。
    private static func textStep(for bytes: [UInt8]) -> TerminalSequenceStep? {
        guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        let scalars = bytes.map { Character(UnicodeScalar($0)) }
        return .text(String(scalars))
    }

    /// 老工具条的键结构，只为迁移解码用。
    struct LegacyTerminalKey: Codable {
        var id: UUID?
        var label: String
        var bytes: [UInt8]
    }

    // MARK: 写盘

    private func persist() {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: Keys.layout)
        }
        if let data = try? JSONEncoder().encode(customKeys) {
            defaults.set(data, forKey: Keys.customKeys)
        }
    }

    func setLayout(_ newLayout: TerminalToolbarLayout) {
        var next = newLayout
        if next.drawerRows.isEmpty { next.drawerRows = [[]] }
        layout = next
        persist()
    }

    func setCustomKeys(_ keys: [TerminalCustomKey]) {
        customKeys = keys
        persist()
    }

    func customKey(_ id: UUID) -> TerminalCustomKey? {
        customKeys.first { $0.id == id }
    }

    /// 恢复默认布局。**自定义键的定义保留**（rootshell 注释说保留、代码却 `customKeys = []`
    /// 全删——物料表 §7.3 实锤的 bug，不抄）。它们只是离开布局，去 Hidden 区还能点回来。
    func resetToDefaults() {
        layout = .default
        persist()
    }

    var isCustomized: Bool { layout != .default || !customKeys.isEmpty }
}

/// 「…」按一下做什么：stack = 每按一次多显示一行；cycle = 始终只显示一行，内容换下一行。
/// 缺省 stack（物料表 §6.2）。
enum TerminalDrawerToggleMode: String, CaseIterable, Codable, Sendable {
    case stack
    case cycle

    var label: String {
        switch self {
        case .stack: return "叠加"
        case .cycle: return "轮换"
        }
    }
}

/// 抽屉运行时状态（物料表 §6.1）。
///
/// rootshell 还有一个 `.arrows` 态（专门装四个方向键的那行），**这里没有** ——
/// 它的唯一触发点是 joystick 键的 drawer 模式，而粟粟批注 §五-4 明确「只 joystick，
/// 不抄 1.5s 切双模式」。触发点没了 `.arrows` 就是不可达状态，不留死码。
/// 四个方向键改为默认放在 Drawer 0（任务书 C5），照样一按就有。
enum TerminalDrawerState: Equatable, Sendable {
    case closed
    /// 叠加：显示第 0..<count 行，新开的在最上面
    case stacked(count: Int)
    /// 轮换：始终只显示一行，内容是第 index 行
    case cycling(index: Int)

    /// 当前该显示哪几行，**按从上到下的排列顺序**。
    /// 叠加时新增的在最上面，Drawer 1（index 0）始终贴着主行（物料表 §6.2）。
    func visibleRowIndices(rowCount: Int) -> [Int] {
        switch self {
        case .closed: return []
        case .stacked(let c): return Array((0..<min(max(1, c), max(1, rowCount))).reversed())
        case .cycling(let i): return [min(max(0, i), max(0, rowCount - 1))]
        }
    }

    /// 宽度重建后把 count/index 夹回当前行数（物料表 §6.1）
    func clamped(rowCount: Int) -> TerminalDrawerState {
        let n = max(1, rowCount)
        switch self {
        case .closed: return .closed
        case .stacked(let c): return .stacked(count: min(max(1, c), n))
        case .cycling(let i): return .cycling(index: min(max(0, i), n - 1))
        }
    }

    /// 按一下「…」。抽屉开着时在设置里换了模式，下一次按**直接回 closed**，
    /// 不在当前打开状态原地转模式（物料表 §6.2 末条）。
    func advanced(mode: TerminalDrawerToggleMode, rowCount: Int) -> TerminalDrawerState {
        let n = max(1, rowCount)
        switch (mode, self) {
        case (.stack, .closed):            return .stacked(count: 1)
        case (.stack, .stacked(let c)):    return c >= n ? .closed : .stacked(count: c + 1)
        case (.stack, .cycling):           return .closed
        case (.cycle, .closed):            return .cycling(index: 0)
        case (.cycle, .cycling(let i)):    return i + 1 >= n ? .closed : .cycling(index: i + 1)
        case (.cycle, .stacked):           return .closed
        }
    }
}

// MARK: - 容量与溢出

/// 主行容量算完后的实际渲染物料（物料表 §1.4）。
struct TerminalToolbarResolvedLayout: Equatable {
    var mainRow: [TerminalKeySlot]
    var drawerRows: [[TerminalKeySlot]]
    /// 主行放得下几个（设置页 header 显示 `count/capacity`，超了标橙）
    var capacity: Int
}

enum TerminalToolbarCapacity {
    /// 主行容量 = 可用宽 / normalWidth 取整，**不管键本身是宽键还是普通键、也不算 spacing**
    /// —— 照抄 rootshell（`KeyboardToolbarManager.swift:241-254`，物料表 §9.3）。
    static func capacity(availableWidth: CGFloat, normalWidth: CGFloat) -> Int {
        guard normalWidth > 0, availableWidth > 0 else { return 1 }
        return max(1, Int(availableWidth / normalWidth))
    }

    /// 把配置层布局算成实际渲染布局：
    /// 1. 主行超容量 → 尾部溢出槽位塞进 Drawer 0 **头部**
    /// 2. 有抽屉内容且用户没显式隐藏 `drawerToggle` → 强制把它留在主行；必要时顶掉主行最后一键，
    ///    被顶的键也进 Drawer 0 头部
    static func resolve(layout: TerminalToolbarLayout,
                        availableWidth: CGFloat,
                        normalWidth: CGFloat) -> TerminalToolbarResolvedLayout {
        let cap = capacity(availableWidth: availableWidth, normalWidth: normalWidth)
        var main = layout.mainRow
        var drawers = layout.drawerRows.isEmpty ? [[]] : layout.drawerRows

        var overflow: [TerminalKeySlot] = []
        if main.count > cap {
            overflow = Array(main[cap...])
            main = Array(main[..<cap])
        }

        let toggle = TerminalKeySlot.builtIn(.drawerToggle)
        let hasDrawerContent = drawers.contains { !$0.isEmpty } || !overflow.isEmpty
        let toggleHidden = layout.hiddenKeys.contains(.drawerToggle)
        if hasDrawerContent && !toggleHidden && !main.contains(toggle) {
            // toggle 被挤进溢出了，或者压根不在布局里 —— 两种都要把它捞回主行
            overflow.removeAll { $0 == toggle }
            if main.count >= cap, let last = main.popLast() {
                overflow.insert(last, at: 0)
            }
            main.append(toggle)
        }

        if !overflow.isEmpty {
            drawers[0].insert(contentsOf: overflow, at: 0)
        }

        return TerminalToolbarResolvedLayout(mainRow: main, drawerRows: drawers, capacity: cap)
    }

    /// 抽屉行渲染时跳过 `drawerToggle` / `arrowJoystick` —— 即使配置层有这两个槽位，
    /// 它们也不该在抽屉里画出来（物料表 §1.4 末条）。
    static func drawerRenderable(_ row: [TerminalKeySlot]) -> [TerminalKeySlot] {
        row.filter { slot in
            guard let id = slot.builtInID else { return true }
            return id != .drawerToggle && id != .arrowJoystick
        }
    }
}
