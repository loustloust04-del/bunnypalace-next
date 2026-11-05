import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - key 卡（小样 keyCard ③ 填钥匙 ④ 测试中 ⑤ 失败 ⑥ 成功挑模型 ⑦ 先跳过）
// 状态全在 XiaoyaKeyCardModel（调用方持有：P4 的剧本引擎能看着 phase 换舞台表情）。
// 「就用这个」调注入的 commit（P4 接 CredentialCommitter），成功后才发 .keySaved；「先跳过」发 .skipped。

struct XiaoyaKeyCardView: View {
    @ObservedObject var model: XiaoyaKeyCardModel
    let answer: XiaoyaCardAnswer?
    let commit: XiaoyaKeyCardModel.Commit
    let onAnswer: (XiaoyaCardAnswer) -> Void

    @State private var showAllModels = false
    private static let modelPreviewCount = 6

    var body: some View {
        switch answer {
        case .keySaved(let saved)?:
            XiaoyaCardFrame(kicker: "钥匙 · API key") {
                XiaoyaSkinReader { skin in
                    HStack(spacing: 10) {
                        XiaoyaBadge(text: "✓", color: skin.ok)
                        (Text(saved.providerName).fontWeight(.semibold).foregroundStyle(skin.ink)
                            + Text(" · ")
                            + Text(saved.modelId).font(.system(size: XiaoyaCardFont.small, design: .monospaced))
                            + Text(" · 已存好，设成默认模型并收藏"))
                            .font(.system(size: XiaoyaCardFont.small + 1))
                            .foregroundStyle(skin.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            }
        case .skipped?:
            XiaoyaCardFrame(kicker: "钥匙 · API key") {
                XiaoyaSkinReader { skin in
                    XiaoyaCardSummary(text: XiaoyaCardAnswer.skipped.summary) {
                        XiaoyaBadge(text: "–", color: skin.inkMuted)
                    }
                }
                .padding(.top, 6)
            }
        default:
            XiaoyaCardFrame(kicker: "钥匙 · API key", question: "接一把钥匙，我就能真的跟你说话") {
                form
            }
        }
    }

    // MARK: 表单

    @ViewBuilder
    private var form: some View {
        XiaoyaField(label: "服务商") { providerChips }
            .padding(.top, -10)
        if model.isCustom {
            XiaoyaField(label: "协议") { protocolSegment }
            XiaoyaField(label: "中转地址") {
                XiaoyaInputBox {
                    XiaoyaPlainField(placeholder: "https://你的中转站.com", text: Binding(get: { model.customBaseURL }, set: { model.setBaseURL($0) }),
                                     secure: false, kind: .url)
                }
                monoHint("实际请求：", model.endpointPreview ?? "（填了地址这里显示完整网址）")
            }
        } else {
            monoHint("官方地址，不用改：", model.officialBaseURL)
                .padding(.top, 3)
        }
        XiaoyaField(label: "API key") {
            XiaoyaInputBox {
                XiaoyaPlainField(placeholder: "sk-…", text: Binding(get: { model.key }, set: { model.setKey($0) }),
                                 secure: !model.showKey, kind: .secret)
                eyeButton
            }
            XiaoyaHint("只存在这台设备的钥匙串里。点眼睛可以看明文，核对有没有多复制空格。")
        }
        // 自定义中转不给 /models：测之前就能手填模型 ID，测试拿它发 hi（sol #8）；测通后这一栏挪进结果条
        if model.isCustom, !succeeded {
            XiaoyaField(label: "模型 ID（可不填）") {
                XiaoyaInputBox {
                    XiaoyaPlainField(placeholder: "比如 gpt-4o-mini", text: Binding(get: { model.manualModel }, set: { model.setManualModel($0) }),
                                     secure: false, kind: .identifier)
                }
                XiaoyaHint("不填就先拉中转的模型清单；中转不给清单就填一个它支持的模型来测。")
            }
        }
        if let note = model.note {
            XiaoyaSkinReader { skin in XiaoyaHint("↻ " + note, color: skin.ink) }
        }
        result
        actions
    }

    private var providerChips: some View {
        let guided = XiaoyaKeyCardModel.guidedPresets.map(\.id)
        let primary = XiaoyaKeyCardModel.primaryPresetIds.filter(guided.contains)
        let more = guided.filter { !primary.contains($0) }
        let shownMore = model.showAllProviders ? more : more.filter { $0 == model.selection }
        return XiaoyaFlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(primary + [CredentialDraft.customSelection] + shownMore, id: \.self) { id in
                XiaoyaChip(title: XiaoyaKeyCardModel.chipTitle(id), on: model.selection == id) { model.selectProvider(id) }
            }
            if !more.isEmpty {
                XiaoyaChip(title: model.showAllProviders ? "收起" : "更多 \(more.count) 家…", on: false, muted: true) {
                    model.showAllProviders.toggle()
                }
            }
        }
    }

    private var protocolSegment: some View {
        XiaoyaSkinReader { skin in
            HStack(spacing: 0) {
                ForEach([ProviderType.openaiCompatible, .anthropic], id: \.self) { type in
                    let on = model.customType == type
                    Button { model.setProtocol(type) } label: {
                        Text(type == .anthropic ? "Anthropic 兼容" : "OpenAI 兼容")
                            .font(.system(size: XiaoyaCardFont.small))
                            .foregroundStyle(on ? skin.paper : skin.inkSoft)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(on ? skin.ink : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(skin.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(skin.line, lineWidth: 1))
        }
    }

    private var eyeButton: some View {
        XiaoyaSkinReader { skin in
            Button { model.showKey.toggle() } label: {
                Image(systemName: model.showKey ? "eye.slash" : "eye")
                    .font(.system(size: 15))
                    .foregroundStyle(skin.inkSoft)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.showKey ? "隐藏" : "显示明文核对")
        }
    }

    private func monoHint(_ label: String, _ value: String) -> some View {
        XiaoyaHint(text: Text(label) + Text(value).font(.system(size: XiaoyaCardFont.mono, design: .monospaced)))
    }

    // MARK: 结果条

    @ViewBuilder
    private var result: some View {
        switch model.phase {
        case .edit:
            EmptyView()
        case .testing:
            XiaoyaResultBar(tone: .wait, title: "在试…") {
                if let m = model.testingModelHint {
                    Text("用 ") + mono(m) + Text(" 发一句 hi，最多等 15 秒")
                } else {
                    Text("先拉一下模型清单，再发一句 hi，最多等 15 秒")
                }
            }
        case .failed(let f):
            XiaoyaResultBar(tone: .bad, badge: f.status.map(String.init) ?? "—", title: "没连上") {
                Text(f.reason).fixedSize(horizontal: false, vertical: true)
                XiaoyaSkinReader { skin in
                    VStack(alignment: .leading, spacing: 3) {
                        if let upstream = f.upstream {
                            (Text("上游原文：") + mono(upstream)).foregroundStyle(skin.inkSoft)
                        }
                        if !f.url.isEmpty {
                            (Text("请求地址：") + mono(f.url)).foregroundStyle(skin.inkSoft)
                        }
                    }
                    .font(.system(size: XiaoyaCardFont.hint))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }
            }
        case .succeeded(let s):
            XiaoyaResultBar(tone: .ok, badge: "✓", title: "连上了") {
                (Text("用 ") + mono(s.testedModel) + Text(" 回了一句。拉到 \(s.models.count) 个模型，挑一个当默认："))
                    .fixedSize(horizontal: false, vertical: true)
                modelList(s)
                XiaoyaInputBox {
                    XiaoyaPlainField(placeholder: "列表里没有？手填模型 ID", text: Binding(get: { model.manualModel }, set: { model.setManualModel($0) }),
                                     secure: false, kind: .identifier)
                }
                .padding(.top, 4)
            }
        }
    }

    private func modelList(_ s: XiaoyaKeyCardModel.Success) -> some View {
        let shown = showAllModels ? s.models : Array(s.models.prefix(Self.modelPreviewCount))
        return XiaoyaSkinReader { skin in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { m in
                    let on = model.pickedModel == m.modelId && model.manualModel.trimmingCharacters(in: .whitespaces).isEmpty
                    Button { model.pick(m.modelId) } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .strokeBorder(on ? skin.ink : skin.inkMuted, lineWidth: on ? 5 : 1.5)
                                .frame(width: 16, height: 16)
                            Text(m.modelId)
                                .font(.system(size: XiaoyaCardFont.small + 0.5, design: .monospaced))
                                .foregroundStyle(skin.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if m.modelId == s.recommended {
                                Text("★ 省钱好用")
                                    .font(.system(size: XiaoyaCardFont.hint))
                                    .foregroundStyle(skin.ok)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if s.models.count > Self.modelPreviewCount {
                    Button(showAllModels ? "收起" : "展开全部 \(s.models.count) 个") { showAllModels.toggle() }
                        .buttonStyle(.xiaoya(.text))
                }
            }
            .padding(.top, 5)
        }
    }

    private func mono(_ s: String) -> Text {
        Text(s).font(.system(size: XiaoyaCardFont.mono, design: .monospaced))
    }

    // MARK: 按钮

    private var actions: some View {
        XiaoyaCardActions {
            if case .succeeded = model.phase {
                Button("就用这个") {
                    if let saved = model.save(commit: commit) { onAnswer(.keySaved(saved)) }
                }
                .buttonStyle(.xiaoya(.primary))
                .disabled(!model.canSave)
                Button("换一家") { model.changeProvider() }
                    .buttonStyle(.xiaoya(.text))
            } else {
                Button(failedOnce ? "改好了，再测一次" : "测一下") {
                    Task { await model.test() }
                }
                .buttonStyle(.xiaoya(.primary))
                .disabled(!model.canTest)
            }
            Spacer(minLength: 0)
            Button("先跳过") { onAnswer(.skipped) }
                .buttonStyle(.xiaoya(.text))
        }
    }

    private var failedOnce: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private var succeeded: Bool {
        if case .succeeded = model.phase { return true }
        return false
    }
}

// MARK: - 不改字的输入框
// key / 地址 / 模型 ID 都是要逐字原样的东西：关自动大写、自动纠错、拼写检查、智能引号 / 破折号（iOS 粘贴 key 被改成弯引号是老坑）。
// iOS 用 UITextField（SwiftUI 的 TextField 关不掉智能标点）；mac 的输入框本来就不替换，用 SwiftUI 的。

enum XiaoyaPlainFieldKind {
    case secret, url, identifier
}

struct XiaoyaPlainField: View {
    let placeholder: String
    @Binding var text: String
    let secure: Bool
    let kind: XiaoyaPlainFieldKind

    init(placeholder: String, text: Binding<String>, secure: Bool, kind: XiaoyaPlainFieldKind) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.kind = kind
    }

    var body: some View {
        XiaoyaSkinReader { skin in
            #if os(iOS)
            XiaoyaUIKitField(placeholder: placeholder, text: $text, secure: secure, kind: kind,
                             ink: UIColor(skin.ink), placeholderColor: UIColor(skin.inkMuted))
                .frame(minHeight: 36)
            #else
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .autocorrectionDisabled(true)
                }
            }
            .textFieldStyle(.plain)
            .padding(.vertical, 8)
            #endif
        }
    }
}

#if os(iOS)
private struct XiaoyaUIKitField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let secure: Bool
    let kind: XiaoyaPlainFieldKind
    let ink: UIColor
    let placeholderColor: UIColor

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .systemFont(ofSize: XiaoyaCardFont.body)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .never
        field.keyboardType = kind == .url ? .URL : .asciiCapable
        field.returnKeyType = .done
        // 填 key 不弹「存储密码？」（同 master 75c5af732 给 API Key / Hub Token 的处理）
        if secure { field.textContentType = .oneTimeCode }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.addTarget(context.coordinator, action: #selector(Coordinator.done(_:)), for: .editingDidEndOnExit)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
        if field.isSecureTextEntry != secure { field.isSecureTextEntry = secure }
        if field.textColor != ink { field.textColor = ink }
        let attributed = NSAttributedString(string: placeholder, attributes: [.foregroundColor: placeholderColor])
        if field.attributedPlaceholder != attributed { field.attributedPlaceholder = attributed }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        @objc func done(_ field: UITextField) { field.resignFirstResponder() }
    }
}
#endif
