import SwiftUI
import SwiftStreamingMarkdown

/// 提问卡（docs/plan-ask-inline.md）：选项模式点选 / 问答模式填字 → 带答案的同 id 新卡进输入框（同骰子）；流式中、已过期、只读不可答
struct AskCardView: View {
    let card: AskCard
    let nodeId: String?
    let streaming: Bool
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    /// isCCConversation 回退读全局模型。B-8（plan-paging-decouple B-0 表 1）：翻页不再重交 rootView 后，这个值要自带失效通道——声明即订阅
    @AppStorage("selectedChatModel") private var selectedChatModelSubscription = ""
    /// 多选勾选中、还没点「确定」的；nil = 跟卡上已选的走
    @State private var multiDraft: Set<Int>?
    /// 问答框里正在改的字；nil = 跟卡上的答案走
    @State private var draft: String?
    /// 加密问答（docs/plan-secure-ask.md）：真值只在这里待到点「填好了」，存进钥匙串就清空
    @State private var secretDraft = ""
    @State private var secretThisConversationOnly = true
    @State private var secretSaveFailed = false
    /// 表单（docs/plan-ask-form.md）：普通框正在改的字（按字段下标；没有 = 跟卡上的答案走）
    @State private var fieldDrafts: [Int: String] = [:]
    /// 表单的加密框：真值只在这里待到点「提交」，存进钥匙串就清空
    @State private var secretFieldDrafts: [Int: String] = [:]
    /// 表单带类型的项（选择 / 日期 / 数字 / 滑块）正在改的值；没有 = 跟卡上的答案 / 默认走
    @State private var formValues: [Int: AskCard.FieldValue] = [:]
    /// 加密卡的输入单开着（docs/plan-secure-ask-sheet.md）；关单（取消 / 下拉 / 保存成功）清草稿
    @State private var sheetOpen = false

    private var chatCard: ChatCard { .ask(card) }

    private struct Snapshot {
        let status: ChatCardStatus
        let pending: AskCard?
        var badge: ChatCardBadge {
            if status == .stale { return .stale }
            return pending == nil ? .none : .pending
        }
    }

    private func snapshot() -> Snapshot {
        guard !streaming, let viewModel else { return Snapshot(status: .readOnly, pending: nil) }
        let status = viewModel.cardStatus(chatCard, nodeId: nodeId)
        guard status == .live, let id = chatCard.id,
              case .ask(let q)? = viewModel.pendingCard(id: id),
              ChatCardIndex.showsPending(baseNodeId: viewModel.cardStagingBase[id], nodeId: nodeId) else {
            return Snapshot(status: status, pending: nil)
        }
        return Snapshot(status: status, pending: q)
    }

    var body: some View {
        let snap = snapshot()
        let shown = snap.pending ?? card
        let interactive = snap.status == .live && shown.problem == nil
        ChatCardShell(kindLabel: "提问", badge: snap.badge) {
            VStack(alignment: .leading, spacing: 12) {
                if Self.usesSheet(shown) {
                    secureCard(shown, interactive: interactive)
                } else {
                    Text(shown.question).font(.headline)
                    if let options = shown.options {
                        optionsList(options, shown: shown, interactive: interactive)
                    } else if shown.problem == nil {
                        if let fields = shown.fields {
                            formRows(fields, shown: shown, interactive: interactive)
                        } else {
                            answerRow(shown, interactive: interactive)
                        }
                    }
                }
                if let problem = shown.problem {
                    Text(problem).font(.caption).foregroundStyle(CodeBlockStyle.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $sheetOpen, onDismiss: clearSheetDrafts) {
            secureSheet(shown)
        }
        .onChange(of: interactive) { _, live in
            if !live { sheetOpen = false }
        }
    }

    // MARK: - 选项

    @ViewBuilder
    private func optionsList(_ options: [String], shown: AskCard, interactive: Bool) -> some View {
        let selected = shown.multi ? (multiDraft ?? Set(shown.validPicked)) : Set(shown.validPicked)
        VStack(alignment: .leading, spacing: 4) {
            if shown.multi {
                Text("可多选").font(.caption).foregroundStyle(CodeBlockStyle.label)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Button { tap(i, shown: shown) } label: {
                    optionRow(index: i, text: option, on: selected.contains(i))
                }
                .buttonStyle(.plain)
                .disabled(!interactive)
            }
            if shown.multi, interactive {
                Button { confirmMulti(shown) } label: {
                    Label("确定", systemImage: "checkmark")
                        .font(.subheadline)
                        .foregroundStyle(CodeBlockStyle.label)
                }
                .buttonStyle(.plain)
                .disabled((multiDraft ?? []).isEmpty)
                .padding(.top, 4)
            }
        }
    }

    /// 样子同 AskUserQuestionSheet.optionRow（编号圆圈 + 文字），选中 = 圆圈填满 + 行尾对勾
    private func optionRow(index: Int, text: String, on: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? Theme.branchIndicator : CodeBlockStyle.stroke))
            Text(text)
                .foregroundStyle(Color.primary)
                .fontWeight(on ? .semibold : .regular)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.branchIndicator)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func tap(_ index: Int, shown: AskCard) {
        if shown.multi {
            var set = multiDraft ?? Set(shown.validPicked)
            if set.contains(index) { set.remove(index) } else { set.insert(index) }
            multiDraft = set
        } else {
            viewModel?.stageCard(.ask(shown.picking([index])), baseNodeId: nodeId)
        }
    }

    private func confirmMulti(_ shown: AskCard) {
        guard let set = multiDraft, !set.isEmpty else { return }
        viewModel?.stageCard(.ask(shown.picking(Array(set))), baseNodeId: nodeId)
        multiDraft = nil
    }

    // MARK: - 问答

    @ViewBuilder
    private func answerRow(_ shown: AskCard, interactive: Bool) -> some View {
        let text = draft ?? shown.answer ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 10) {
            Group {
                if interactive {
                    TextField(shown.placeholder ?? "写下你的回答", text: Binding(get: { text }, set: { draft = $0 }))
                        .textFieldStyle(.plain)
                        .onSubmit { submitAnswer(trimmed, shown: shown) }
                } else {
                    Text(shown.answer ?? shown.placeholder ?? " ")
                        .foregroundStyle(shown.answer == nil ? CodeBlockStyle.label : Color.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
            if interactive {
                Button { submitAnswer(trimmed, shown: shown) } label: {
                    Text("填好了")
                        .font(.subheadline)
                        .foregroundStyle(CodeBlockStyle.label)
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || trimmed == shown.answer)
            }
        }
    }

    private func submitAnswer(_ trimmed: String, shown: AskCard) {
        guard !trimmed.isEmpty, trimmed != shown.answer else { return }
        viewModel?.stageCard(.ask(shown.answering(trimmed)), baseNodeId: nodeId)
        draft = nil
    }

    // MARK: - 加密问答

    /// 走弹单的卡（docs/plan-secure-ask-sheet.md）：单个加密问答，或含任一加密项的表单；其余提问卡照旧在卡里填
    static func usesSheet(_ card: AskCard) -> Bool {
        guard card.options == nil else { return false }
        if let fields = card.fields { return fields.contains(where: \.secure) }
        return card.secure
    }

    /// 单个加密卡的那一项叫什么（小卡副标题 / 弹单 label / 无障碍 label）
    private static func secretName(_ card: AskCard) -> String {
        card.placeholder ?? "密码"
    }

    /// 卡上加密答案（单个 = answer；表单 = 各加密项的 answer）
    private static func secretAnswers(_ card: AskCard) -> [String] {
        if let fields = card.fields { return fields.filter(\.secure).compactMap(\.answer) }
        return card.answer.map { [$0] } ?? []
    }

    private static func answered(_ card: AskCard) -> Bool {
        if let fields = card.fields { return fields.contains { $0.answer != nil || $0.picked != nil } }
        return card.answer != nil
    }

    /// 普通项的答案原文（选择项写选项文字，数字带单位）；密码不露
    private static func plainAnswers(_ card: AskCard) -> [String] {
        (card.fields ?? []).filter { !$0.secure }.compactMap { field in
            if let picked = field.picked {
                let names = picked.compactMap { field.options?.indices.contains($0) == true ? field.options?[$0] : nil }
                return names.isEmpty ? nil : names.joined(separator: "、")
            }
            guard let answer = field.answer, !answer.isEmpty else { return nil }
            return answer + (field.kind == .number || field.kind == .slider ? (field.unit ?? "") : "")
        }
    }

    /// 聊天里的小卡：图标 + 题目 + 副标题 + 整宽「填写」/「修改」；输入在弹单里
    @ViewBuilder
    private func secureCard(_ shown: AskCard, interactive: Bool) -> some View {
        let answers = Self.secretAnswers(shown)
        // 模型自己写了 answer：不冒充加密值，也不把它显示出来
        let notSecret = answers.contains { !SecretVault.isPlaceholder($0) }
        let saved = Self.answered(shown) && !answers.isEmpty && !notSecret
        let unfilledNote = shown.siteDisplay
            ?? (shown.fields.map { $0.map(\.label).joined(separator: "、") } ?? Self.secretName(shown))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: saved ? "checkmark" : "lock")
                    .font(.system(size: 17, weight: saved ? .semibold : .regular))
                    .foregroundStyle(saved ? Color.white : CodeBlockStyle.label)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(saved ? Theme.branchIndicator : Theme.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.question).font(.headline)
                    if saved {
                        SecretSavedSubtitle(plain: Self.plainAnswers(shown), answer: answers[0])
                    } else {
                        Text("加密卡 · " + unfilledNote)
                            .font(.caption)
                            .foregroundStyle(CodeBlockStyle.label)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if interactive {
                Button { sheetOpen = true } label: {
                    Text(Self.answered(shown) ? "修改" : "填写")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.branchIndicator))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if notSecret {
                Text("这张卡的答案不是加密值").font(.caption).foregroundStyle(CodeBlockStyle.label)
            }
            if isCCConversation {
                Text("CC 会话里还不能使用加密值").font(.caption).foregroundStyle(CodeBlockStyle.label)
            }
        }
    }

    /// 弹单：单个加密卡一个圆点框；表单复用表单行控件（不描边，虚线分隔）
    private func secureSheet(_ shown: AskCard) -> some View {
        SecureAskSheet(question: shown.question,
                       site: shown.siteDisplay,
                       thisConversationOnly: $secretThisConversationOnly,
                       saveFailed: secretSaveFailed,
                       canSave: shown.fields.map(formReady)
                           ?? !secretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       onSave: { saveSheet(shown) },
                       onCancel: { sheetOpen = false }) {
            if let fields = shown.fields {
                ForEach(Array(fields.enumerated()), id: \.offset) { i, field in
                    if i > 0 { SecureAskDashedRule() }
                    formField(i, field: field, shown: shown, fields: fields, interactive: true, boxed: false)
                        .padding(.vertical, 9)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.secretName(shown)).font(.caption).foregroundStyle(CodeBlockStyle.label)
                    SecureField(shown.answer == nil ? "只存进钥匙串，AI 看不到" : "重填", text: $secretDraft)
                        .textFieldStyle(.plain)
                        .textContentType(.oneTimeCode)
                        .accessibilityLabel(Self.secretName(shown))
                        .onSubmit { submitSecret(shown) }
                        .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
            }
        }
    }

    private func saveSheet(_ shown: AskCard) {
        if let fields = shown.fields { submitForm(shown, fields: fields) } else { submitSecret(shown) }
    }

    /// 关单（取消 / 下拉 / 保存成功）：加密草稿清掉；普通项也回到卡上的答案，下次「修改」从上次答案起
    private func clearSheetDrafts() {
        secretDraft = ""
        secretFieldDrafts = [:]
        fieldDrafts = [:]
        formValues = [:]
        secretSaveFailed = false
    }

    /// 真值进钥匙串 → 卡上只放占位；真值不进 stageCard / 附件 / 草稿
    private func submitSecret(_ shown: AskCard) {
        guard let viewModel, !secretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var scope: String? = nil
        if secretThisConversationOnly {
            guard let conv = viewModel.selectedConversation?.id else { secretSaveFailed = true; return }
            scope = conv
        }
        guard let id = SecretVault.save(secretDraft, label: shown.question, conversationId: scope) else {
            secretSaveFailed = true
            return
        }
        secretDraft = ""
        secretSaveFailed = false
        viewModel.stageCard(.ask(shown.answering(SecretVault.placeholder(id))), baseNodeId: nodeId)
        sheetOpen = false
    }

    // MARK: - 表单

    /// 每行 label + 框（普通 TextField / 加密 SecureField）；有加密框才出范围开关（整卡共用）；一个「提交」（直接发）
    @ViewBuilder
    private func formRows(_ fields: [AskCard.Field], shown: AskCard, interactive: Bool) -> some View {
        let hasSecret = fields.contains(where: \.secure)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(fields.enumerated()), id: \.offset) { i, field in
                formField(i, field: field, shown: shown, fields: fields, interactive: interactive)
            }
            if interactive {
                if hasSecret {
                    Toggle("只在这个对话里用", isOn: $secretThisConversationOnly)
                        .font(.caption)
                        .foregroundStyle(CodeBlockStyle.label)
                        .tint(Theme.branchIndicator)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button { submitForm(shown, fields: fields) } label: {
                        Text("提交")
                            .font(.subheadline)
                            .foregroundStyle(CodeBlockStyle.label)
                    }
                    .buttonStyle(.plain)
                    .disabled(!formReady(fields))
                }
                if secretSaveFailed {
                    Text("没存进钥匙串，再试一次").font(.caption).foregroundStyle(CodeBlockStyle.label)
                }
            }
            if hasSecret, isCCConversation {
                Text("CC 会话里还不能使用加密值").font(.caption).foregroundStyle(CodeBlockStyle.label)
            }
        }
    }

    /// 表单的一项：label + 控件 + 当场校验提示；卡里（描边框）和加密卡弹单（boxed: false，不描边）共用
    @ViewBuilder
    private func formField(_ i: Int, field: AskCard.Field, shown: AskCard, fields: [AskCard.Field], interactive: Bool,
                           boxed: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.required || field.secure ? field.label : "\(field.label)（选填）")
                .font(.caption).foregroundStyle(CodeBlockStyle.label)
            if field.secure {
                secretFieldRow(i, field: field, shown: shown, fields: fields, boxed: boxed)
            } else if field.kind == .text {
                plainFieldRow(i, field: field, shown: shown, fields: fields, interactive: interactive, boxed: boxed)
            } else {
                typedFieldRow(i, field: field, interactive: interactive, boxed: boxed)
            }
            // 格式 / 范围不对当场提示；「必填」只让按钮变灰，不一上来就满屏红字
            if interactive, !field.secure, let p = field.problem(for: value(i, field)), p != "必填" {
                Text(p).font(.caption2).foregroundStyle(Color.red.opacity(0.75))
            }
        }
    }

    @ViewBuilder
    private func plainFieldRow(_ i: Int, field: AskCard.Field, shown: AskCard, fields: [AskCard.Field], interactive: Bool,
                               boxed: Bool) -> some View {
        Group {
            if interactive {
                TextField(field.placeholder ?? "写下你的回答",
                          text: Binding(get: { fieldDrafts[i] ?? initialText(field) }, set: { fieldDrafts[i] = $0 }))
                    .textFieldStyle(.plain)
                    .accessibilityLabel(field.label)
                    .onSubmit { submitForm(shown, fields: fields) }
            } else {
                Text(field.answer ?? field.placeholder ?? " ")
                    .foregroundStyle(field.answer == nil ? CodeBlockStyle.label : Color.primary)
            }
        }
        .fieldBox(boxed)
    }

    /// 加密项只在弹单里填（docs/plan-secure-ask-sheet.md）：已存过的留空 = 沿用旧占位
    private func secretFieldRow(_ i: Int, field: AskCard.Field, shown: AskCard, fields: [AskCard.Field], boxed: Bool) -> some View {
        let keeps = field.answer.map(SecretVault.isPlaceholder) ?? false
        return SecureField(keeps ? "留空沿用" : (field.placeholder ?? "只存进钥匙串，AI 看不到"),
                           text: Binding(get: { secretFieldDrafts[i] ?? "" }, set: { secretFieldDrafts[i] = $0 }))
            .textFieldStyle(.plain)
            .textContentType(.oneTimeCode)
            .accessibilityLabel(field.label)
            .onSubmit { submitForm(shown, fields: fields) }
            .fieldBox(boxed)
    }

    private func plainValue(_ i: Int, _ field: AskCard.Field) -> String {
        (fieldDrafts[i] ?? initialText(field)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var today: String { Self.dayFormatter.string(from: Date()) }

    private func initialText(_ field: AskCard.Field) -> String {
        if case .text(let t) = field.initialValue(today: today) { return t }
        return ""
    }

    /// 这一项现在的值（文字项走 fieldDrafts，其余走 formValues；都没改过 = 已答 / 默认）
    private func value(_ i: Int, _ field: AskCard.Field) -> AskCard.FieldValue {
        if field.kind == .text { return .text(fieldDrafts[i] ?? initialText(field)) }
        return formValues[i] ?? field.initialValue(today: today)
    }

    private func pickedSet(_ i: Int, _ field: AskCard.Field) -> Set<Int> {
        if case .picked(let ix) = value(i, field) { return Set(ix) }
        return []
    }

    private func textValue(_ i: Int, _ field: AskCard.Field) -> String {
        if case .text(let t) = value(i, field) { return t }
        return ""
    }

    // MARK: 带类型的项（粟粟 10-03 表单卡）

    @ViewBuilder
    private func typedFieldRow(_ i: Int, field: AskCard.Field, interactive: Bool, boxed: Bool) -> some View {
        switch field.kind {
        case .single, .multi:
            let selected = pickedSet(i, field)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array((field.options ?? []).enumerated()), id: \.offset) { j, option in
                    Button {
                        var next = selected
                        if field.kind == .single { next = selected.contains(j) && !field.required ? [] : [j] }
                        else if next.contains(j) { next.remove(j) } else { next.insert(j) }
                        formValues[i] = .picked(next.sorted())
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: field.kind == .multi
                                  ? (selected.contains(j) ? "checkmark.square.fill" : "square")
                                  : (selected.contains(j) ? "largecircle.fill.circle" : "circle"))
                                .foregroundStyle(selected.contains(j) ? Theme.branchIndicator : CodeBlockStyle.label)
                            Text(option).foregroundStyle(Color.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!interactive)
                    .accessibilityAddTraits(selected.contains(j) ? .isSelected : [])
                }
            }
        case .date:
            if interactive {
                DatePicker(field.label, selection: Binding(
                    get: { Self.dayFormatter.date(from: textValue(i, field)) ?? Date() },
                    set: { formValues[i] = .text(Self.dayFormatter.string(from: $0)) }),
                    displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            } else {
                Text(field.answer ?? " ").fieldBox()
            }
        case .number:
            HStack(spacing: 8) {
                if interactive {
                    TextField(field.placeholder ?? "数字", text: Binding(get: { textValue(i, field) },
                                                                       set: { formValues[i] = .text($0) }))
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityLabel(field.label)
                        .fieldBox(boxed)
                    if let unit = field.unit { Text(unit).foregroundStyle(CodeBlockStyle.label) }
                    Stepper(field.label, onIncrement: { nudge(i, field, by: 1) }, onDecrement: { nudge(i, field, by: -1) })
                        .labelsHidden()
                } else {
                    Text((field.answer ?? " ") + (field.answer != nil ? (field.unit ?? "") : "")).fieldBox()
                }
            }
        case .slider:
            let lo = field.min ?? 0, hi = Swift.max(field.max ?? 1, lo + 1)
            HStack(spacing: 10) {
                Slider(value: Binding(get: { Double(textValue(i, field)) ?? lo },
                                      set: { formValues[i] = .text(AskCard.Field.format($0)) }),
                       in: lo...hi, step: field.step ?? 1)
                    .tint(Theme.branchIndicator)
                    .disabled(!interactive)
                    .accessibilityLabel(field.label)
                Text(textValue(i, field) + (field.unit ?? ""))
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 44, alignment: .trailing)
            }
        case .text:
            EmptyView()
        }
    }

    /// 数字项的加减：按 step（默认 1），夹在最小 / 最大之间
    private func nudge(_ i: Int, _ field: AskCard.Field, by sign: Double) {
        var n = (Double(textValue(i, field)) ?? field.min ?? 0) + sign * (field.step ?? 1)
        if let lo = field.min { n = Swift.max(n, lo) }
        if let hi = field.max { n = Swift.min(n, hi) }
        formValues[i] = .text(AskCard.Field.format(n))
    }

    private func hasNewSecret(_ i: Int) -> Bool {
        !(secretFieldDrafts[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 每项都过校验（必填有值、格式 / 范围对；加密项留空 = 沿用旧占位）；答过的卡要至少改一处才能再交
    private func formReady(_ fields: [AskCard.Field]) -> Bool {
        var changed = false
        let answeredBefore = fields.contains { $0.answer != nil || $0.picked != nil }
        for (i, field) in fields.enumerated() {
            if field.secure {
                if hasNewSecret(i) { changed = true; continue }
                guard let answer = field.answer, SecretVault.isPlaceholder(answer) else { return false }
            } else {
                let v = value(i, field)
                if field.problem(for: v) != nil { return false }
                switch v {
                case .text(let t):
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed != (field.answer ?? "") { changed = true }
                case .picked(let ix):
                    if ix.sorted() != (field.picked ?? []) { changed = true }
                }
            }
        }
        return answeredBefore ? changed : true
    }

    /// 加密项逐个进钥匙串（任何一个失败：已存的删掉、整卡不 stage、输入留着重试），普通项原文
    private func submitForm(_ shown: AskCard, fields: [AskCard.Field]) {
        guard let viewModel, formReady(fields) else { return }
        var scope: String? = nil
        if fields.contains(where: \.secure), secretThisConversationOnly {
            guard let conv = viewModel.selectedConversation?.id else { secretSaveFailed = true; return }
            scope = conv
        }
        var values: [AskCard.FieldValue] = []
        var savedIds: [String] = []
        for (i, field) in fields.enumerated() {
            guard field.secure else {
                values.append(value(i, field))
                continue
            }
            guard hasNewSecret(i), let secret = secretFieldDrafts[i] else {
                values.append(.text(field.answer ?? ""))
                continue
            }
            guard let id = SecretVault.save(secret, label: "\(shown.question) · \(field.label)", conversationId: scope) else {
                savedIds.forEach(SecretVault.delete)
                secretSaveFailed = true
                return
            }
            savedIds.append(id)
            values.append(.text(SecretVault.placeholder(id)))
        }
        fieldDrafts = [:]
        secretFieldDrafts = [:]
        formValues = [:]
        secretSaveFailed = false
        // 粟粟 10-03：表单提交直接发出去（只发这张卡，不动输入框里的草稿）
        viewModel.sendCardNow(.ask(shown.filling(values: values)), baseNodeId: nodeId)
        sheetOpen = false
    }

    /// CC / Codex 桥：工具在 hub 那边执行，app 换不了真值
    private var isCCConversation: Bool {
        guard let providerManager, let conv = viewModel?.selectedConversation else { return false }
        let model = providerManager.resolveModel(conversationModelId: conv.selectedModelId,
                                                 globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        return providerManager.provider(for: model)?.type == .ccBridge
    }
}

/// 加密小卡填好后的副标题：「已保存 · 普通项答案 · 范围」（范围从钥匙串属性里读）；密码不露
private struct SecretSavedSubtitle: View {
    let plain: [String]
    let answer: String
    @State private var scopeNote: String?

    var body: some View {
        Text((["已保存"] + plain + [scopeNote].compactMap { $0 }).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(CodeBlockStyle.label)
            .lineLimit(1)
            .task(id: answer) { scopeNote = Self.scopeNote(for: answer) }
    }

    private static func scopeNote(for answer: String) -> String? {
        guard let id = SecretVault.ids(in: answer).first else { return nil }
        guard let entry = SecretVault.entry(id) else { return "这台设备上没有" }
        return entry.conversationId == nil ? "所有对话" : "仅这个对话"
    }
}

extension View {
    /// 问答框的描边样式（同 answerRow；审批卡也用）
    func fieldBox() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
    }

    /// boxed = false：加密卡弹单的字段组里不描边（字段组本身是白底圆角卡，项之间虚线）
    @ViewBuilder
    fileprivate func fieldBox(_ boxed: Bool) -> some View {
        if boxed {
            fieldBox()
        } else {
            frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
        }
    }
}
