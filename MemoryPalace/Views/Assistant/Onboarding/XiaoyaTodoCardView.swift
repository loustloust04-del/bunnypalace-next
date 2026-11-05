import SwiftUI

// MARK: - 待办卡（小样 todoCard：⑭「你可以试试」）
// 只读三四条，不打勾（plan §3：小样里能点着划掉只是演示，真卡不记状态）。

struct XiaoyaTodoCardView: View {
    let items: [String]

    var body: some View {
        XiaoyaCardFrame(kicker: "你可以试试") {
            XiaoyaSkinReader { skin in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .stroke(skin.inkMuted, lineWidth: 1.5)
                                .frame(width: 16, height: 16)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                            Text(item)
                                .font(.system(size: XiaoyaCardFont.body - 0.5))
                                .foregroundStyle(skin.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle()
                                    .stroke(skin.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .frame(height: 1)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
