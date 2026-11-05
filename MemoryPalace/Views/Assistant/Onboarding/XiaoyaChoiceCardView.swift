import SwiftUI

// MARK: - 选择卡（小样 choiceCard：② 分流 / 有 Mac 吗 / 建一个 Ta？）
// 选项行：标题 + 小字 + ›；点过的那行变墨色实底 + ✓，其余变淡，整张卡不再能点。

struct XiaoyaChoiceCardView: View {
    let payload: XiaoyaChoicePayload
    let answer: XiaoyaCardAnswer?
    let onAnswer: (XiaoyaCardAnswer) -> Void

    private var pickedId: String? {
        if case .picked(let id) = answer { return id }
        return nil
    }

    var body: some View {
        XiaoyaCardFrame(kicker: payload.kicker, question: payload.question) {
            VStack(spacing: 7) {
                ForEach(payload.options) { option in
                    row(option)
                }
            }
            .padding(.top, payload.question.isEmpty ? 7 : 0)
        }
    }

    private func row(_ option: XiaoyaChoiceOption) -> some View {
        let picked = pickedId == option.id
        let done = answer != nil
        return XiaoyaSkinReader { skin in
            Button {
                guard !done else { return }
                onAnswer(.picked(option.id))
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.title)
                            .font(.system(size: XiaoyaCardFont.body, weight: .semibold))
                            .foregroundStyle(picked ? skin.paper : skin.ink)
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: XiaoyaCardFont.small))
                                .foregroundStyle(picked ? skin.paper.opacity(0.75) : skin.inkMuted)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(picked ? "✓" : "›")
                        .font(.system(size: 16))
                        .foregroundStyle(picked ? skin.paper.opacity(0.75) : skin.inkMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(picked ? skin.ink : skin.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(picked ? skin.ink : skin.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!done)        // 不用 .disabled：plain 按钮禁用会整行变淡，选中那行要保持实底
            .opacity(done && !picked ? 0.38 : 1)
        }
    }
}
