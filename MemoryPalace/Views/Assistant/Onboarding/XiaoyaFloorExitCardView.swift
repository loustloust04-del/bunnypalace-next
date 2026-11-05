import SwiftUI

// MARK: - 新楼层出口卡（小样 floorCard：⑩ 酒馆 / ⑪ 陪伴 建好 Ta 楼层；end() 的两张「出口」卡也在这儿）
// 建楼层不自动切（H6）：用户点「去找 X →」才走。点过「去找」之后这颗还能再点（再发一次 .floor(.go)，P4 照跳）；
// 「继续问我」点过就灰掉；追加导入（世界书 / 预设 / 聊天记录）随时能点，固定落到这张卡的 Ta 楼层（H7，P4 做）。

struct XiaoyaFloorExitCardView: View {
    let payload: XiaoyaFloorExitPayload
    let answer: XiaoyaCardAnswer?
    let onAnswer: (XiaoyaCardAnswer) -> Void

    var body: some View {
        XiaoyaCardFrame(kicker: "新楼层", question: "\(payload.ta.name) 的楼层建好了") {
            XiaoyaTaHeader(name: payload.ta.name, meta: payload.meta)
                .padding(.top, -6)
            XiaoyaHint(XiaoyaScriptLines.floorExitHint)
            XiaoyaHint("没有自动切过去——你点了才走。以后在楼层列表里也能找到 Ta。")
            XiaoyaCardActions {
                Button("去找 \(payload.ta.name) →") { onAnswer(.floor(.go)) }
                    .buttonStyle(.xiaoya(.primary))
                Button("继续问我") { onAnswer(.floor(.stay)) }
                    .buttonStyle(.xiaoya(.secondary))
                    .disabled(answer != nil)
            }
            if !payload.extras.isEmpty {
                XiaoyaFlowRow(spacing: 8, lineSpacing: 2) {
                    ForEach(payload.extras, id: \.self) { extra in
                        Button("＋ " + extra.label(taName: payload.ta.name)) { onAnswer(.floorExtra(extra)) }
                            .buttonStyle(.xiaoya(.text))
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

/// 结束时的出口（有 Ta）：一颗「去找 X →」，每点一次发一次 .floor(.go)
struct XiaoyaGoTaCardView: View {
    let ta: XiaoyaTaRef
    let onAnswer: (XiaoyaCardAnswer) -> Void

    var body: some View {
        XiaoyaCardFrame(kicker: "出口") {
            XiaoyaCardActions(topPadding: 6) {
                Button("去找 \(ta.name) →") { onAnswer(.floor(.go)) }
                    .buttonStyle(.xiaoya(.primary))
            }
        }
    }
}

/// 结束时的出口（还没有 Ta）：「建一个 Ta →」，点过就灰（P4 接着出起名卡）
struct XiaoyaMakeTaCardView: View {
    let answer: XiaoyaCardAnswer?
    let onAnswer: (XiaoyaCardAnswer) -> Void

    var body: some View {
        XiaoyaCardFrame(kicker: "出口") {
            XiaoyaHint("你还没有自己的 Ta。想要的话随时跟我说「建一个 Ta」。")
                .padding(.top, -1)
            XiaoyaCardActions {
                Button("建一个 Ta →") { onAnswer(.makeTa) }
                    .buttonStyle(.xiaoya(.secondary))
                    .disabled(answer != nil)
            }
        }
    }
}

/// 放不下就折行的一排（追加导入按钮、服务商 chips）
struct XiaoyaFlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
