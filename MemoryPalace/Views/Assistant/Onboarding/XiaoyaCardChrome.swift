import SwiftUI

// MARK: - 小芽引导卡 · 外框与零件（plan-onboarding-xiaoya-impl §3；小样 .card .res .acts）
// 颜色全部取 XiaoyaSkin（跟 app 亮暗走），圆角 / 字号对齐 AssistantProposalCard（同一个房间里的卡）。
// 卡片不依赖 ConversationViewModel，也不写任何数据。

private struct XiaoyaSkinKey: EnvironmentKey {
    static let defaultValue: XiaoyaSkin? = nil
}

extension EnvironmentValues {
    /// 小芽对话页注入的皮肤；没注入就按系统亮暗取（XiaoyaSkin.current）
    var xiaoyaSkin: XiaoyaSkin? {
        get { self[XiaoyaSkinKey.self] }
        set { self[XiaoyaSkinKey.self] = newValue }
    }
}

/// 卡里统一的字号：iOS 照小样像素，mac 跟 Theme.F 一起小一号
enum XiaoyaCardFont {
    static let kicker: CGFloat = 11
    static let question = Theme.F.body + 1.5
    static let body = Theme.F.body + 0.5
    static let small = Theme.F.secondary - 0.5
    static let hint = Theme.F.secondary - 1
    static let mono = Theme.F.secondary - 1.5
}

/// 子视图里取皮肤：注入优先，否则按当前配色
struct XiaoyaSkinReader<Content: View>: View {
    @Environment(\.xiaoyaSkin) private var injected
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: (XiaoyaSkin) -> Content

    var body: some View { content(injected ?? XiaoyaSkin.current(scheme)) }
}

// MARK: 外框

/// 卡外框：小标题 k（灰、字距）+ 问句 q（粗）+ 内容；k / q 空就不画
struct XiaoyaCardFrame<Content: View>: View {
    var kicker: String = ""
    var question: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        XiaoyaSkinReader { skin in
            VStack(alignment: .leading, spacing: 0) {
                if !kicker.isEmpty {
                    Text(kicker)
                        .font(.system(size: XiaoyaCardFont.kicker))
                        .tracking(1.5)
                        .foregroundStyle(skin.inkMuted)
                }
                if !question.isEmpty {
                    Text(question)
                        .font(.system(size: XiaoyaCardFont.question, weight: .semibold))
                        .foregroundStyle(skin.ink)
                        .padding(.top, 1)
                        .padding(.bottom, 10)
                }
                content()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(skin.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(skin.line, lineWidth: 1))
        }
    }
}

// MARK: 收起后的一行 / 角标 / 头像

/// 圆角标：状态码、✓、!、–
struct XiaoyaBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .serif))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(color, in: Capsule())
    }
}

/// 收起后的摘要行：前面一个角标（或头像），后面一句话
struct XiaoyaCardSummary<Lead: View>: View {
    let text: String
    @ViewBuilder let lead: () -> Lead

    var body: some View {
        XiaoyaSkinReader { skin in
            HStack(spacing: 10) {
                lead()
                Text(text)
                    .font(.system(size: XiaoyaCardFont.small + 1))
                    .foregroundStyle(skin.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Ta 的首字圆头像（小样 .ava）
struct XiaoyaInitialAvatar: View {
    let name: String
    var size: CGFloat = 46

    var body: some View {
        XiaoyaSkinReader { skin in
            Text(name.first.map(String.init) ?? "✿")
                .font(.system(size: size * 0.41, weight: .semibold))
                .foregroundStyle(skin.paper)
                .frame(width: size, height: size)
                .background(skin.ink, in: Circle())
        }
    }
}

/// Ta 名片：头像 + 名字 + 一行 meta（小样 .tacard）
struct XiaoyaTaHeader: View {
    let name: String
    let meta: String

    var body: some View {
        XiaoyaSkinReader { skin in
            HStack(spacing: 12) {
                XiaoyaInitialAvatar(name: name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: XiaoyaCardFont.body + 1.5, weight: .semibold))
                        .foregroundStyle(skin.ink)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: XiaoyaCardFont.small))
                            .foregroundStyle(skin.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: 结果条（wait / ok / bad）

enum XiaoyaResultTone {
    case wait, ok, bad
}

/// 结果条：白底细框、左边 4pt 色条；标题行前面是转圈（wait）或角标（ok / bad）
struct XiaoyaResultBar<Detail: View>: View {
    let tone: XiaoyaResultTone
    var badge: String? = nil
    let title: String
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        XiaoyaSkinReader { skin in
            let stripe: Color = switch tone {
            case .wait: skin.inkMuted
            case .ok: skin.ok
            case .bad: skin.bad
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if tone == .wait {
                        ProgressView().controlSize(.small).tint(skin.inkSoft)
                    } else if let badge {
                        XiaoyaBadge(text: badge, color: stripe)
                    }
                    Text(title)
                        .font(.system(size: XiaoyaCardFont.body - 0.5, weight: .semibold))
                        .foregroundStyle(skin.ink)
                }
                detail()
            }
            .font(.system(size: XiaoyaCardFont.small + 1))
            .foregroundStyle(skin.ink)
            .padding(.leading, 12 + 3)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(skin.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) { stripe.frame(width: 4) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(skin.line, lineWidth: 1))
            .padding(.top, 12)
        }
    }
}

extension XiaoyaResultBar where Detail == EmptyView {
    init(tone: XiaoyaResultTone, badge: String? = nil, title: String) {
        self.init(tone: tone, badge: badge, title: title) { EmptyView() }
    }
}

// MARK: 按钮三档（b1 实心 / b2 描边 / b3 文字）

enum XiaoyaButtonTier {
    case primary, secondary, text
}

struct XiaoyaCardButtonStyle: ButtonStyle {
    let tier: XiaoyaButtonTier

    func makeBody(configuration: Configuration) -> some View {
        XiaoyaCardButtonBody(tier: tier, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct XiaoyaCardButtonBody<Label: View>: View {
    let tier: XiaoyaButtonTier
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        XiaoyaSkinReader { skin in
            switch tier {
            case .primary:
                label
                    .font(.system(size: XiaoyaCardFont.body - 0.5, weight: .semibold))
                    .foregroundStyle(skin.paper)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(skin.ink, in: Capsule())
                    .contentShape(Capsule())
                    .opacity(enabled ? (pressed ? 0.8 : 1) : 0.35)
            case .secondary:
                label
                    .font(.system(size: XiaoyaCardFont.body - 0.5))
                    .foregroundStyle(skin.inkSoft)
                    .padding(.horizontal, 15).padding(.vertical, 7)
                    .overlay(Capsule().stroke(skin.line, lineWidth: 1))
                    .contentShape(Capsule())
                    .opacity(enabled ? (pressed ? 0.7 : 1) : 0.4)
            case .text:
                label
                    .font(.system(size: XiaoyaCardFont.small + 0.5))
                    .foregroundStyle(skin.inkSoft)
                    .underline()
                    .padding(.vertical, 4).padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .opacity(enabled ? (pressed ? 0.6 : 1) : 0.4)
            }
        }
    }
}

extension ButtonStyle where Self == XiaoyaCardButtonStyle {
    static func xiaoya(_ tier: XiaoyaButtonTier) -> XiaoyaCardButtonStyle { XiaoyaCardButtonStyle(tier: tier) }
}

/// 一排按钮（小样 .acts：上空 14、间距 8、能折行就折行——这里用横排，三颗以内放得下）
struct XiaoyaCardActions<Content: View>: View {
    var topPadding: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topPadding)
    }
}

// MARK: 表单零件

/// 字段：小标签（可带灰色「（选填）」）+ 内容
struct XiaoyaField<Content: View>: View {
    let label: String
    var optionalNote: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        XiaoyaSkinReader { skin in
            VStack(alignment: .leading, spacing: 4) {
                if !label.isEmpty {
                    (Text(label).foregroundStyle(skin.inkSoft)
                        + Text(optionalNote.map { " " + $0 } ?? "").foregroundStyle(skin.inkMuted))
                        .font(.system(size: XiaoyaCardFont.hint))
                }
                content()
            }
            .padding(.top, 10)
        }
    }
}

/// 输入框外壳：白底细框圆角 10，最低 40 高
struct XiaoyaInputBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        XiaoyaSkinReader { skin in
            HStack(spacing: 4) { content() }
                .font(.system(size: XiaoyaCardFont.body))
                .foregroundStyle(skin.ink)
                .padding(.leading, 11)
                .padding(.trailing, 6)
                .frame(minHeight: 40)
                .background(skin.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(skin.line, lineWidth: 1))
        }
    }
}

/// 灰色说明小字
struct XiaoyaHint: View {
    let text: Text
    var color: Color? = nil

    init(_ string: String, color: Color? = nil) {
        self.text = Text(string)
        self.color = color
    }

    init(text: Text, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        XiaoyaSkinReader { skin in
            text
                .font(.system(size: XiaoyaCardFont.hint))
                .foregroundStyle(color ?? skin.inkMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
        }
    }
}

/// 小胶囊（服务商 chips）：选中 = 墨色实底
struct XiaoyaChip: View {
    let title: String
    let on: Bool
    var muted = false
    let action: () -> Void

    var body: some View {
        XiaoyaSkinReader { skin in
            Button(action: action) {
                Text(title)
                    .font(.system(size: XiaoyaCardFont.small + 0.5))
                    .foregroundStyle(on ? skin.paper : (muted ? skin.inkMuted : skin.ink))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(on ? skin.ink : skin.field, in: Capsule())
                    .overlay(Capsule().stroke(on ? skin.ink : skin.line, style: StrokeStyle(lineWidth: 1, dash: muted ? [3, 2] : [])))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
