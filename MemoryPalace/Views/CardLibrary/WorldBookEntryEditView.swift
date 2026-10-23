import SwiftUI

/// 条目编辑（⑥，小样 06）：内容 / 触发 / 注入 / 高级 四组。非法值行内提示、不能保存，不替你改；
/// ② 标为不支持的位置显示原值，必须选一个支持的位置才能保存。没动过的字段（关键词原文、可选开关的缺省）原样留着。
struct WorldBookEntryEditView: View {
    let entry: WorldBookEntry
    let bookName: String
    let isNew: Bool
    let readOnly: Bool
    let onSave: (WorldBookEntry) throws -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    enum Failure: LocalizedError {
        case entryMissing
        var errorDescription: String? { "这一条已经不在了（可能被别处删掉），没有保存" }
    }

    @State private var comment: String
    @State private var content: String
    @State private var keysText: String
    @State private var secondaryText: String
    @State private var useSecondary: Bool
    @State private var logic: WorldBookEntry.SelectiveLogic
    @State private var scanDepthText: String
    @State private var useProbability: Bool
    @State private var probabilityText: String
    @State private var position: WorldBookEntry.InsertionPosition
    @State private var depthText: String
    @State private var orderText: String
    @State private var isConstant: Bool
    @State private var matchWholeWords: Bool
    @State private var caseSensitive: Bool
    @State private var saveError: String?
    private let initialKeysText: String
    private let initialSecondaryText: String

    init(entry: WorldBookEntry, bookName: String, isNew: Bool, readOnly: Bool,
         onSave: @escaping (WorldBookEntry) throws -> Void, onDelete: (() -> Void)?, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.bookName = bookName
        self.isNew = isNew
        self.readOnly = readOnly
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        let keys = entry.keys.joined(separator: ", ")
        let secondary = entry.secondaryKeys.joined(separator: ", ")
        initialKeysText = keys
        initialSecondaryText = secondary
        _comment = State(initialValue: entry.comment)
        _content = State(initialValue: entry.content)
        _keysText = State(initialValue: keys)
        _secondaryText = State(initialValue: secondary)
        _useSecondary = State(initialValue: entry.selectiveEnabled != false)
        _logic = State(initialValue: entry.selectiveLogic)
        _scanDepthText = State(initialValue: entry.scanDepth.map(String.init) ?? "")
        _useProbability = State(initialValue: entry.useProbability != false)
        _probabilityText = State(initialValue: String(entry.probability))
        _position = State(initialValue: entry.position)
        _depthText = State(initialValue: entry.depth.map(String.init) ?? "")
        _orderText = State(initialValue: String(entry.insertionOrder))
        _isConstant = State(initialValue: entry.isConstant)
        _matchWholeWords = State(initialValue: entry.matchWholeWords)
        _caseSensitive = State(initialValue: entry.caseSensitive)
    }

    // MARK: - 校验（只提示，不改值）

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    private var scanDepthError: String? {
        let text = Self.trimmed(scanDepthText)
        guard !text.isEmpty else { return nil }
        guard let value = Int(text), value >= 0 else { return "扫描深度要是 0 或正整数；留空 = 最近 10 条" }
        return nil
    }

    private var probabilityError: String? {
        guard let value = Int(Self.trimmed(probabilityText)), (0...100).contains(value) else { return "概率要是 0 到 100 的整数" }
        return nil
    }

    private var depthError: String? {
        let text = Self.trimmed(depthText)
        guard position == .atDepth, !text.isEmpty else { return nil }
        guard let value = Int(text), value >= 0 else { return "深度要是 0 或正整数（0 = 最新一条之后）" }
        return nil
    }

    private var orderError: String? {
        Int(Self.trimmed(orderText)) == nil ? "顺序要是整数" : nil
    }

    private var positionError: String? {
        position == .unsupported ? "选一个支持的位置才能保存" : nil
    }

    private var canSave: Bool {
        !readOnly && [scanDepthError, probabilityError, depthError, orderError, positionError].allSatisfy { $0 == nil }
    }

    private static func splitKeys(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var edited: WorldBookEntry {
        var next = entry
        next.comment = comment
        next.content = content
        if keysText != initialKeysText { next.keys = Self.splitKeys(keysText) }
        if secondaryText != initialSecondaryText { next.secondaryKeys = Self.splitKeys(secondaryText) }
        if useSecondary != (entry.selectiveEnabled != false) { next.selectiveEnabled = useSecondary }
        next.selectiveLogic = logic
        let scan = Self.trimmed(scanDepthText)
        next.scanDepth = scan.isEmpty ? nil : Int(scan)
        if useProbability != (entry.useProbability != false) { next.useProbability = useProbability }
        next.probability = Int(Self.trimmed(probabilityText)) ?? entry.probability
        next.position = position
        if position == .atDepth {
            let depth = Self.trimmed(depthText)
            next.depth = depth.isEmpty ? nil : Int(depth)
        }
        next.insertionOrder = Int(Self.trimmed(orderText)) ?? entry.insertionOrder
        next.isConstant = isConstant
        next.matchWholeWords = matchWholeWords
        next.caseSensitive = caseSensitive
        return next
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    CalendarTicket {
                        titleBlock
                        TicketNotch()
                        IOSSubLabel(text: "内容")
                        field("备注标题") {
                            TextField("给这一条起个名字", text: $comment)
                                .textFieldStyle(.plain).font(.system(size: 15))
                        }
                        field("正文") {
                            TextEditor(text: $content)
                                .font(.system(size: 14))
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                        }
                        TicketNotch()
                        IOSSubLabel(text: "触发")
                        field("主关键词") { keyField("逗号分隔，命中任一就触发", text: $keysText) }
                        field("次关键词") { keyField("可选，逗号分隔", text: $secondaryText) }
                        toggleRow("次关键词参与判断", isOn: $useSecondary)
                        pickerRow("组合逻辑", enabled: useSecondary) {
                            Picker("组合逻辑", selection: $logic) {
                                ForEach(Self.logicOptions, id: \.0) { value, label in Text(label).tag(value) }
                            }
                        }
                        numberRow("扫描深度", text: $scanDepthText, placeholder: "10", unit: "条", prefix: "最近")
                        note(scanDepthError, fallback: "只看最近几条消息里有没有关键词；留空 = 最近 10 条")
                        toggleRow("按概率触发", isOn: $useProbability)
                        numberRow("概率", text: $probabilityText, placeholder: "100", unit: "%", enabled: useProbability)
                        note(probabilityError, fallback: useProbability ? "命中后按这个概率注入" : "关掉 = 命中就注入")
                        TicketNotch()
                        IOSSubLabel(text: "注入")
                        pickerRow("位置", enabled: true) {
                            Picker("位置", selection: $position) {
                                if entry.position == .unsupported {
                                    Text(unsupportedLabel).tag(WorldBookEntry.InsertionPosition.unsupported)
                                }
                                ForEach(WorldBookLibrary.supportedPositions, id: \.self) { value in
                                    Text(WorldBookLibrary.positionName(value)).tag(value)
                                }
                            }
                        }
                        if let positionError { note(positionError, color: Theme.danger) }
                        numberRow("深度", text: $depthText, placeholder: "4", unit: nil, enabled: position == .atDepth, stepper: true)
                        note(depthError, fallback: position == .atDepth ? "0 = 最新一条之后，数字越大越靠前" : "只有「对话中（按深度）」才用得上")
                        numberRow("顺序", text: $orderText, placeholder: "100", unit: nil, stepper: true, allowsNegative: true)
                        note(orderError, fallback: "数字小的先注入")
                        TicketNotch()
                        IOSSubLabel(text: "高级")
                        toggleRow("常驻（不看关键词）", isOn: $isConstant)
                        toggleRow("全词匹配", isOn: $matchWholeWords)
                        toggleRow("区分大小写", isOn: $caseSensitive)
                        Color.clear.frame(height: 12)
                    }
                    .disabled(readOnly)
                    if let onDelete, !readOnly {
                        Button(action: onDelete) {
                            VStack(spacing: 2) {
                                Text("删除条目").font(.system(size: 15)).foregroundColor(Theme.danger)
                                Text("删除后可在 5 秒内撤销").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.sidebarBg)
            .navigationTitle(readOnly ? "查看条目" : (isNew ? "新条目" : "编辑条目"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readOnly ? "关闭" : "取消") { onCancel() }.foregroundColor(Theme.textMuted)
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { save() }
                            .foregroundColor(canSave ? Theme.branchIndicator : Theme.textMuted)
                            .disabled(!canSave)
                    }
                }
            }
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好的") { saveError = nil }
        } message: { Text(saveError ?? "") }
        #if os(macOS)
        .frame(width: 480, height: 680)
        #endif
    }

    private static let logicOptions: [(WorldBookEntry.SelectiveLogic, String)] = [
        (.andAny, "主词任一 ＋ 次词任一"),
        (.andAll, "主词任一 ＋ 次词全部"),
        (.notAny, "主词任一，次词都没出现"),
        (.notAll, "主词任一，次词没全出现"),
    ]

    private var unsupportedLabel: String {
        "不支持的位置" + (WorldBookLibrary.rawPosition(of: entry).map { "（原值 \($0)）" } ?? "")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comment.isEmpty ? WorldBookLibrary.title(of: entry) : comment)
                .font(.system(size: 22, weight: .semibold)).foregroundColor(Theme.textPrimary).lineLimit(2)
            Text("在「\(bookName)」里" + (readOnly ? " · 只读，先切到所属楼层再改" : ""))
                .font(.system(size: 12)).foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 18)
    }

    // MARK: - 行零件

    private func keyField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.textMuted)
            content()
                .padding(10)
                .background(Theme.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 10)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.branchIndicator)
                    .accessibilityLabel(title)
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 44)
            IOSHairline()
        }
    }

    private func pickerRow<Content: View>(_ title: String, enabled: Bool, @ViewBuilder picker: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 16)).foregroundColor(enabled ? Theme.textPrimary : Theme.textMuted)
                Spacer(minLength: 8)
                picker()
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(Theme.textSecondary)
                    .disabled(!enabled)
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 44)
            IOSHairline()
        }
    }

    private func numberRow(_ title: String, text: Binding<String>, placeholder: String, unit: String?,
                           prefix: String? = nil, enabled: Bool = true, stepper: Bool = false,
                           allowsNegative: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 16)).foregroundColor(enabled ? Theme.textPrimary : Theme.textMuted)
                Spacer(minLength: 8)
                if let prefix { Text(prefix).font(.system(size: 15)).foregroundColor(Theme.textMuted) }
                if stepper { stepButton("minus", text: text, delta: -1, placeholder: placeholder, allowsNegative: allowsNegative, enabled: enabled) }
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15))
                    .frame(width: 60, height: 32)
                    .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    #if os(iOS)
                    .keyboardType(allowsNegative ? .numbersAndPunctuation : .numberPad)
                    #endif
                    .disabled(!enabled)
                    .accessibilityLabel(title)
                if stepper { stepButton("plus", text: text, delta: 1, placeholder: placeholder, allowsNegative: allowsNegative, enabled: enabled) }
                if let unit { Text(unit).font(.system(size: 15)).foregroundColor(Theme.textMuted) }
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 44)
            IOSHairline()
        }
    }

    private func stepButton(_ icon: String, text: Binding<String>, delta: Int, placeholder: String,
                            allowsNegative: Bool, enabled: Bool) -> some View {
        Button {
            let current = Int(Self.trimmed(text.wrappedValue)) ?? Int(placeholder) ?? 0
            let next = current + delta
            if allowsNegative || next >= 0 { text.wrappedValue = String(next) }
        } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundColor(enabled ? Theme.branchIndicator : Theme.textMuted)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(delta > 0 ? "加一" : "减一")
    }

    @ViewBuilder
    private func note(_ error: String?, fallback: String) -> some View {
        if let error { note(error, color: Theme.danger) } else { note(fallback, color: Theme.textMuted) }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IOSCal.pad)
            .padding(.top, 6)
    }

    private func save() {
        guard canSave else { return }
        do { try onSave(edited) } catch { saveError = error.localizedDescription }
    }
}
