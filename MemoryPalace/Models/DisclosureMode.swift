import SwiftUI

/// 折叠行显示模式（plan-disclosure-modes）：思考过程 / 想起来了 / 工具调用 三行共用一个枚举、一种设置行。
enum DisclosureMode: String, CaseIterable, Identifiable {
    case hidden, inline, sheet
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hidden: return "隐藏"
        case .inline: return "原地展开"
        case .sheet: return "弹出显示"
        }
    }
    var iconName: String {
        switch self {
        case .hidden: return "eye.slash"
        case .inline: return "chevron.down"
        case .sheet: return "rectangle.portrait.bottomhalf.inset.filled"
        }
    }
    var summary: String {
        switch self {
        case .hidden: return "不显示这一行"
        case .inline: return "点一下在气泡里展开"
        case .sheet: return "点一下弹出整页面板"
        }
    }
}

enum DisclosureKind {
    case thinking, recall, tool

    var key: String {
        switch self {
        case .thinking: return "thinkingDisplayMode"
        case .recall: return "recallDisplayMode"
        case .tool: return "toolDisplayMode"
        }
    }
    var title: String {
        switch self {
        case .thinking: return "思考过程"
        case .recall: return "想起来了"
        case .tool: return "工具调用"
        }
    }

    /// 新 key 没设过时的默认值 = 旧开关迁移：thinkingSheetMode=true → 弹出；mem_recall_card=false → 隐藏
    var migratedDefault: DisclosureMode {
        let d = UserDefaults.standard
        switch self {
        case .thinking: return d.bool(forKey: "thinkingSheetMode") ? .sheet : .inline
        case .recall: return (d.object(forKey: "mem_recall_card") != nil && !d.bool(forKey: "mem_recall_card")) ? .hidden : .inline
        case .tool: return .inline
        }
    }

    var mode: DisclosureMode {
        DisclosureMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? migratedDefault
    }
}

/// 设置行（等待动画行同款）：左标题 body/textPrimary，右当前档 secondary/textMuted + 小 chevron，点开菜单选档
struct DisclosureModeRow: View {
    let kind: DisclosureKind
    let fontSize: CGFloat
    let valueSize: CGFloat
    @AppStorage private var modeRaw: String

    init(kind: DisclosureKind, fontSize: CGFloat, valueSize: CGFloat) {
        self.kind = kind
        self.fontSize = fontSize
        self.valueSize = valueSize
        _modeRaw = AppStorage(wrappedValue: kind.migratedDefault.rawValue, kind.key)
    }

    private var mode: DisclosureMode { DisclosureMode(rawValue: modeRaw) ?? .inline }

    var body: some View {
        Menu {
            Picker("", selection: $modeRaw) {
                ForEach(DisclosureMode.allCases) { m in
                    Label(m.displayName, systemImage: m.iconName).tag(m.rawValue)
                }
            }
        } label: {
            SettingsValueRowLabel(title: kind.title, value: mode.displayName, fontSize: fontSize, valueSize: valueSize)
        }
        .buttonStyle(.plain)
    }
}

/// 「标题 …… 值 ›」行的 label（等待动画 NavigationLink 行同款字号/色）；Menu 和 NavigationLink 共用
struct SettingsValueRowLabel: View {
    let title: String
    let value: String
    let fontSize: CGFloat
    let valueSize: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: fontSize))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: valueSize))
                .foregroundColor(Theme.textMuted)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: valueSize - 3, weight: .semibold))
                .foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .contentShape(Rectangle())
    }
}
