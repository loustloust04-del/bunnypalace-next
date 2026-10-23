#if os(iOS)
import SwiftUI
import UIKit

/// 群聊页颜色：背景 / 对方气泡 / 我的气泡。两层：
/// 设置 › 群聊 › 聊天外观 是全局（AppStorage，空串 = 默认）；编辑群聊 › 聊天外观 是这个群单独的（nil = 跟随设置）。
/// 生效顺序：这个群选的 → 全局选的 → 默认（浅灰底 / 白气泡 / 主题的「你」气泡色）。
enum GroupRoomStyle {
    struct Option {
        let name: String
        let hex: String?
    }

    static let backgroundKey = "groupRoomBackgroundHex"
    static let othersKey = "groupRoomOthersBubbleHex"
    static let mineKey = "groupRoomMineBubbleHex"

    static let backgrounds: [Option] = [
        .init(name: "默认", hex: nil), .init(name: "奶白", hex: "#FFFCF8"), .init(name: "薄荷", hex: "#EAF2EC"),
        .init(name: "雾粉", hex: "#F6ECEC"), .init(name: "藕紫", hex: "#EFEBF4"), .init(name: "暖杏", hex: "#F5EEE4"),
        .init(name: "石灰", hex: "#E4E3DF"),
    ]
    static let others: [Option] = [
        .init(name: "白", hex: nil), .init(name: "奶白", hex: "#FFFCF8"), .init(name: "浅灰", hex: "#F1F0EC"),
        .init(name: "薄荷", hex: "#E6F0E9"), .init(name: "雾粉", hex: "#F7E9EA"),
    ]
    static let mine: [Option] = [
        .init(name: "主题色", hex: nil), .init(name: "薄荷", hex: "#DCEBE1"), .init(name: "雾粉", hex: "#F3DFE1"),
        .init(name: "藕紫", hex: "#E5DEF0"), .init(name: "杏", hex: "#F2E3D3"), .init(name: "石灰", hex: "#E6E5E1"),
    ]

    /// AppStorage 里空串 = 没选
    static func stored(_ value: String) -> String? { value.isEmpty ? nil : value }

    static func background(_ hex: String?) -> Color { hex.map(FolderPalette.color) ?? AgoraRoomView.roomBackground }
    static func othersColor(_ hex: String?) -> Color { hex.map(FolderPalette.color) ?? .white }
    static func mineColor(_ hex: String?) -> Color { hex.map(FolderPalette.color) ?? Theme.userBubble }
    static func othersFill(_ hex: String?) -> UIColor { UIColor(othersColor(hex)) }
    static func mineFill(_ hex: String?) -> UIColor { UIColor(mineColor(hex)) }
}

extension Binding where Value == String {
    /// AppStorage 存空串表示「默认」，色块那边用 nil
    var storedHex: Binding<String?> {
        Binding<String?>(get: { GroupRoomStyle.stored(wrappedValue) }, set: { wrappedValue = $0 ?? "" })
    }
}

/// 一排色块：选中的外面一圈描边。nil 那格画 `fallback`（默认色 / 跟随设置时的全局色）
struct GroupColorSwatchRow: View {
    let title: String
    let options: [GroupRoomStyle.Option]
    @Binding var selection: String?
    let fallback: Color
    /// nil 那格的名字（设置里是「默认」这类，编辑群聊里是「跟随设置」）
    var nilName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline)
            HStack(spacing: 12) {
                ForEach(options.indices, id: \.self) { i in
                    let option = options[i]
                    let isOn = selection == option.hex
                    Circle()
                        .fill(option.hex.map(FolderPalette.color) ?? fallback)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(isOn ? 0.45 : 0), lineWidth: 2).padding(-4))
                        .contentShape(Circle())
                        .onTapGesture { selection = option.hex }
                        .accessibilityLabel("\(title)：\(option.hex == nil ? (nilName ?? option.name) : option.name)")
                        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
