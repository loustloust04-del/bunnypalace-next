import SwiftUI

/// 划线色板（设置 › 外观 › 文本 › 划线颜色，二级页 `HighlightColorsPage`）：读书、聊天、单词页等所有能划线的地方共用。
/// 默认 6 色 + 自己加的（长按删；删了已经划的线颜色不变）。书房设置里有一行跳到这里。
struct HighlightColorsSection: View {
    var anchor: String? = nil
    @AppStorage(HighlightPalette.customKey) private var customColorsRaw = ""
    @State private var pickedColor = Color(hex: 0xD7A6B8)

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(HighlightPalette.defaults, id: \.hex) { c in
                        Circle().fill(HighlightPalette.color(c.hex)).frame(width: 30, height: 30)
                            .accessibilityLabel(c.name)
                    }
                    ForEach(HighlightPalette.customColors(customColorsRaw), id: \.self) { hex in
                        Circle().fill(HighlightPalette.color(hex)).frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                            .contextMenu {
                                Button("删除这个颜色", role: .destructive) {
                                    customColorsRaw = HighlightPalette.customColors(customColorsRaw)
                                        .filter { $0 != hex }.joined(separator: ",")
                                }
                            }
                            .accessibilityLabel("自定义颜色 \(hex)")
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                ColorPicker("挑一个颜色", selection: $pickedColor, supportsOpacity: false)
                Button("加进色板") {
                    let hex = HighlightPalette.hex(of: pickedColor)
                    var list = HighlightPalette.customColors(customColorsRaw)
                    guard !list.contains(hex), !HighlightPalette.defaults.contains(where: { $0.hex == hex }) else { return }
                    list.append(hex)
                    customColorsRaw = list.joined(separator: ",")
                }
                .foregroundStyle(Theme.branchIndicator)
            }
            .searchAnchor(anchor ?? "")
        } header: {
            Text("划线颜色")
        } footer: {
            Text("读书、聊天、单词页等地方划线时从这里选颜色。自己加的颜色长按可以删；删掉后，已经划过的线颜色不变。")
        }
        .listRowBackground(Theme.mainBg)
    }
}

/// 书房设置里「划线颜色 ›」点进来的那一页
struct HighlightColorsPage: View {
    var body: some View {
        List { HighlightColorsSection() }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("划线颜色")
    }
}
