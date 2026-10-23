import SwiftUI

/// 心声卡片：默认 collapsed 成 💭 chip；点开 → 日记本样式（点阵 bg + 圆角 + 学日历的描边）；X 关闭。
/// 用在两处：聊天流里 assistant 节点（contentType=heartvoice）+ AI 资料卡碎碎念 section。
/// 手写字体后续：FontManager.handwritingName（粟粟还没下载，先空着用 system）。
struct HeartvoiceCardView: View {
    let text: String
    let time: Date?

    @State private var isExpanded = false

    var body: some View {
        Group {
            if isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isExpanded)
    }

    // MARK: - Collapsed

    private var collapsed: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 18))
                if let time {
                    Text(timeLabel(time))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted.opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.mainBg.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.accent.opacity(0.72), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded（日记本）

    private var expanded: some View {
        ZStack(alignment: .topTrailing) {
            // 内容层（前景）
            VStack(alignment: .leading, spacing: 10) {
                if let time {
                    Text(timeLabel(time))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted.opacity(0.8))
                }
                Text(text)
                    // TODO: 等粟粟下载手写字体后改 FontManager.font(size: 14, name: handwriting)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            // X 关闭按钮（右上角浮在内容之上）
            Button {
                isExpanded = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Theme.mainBg.opacity(0.9))
                    )
                    .overlay(
                        Circle().stroke(Theme.accent.opacity(0.72), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
        .background(
            // 点阵背景层
            DotGridBackground()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .background(
            // 底色（点阵之下）
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.mainBg.opacity(0.9))
        )
        .overlay(
            // 学日历的描边
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.accent.opacity(0.72), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Helpers

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M月d日 HH:mm"
        }
        return f.string(from: date)
    }
}

/// 点阵背景：浅薄荷小圆点网格，10pt 间距、1.5pt 直径。
struct DotGridBackground: View {
    var dotColor: Color = Theme.accent.opacity(0.55)
    var spacing: CGFloat = 10
    var dotSize: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let rows = Int(size.height / spacing)
            let cols = Int(size.width / spacing)
            guard rows > 0, cols > 0 else { return }
            for r in 0...rows {
                for c in 0...cols {
                    let x = CGFloat(c) * spacing + spacing / 2
                    let y = CGFloat(r) * spacing + spacing / 2
                    let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                }
            }
        }
    }
}
