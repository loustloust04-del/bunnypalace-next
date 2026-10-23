import SwiftUI

// MARK: - Regex Script Editor

struct RegexScriptEditor: View {
    let script: RegexScript
    let isNew: Bool
    let onSave: (RegexScript) -> Void
    let onCancel: () -> Void

    @State private var scriptName: String
    @State private var findRegex: String
    @State private var replaceString: String
    @State private var markdownOnly: Bool
    @State private var promptOnly: Bool
    @State private var disabled: Bool
    @State private var placementUser: Bool
    @State private var placementAI: Bool

    init(script: RegexScript, isNew: Bool, onSave: @escaping (RegexScript) -> Void, onCancel: @escaping () -> Void) {
        self.script = script
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _scriptName = State(initialValue: script.scriptName)
        _findRegex = State(initialValue: script.findRegex)
        _replaceString = State(initialValue: script.replaceString)
        _markdownOnly = State(initialValue: script.markdownOnly)
        _promptOnly = State(initialValue: script.promptOnly)
        _disabled = State(initialValue: script.disabled)
        _placementUser = State(initialValue: script.placement.contains(1))
        _placementAI = State(initialValue: script.placement.contains(2))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("取消") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.branchIndicator)
                Spacer()
                Text(isNew ? "新建正则" : "编辑正则")
                    .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.branchIndicator))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.2)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fieldSection("脚本名称") {
                        TextField("状态栏", text: $scriptName)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                    }

                    fieldSection("查找正则（/pattern/flags）") {
                        TextEditor(text: $findRegex)
                            .font(.system(size: Theme.F.mono, design: .monospaced))
                            .frame(minHeight: 60)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                            .scrollContentBackground(.hidden)
                    }

                    fieldSection("替换模板（$1 $2 捕获组）") {
                        TextEditor(text: $replaceString)
                            .font(.system(size: Theme.F.mono, design: .monospaced))
                            .frame(minHeight: 80)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                            .scrollContentBackground(.hidden)
                    }

                    // 应用目标
                    fieldSection("应用到") {
                        HStack(spacing: 16) {
                            Toggle("用户消息", isOn: $placementUser)
                                .font(.system(size: Theme.F.body))
                            Toggle("AI 消息", isOn: $placementAI)
                                .font(.system(size: Theme.F.body))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }

                    // 模式
                    fieldSection("执行时机") {
                        HStack(spacing: 16) {
                            Toggle("渲染时", isOn: $markdownOnly)
                                .font(.system(size: Theme.F.body))
                            Toggle("发送 API 时", isOn: $promptOnly)
                                .font(.system(size: Theme.F.body))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                        // 副文案按双 toggle 状态切换：双开警告（事故根因防呆）/ 双关说明 / 单选不显示
                        if markdownOnly && promptOnly {
                            Text("⚠️ 两个都开 = 渲染时和发送时都跑，楼层里也会被替换")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(.red)
                        } else if !markdownOnly && !promptOnly {
                            Text("两个都关 = 普通模式（非渲染非API）")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                .padding(16)
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
        .background(Theme.sidebarBg)
    }

    private func fieldSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
            content()
        }
    }

    private func save() {
        var updated = script
        updated.scriptName = scriptName
        updated.findRegex = findRegex
        updated.replaceString = replaceString
        updated.markdownOnly = markdownOnly
        updated.promptOnly = promptOnly
        updated.disabled = disabled

        var placement: [Int] = []
        if placementUser { placement.append(1) }
        if placementAI { placement.append(2) }
        if placement.isEmpty { placement = [2] } // 默认 AI
        updated.placement = placement

        onSave(updated)
    }
}
