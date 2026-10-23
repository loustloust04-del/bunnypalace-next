import SwiftUI

/// 正则编辑页（⑤b，小样 07 第二台）：名字 / 查找 / 替换 / 作用阶段 / 作用对象 / 深度 / 编辑时运行 + 测试区。
/// 阶段映射回旧 flags（不改存储格式），旧 flags 表达不了的组合禁止保存；测试区走生产执行链。
struct RegexRuleEditor: View {
    let rule: RegexScript
    let ownerLabel: String
    let isNew: Bool
    let names: EffectiveCharacterContext
    let onSave: (RegexScript) throws -> Void
    let onDelete: (() throws -> Void)?
    let onCancel: () -> Void

    @State private var name: String
    @State private var find: String
    @State private var replace: String
    @State private var display: Bool
    @State private var send: Bool
    @State private var input: Bool
    @State private var targetUser: Bool
    @State private var targetAI: Bool
    @State private var targetWorld: Bool
    @State private var depthText: String
    @State private var runOnEdit: Bool
    @State private var testText = ""
    @State private var testAsUser = false
    @State private var saveError: String?
    @State private var confirmingDelete = false
    private let initialDepthText: String

    init(rule: RegexScript, ownerLabel: String, isNew: Bool, names: EffectiveCharacterContext,
         onSave: @escaping (RegexScript) throws -> Void, onDelete: (() throws -> Void)?, onCancel: @escaping () -> Void) {
        self.rule = rule
        self.ownerLabel = ownerLabel
        self.isNew = isNew
        self.names = names
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        let phases = rule.phases
        let depth = RegexLibrary.recentCount(maxDepth: rule.maxDepth).map(String.init) ?? ""
        initialDepthText = depth
        _name = State(initialValue: rule.scriptName)
        _find = State(initialValue: rule.findRegex)
        _replace = State(initialValue: rule.replaceString)
        _display = State(initialValue: phases.contains(.display))
        _send = State(initialValue: phases.contains(.send))
        _input = State(initialValue: phases.contains(.input))
        _targetUser = State(initialValue: rule.placement.contains(RegexPipeline.userPlacement))
        _targetAI = State(initialValue: rule.placement.contains(RegexPipeline.assistantPlacement))
        _targetWorld = State(initialValue: rule.placement.contains(RegexPipeline.worldInfoPlacement))
        _depthText = State(initialValue: depth)
        _runOnEdit = State(initialValue: rule.runOnEdit)
    }

    private var phaseChoice: Set<RegexPhase> {
        var phases: Set<RegexPhase> = []
        if display { phases.insert(.display) }
        if send { phases.insert(.send) }
        if input { phases.insert(.input) }
        return phases
    }

    /// 1 / 2 / 5 之外保存着的 placement 原样留着；勾选没变就连顺序也不动
    private var placement: [Int] {
        let editable = [RegexPipeline.userPlacement, RegexPipeline.assistantPlacement, RegexPipeline.worldInfoPlacement]
        var chosen: [Int] = []
        if targetUser { chosen.append(RegexPipeline.userPlacement) }
        if targetAI { chosen.append(RegexPipeline.assistantPlacement) }
        if targetWorld { chosen.append(RegexPipeline.worldInfoPlacement) }
        let next = chosen + rule.placement.filter { !editable.contains($0) }
        return Set(next) == Set(rule.placement) ? rule.placement : next
    }

    private var edited: Result<RegexScript, RegexLibrary.PhaseChoiceError> {
        RegexLibrary.flags(for: phaseChoice).map { flags in
            var script = rule
            script.scriptName = name
            script.findRegex = find
            script.replaceString = replace
            script.markdownOnly = flags.markdownOnly
            script.promptOnly = flags.promptOnly
            script.placement = placement
            if depthText != initialDepthText {
                script.maxDepth = RegexLibrary.maxDepth(recentCount: Int(depthText))
            }
            script.runOnEdit = runOnEdit
            return script
        }
    }

    private var phaseError: RegexLibrary.PhaseChoiceError? {
        if case .failure(let error) = edited { return error }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    CalendarTicket {
                        titleBlock
                        TicketNotch()
                        field("查找") {
                            TextEditor(text: $find)
                                .font(.system(size: 14, design: .monospaced))
                                .frame(minHeight: 72)
                                .scrollContentBackground(.hidden)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                        field("替换为") {
                            TextField("留空 = 删掉匹配到的文字", text: $replace, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                        IOSSubLabel(text: "作用在")
                        toggleRow("显示", isOn: $display)
                        toggleRow("发送", isOn: $send)
                        toggleRow("输入", isOn: $input)
                        if let phaseError {
                            note(phaseError.message, color: Theme.danger)
                        }
                        IOSSubLabel(text: "作用于")
                        toggleRow("用户消息", isOn: $targetUser)
                        toggleRow("AI 消息", isOn: $targetAI)
                        toggleRow("世界书", isOn: $targetWorld)
                        if RegexLibrary.hasUnsupportedPlacement(rule) {
                            note("还有保存着的其他位置（\(unsupportedList)），这个位置暂不支持，原样保留")
                        }
                        IOSSubLabel(text: "深度")
                        depthRow
                        note(depthNote)
                        toggleRow("编辑时也运行", isOn: $runOnEdit)
                        TicketNotch()
                        testArea
                        Color.clear.frame(height: 12)
                    }
                    if onDelete != nil {
                        Button { confirmingDelete = true } label: {
                            Text("删除这条规则")
                                .font(.system(size: 15))
                                .foregroundColor(Theme.danger)
                                .frame(maxWidth: .infinity, minHeight: 44)
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
            .navigationTitle(isNew ? "新建正则" : "编辑正则")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }.foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(phaseError == nil ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(phaseError != nil)
                }
            }
        }
        .confirmationDialog("删除这条规则？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好的") { saveError = nil }
        } message: { Text(saveError ?? "") }
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("规则名", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(ownerLabel).font(.system(size: 12)).foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 18)
    }

    private var unsupportedList: String {
        rule.placement.filter { RegexLibrary.unsupportedPlacements.contains($0) }.map(String.init).joined(separator: "、")
    }

    private var depthRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("只改最近 N 条").font(.system(size: 16)).foregroundColor(send ? Theme.textPrimary : Theme.textMuted)
                Spacer(minLength: 8)
                TextField("不限", text: $depthText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15))
                    .frame(width: 56, height: 32)
                    .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .disabled(!send)
                    .accessibilityLabel("最近消息条数")
                    .onChange(of: depthText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { depthText = digits }
                    }
                Text("条").font(.system(size: 15)).foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 44)
            IOSHairline()
        }
    }

    private var depthNote: String {
        guard send else { return "只在「发送」打开时生效" }
        guard let count = Int(depthText), count > 0 else { return "不限，所有消息都改" }
        return "仅处理最近 \(count) 条消息，更早的消息保持原样。"
    }

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("测试区").font(.system(size: 12)).tracking(0.5).foregroundColor(Theme.textMuted)
            TextField("输入一句", text: $testText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .background(Theme.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                testTarget("作为用户消息", user: true)
                testTarget("作为 AI 消息", user: false)
            }
            testResult
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 6)
    }

    private func testTarget(_ title: String, user: Bool) -> some View {
        let on = testAsUser == user
        return Button { testAsUser = user } label: {
            Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Theme.branchIndicator : Theme.textMuted)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Theme.accent : Theme.textPrimary.opacity(0.05), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder
    private var testResult: some View {
        let placement = testAsUser ? RegexPipeline.userPlacement : RegexPipeline.assistantPlacement
        switch edited {
        case .failure:
            note("先把「作用在」改成支持的组合再试", color: Theme.textMuted, padded: false)
        case .success(let draft):
            if let error = RegexEngine.compileError(for: draft, userName: names.userName, charName: names.charName) {
                note("正则写不通：\(error)", color: Theme.danger, padded: false)
            } else if draft.findRegex.trimmingCharacters(in: .whitespaces).isEmpty {
                note("先写查找", color: Theme.textMuted, padded: false)
            } else if !draft.placement.contains(placement) {
                note("这条规则没勾「\(testAsUser ? "用户消息" : "AI 消息")」，这句原样不动", color: Theme.textMuted, padded: false)
            } else if !testText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("↓ 改写结果").font(.system(size: 11)).foregroundColor(Theme.branchIndicator)
                    Text(RegexLibrary.preview(draft, text: testText, placement: placement,
                                              userName: names.userName, charName: names.charName))
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
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

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.textMuted)
            content()
                .padding(10)
                .background(Theme.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 12)
    }

    private func note(_ text: String, color: Color = Theme.textMuted, padded: Bool = true) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, padded ? IOSCal.pad : 0)
            .padding(.top, 6)
    }

    private func save() {
        switch edited {
        case .failure(let error): saveError = error.message
        case .success(let script):
            do { try onSave(script) } catch { saveError = error.localizedDescription }
        }
    }

    private func delete() {
        guard let onDelete else { return }
        do { try onDelete() } catch { saveError = error.localizedDescription }
    }
}
