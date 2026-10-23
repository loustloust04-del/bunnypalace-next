import SwiftUI

/// 等待动画的思考球样式（Vendor/ThinkingOrbsKit 9 种），存 UserDefaults `thinkingOrbStyle`（OrbState.rawValue）。
extension OrbState {
    static let storageKey = "thinkingOrbStyle"
    /// 怀旧三点（不是 OrbState，存同一个 key）
    static let legacyDotsRaw = "dots"

    static func stored(_ raw: String) -> OrbState { OrbState(rawValue: raw) ?? .working }

    var displayName: String {
        switch self {
        case .working: return "轨道"
        case .searching: return "地球"
        case .solving: return "魔方"
        case .listening: return "声波"
        case .connecting: return "网络"
        case .weaving: return "编织"
        case .composing: return "丝带"
        case .breathing: return "呼吸"
        case .shaping: return "变形"
        }
    }
}

/// 设置页一排活的小球，点选。横向 ScrollView 里 Button 会被滚动手势吞，所以用自适应网格 + onTapGesture。
struct ThinkingOrbStylePicker: View {
    @AppStorage(OrbState.storageKey) private var styleRaw = OrbState.working.rawValue

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 10) {
            ForEach(OrbState.allCases, id: \.self) { state in
                cell(raw: state.rawValue, name: state.displayName) {
                    Theme.textSecondary
                        .mask { ThinkingOrb(state: state, size: .px20, displaySize: 30) }
                        .frame(width: 30, height: 30)
                }
            }
            cell(raw: OrbState.legacyDotsRaw, name: "三点") {
                BouncingDotsView().frame(width: 30, height: 30)
            }
        }
    }

    private func cell<Preview: View>(raw: String, name: String, @ViewBuilder preview: () -> Preview) -> some View {
        let selected = styleRaw == raw
        return VStack(spacing: 4) {
            preview()
                .padding(7)
                .background(Circle().fill(selected ? Theme.accent : .clear))
                .overlay(Circle().stroke(selected ? Theme.branchIndicator : .clear, lineWidth: 1.5))
            Text(name)
                .font(.system(size: 11))
                .foregroundColor(selected ? Theme.textPrimary : Theme.textMuted)
        }
        .contentShape(Rectangle())
        .onTapGesture { styleRaw = raw }
    }
}
