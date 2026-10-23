import Foundation

/// 桌面上可放的小组件种类。
enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case pet
    case todo
    case garden
    case contacts
    case vocab
    #if PERSONAL_APPS
    #if DEBUG
    case topicBox
    #endif
    #endif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pet:      return "宠物"
        case .todo:     return "待办"
        case .garden:   return "花园"
        case .contacts: return "通讯录"
        case .vocab:    return "单词"
        #if PERSONAL_APPS
        #if DEBUG
        case .topicBox: return "话题盒"
        #endif
        #endif
        }
    }

    var icon: String {
        switch self {
        case .pet:      return "pawprint.fill"
        case .todo:     return "checklist"
        case .garden:   return "leaf.fill"
        case .contacts: return "person.2.fill"
        case .vocab:    return "abc"
        #if PERSONAL_APPS
        #if DEBUG
        case .topicBox: return "lightbulb"
        #endif
        #endif
        }
    }
}

/// 组件尺寸（同官方三档）：小方 / 长条 / 大方。
enum WidgetSize: String, Codable {
    case small    // 小方：半屏宽方块（1:1），一行并两个
    case medium   // 长条：整屏宽横条（2:1）
    case large    // 大方：整屏宽大方块（1:1）

    /// tap 一下循环切换。
    var next: WidgetSize {
        switch self {
        case .small:  return .medium
        case .medium: return .large
        case .large:  return .small
        }
    }

    /// 是否整屏宽（长条 / 大方独占一行；小方半宽）。
    var isFullWidth: Bool { self != .small }
}

/// 桌面上的一个组件实例（种类 + 尺寸）。每种最多一个，故 id = kind。
struct WidgetInstance: Codable, Identifiable {
    var kind: WidgetKind
    var size: WidgetSize = .medium
    var id: String { kind.rawValue }
}

private struct LenientWidget: Decodable {
    let instance: WidgetInstance?
    init(from decoder: Decoder) throws { instance = try? WidgetInstance(from: decoder) }
}

/// 桌面 widget 的有序列表 + 增/删/拖动排序 + 改尺寸。全局一份，UserDefaults 持久化。
@MainActor
@Observable
final class DashboardManager {
    static let shared = DashboardManager()
    private static let key = "dashboardWidgets_v2"

    private(set) var widgets: [WidgetInstance]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let w = Self.decodeWidgets(data) {
            widgets = w
        } else {
            widgets = [WidgetInstance(kind: .pet, size: .medium),
                       WidgetInstance(kind: .todo, size: .medium)]
        }
    }

    /// 逐个解码、认不出的种类跳过（#096：Debug 包存过话题盒小组件，换到 Release 后别把整份布局一起丢了）
    nonisolated static func decodeWidgets(_ data: Data) -> [WidgetInstance]? {
        (try? JSONDecoder().decode([LenientWidget].self, from: data))?.compactMap(\.instance)
    }

    var availableToAdd: [WidgetKind] {
        WidgetKind.allCases.filter { kind in !widgets.contains(where: { $0.kind == kind }) }
    }

    func add(_ kind: WidgetKind) {
        guard !widgets.contains(where: { $0.kind == kind }) else { return }
        widgets.append(WidgetInstance(kind: kind, size: .medium))
        save()
    }

    func remove(_ kind: WidgetKind) {
        widgets.removeAll { $0.kind == kind }
        save()
    }

    /// 把 dragged 插到 target 之前（拖动重排）。
    func move(_ dragged: WidgetKind, before target: WidgetKind) {
        guard dragged != target,
              let from = widgets.firstIndex(where: { $0.kind == dragged }) else { return }
        let item = widgets.remove(at: from)
        if let to = widgets.firstIndex(where: { $0.kind == target }) {
            widgets.insert(item, at: to)
        } else {
            widgets.append(item)
        }
        save()
    }

    /// 设成指定尺寸（长按菜单选）。
    func setSize(_ kind: WidgetKind, _ size: WidgetSize) {
        guard let idx = widgets.firstIndex(where: { $0.kind == kind }) else { return }
        widgets[idx].size = size
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(widgets) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }
}
