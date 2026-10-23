import SwiftUI

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 自定义键编辑器（plan §C6，物料表 §10.3）。三种动作类型：文本 / 组合键 / 序列。
///
/// 跟 rootshell 的两处差别，都是**修掉它的已知缺口**而不是照抄（物料表 ASK2 裁决）：
/// - **数字 + Shift 禁选**：rootshell 让你选得出 Shift+1，执行时却发的是 `1`（`characterData`
///   收了 shift 但没用，§10.4）。发不出来的组合干脆不让选。
/// - **Cmd 没有**：tmux 终端没有 Cmd 字节可发，rootshell 自己的 Cmd 宏也是存而不发的死码。
struct TerminalCustomKeyEditor: View {
    let existing: TerminalCustomKey?
    let onSave: (TerminalCustomKey) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum ActionType: String, CaseIterable, Identifiable {
        case text = "文本"
        case combo = "组合键"
        case sequence = "序列"
        var id: String { rawValue }
    }

    @State private var label: String
    @State private var actionType: ActionType
    @State private var text: String
    @State private var appendReturn: Bool
    @State private var modifiers: TerminalKeyModifiers
    @State private var comboKey: TerminalKeyCombo.ComboKey
    @State private var steps: [TerminalSequenceStep]

    init(existing: TerminalCustomKey?, onSave: @escaping (TerminalCustomKey) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _label = State(initialValue: existing?.label ?? "")

        let sequence = existing?.sequence ?? []
        switch sequence.count {
        case 1:
            switch sequence[0] {
            case .text(let t):
                _actionType = State(initialValue: .text)
                _text = State(initialValue: t.hasSuffix("\r") ? String(t.dropLast()) : t)
                _appendReturn = State(initialValue: t.hasSuffix("\r"))
                _modifiers = State(initialValue: [])
                _comboKey = State(initialValue: .letter("a"))
            case .keyCombo(let c):
                _actionType = State(initialValue: .combo)
                _text = State(initialValue: "")
                _appendReturn = State(initialValue: false)
                _modifiers = State(initialValue: c.modifiers)
                _comboKey = State(initialValue: c.key)
            }
        case 0:
            _actionType = State(initialValue: .text)
            _text = State(initialValue: "")
            // 新建默认带回车 —— 自定义键多半是「敲一条命令」（物料表 §10.3）
            _appendReturn = State(initialValue: true)
            _modifiers = State(initialValue: [])
            _comboKey = State(initialValue: .letter("a"))
        default:
            _actionType = State(initialValue: .sequence)
            _text = State(initialValue: "")
            _appendReturn = State(initialValue: false)
            _modifiers = State(initialValue: [])
            _comboKey = State(initialValue: .letter("a"))
        }
        _steps = State(initialValue: sequence.count > 1 ? sequence : [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("键面文字") {
                    TextField("显示在键上的字", text: $label)
                    if label.count > 2 {
                        Text("没设图标时键面只显示前 2 个字：\(String(label.prefix(2)))")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                    }
                }

                Picker("类型", selection: $actionType) {
                    ForEach(ActionType.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch actionType {
                case .text: textSection
                case .combo: comboSection
                case .sequence: sequenceSection
                }
            }
            .navigationTitle(existing == nil ? "新建按键" : "编辑按键")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let key = build() { onSave(key) }
                        dismiss()
                    }
                    .disabled(build() == nil)
                }
            }
        }
    }

    // MARK: 三种类型

    private var textSection: some View {
        Section {
            TextField("要发送的文字", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Toggle("末尾加回车", isOn: $appendReturn)
        } footer: {
            Text("整段按 UTF-8 发给终端。")
        }
    }

    private var comboSection: some View {
        Section {
            Toggle("Control", isOn: modifierBinding(.control))
            Toggle("Option", isOn: modifierBinding(.alt))
            Toggle("Shift", isOn: modifierBinding(.shift))
                .disabled(isDigitKey)
            Picker("按键", selection: $comboKey) {
                ForEach(Self.letterKeys, id: \.self) { Text(Self.keyLabel($0)).tag($0) }
                ForEach(Self.digitKeys, id: \.self) { Text(Self.keyLabel($0)).tag($0) }
                ForEach(Self.specialKeys, id: \.self) { Text(Self.keyLabel($0)).tag($0) }
            }
            .onChange(of: comboKey) { _, _ in
                // 切到数字就把 Shift 摘掉，别留一个发不出去的组合
                if isDigitKey { modifiers.remove(.shift) }
            }
        } footer: {
            Text(isDigitKey
                 ? "数字键不能配 Shift —— 终端这条链上 Shift+数字不会变成符号，选了也发不出来。要发 ! @ # 直接用「文本」类型。"
                 : "Ctrl+字母 = ascii−96，Option = ESC 前缀，方向/Home/End 这类走 xterm CSI 参数。")
        }
    }

    private var sequenceSection: some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text(Self.stepLabel(step))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }
            .onDelete { steps.remove(atOffsets: $0) }
            .onMove { steps.move(fromOffsets: $0, toOffset: $1) }

            Button {
                steps.append(.text(text.isEmpty ? " " : text))
                text = ""
            } label: {
                Label("加一步文本", systemImage: "text.cursor")
                    .foregroundColor(Theme.branchIndicator)
            }
            Button {
                steps.append(.keyCombo(TerminalKeyCombo(modifiers: modifiers, key: comboKey)))
            } label: {
                Label("加一步组合键", systemImage: "command")
                    .foregroundColor(Theme.branchIndicator)
            }
            TextField("下一步的文本", text: $text)
                .autocorrectionDisabled()
        } footer: {
            Text("逐步发送。某一步最后一个字节是 ESC 且后面还有步时会自动等 50ms，防止终端把 ESC 和下一个字符合成 Option+键。")
        }
    }

    // MARK: 组装

    private var isDigitKey: Bool {
        if case .digit = comboKey { return true }
        return false
    }

    private func modifierBinding(_ m: TerminalKeyModifiers) -> Binding<Bool> {
        Binding(
            get: { modifiers.contains(m) },
            set: { on in if on { modifiers.insert(m) } else { modifiers.remove(m) } }
        )
    }

    private func build() -> TerminalCustomKey? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let sequence: [TerminalSequenceStep]
        switch actionType {
        case .text:
            guard !text.isEmpty else { return nil }
            sequence = [.text(appendReturn ? text + "\r" : text)]
        case .combo:
            sequence = [.keyCombo(TerminalKeyCombo(modifiers: modifiers, key: comboKey))]
        case .sequence:
            guard !steps.isEmpty else { return nil }
            sequence = steps
        }
        return TerminalCustomKey(id: existing?.id ?? UUID(),
                                 label: trimmed,
                                 iconName: existing?.iconName,
                                 sequence: sequence)
    }

    // MARK: 选择器物料

    static let letterKeys: [TerminalKeyCombo.ComboKey] =
        "abcdefghijklmnopqrstuvwxyz".map { .letter(String($0)) }
    static let digitKeys: [TerminalKeyCombo.ComboKey] =
        "0123456789".map { .digit(String($0)) }
    static let specialKeys: [TerminalKeyCombo.ComboKey] =
        TerminalKeyCombo.SpecialKey.allCases.map { .special($0) }

    static func keyLabel(_ key: TerminalKeyCombo.ComboKey) -> String {
        switch key {
        case .letter(let s): return s.uppercased()
        case .digit(let s): return s
        case .symbol(let s): return s
        case .special(let sp): return sp.label
        }
    }

    static func stepLabel(_ step: TerminalSequenceStep) -> String {
        switch step {
        case .text(let t):
            return "文本 · \(t.replacingOccurrences(of: "\r", with: "↵"))"
        case .keyCombo(let c):
            var parts: [String] = []
            if c.modifiers.contains(.control) { parts.append("⌃") }
            if c.modifiers.contains(.alt) { parts.append("⌥") }
            if c.modifiers.contains(.shift) { parts.append("⇧") }
            return "组合 · " + parts.joined() + keyLabel(c.key)
        }
    }
}
