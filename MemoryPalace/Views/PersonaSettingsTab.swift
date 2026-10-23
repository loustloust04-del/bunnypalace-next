import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

// MARK: - Persona Settings Tab

/// D4 删插槽的唯一实现：按 preset id 读最新 preset、在最新数组里按 slot id 重找 index。
/// 三个入口（iOS swipe / mac 行内 xmark / `SlotEditPage` 删除钮）都只在自己的确认分支里调这一个。
private func deletePromptSlot(presetId: String, slotId: String, psm: PresetManager) {
    guard var p = psm.preset(byId: presetId),
          let idx = p.prompts.firstIndex(where: { $0.id == slotId }) else { return }
    p.prompts.remove(at: idx)
    psm.save(p)
}

struct PersonaSettingsTab: View {
    var useSheetNavigation: Bool = false  // 右栏用 sheet 代替 push 导航
    var viewModel: ConversationViewModel?  // 右栏传入，设置页为 nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.settingsMetrics) private var m
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @AppStorage("personaEditMode") private var personaEditMode = "simple"
    @State private var showPresetImporter = false
    /// 修全局卡顿：Prompt 页检查器用的预览（实发同一条组装路径）不再在 body 里同步算——输入变了防抖 0.25 秒后在 task 里算一次
    @State private var promptPreview: TurnPreview? = nil
    /// #089 P0-c：「请求」页看哪份——sent = 上一次真实发出的（默认）/ preview = 下一轮预览
    @State private var requestSource = "sent"
    /// #00207 返工：预览只在 Prompt 页真被看着时算——page2 切走 / 回聊天时页面还挂着、不会 onDisappear（Air 上每 2–4 秒一次 0.5–1 秒）
    @State private var promptPageOnScreen = false
    @Environment(\.scenePhase) private var promptPreviewScenePhase
    #if os(iOS)
    @Environment(\.page2AppActive) private var promptPreviewAppActive
    #else
    private let promptPreviewAppActive = true
    #endif
    @State private var presetImportNotice: String?
    @State private var expandedSlotIds: Set<String> = []
    @State private var samplingExpanded = false
    @State private var expandedSegmentIndices: Set<Int> = []
    @AppStorage("selectedChatModel") private var selectedChatModelId = ""
    @State private var selectedSlotIndex: Int? = nil
    @State private var showFullEditor = false
    @State private var fullEditLabel = ""
    @State private var fullEditText = ""
    @State private var fullEditSlotId: String? = nil
    @State private var showStyleManagerFromSlots = false
    @State private var isRenamingPreset = false
    @State private var renamingPresetName = ""
    @State private var iOSSimpleDrafts: [String: String] = [:]
    @State private var iOSSimpleDraftPresetId: String? = nil
    @State private var iOSSimpleSaveTask: Task<Void, Never>? = nil
    @State private var iOSSimpleFocusedSlotId: String? = nil
    @State private var iOSSimpleScrollRequest = 0
    @State private var iOSSimpleVisibilityTask: Task<Void, Never>? = nil
    // 原始模式 JSON 缓冲
    @State private var rawJSONBuffer = ""
    @State private var rawJSONError: String? = nil
    @State private var rawJSONDirty = false

    // D3–D6 破坏性动作确认：点击只置 pending，确认分支才写；取消零写入。
    // pending 只记 ID（楼层 / 预设 / 插槽），确认时按 ID 读最新数据重找，列表顺序变了也删对对象。
    @State private var pendingDeletePreset: PendingPresetDelete?
    @State private var pendingDeleteSlot: PendingSlotDelete?
    /// D5：pending 记 preset id，弹窗开着时楼层被别处切走就不覆盖（R6c S1）
    @State private var pendingApplyRawJSONPresetId: String?
    @State private var pendingResetRawJSON = false

    private struct PendingPresetDelete {
        let profileId: String
        let presetId: String
    }

    /// D4 三个入口（iOS swipe / mac 行内 xmark / `SlotEditPage` 删除钮）里页内两个共用这一份
    private struct PendingSlotDelete {
        let presetId: String
        let slotId: String
    }

    private struct SimplePromptField: Identifiable {
        let slotId: String
        let label: String
        let placeholder: String

        var id: String { slotId }
    }

    private static let iOSSimplePromptSlotIds = [
        PromptSlot.mainId,
        PromptSlot.charDescriptionId,
        PromptSlot.personaDescriptionId,
        PromptSlot.dialogueExamplesId,
        PromptSlot.jailbreakId,
    ]

    private static let iOSSimplePromptFields = [
        SimplePromptField(slotId: PromptSlot.mainId, label: "系统指令", placeholder: "你是一个有帮助的助手..."),
        SimplePromptField(slotId: PromptSlot.charDescriptionId, label: "助手设定", placeholder: "AI 助手的设定、风格、背景..."),
        SimplePromptField(slotId: PromptSlot.personaDescriptionId, label: "用户描述", placeholder: "介绍下自己…"),
        SimplePromptField(slotId: PromptSlot.dialogueExamplesId, label: "对话示例", placeholder: "{{user}}: 你好\n{{char}}: 你好，今天能帮什么？"),
        SimplePromptField(slotId: PromptSlot.jailbreakId, label: "后置提醒", placeholder: "保持角色设定，用自然的语气回应。"),
    ]

    var body: some View {
        iOSPromptPage
    }

    // MARK: - Preset Export / Import

    /// 兜底：presetId 没指向本楼层实例（漏网的创建路径/异常数据）就地实例化。幂等。
    private func ensureFloorInstance(_ profile: Profile, pm: ProfileManager, psm: PresetManager) {
        guard psm.preset(byId: profile.presetId)?.ownerProfileId != profile.id else { return }
        switchFloor(profile, toTemplate: profile.presetId, pm: pm, psm: psm)
    }

    /// 楼层切换模板：旧实例保留（切回时改动还在），没有实例则 deep copy 一份
    private func switchFloor(_ profile: Profile, toTemplate templateId: String, pm: ProfileManager, psm: PresetManager) {
        var p = profile
        if let existing = psm.instance(ownerProfileId: profile.id, sourceTemplateId: templateId) {
            p.presetId = existing.id
        } else {
            p.presetId = psm.instantiate(templateId: templateId, for: profile.id).id
        }
        pm.updateProfile(p)
    }

    /// 重命名：实例 + 源模板一起改（选择器和楼层显示一致），内置模板不改名
    private func renamePreset(_ preset: Preset, to newName: String, psm: PresetManager) {
        guard !newName.isEmpty else { return }
        var inst = preset
        inst.name = newName
        psm.save(inst)
        if let tid = inst.sourceTemplateId, var tpl = psm.preset(byId: tid), !tpl.isBuiltIn {
            tpl.name = newName
            psm.save(tpl)
        }
    }

    private func exportPreset(_ preset: Preset) {
        guard let data = preset.toSillyTavernJSON() else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "导出预设"
        panel.nameFieldStringValue = "\(preset.name).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
        #else
        // iOS：写 tmp 后走系统分享面板（贴纸页 StickerPage 同款）
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(preset.name).json")
        do {
            try data.write(to: url)
        } catch {
            return
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = root.view
                popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            }
            root.present(activityVC, animated: true)
        }
        #endif
    }

    // MARK: - D3 / D4 确认分支（只在这里写；取消零写入）

    /// D3：确认才删。按 pending 的楼层 ID 读最新 profile、按预设 ID 读最新实例；对象没了就不写。
    private func confirmDeletePreset() {
        guard let pending = pendingDeletePreset else { return }
        pendingDeletePreset = nil
        guard let pm = profileManager, let psm = presetManager else { return }
        guard let profile = pm.profiles.first(where: { $0.id == pending.profileId }) else { return }
        guard let preset = psm.preset(byId: pending.presetId), !preset.isBuiltIn else { return }
        // 删源模板 + 本楼层实例，本楼层切回默认模板
        if let tid = preset.sourceTemplateId, let tpl = psm.preset(byId: tid) {
            psm.delete(tpl)
        }
        psm.removeInstance(preset)
        switchFloor(profile, toTemplate: Preset.balanced.id, pm: pm, psm: psm)
    }

    /// D4：确认才删。按预设 ID 读最新 preset、在最新数组里按插槽 ID 重找 index。
    private func confirmDeleteSlot() {
        guard let pending = pendingDeleteSlot else { return }
        pendingDeleteSlot = nil
        guard let psm = presetManager else { return }
        deletePromptSlot(presetId: pending.presetId, slotId: pending.slotId, psm: psm)
        expandedSlotIds.remove(pending.slotId)
    }

    private func importPresetData(_ data: Data) {
        guard let psm = presetManager else { return }
        do {
            let imported = try psm.importFromSillyTavern(data)
            if let pm = profileManager {
                var p = pm.currentProfile
                p.presetId = imported.preset.id
                pm.updateProfile(p)
            }
            // ④a：prompt_order 没按 100001 组导入时告诉她（兜底用了文件顺序、全开）
            if !imported.notes.isEmpty { presetImportNotice = imported.notes.joined(separator: "\n") }
        } catch {
            presetImportNotice = "导入失败：\(error.localizedDescription)"
        }
    }

    private func handlePresetImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        importPresetData(data)
    }

    // MARK: Persona — 采样参数

    private func personaSamplingSection(preset: Preset, profile: Profile, pm: ProfileManager, psm: PresetManager) -> some View {
        let tempBinding = Binding<Double>(
            get: { preset.sampling.temperature },
            set: { val in
                var p = preset
                p.sampling.temperature = val
                psm.save(p)
            }
        )
        let contextBinding = Binding<Double>(
            get: { Double(preset.sampling.contextDepth) },
            set: { val in
                var p = preset
                p.sampling.contextDepth = Int(val)
                psm.save(p)
            }
        )
        let topPBinding = Binding<Double>(
            get: { preset.sampling.topP },
            set: { val in
                var p = preset
                p.sampling.topP = val
                psm.save(p)
            }
        )
        let maxTokensBinding = Binding<Double>(
            get: { Double(preset.sampling.maxTokens) },
            set: { val in
                var p = preset
                p.sampling.maxTokens = Int(val)
                p.sampling.maxTokensAuto = false
                psm.save(p)
            }
        )
        let maxTokensAutoBinding = Binding<Bool>(
            get: { preset.sampling.isMaxTokensAuto },
            set: { val in
                var p = preset
                p.sampling.maxTokensAuto = val
                psm.save(p)
            }
        )
        let modelOutputLimit = providerManager?.model(byId: selectedChatModelId).flatMap { OutputTokenCap.modelLimit($0.modelId) }
        // 直连 Anthropic 的 Opus 4.7+ / 5 系不收这三项，请求里不带（ChatService Anthropic buildRequestBody）
        let samplingIgnored = providerManager?.model(byId: selectedChatModelId).map { model in
            providerManager?.provider(for: model)?.type == .anthropic && ReasoningEffort.needsAdaptive(model.modelId)
        } ?? false
        let topKBinding = Binding<Double>(
            get: { Double(preset.sampling.topK) },
            set: { val in
                var p = preset
                p.sampling.topK = Int(val)
                psm.save(p)
            }
        )
        let freqBinding = Binding<Double>(
            get: { preset.sampling.frequencyPenalty },
            set: { val in
                var p = preset
                p.sampling.frequencyPenalty = val
                psm.save(p)
            }
        )
        let presBinding = Binding<Double>(
            get: { preset.sampling.presencePenalty },
            set: { val in
                var p = preset
                p.sampling.presencePenalty = val
                psm.save(p)
            }
        )
        let seedBinding = Binding<Double>(
            get: { Double(preset.sampling.seed) },
            set: { val in
                var p = preset
                p.sampling.seed = Int(val)
                psm.save(p)
            }
        )
        let reasoningBinding = Binding<String>(
            get: { preset.sampling.reasoningEffort },
            set: { val in
                var p = preset
                p.sampling.reasoningEffort = val
                psm.save(p)
            }
        )
        let verbosityBinding = Binding<String>(
            get: { preset.sampling.verbosity },
            set: { val in
                var p = preset
                p.sampling.verbosity = val
                psm.save(p)
            }
        )
        let streamingBinding = Binding<Bool>(
            get: { preset.sampling.streaming },
            set: { val in
                var p = preset
                p.sampling.streaming = val
                psm.save(p)
            }
        )
        let continuePostfixBinding = Binding<String>(
            get: { preset.sampling.continuePostfix },
            set: { val in
                var p = preset
                p.sampling.continuePostfix = val
                psm.save(p)
            }
        )
        let continuePrefillBinding = Binding<Bool>(
            get: { preset.sampling.continuePrefill },
            set: { val in
                var p = preset
                p.sampling.continuePrefill = val
                psm.save(p)
            }
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text("采样参数")
                .font(m.sectionHeader.weight(.medium))
                .foregroundColor(Theme.textSecondary)
            if samplingIgnored {
                Text("当前模型不支持 Temperature / Top P / Top K，调了不生效")
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted)
            }

            VStack(alignment: .leading, spacing: 12) {
                ParameterRow(label: "Temperature", value: tempBinding, range: 0...2, step: 0.1)
                ParameterRow(label: "上下文深度", value: contextBinding, range: 5...200, step: 5, intMode: true)
                ParameterRow(label: "Top P", value: topPBinding, range: 0...1, step: 0.05, format: "%.2f")
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: maxTokensAutoBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Max Tokens 按模型自动")
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                            if preset.sampling.isMaxTokensAuto {
                                Text("当前模型：\(OutputTokenCap.visibleCap(preset.sampling, limit: modelOutputLimit))")
                                    .font(m.secondary)
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                    if !preset.sampling.isMaxTokensAuto {
                        ParameterRow(label: "Max Tokens", value: maxTokensBinding,
                                     range: 256...Double(max(4096, modelOutputLimit ?? 32_768)), step: 256, intMode: true)
                    }
                }
                ParameterRow(label: "Top K", value: topKBinding, range: 0...500, step: 1, intMode: true)
                ParameterRow(label: "Freq Penalty", value: freqBinding, range: -2...2, step: 0.05, format: "%.2f")
                // G5：全称取 mac 长版（iOS 原「Pres Penalty」）
                ParameterRow(label: "Presence Penalty", value: presBinding, range: -2...2, step: 0.05, format: "%.2f")
                ParameterRow(label: "Seed", value: seedBinding, range: -1...9999, step: 1, intMode: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("推理深度")
                        .font(m.label)
                        .foregroundColor(Theme.textMuted)
                    Picker("", selection: reasoningBinding) {
                        Text("自动").tag("auto")
                        Text("低").tag("low")
                        Text("中").tag("medium")
                        Text("高").tag("high")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("详细度")
                        .font(m.label)
                        .foregroundColor(Theme.textMuted)
                    Picker("", selection: verbosityBinding) {
                        Text("自动").tag("auto")
                        Text("简洁").tag("concise")
                        Text("详细").tag("verbose")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                Toggle(isOn: streamingBinding) {
                    Text("流式输出")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("续写后缀")
                        .font(m.label)
                        .foregroundColor(Theme.textMuted)
                    TextField("", text: continuePostfixBinding)
                        .font(m.body)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            Divider().opacity(0.1)

            Text("后处理")
                .font(m.sectionHeader.weight(.medium))
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: continuePrefillBinding) {
                    Text("续写 Prefill")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
    }

    // MARK: - mac 平台例外体（简单模式字段 + 插槽内联编辑）
    //
    // 合流后主干是 iOS 真身 `iOSPromptPage`；下面这一段只在 mac 编：
    // ① 简单模式的输入框——iOS 走 UIKit 的 `IOSPromptTextView`（自增高 + 焦点回调），mac 没有，用 `TextEditor`（第 4 类）；
    // ② 插槽行——mac 没有 `swipeActions` / push 二级页，保留折叠内联编辑 + 拖拽排序 + 行内删除（B7，第 7 类）。
    // 组头 / 添加钮 / 写作风格 / 导入都已并进两端共用的 `iOSSlotsSection`，这里不再各画一份。
    #if os(macOS)

    // MARK: Persona — 简单模式（mac 字段体；草稿链与 iOS 同一条，见 B11）

    /// 每个字段一个 `Section`：`MacSettingsForm` 的组头 + 卡 = 合流前 `MacSettingsSection` 的长相，不多套一层卡。
    /// 标签 / 占位文案取 iOS 那份表（C 文案默认取 iOS 原文）。
    @ViewBuilder
    private func personaSimpleMode(preset: Preset, psm: PresetManager) -> some View {
        ForEach(Self.iOSSimplePromptFields) { field in
            Section(field.label) {
                personaSlotField(preset: preset, slotId: field.slotId,
                                 placeholder: field.placeholder, psm: psm,
                                 height: Self.macSimpleFieldHeights[field.slotId] ?? 40)
            }
        }
        Section {
            Text("修改即时生效，切换模式可看到同步")
                .font(ShellStyle.secondaryFont)
                .foregroundColor(Theme.textMuted)
        }
    }

    /// 合流前 mac 各字段的高度（`personaSimpleMode` 原调用点），保住原长相
    private static let macSimpleFieldHeights: [String: CGFloat] = [
        PromptSlot.charDescriptionId: 60,
        PromptSlot.dialogueExamplesId: 50,
    ]

    /// B11 单草稿链：mac 也走 iOS 的简单模式草稿状态（删掉原来的每键直写 `psm.save`）。
    /// mac 没有防抖 = 同步 persist（`immediate: true`），不是把调度器的 sleep 常量改 0。
    private func personaSlotField(preset: Preset, slotId: String,
                                  placeholder: String, psm: PresetManager, height: CGFloat = 40) -> some View {
        personaTextField(text: iOSSimpleBinding(for: slotId, preset: preset, psm: psm, immediate: true),
                         placeholder: placeholder, height: height)
    }

    private func personaTextField(text: Binding<String>, placeholder: String, height: CGFloat = 40) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(ShellStyle.bodyFont.weight(.regular))
                .frame(height: height)
                .padding(6)
                .scrollContentBackground(.hidden)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(ShellStyle.bodyFont.weight(.regular))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
                    .padding(.leading, 10)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
    }

    // MARK: Persona — 插槽模式（mac 内联行，B7）

    private func personaSlotsMode(preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(preset.prompts.enumerated()), id: \.element.id) { index, slot in
                // macOS: original collapsible row
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal")
                            .font(ShellStyle.microFont)
                            .foregroundColor(Theme.textMuted.opacity(0.5))

                        if !slot.isLocked {
                            Toggle("", isOn: Binding(
                                get: { slot.isEnabled },
                                set: { val in
                                    var p = preset
                                    p.prompts[index].isEnabled = val
                                    psm.save(p)
                                }
                            ))
                            .toggleStyle(.switch)
                            .scaleEffect(0.6)
                            .frame(width: 30)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(ShellStyle.microFont)
                                .foregroundColor(Theme.textMuted)
                                .frame(width: 30)
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if expandedSlotIds.contains(slot.id) { expandedSlotIds.remove(slot.id) } else { expandedSlotIds.insert(slot.id) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: expandedSlotIds.contains(slot.id) ? "chevron.down" : "chevron.right")
                                    .font(ShellStyle.microFont)
                                Text(slot.name)
                                    .font(ShellStyle.bodyFont.weight(.regular))
                                    .lineLimit(1)
                            }
                            .foregroundColor(slot.isEnabled || slot.isLocked ? Theme.textPrimary : Theme.textMuted)
                        }
                        .buttonStyle(.plain)

                        Text(slot.role)
                            .font(ShellStyle.microFont)
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(
                                slot.role == "system" ? Theme.textMuted :
                                slot.role == "user" ? Theme.branchIndicator : .orange
                            ))

                        if slot.isMarker {
                            Text("占位")
                                .font(ShellStyle.microFont)
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().stroke(Theme.textMuted, lineWidth: 0.5))
                        }

                        Spacer()

                        if !slot.isSystemPrompt && !slot.isMarker {
                            // D4 入口 ②（mac 行内）：只置 pending
                            Button {
                                pendingDeleteSlot = PendingSlotDelete(presetId: preset.id, slotId: slot.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(ShellStyle.secondaryFont)
                                    .foregroundColor(Theme.danger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)

                    if expandedSlotIds.contains(slot.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            if slot.isMarker {
                                slotMarkerEditor(slot: slot, index: index, preset: preset, psm: psm)
                            } else {
                                slotContentEditor(slot: slot, index: index, preset: preset, psm: psm)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((slot.isEnabled || slot.isLocked) ? Theme.assistantBubble : Theme.mainBg.opacity(0.5))
                )
                .draggable(slot.id) {
                    Text(slot.name)
                        .font(ShellStyle.secondaryFont)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.assistantBubble))
                }
                .dropDestination(for: String.self) { droppedIds, _ in
                    guard let droppedId = droppedIds.first,
                          let fromIndex = preset.prompts.firstIndex(where: { $0.id == droppedId }),
                          fromIndex != index else { return false }
                    // ④a：顺序只经 SlotOrder 写（sequenceIndex），组装器读同一份，拖完发送顺序跟着变
                    var p = preset
                    p.prompts = SlotOrder.moving(p.prompts, slotId: droppedId, toIndex: index)
                    psm.save(p)
                    return true
                }
            }
        }
    }

    // MARK: Persona — Slot Editors

    /// 普通插槽编辑器（名称/role/depth/内容）
    private func slotContentEditor(slot: PromptSlot, index: Int, preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("名称")
                    .font(ShellStyle.bodyFont.weight(.regular)).foregroundColor(Theme.textMuted)
                    .frame(width: 35, alignment: .trailing)
                TextField("插槽名称", text: Binding(
                    get: { slot.name },
                    set: { val in var p = preset; p.prompts[index].name = val; psm.save(p) }
                ))
                .font(ShellStyle.bodyFont.weight(.regular)).textFieldStyle(.plain)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
            }

            HStack(spacing: 8) {
                Text("角色")
                    .font(ShellStyle.bodyFont.weight(.regular)).foregroundColor(Theme.textMuted)
                    .frame(width: 35, alignment: .trailing)
                Picker("", selection: Binding(
                    get: { slot.role },
                    set: { val in var p = preset; p.prompts[index].role = val; psm.save(p) }
                )) {
                    Text("system").tag("system")
                    Text("user").tag("user")
                    Text("assistant").tag("assistant")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 200)
            }

            HStack(spacing: 8) {
                Text("深度")
                    .font(ShellStyle.bodyFont.weight(.regular)).foregroundColor(Theme.textMuted)
                    .frame(width: 35, alignment: .trailing)
                TextField("0", value: Binding(
                    get: { slot.injectionDepth },
                    set: { val in var p = preset; SlotOrder.setDepth(val, of: &p.prompts[index]); psm.save(p) }
                ), format: .number)
                .font(ShellStyle.bodyFont.weight(.regular)).textFieldStyle(.plain).frame(width: 40)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
                Text("0=按顺序，>0=从末尾倒数第 N 条插入")
                    .font(ShellStyle.secondaryFont).foregroundColor(Theme.textMuted)
            }

            Text("内容")
                .font(ShellStyle.bodyFont.weight(.regular)).foregroundColor(Theme.textMuted)
            TextEditor(text: Binding(
                get: { slot.content },
                set: { val in var p = preset; p.prompts[index].content = val; psm.save(p) }
            ))
            .font(ShellStyle.secondaryFont.monospaced())
            .frame(height: 80).padding(4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
            .scrollContentBackground(.hidden)
        }
    }

    /// Marker 插槽编辑器（直接编辑 slot content，和简单模式同步）
    private func slotMarkerEditor(slot: PromptSlot, index: Int, preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if slot.id == PromptSlot.memoryInjectionId || slot.id == PromptSlot.chatHistoryId || slot.id == PromptSlot.contextSummaryId || slot.id == PromptSlot.userProfileId {
                Text("此插槽由系统自动填充")
                    .font(ShellStyle.secondaryFont)
                    .foregroundColor(Theme.textMuted)
            } else {
                Text("内容")
                    .font(ShellStyle.bodyFont.weight(.regular))
                    .foregroundColor(Theme.textSecondary)
                Text("留空时由楼层对应字段填充（助手设定/用户描述等）；填了内容则优先用这里的")
                    .font(ShellStyle.secondaryFont)
                    .foregroundColor(Theme.textMuted)

                TextEditor(text: Binding(
                    get: { slot.content },
                    set: { val in var p = preset; p.prompts[index].content = val; psm.save(p) }
                ))
                .font(ShellStyle.bodyFont.weight(.regular))
                .frame(height: 60).padding(4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
                .scrollContentBackground(.hidden)
            }
        }
    }

    // mac 平台例外体到此为止
    #endif

    // MARK: Persona — 原始模式（JSON 编辑器）

    private func personaRawMode(preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("JSON 编辑器")
                    .font(m.sectionHeader.weight(.medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()

                if rawJSONDirty {
                    // D5：整份覆盖，先确认
                    Button(action: { pendingApplyRawJSONPresetId = preset.id }) {
                        Text("应用")
                            .font(m.secondary.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                }

                // D6：重置丢掉这次编辑，先确认
                Button(action: { pendingResetRawJSON = true }) {
                    Text("重置")
                        .font(m.secondary)
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            if let error = rawJSONError {
                Text(error)
                    .font(m.caption)
                    .foregroundColor(.red)
            }

            TextEditor(text: $rawJSONBuffer)
                .font(m.mono)
                .frame(minHeight: 300)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                .onChange(of: rawJSONBuffer) { _, _ in
                    rawJSONDirty = true
                    rawJSONError = nil
                }
        }
        .onAppear {
            if rawJSONBuffer.isEmpty || !rawJSONDirty {
                rawJSONBuffer = preset.toJSONString()
                rawJSONDirty = false
            }
        }
    }

    /// D6 确认分支：把缓冲拉回最新落盘内容（只丢编辑器里的改动，不写库）
    private func resetRawJSON(preset: Preset, psm: PresetManager) {
        rawJSONBuffer = (psm.preset(byId: preset.id) ?? preset).toJSONString()
        rawJSONDirty = false
        rawJSONError = nil
    }

    /// D5 确认分支：整份覆盖。按 ID 读最新 preset 保 ID / 名称 / 内置标记，避免用进页时的旧快照。
    private func applyRawJSON(preset: Preset, psm: PresetManager) {
        let latest = psm.preset(byId: preset.id) ?? preset
        do {
            var parsed = try Preset.fromJSONString(rawJSONBuffer)
            parsed.id = latest.id // 保持 ID
            parsed.name = latest.name // 保持名称
            parsed.isBuiltIn = latest.isBuiltIn
            psm.save(parsed)
            rawJSONDirty = false
            rawJSONError = nil
        } catch {
            rawJSONError = "JSON 解析失败: \(error.localizedDescription)"
        }
    }

    // MARK: Persona — Tab 4: 组装预览（模板层，宏未展开）

    private func personaAssemblyPreview(preset: Preset, turn: TurnPreview?) -> some View {
        let segments = turn?.segments ?? []
        let tokens = segments.reduce(0) { $0 + TokenEstimator.estimate($1.template) }
        let hasHistory = segments.contains { $0.source == .chatHistory }
        let badges = cacheCoverageBadges(segments: segments)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("组装预览（模板）")
                    .font(m.sectionHeader.weight(.medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text("\(segments.count) 段 · ≈ \(tokens) tokens")
                    .font(m.mono)
                    .foregroundColor(Theme.textMuted)
            }

            if !badges.isEmpty {
                Text("✅=上一轮缓存命中范围内 · ❌=范围外（按 token 粗估，动态段在外是设计如此）")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }

            if turn == nil {
                unboundTurnNotice
            }

            // 卡库 ③-4：有效身份从哪一级来、退回原因、身份的书注入了哪些（与实发同一次解析，随 previewTurn 带来）
            if let identity = turn?.identity, !identity.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(identity.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }

            if let hits = turn?.memoryHits, !hits.isEmpty {
                memoryHitsBlock(hits)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                        taggedSegmentBlock(seg, index: idx, showTemplate: true, cacheBadge: badges[idx])
                    }

                    if turn != nil, !hasHistory {
                        noHistoryPlaceholder(depth: preset.sampling.contextDepth)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
        }
    }


    // MARK: Persona — 用量·缓存仪表盘（tab 选择条上方，可折叠；缓存开关在这里）

    @AppStorage("cacheDashboardExpanded") private var cacheDashboardExpanded = false
    @State private var ctxSummaryExpanded = false
    @AppStorage("ctx_compress_interval") private var ctxCompressInterval = 5

    @ViewBuilder
    func cacheDashboard(preset: Preset, psm: PresetManager, turn: TurnPreview?) -> some View {
        let nodes = Array((viewModel?.currentPath ?? [])
            .filter { $0.role == "assistant" && $0.usagePromptTokens != nil }
            .suffix(20))

        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { cacheDashboardExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cacheDashboardExpanded ? "chevron.down" : "chevron.right")
                        .font(m.caption)
                    Text("用量 · 缓存 · 上下文")
                        .font(m.sectionHeader.weight(.medium))
                    Spacer()
                    if !cacheDashboardExpanded, let u = viewModel?.lastTurnUsage {
                        Text("↑\(u.inputTokens) ↓\(u.outputTokens)" + ((u.cacheReadTokens ?? 0) > 0 ? " · 命中" : ""))
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .foregroundColor(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if cacheDashboardExpanded {
                // 上一轮（实时，不依赖落盘）
                if let u = viewModel?.lastTurnUsage {
                    Text("上一轮：输入 \(u.inputTokens) · 输出 \(u.outputTokens)" +
                         (u.cacheReadTokens.map { " · 缓存读 \($0)" } ?? "") +
                         (u.cacheWriteTokens.map { " · 缓存写 \($0)" } ?? ""))
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }

                // 本对话最近 20 轮聚合（查 currentPath 落盘字段）
                if nodes.isEmpty {
                    Text("本对话还没有带用量数据的回复（旧消息无数据，新发一轮即有）")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                } else {
                    let prompt = nodes.reduce(0) { $0 + ($1.usagePromptTokens ?? 0) }
                    let completion = nodes.reduce(0) { $0 + ($1.usageCompletionTokens ?? 0) }
                    let read = nodes.reduce(0) { $0 + ($1.usageCacheReadTokens ?? 0) }
                    let cost = nodes.reduce(0.0) { $0 + ($1.usageCostUSD ?? 0) }
                    let saved = nodes.reduce(0.0) { $0 + ($1.usageSavedUSD ?? 0) }
                    let hitTurns = nodes.filter { ($0.usageCacheReadTokens ?? 0) > 0 }.count
                    let tokenRate = prompt > 0 ? Int(Double(read) / Double(prompt) * 100) : 0

                    VStack(alignment: .leading, spacing: 4) {
                        statLine("最近 \(nodes.count) 轮", "输入 \(prompt) · 输出 \(completion) token")
                        statLine("缓存命中", "token \(tokenRate)%（\(read)）· 轮次 \(hitTurns)/\(nodes.count)")
                        statLine("费用", String(format: "$%.4f", cost) + (saved > 0 ? String(format: "（缓存省 $%.4f）", saved) : ""))
                    }
                }

                Divider().opacity(0.15)

                // 上下文压缩：状态 + 手动按钮（粟粟：从来没见它触发过 → 状态摆出来 + 给个手动钮）
                if let conv = viewModel?.selectedConversation {
                    let convId = conv.id
                    let msgCount = (viewModel?.currentPath ?? []).filter {
                        ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent
                    }.count
                    let depth = preset.sampling.contextDepth
                    let ctxSummary = ContextSummarizer.load(conversationId: convId, profileId: conv.profileId)
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { ctxSummaryExpanded.toggle() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("上下文压缩")
                                        .font(m.body)
                                        .foregroundColor(Theme.textPrimary)
                                    if ctxSummary != nil {
                                        Image(systemName: ctxSummaryExpanded ? "chevron.down" : "chevron.right")
                                            #if os(macOS)
                                            .font(ShellStyle.microFont)
                                            #else
                                            .font(.system(size: 9))
                                            #endif
                                            .foregroundColor(Theme.textMuted)
                                    }
                                }
                                Text(ctxSummary.map { "已覆盖 \($0.coveredCount) 条 · 摘要 \($0.summary.count) 字（点开看全文）" }
                                     ?? (msgCount > depth ? "已超窗未压缩（\(msgCount)/\(depth) 条）" : "未超窗（\(msgCount)/\(depth) 条）"))
                                    .font(m.caption)
                                    .foregroundColor(Theme.textMuted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("立即压缩") {
                            if let pm = providerManager, let model = turn?.model, let profile = profileManager?.currentProfile {
                                viewModel?.manualCompressContext(contextDepth: depth, profile: profile, model: model, providerManager: pm)
                            }
                        }
                        .font(m.secondary)
                        .foregroundColor(msgCount > depth ? Theme.branchIndicator : Theme.textMuted)
                        .buttonStyle(.plain)
                        .disabled(msgCount <= depth || turn == nil)
                    }

                    Stepper(value: $ctxCompressInterval, in: 1...20) {
                        HStack {
                            Text("压缩频率")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                            Text("每 \(ctxCompressInterval) 轮")
                                .font(m.caption.monospaced())
                                .foregroundColor(Theme.textSecondary)
                        }
                    }

                    // 摘要全文（粟粟：我要看见它写了什么）
                    if ctxSummaryExpanded, let s = ctxSummary {
                        ScrollView {
                            Text(s.summary)
                                .font(m.caption.monospaced())
                                .foregroundColor(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 220)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
                    }

                    Divider().opacity(0.15)
                }

                // 缓存命中优化开关（粟粟批注：放仪表盘里，不放采样参数）
                Toggle(isOn: Binding(
                    get: { preset.sampling.cacheFriendly == true },
                    set: { val in
                        var p = preset
                        p.sampling.cacheFriendly = val
                        psm.save(p)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("缓存命中优化")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Text("每轮会变的内容（时间、命中的记忆、世界书触发条）自动挪到对话末尾，前面逐字不变让 API 缓存命中、token 费大降。代价：你排的插槽顺序实发时会被调整。检查器显示的是调整后的真实顺序。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #if os(macOS)
                .toggleStyle(.switch)
                #endif
                .tint(Theme.branchIndicator)

                Divider().opacity(0.15)

                // AI 工具清单（粟粟：我都不知道 AI 现在能用哪些工具）——previewTurn 与实发同一条取模型 / 取工具路径，所见即所发
                if let turn {
                    let toolNames = (turn.tools ?? [])
                        .compactMap { ($0["name"] as? String) ?? (($0["function"] as? [String: Any])?["name"] as? String) }
                    let fsNames = toolNames.filter { $0.hasPrefix("fs_") }
                    let metaNames = toolNames.filter { ["tool_search", "tool_inspect", "tool_invoke"].contains($0) }
                    let codingNames = toolNames.filter { name -> Bool in
                        #if os(macOS)
                        return CodingTools.names.contains(name)
                        #else
                        return false
                        #endif
                    }
                    // #069：注册表里的都是内建；以前把 fs_ / 回忆 / 心声以外的内建全算成 MCP
                    let registryNames = Set(ToolRegistry.all.map(\.definition.name))
                    let groupedNames: Set<String> = Set(fsNames + metaNames + codingNames + [RecallTool.toolName, InnerVoice.toolName])
                    let otherBuiltinNames = toolNames.filter { registryNames.contains($0) && !groupedNames.contains($0) }
                    let serverToolNames = (turn.tools ?? []).filter { $0["function"] == nil && $0["type"] != nil }.compactMap { $0["name"] as? String }
                    let mcpNames = toolNames.filter { !registryNames.contains($0) && !serverToolNames.contains($0) }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI 工具（本对话实发 \(toolNames.count) 个）")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        if toolNames.isEmpty {
                            Text("当前不下发任何工具（\(toolsAbsentText(turn.toolsAbsentReason))）")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        } else {
                            if !fsNames.isEmpty { statLine("文件库", fsNames.joined(separator: " ")) }
                            if toolNames.contains(RecallTool.toolName) { statLine("回忆", RecallTool.toolName) }
                            if toolNames.contains(InnerVoice.toolName) { statLine("心声", InnerVoice.toolName) }
                            if !codingNames.isEmpty { statLine("编程会话", codingNames.joined(separator: " ")) }
                            if !otherBuiltinNames.isEmpty { statLine("其它", otherBuiltinNames.joined(separator: " ")) }
                            if !serverToolNames.isEmpty { statLine("联网", serverToolNames.joined(separator: " ") + "（服务端搜索）") }
                            if !metaNames.isEmpty { statLine("元工具", metaNames.joined(separator: " ") + "（查 / 调下面收起来的工具）") }
                            if !turn.tuckedTools.isEmpty { statLine("更多工具", turn.tuckedTools.joined(separator: " ") + "（不在清单里，经元工具调）") }
                            if !mcpNames.isEmpty { statLine("MCP", mcpNames.joined(separator: " ")) }
                            Text("开关：文件库→设置·文件库｜回忆·心声→设置·记忆｜MCP→设置·MCP")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted.opacity(0.7))
                        }
                    }
                } else {
                    unboundTurnNotice
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.assistantBubble.opacity(0.5)))
    }

    /// ④：工具为空按真实原因说（与 toolInjection 过滤链一一对应）
    private func toolsAbsentText(_ reason: ToolsAbsentReason?) -> String {
        switch reason {
        case .cardNotFound: return "找不到这张卡"
        case .cardToolsOff: return "这张卡关了工具调用"
        case .masterOff: return "工具总开关关着"
        case .ccBridge: return "CC Bridge：上游自带工具"
        case .localModel: return "本机模型不下发工具"
        case .noneEnabled, nil: return "没有启用任何工具"
        }
    }

    /// ①：设置页入口没有对话——不编数字、不编段落
    private var unboundTurnNotice: some View {
        Text("设置页没有绑定对话——到聊天右栏「Prompt 工具」看这一轮实发")
            .font(m.caption)
            .foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// D4：拿上一轮 cacheRead 对照各段累计 token 估算，标缓存覆盖边界（粗估，tool schema 不计入故偏乐观）
    private func cacheCoverageBadges(segments: [TaggedSegment]) -> [Int: String] {
        guard let covered = viewModel?.lastTurnUsage?.cacheReadTokens, covered > 0 else { return [:] }
        // 线上顺序：所有 system 段并成 system prompt 在前，非 system 消息在后（与 assemble() 一致）
        let wireOrder = segments.enumerated().filter { $0.element.role == "system" }
            + segments.enumerated().filter { $0.element.role != "system" }
        var badges: [Int: String] = [:]
        var cum = 0
        for (idx, seg) in wireOrder {
            let t = TokenEstimator.estimate(seg.content)
            if cum + t <= covered { badges[idx] = "✅" }
            else if cum < covered { badges[idx] = "～" }   // 缓存边界落在这段中间
            else { badges[idx] = "❌" }
            cum += t
        }
        return badges
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(m.caption.monospaced())
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: Persona — Tab 5: 请求预览（原始 JSON body）

    private func personaRequestPreview(turn: TurnPreview?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $requestSource) {
                Text("上一次真实发出").tag("sent")
                Text("下一轮预览").tag("preview")
            }
            .pickerStyle(.segmented)
            .tint(Theme.branchIndicator)
            if requestSource == "sent" {
                SentRequestBodyView(conversationId: viewModel?.selectedConversation?.id)
            } else {
                personaRequestNextTurn(turn: turn)
            }
        }
    }

    private func personaRequestNextTurn(turn: TurnPreview?) -> some View {
        let (json, placementNote) = buildRequestJSON(turn)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("预览：现在点发送会发的（还没发）")
                    .font(m.sectionHeader.weight(.medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = json
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            // ④b：组装页是逻辑顺序；这里说明这个 provider 实际把不在开头的 system 怎么发
            if let placementNote {
                Text(placementNote)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // #089 P0-a：预设里深度 0 的 assistant 预填 → 发出去最后一条是 assistant
            if turn?.ordered.last(where: { !$0.pinnedToSystemPrefix && $0.role != "system" })?.role == "assistant" {
                Text("⚠️ 预设里有深度 0 的 assistant 预填，发出去的最后一条是 assistant。新模型可能不认预填、直接报错。")
                    .font(m.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.vertical) {
                Text(json)
                    .font(m.caption.monospaced())
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
        }
    }

    /// 请求 Body = previewTurn 用实发同一个 provider 构造函数建的 body（只在请求 tab 可见时算）
    private func buildRequestJSON(_ turn: TurnPreview?) -> (json: String, placementNote: String?) {
        guard let pm = providerManager else {
            return ("// 无法获取 provider 信息", nil)
        }
        guard let turn else {
            return ("// 设置页没有绑定对话——到聊天右栏「Prompt 工具」看这一轮实发", nil)
        }
        guard let body = turn.requestBody(providerManager: pm) else {
            return ("// 当前 provider（cc-bridge）不走标准请求体，无法预览", nil)
        }
        let note = turn.placementNote(providerManager: pm)
        guard let data = try? JSONSerialization.data(withJSONObject: Self.redactingImageData(body), options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return ("// JSON 序列化失败", note)
        }
        return (str, note)
    }

    /// ③：显示用——图片 base64 换成 `<image/jpeg 182KB>` 占位（复制也是占位版；实发 / 测试比的是原始 body）
    static func redactingImageData(_ value: Any) -> Any {
        if let s = value as? String, s.hasPrefix("data:"), let r = s.range(of: ";base64,") {
            let mime = String(s[s.index(s.startIndex, offsetBy: 5)..<r.lowerBound])
            return imagePlaceholder(mime: mime, base64Length: s.utf8.count - s[..<r.upperBound].utf8.count)
        }
        if var dict = value as? [String: Any] {
            if dict["type"] as? String == "base64", let data = dict["data"] as? String {
                dict["data"] = imagePlaceholder(mime: dict["media_type"] as? String ?? "image", base64Length: data.utf8.count)
                return dict
            }
            return dict.mapValues(redactingImageData)
        }
        if let array = value as? [Any] {
            return array.map(redactingImageData)
        }
        return value
    }

    private static func imagePlaceholder(mime: String, base64Length: Int) -> String {
        "<\(mime) \(max(1, base64Length * 3 / 4 / 1024))KB>"
    }

    // MARK: Persona — 预览辅助

    /// S1 检查器逐条记忆命中（观察面不带反馈按钮——操作在聊天流卡片上）
    @ViewBuilder
    private func memoryHitsBlock(_ hits: [InjectionHit]) -> some View {
        let stable = hits.filter { $0.retrieverId == "persistent" }
        let volatile = hits.filter { $0.retrieverId != "persistent" }
        VStack(alignment: .leading, spacing: 3) {
            Text("🧠 记忆命中 \(hits.count) 条（常驻 \(stable.count) · 本轮相关 \(volatile.count)）")
                .font(m.caption.weight(.medium))
                .foregroundColor(Theme.textSecondary)
            ForEach(volatile, id: \.memoryId) { hit in
                HStack(spacing: 4) {
                    Text("· \(hit.snippet)")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    Spacer()
                    Text(RecallCardView.retrieverLabels[hit.retrieverId] ?? hit.retrieverId)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                    if let sc = hit.score {
                        Text(String(format: "%.2f", sc))
                            .font(m.caption.monospaced())
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.4)))
    }

    /// 带来源标签的折叠段落块——点击展开全文
    private func taggedSegmentBlock(_ seg: TaggedSegment, index: Int, showTemplate: Bool, cacheBadge: String? = nil) -> some View {
        let text = showTemplate ? seg.template : seg.content
        let segTokens = TokenEstimator.estimate(text)
        let isExpanded = expandedSegmentIndices.contains(index)

        return VStack(alignment: .leading, spacing: 0) {
            // 头部（始终可见）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedSegmentIndices.remove(index) }
                    else { expandedSegmentIndices.insert(index) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        #if os(macOS)
                        .font(ShellStyle.microFont)
                        #else
                        .font(.system(size: 9, weight: .semibold))
                        #endif
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 12)

                    Text(seg.role.uppercased())
                        .font(m.mono.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(roleColor(seg.role)))

                    Text(seg.source.displayName)
                        .font(m.caption.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(sourceColor(seg.source)))

                    Spacer()

                    if let cacheBadge {
                        Text(cacheBadge)
                            .font(m.caption)
                    }

                    Text("≈\(segTokens)")
                        .font(m.caption.monospaced())
                        .foregroundColor(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)

            // 展开后的内容
            if isExpanded {
                Text(text)
                    .font(m.mono)
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .padding(.leading, 12)
            } else if !text.isEmpty {
                Text(text.prefix(80) + (text.count > 80 ? "…" : ""))
                    .font(m.caption.monospaced())
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                    .padding(.leading, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(sourceColor(seg.source).opacity(0.06)))
    }

    private func noHistoryPlaceholder(depth: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "ellipsis.bubble")
                .font(m.caption)
            Text("打开对话后可预览完整上下文（深度: \(depth) 条）")
                .font(m.caption)
        }
        .foregroundColor(Theme.textMuted)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Theme.textMuted.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "system": return .purple
        case "user": return .blue
        case "assistant": return .green
        default: return .gray
        }
    }

    private func sourceColor(_ source: SegmentSource) -> Color {
        switch source {
        case .slot(let id, _):
            switch id {
            case PromptSlot.mainId: return .purple
            case PromptSlot.charDescriptionId: return .pink
            case PromptSlot.personaDescriptionId: return .green
            case PromptSlot.jailbreakId: return .red
            case PromptSlot.scenarioId: return .indigo
            default: return .gray
            }
        case .memory: return .orange
        case .worldBook: return .teal
        case .contextSummary: return .gray
        case .chatHistory: return .secondary
        case .dialogueExample: return .mint
        case .fileLibrary: return Theme.branchIndicator
        case .userProfile: return .brown
        case .timeline: return .brown
        case .volatileContext: return .purple
        case .style: return Theme.branchIndicator
        case .cardGuide: return .mint
        case .folder: return .brown
        }
    }
}

/// Prompt 页预览的重算条件：楼层、预设内容、要不要看（含页面可见）、聊天模型变了才重算。
/// 不跟对话的新消息（以前带 currentNodeId，CC 对话一来消息就重组一遍）：回到这页时会重算
private struct PromptPreviewKey: Equatable {
    let profile: Profile
    let preset: Data
    let wantsPreview: Bool
    let model: String
}

// MARK: - Prompt 页主干（合流后两端共用；原 iOS 真身 iOSPromptPage）

extension PersonaSettingsTab {

    /// 检查器唯一数据源：与实发同一个取模型 / 工具 / 组装入口（CVM.previewTurn），nil = 没有对话（设置页入口）
    func previewTurn(profile: Profile, preset: Preset) -> TurnPreview? {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("PersonaSettingsTab.previewTurn") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard let pm = providerManager else { return nil }
        return viewModel?.previewTurn(profile: profile, preset: preset, providerManager: pm,
                                      globalModelId: selectedChatModelId, context: modelContext)
    }

    var iOSPersonaEditModeSelection: Binding<String> {
        Binding(
            get: { personaEditMode.isEmpty ? "simple" : personaEditMode },
            set: { personaEditMode = $0 }
        )
    }

    var iOSPromptPage: some View {
        Group {
            if let pm = profileManager, let psm = presetManager {
                let profile = pm.currentProfile
                let preset = psm.preset(byId: profile.presetId) ?? Preset.balanced

                iOSPromptPageContent(profile: profile, preset: preset, pm: pm, psm: psm)
                    .onAppear {
                        ensureFloorInstance(profile, pm: pm, psm: psm)
                        // B11：草稿会话只在简单模式里存在——从插槽 / raw 模式进页不快照，
                        // 否则那份旧快照会在离页 flush 时把插槽内联 / JSON「应用」写下去的内容盖回来
                        syncSimpleDraftsIfSimple(preset)
                    }
                    .onAppear { AssistantContext.shared.report(page: "preset") }
                    .onDisappear { AssistantContext.shared.clear(page: "preset") }
                    .onChange(of: profile.presetId) { _, newPresetId in
                        syncSimpleDraftsIfSimple(psm.preset(byId: newPresetId) ?? preset)
                    }
                    .onChange(of: personaEditMode) { _, newMode in
                        expandedSegmentIndices.removeAll()
                        if newMode == "simple" || newMode.isEmpty {
                            let latestPreset = psm.preset(byId: profile.presetId) ?? preset
                            syncIOSSimpleDrafts(from: latestPreset, force: true)
                        } else {
                            // B11 astra R5b-I2 ②：先 flush 再让草稿会话失效——之后的离页 / 切预设 /
                            // 复制 / 导出都 flush 不动旧稿（插槽内联仍直写，不会被简单模式的旧快照盖回去）
                            flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                            invalidateIOSSimpleDrafts()
                            iOSSimpleVisibilityTask?.cancel()
                            iOSSimpleVisibilityTask = nil
                            iOSSimpleFocusedSlotId = nil
                        }
                    }
                    .onDisappear {
                        flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                        iOSSimpleVisibilityTask?.cancel()
                        iOSSimpleVisibilityTask = nil
                    }
                    #if os(iOS)
                    .modifier(SlotNavigationModifier(
                        selectedSlotIndex: $selectedSlotIndex,
                        useSheet: useSheetNavigation,
                        presetManager: presetManager,
                        profileManager: profileManager
                    ))
                    #endif
                    // ── D3–D6：破坏性动作确认（点击只置 pending，确认分支才写，取消零写入）──
                    .confirmationDialog(
                        "删除预设？",
                        isPresented: Binding(get: { pendingDeletePreset != nil },
                                             set: { if !$0 { pendingDeletePreset = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("删除", role: .destructive) { confirmDeletePreset() }
                        Button("取消", role: .cancel) { pendingDeletePreset = nil }
                    }
                    .confirmationDialog(
                        "删除插槽？",
                        isPresented: Binding(get: { pendingDeleteSlot != nil },
                                             set: { if !$0 { pendingDeleteSlot = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("删除", role: .destructive) { confirmDeleteSlot() }
                        Button("取消", role: .cancel) { pendingDeleteSlot = nil }
                    }
                    .confirmationDialog(
                        "用这段 JSON 覆盖当前预设？",
                        isPresented: Binding(get: { pendingApplyRawJSONPresetId != nil },
                                             set: { if !$0 { pendingApplyRawJSONPresetId = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("覆盖", role: .destructive) {
                            let target = pendingApplyRawJSONPresetId
                            pendingApplyRawJSONPresetId = nil
                            if target == preset.id { applyRawJSON(preset: preset, psm: psm) }
                        }
                        Button("取消", role: .cancel) { pendingApplyRawJSONPresetId = nil }
                    }
                    .confirmationDialog(
                        "重置会丢掉这次的 JSON 编辑？",
                        isPresented: $pendingResetRawJSON,
                        titleVisibility: .visible
                    ) {
                        Button("重置", role: .destructive) {
                            pendingResetRawJSON = false
                            resetRawJSON(preset: preset, psm: psm)
                        }
                        Button("取消", role: .cancel) { pendingResetRawJSON = false }
                    }
                    // ── G2：预设重命名（两端新增）──
                    .alert("重命名预设", isPresented: $isRenamingPreset) {
                        TextField("预设名称", text: $renamingPresetName)
                        Button("确定") {
                            let latest = psm.preset(byId: profile.presetId) ?? preset
                            renamePreset(latest, to: renamingPresetName, psm: psm)
                        }
                        Button("取消", role: .cancel) {}
                    }
            }
        }
        #if os(iOS)
        .navigationTitle("Prompt")   // mac 根页标题由宿主 `MacSettingsPage` 的 toolbar 给（同外观五页口径）
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showFullEditor) {
            VStack(spacing: 0) {
                HStack {
                    Button("取消") { showFullEditor = false }
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Text(fullEditLabel)
                        .font(.system(size: Theme.F.label, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button("完成") {
                        if let slotId = fullEditSlotId,
                           let psm = presetManager,
                           let pm = profileManager {
                            let profile = pm.currentProfile
                            applyIOSSimpleDraft(slotId: slotId, text: fullEditText, presetId: profile.presetId)
                            persistIOSSimpleDrafts(presetId: profile.presetId, psm: psm)
                        }
                        showFullEditor = false
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.2)

                TextEditor(text: $fullEditText)
                    .font(.system(size: Theme.F.body))
                    .padding(12)
                    .scrollContentBackground(.hidden)
            }
            .background(Theme.sidebarBg)
        }
        #endif
        // E3：`.fileImporter` 出 iOS 门——mac「导入 Prompt 预设」终于有展示器
        .fileImporter(isPresented: $showPresetImporter, allowedContentTypes: [.json]) { result in
            handlePresetImport(result)
        }
        .alert("预设导入提示", isPresented: Binding(get: { presetImportNotice != nil }, set: { if !$0 { presetImportNotice = nil } })) {
            Button("好的") { presetImportNotice = nil }
        } message: { Text(presetImportNotice ?? "") }
    }

    @ViewBuilder
    func iOSPromptPageContent(profile: Profile, preset: Preset, pm: ProfileManager, psm: PresetManager) -> some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("PersonaSettingsTab.iOSPromptPageContent") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        let isSimple = personaEditMode == "simple" || personaEditMode.isEmpty
        // 实发同一条组装路径算一次，三块共用；只在看得见的时候算（仪表盘展开 / 组装 / 请求 tab）
        // 修全局卡顿：body 里只读算好的结果，真正的组装在下面 .task(id:) 里防抖跑（Air 上曾在 body 里同步组装被看门狗杀）
        let showsPreview = cacheDashboardExpanded || personaEditMode == "assembly" || personaEditMode == "request"
        let turn = showsPreview ? promptPreview : nil
        let wantsPreview = showsPreview && promptPageOnScreen && promptPreviewAppActive && promptPreviewScenePhase == .active
        // sortedKeys：预设里有字典，同一份内容每次编出来的顺序可能不同 → key 抖动 → 反复重算
        let presetEncoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }()
        let previewKey = PromptPreviewKey(profile: profile, preset: (try? presetEncoder.encode(preset)) ?? Data(),
                                          wantsPreview: wantsPreview, model: selectedChatModelId)

        return ScrollViewReader { proxy in
            SettingsSectionList(.list) {
                // ── 共享：预设 ──
                Section("预设") {
                    iOSPromptPresetSectionContent(profile: profile, preset: preset, pm: pm, psm: psm)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                // ── 用量·缓存仪表盘（模式选择器上方，可折叠）──
                Section {
                    cacheDashboard(preset: preset, psm: psm, turn: turn)
                        .searchAnchor("leaf-persona-usage")
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                // ── 共享：模式选择器 ──
                Section {
                    iOSPromptModePicker
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                // ── 内容按模式切换 ──
                if isSimple {
                    // 输入框控件两端不同（mac 无 UIKit 自增高编辑器，第 4 类）；草稿链是同一条（B11）
                    #if os(macOS)
                    personaSimpleMode(preset: preset, psm: psm)
                    #else
                    iOSSimpleFieldsSections(preset: preset, psm: psm)
                    #endif
                } else if personaEditMode == "slots" {
                    iOSSlotsSection(preset: preset, profile: profile, pm: pm, psm: psm)
                } else {
                    // raw / assembly / request
                    if personaEditMode == "raw" {
                        Section {
                            DisclosureGroup(isExpanded: $samplingExpanded) {
                                personaSamplingSection(preset: preset, profile: profile, pm: pm, psm: psm)
                            } label: {
                                Text("采样参数")
                                    .font(m.body.weight(.medium))
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }
                        .listRowBackground(Theme.mainBg)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        switch personaEditMode {
                        case "raw":
                            personaRawMode(preset: preset, psm: psm)
                        case "assembly":
                            personaAssemblyPreview(preset: preset, turn: turn)
                        case "request":
                            personaRequestPreview(turn: turn)
                        default:
                            EmptyView()
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }

                // ── 相关：调教 AI 说话的延伸入口（A2：mac 三页各有一级 tab，不再加一遍）──
                #if os(iOS)
                Section("相关") {
                    NavigationLink {
                        AttachmentPage()
                    } label: {
                        promptRelatedRow(icon: "paperclip", title: "附件")
                    }
                    .searchAnchor("leaf-persona-related")
                    NavigationLink {
                        RegexPage()
                    } label: {
                        promptRelatedRow(icon: "textformat.abc", title: "正则")
                    }
                    NavigationLink {
                        WorldBookPage()
                    } label: {
                        promptRelatedRow(icon: "book.closed", title: "世界书")
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
                #endif
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .scrollDismissesKeyboard(.immediately)
            #endif
            // 搜索锚点：复用这里已有的 ScrollViewReader proxy
            .settingsAnchorScroll(proxy)
            #if os(iOS)
            .onChange(of: iOSSimpleScrollRequest) { _, _ in
                guard isSimple, let target = iOSSimpleFocusedSlotId else { return }
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                guard isSimple, let target = iOSSimpleFocusedSlotId else { return }
                requestIOSSimpleFieldVisibility(target, delay: 120_000_000)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                guard isSimple else { return }
                iOSSimpleVisibilityTask?.cancel()
                iOSSimpleVisibilityTask = nil
            }
            #endif
        }
        .onAppear { promptPageOnScreen = true }
        .onDisappear { promptPageOnScreen = false }
        .task(id: previewKey) {
            guard wantsPreview else {
                if !showsPreview { promptPreview = nil }   // 只是看不见：留着上次的结果，回来先显示旧的再重算
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            promptPreview = previewTurn(profile: profile, preset: preset)
        }
    }

    // 下面到 `iOSSimpleFieldsSections` 为止是 iOS 专属：「相关」组行（A2：mac 不加这一组）
    // 与 UIKit 自增高编辑器的字段体（mac 走 `personaSimpleMode`）
    #if os(iOS)

    /// Prompt 页底「相关」入口行：icon + 标题，chevron 由 NavigationLink 自带。
    private func promptRelatedRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 28)
            Text(title)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
    }

    // MARK: - 简单模式字段（List sections）

    @ViewBuilder
    func iOSSimpleFieldsSections(preset: Preset, psm: PresetManager) -> some View {
        Section {
            ForEach(Self.iOSSimplePromptFields) { field in
                iOSSimpleField(
                    field.label,
                    preset: preset,
                    slotId: field.slotId,
                    placeholder: field.placeholder,
                    psm: psm,
                    onBeganEditing: {
                        requestIOSSimpleFieldVisibility(field.slotId)
                    },
                    onEndedEditing: {
                        clearIOSSimpleFieldFocus(field.slotId)
                    },
                    onHeightChange: { _ in
                        guard iOSSimpleFocusedSlotId == field.slotId else { return }
                        requestIOSSimpleFieldVisibility(field.slotId)
                    }
                )
                .id(field.slotId)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowSeparator(.hidden)
            }

            Text("修改即时生效，切换模式可看到同步")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .listRowSeparator(.hidden)
        }
        .listRowBackground(Theme.mainBg)
    }
    #endif

    // MARK: - 插槽模式内容（List sections）

    @ViewBuilder
    func iOSSlotsSection(preset: Preset, profile: Profile, pm: ProfileManager, psm: PresetManager) -> some View {
        Section {
            DisclosureGroup(isExpanded: $samplingExpanded) {
                personaSamplingSection(preset: preset, profile: profile, pm: pm, psm: psm)
            } label: {
                Text("采样参数")
                    .font(m.body.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        Section {
            // B7（第 7 类）：mac 没有 swipeActions / push 二级页 —— 行内折叠编辑 + 拖拽排序 + 行内删除
            #if os(macOS)
            personaSlotsMode(preset: preset, psm: psm)
            #else
            ForEach(Array(preset.prompts.enumerated()), id: \.element.id) { index, slot in
                Button { selectedSlotIndex = index } label: {
                    HStack(spacing: 10) {
                        if !slot.isLocked {
                            Toggle("", isOn: Binding(
                                get: { slot.isEnabled },
                                set: { val in
                                    var p = preset
                                    p.prompts[index].isEnabled = val
                                    psm.save(p)
                                }
                            ))
                            .toggleStyle(.switch)
                            .scaleEffect(0.65)
                            .frame(width: 40)
                            .highPriorityGesture(TapGesture())
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                                .frame(width: 40)
                        }

                        Text(slot.name)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(slot.isEnabled || slot.isLocked ? Theme.textPrimary : Theme.textMuted)
                            .lineLimit(1)

                        Text(slot.role)
                            .font(.system(size: Theme.F.badge, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(
                                slot.role == "system" ? Theme.textMuted :
                                slot.role == "user" ? Theme.branchIndicator : .orange
                            ))

                        if slot.isMarker {
                            Text("占位")
                                .font(.system(size: Theme.F.badge))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().stroke(Theme.textMuted, lineWidth: 0.5))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !slot.isSystemPrompt && !slot.isMarker {
                        // D4 入口 ①（iOS swipe）：只置 pending
                        Button(role: .destructive) {
                            pendingDeleteSlot = PendingSlotDelete(presetId: preset.id, slotId: slot.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    Button { selectedSlotIndex = index } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(Theme.branchIndicator)
                }
            }
            .onMove { from, to in
                // ④a：顺序只经 SlotOrder 写（sequenceIndex），组装器读同一份，拖完发送顺序跟着变
                var p = preset
                p.prompts = SlotOrder.moving(p.prompts, fromOffsets: from, toOffset: to)
                psm.save(p)
            }
            #endif
        } header: {
            HStack {
                Text("Prompt 插槽")
                Spacer()
                Button {
                    var p = preset
                    p.prompts = SlotOrder.appending(PromptSlot(name: "新插槽", role: "system", isSystemPrompt: false, isEnabled: false, injectionOrder: (preset.prompts.last?.injectionOrder ?? 100) + 10), to: p.prompts)
                    psm.save(p)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }
        }

        // 写作风格虚拟槽：不进 preset.prompts，PromptAssembler 在 user 末尾贴 <style>
        Section {
            Button {
                if viewModel != nil { showStyleManagerFromSlots = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .frame(width: 40)
                    Text("写作风格")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text("user 末尾")
                        .font(m.caption.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.branchIndicator))
                    Text("占位")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(Theme.textMuted, lineWidth: 0.5))
                    Spacer()
                    if viewModel != nil {
                        Image(systemName: "chevron.right")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.mainBg)
            .sheet(isPresented: $showStyleManagerFromSlots) {
                if let vm = viewModel {
                    StyleManagerView(viewModel: vm, manager: StyleManager.shared)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        } header: {
            Text("写作风格")
        } footer: {
            if let id = viewModel?.selectedConversation?.currentStyleId, !id.isEmpty,
               let s = StyleManager.shared.find(id) {
                Text("当前：\(s.name)").foregroundColor(Theme.textMuted)
            } else if viewModel == nil {
                Text("在聊天页加号面板选择").foregroundColor(Theme.textMuted)
            } else {
                Text("未选择").foregroundColor(Theme.textMuted)
            }
        }
    }

    @ViewBuilder
    func iOSPromptPresetSectionContent(profile: Profile, preset: Preset, pm: ProfileManager, psm: PresetManager) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { psm.preset(byId: profile.presetId)?.sourceTemplateId ?? profile.presetId },
                set: { newTemplateId in
                    flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                    switchFloor(profile, toTemplate: newTemplateId, pm: pm, psm: psm)
                }
            )) {
                ForEach(psm.templates) { pr in
                    Text(pr.name).tag(pr.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.branchIndicator)

            Spacer()

            HStack(spacing: 16) {
                Button {
                    flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                    // 当前楼层实例 → 存成新模板（其他楼层可选）
                    let latestPreset = psm.preset(byId: profile.presetId) ?? preset
                    _ = psm.duplicate(latestPreset)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                // G2：重命名（两端新增；内置模板不改名）
                if !preset.isBuiltIn {
                    Button {
                        renamingPresetName = preset.name
                        isRenamingPreset = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                    exportPreset(psm.preset(byId: profile.presetId) ?? preset)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Button { showPresetImporter = true } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)

                if !preset.isBuiltIn {
                    // D3：只置 pending，确认分支才删源模板 + 本楼层实例
                    Button {
                        pendingDeletePreset = PendingPresetDelete(profileId: profile.id, presetId: preset.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 18))
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var iOSPromptModePicker: some View {
        Picker("", selection: iOSPersonaEditModeSelection) {
            Text("简单").tag("simple")
            Text("插槽").tag("slots")
            Text("JSON").tag("raw")
            Text("组装").tag("assembly")
            Text("请求").tag("request")
        }
        .pickerStyle(.segmented)
        .tint(Theme.branchIndicator)
    }

    func requestIOSSimpleFieldVisibility(_ slotId: String, delay: UInt64 = 0) {
        iOSSimpleFocusedSlotId = slotId
        iOSSimpleVisibilityTask?.cancel()
        iOSSimpleVisibilityTask = Task { @MainActor [slotId] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            guard iOSSimpleFocusedSlotId == slotId else { return }
            iOSSimpleScrollRequest += 1
        }
    }

    func clearIOSSimpleFieldFocus(_ slotId: String) {
        guard iOSSimpleFocusedSlotId == slotId else { return }
        iOSSimpleVisibilityTask?.cancel()
        iOSSimpleVisibilityTask = nil
        iOSSimpleFocusedSlotId = nil
    }

    #if os(iOS)
    @ViewBuilder
    func iOSSimpleField(
        _ label: String,
        preset: Preset,
        slotId: String,
        placeholder: String,
        psm: PresetManager,
        onBeganEditing: @escaping () -> Void = {},
        onEndedEditing: @escaping () -> Void = {},
        onHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) -> some View {
        let binding = iOSSimpleBinding(for: slotId, preset: preset, psm: psm)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: Theme.F.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button {
                    fullEditLabel = label
                    fullEditText = binding.wrappedValue
                    fullEditSlotId = slotId
                    showFullEditor = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)

            IOSPromptTextView(
                text: binding,
                placeholder: placeholder,
                onBeganEditing: onBeganEditing,
                onEndedEditing: onEndedEditing,
                onHeightChange: onHeightChange
            )
        }
        .id(slotId)
    }
    #endif

    /// `immediate`：mac 侧「0 防抖」= 每次改动同步 persist（B11 astra R5b-I2 ①：
    /// 不能只把 `scheduleIOSSimpleDraftSave` 的 sleep 常量改 0，那仍是可取消的异步 Task）。iOS 仍是 300ms 防抖。
    func iOSSimpleBinding(for slotId: String, preset: Preset, psm: PresetManager,
                          immediate: Bool = false) -> Binding<String> {
        Binding(
            get: {
                if iOSSimpleDraftPresetId == preset.id {
                    return iOSSimpleDrafts[slotId] ?? preset.prompts.first(where: { $0.id == slotId })?.content ?? ""
                }
                return preset.prompts.first(where: { $0.id == slotId })?.content ?? ""
            },
            set: { newValue in
                if iOSSimpleDraftPresetId != preset.id {
                    syncIOSSimpleDrafts(from: preset, force: true)
                }
                applyIOSSimpleDraft(slotId: slotId, text: newValue, presetId: preset.id)
                if immediate {
                    persistIOSSimpleDrafts(presetId: preset.id, psm: psm)
                } else {
                    scheduleIOSSimpleDraftSave(presetId: preset.id, psm: psm)
                }
            }
        )
    }

    /// 简单模式才起草稿会话；别的模式一律让会话失效（B11 单草稿链）
    func syncSimpleDraftsIfSimple(_ preset: Preset) {
        if personaEditMode == "simple" || personaEditMode.isEmpty {
            syncIOSSimpleDrafts(from: preset, force: true)
        } else {
            invalidateIOSSimpleDrafts()
        }
    }

    /// 草稿会话失效（B11 astra R5b-I2 ②）：只在**已经 flush 过**之后调。
    /// 之后 `persistIOSSimpleDrafts` 的 `iOSSimpleDraftPresetId == presetId` 守卫不成立 → 旧稿不再被重放。
    func invalidateIOSSimpleDrafts() {
        iOSSimpleSaveTask?.cancel()
        iOSSimpleSaveTask = nil
        iOSSimpleDraftPresetId = nil
        iOSSimpleDrafts = [:]
    }

    func syncIOSSimpleDrafts(from preset: Preset, force: Bool = false) {
        if !force, iOSSimpleDraftPresetId == preset.id, !iOSSimpleDrafts.isEmpty {
            return
        }
        iOSSimpleSaveTask?.cancel()
        iOSSimpleSaveTask = nil
        iOSSimpleDraftPresetId = preset.id
        iOSSimpleDrafts = iOSSimpleDraftSnapshot(from: preset)
    }

    func applyIOSSimpleDraft(slotId: String, text: String, presetId: String) {
        if iOSSimpleDraftPresetId != presetId {
            iOSSimpleDraftPresetId = presetId
        }
        iOSSimpleDrafts[slotId] = text
    }

    func scheduleIOSSimpleDraftSave(presetId: String, psm: PresetManager) {
        iOSSimpleSaveTask?.cancel()
        iOSSimpleSaveTask = Task { @MainActor [presetId, psm] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            persistIOSSimpleDrafts(presetId: presetId, psm: psm)
        }
    }

    func flushIOSSimpleDraftSave(presetId: String, psm: PresetManager) {
        iOSSimpleSaveTask?.cancel()
        iOSSimpleSaveTask = nil
        persistIOSSimpleDrafts(presetId: presetId, psm: psm)
    }

    func persistIOSSimpleDrafts(presetId: String, psm: PresetManager) {
        guard iOSSimpleDraftPresetId == presetId else { return }
        guard var preset = psm.preset(byId: presetId) else { return }

        var didChange = false
        for slotId in Self.iOSSimplePromptSlotIds {
            guard let text = iOSSimpleDrafts[slotId],
                  let idx = preset.prompts.firstIndex(where: { $0.id == slotId }),
                  preset.prompts[idx].content != text else {
                continue
            }
            preset.prompts[idx].content = text
            didChange = true
        }

        if didChange {
            psm.save(preset)
        }
    }

    func iOSSimpleDraftSnapshot(from preset: Preset) -> [String: String] {
        var snapshot: [String: String] = [:]
        for slotId in Self.iOSSimplePromptSlotIds {
            snapshot[slotId] = preset.prompts.first(where: { $0.id == slotId })?.content ?? ""
        }
        return snapshot
    }
}

// MARK: - Parameter Row

struct ParameterRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: String = "%.1f"
    var intMode: Bool = false

    @State private var isEditing = false
    @State private var editText = ""
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    editText = intMode ? "\(Int(value))" : String(format: format, value)
                    isEditing = true
                } label: {
                    // 数值：iOS 13 medium mono 不变；mac 11 regular → 11 medium（刀 0.5b ⧫3，粟粟裁改）
                    Text(intMode ? "\(Int(value))" : String(format: format, value))
                        .font(m.secondary.weight(.medium).monospaced())
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }

            #if os(macOS)
            MacSettingsSlider(value: $value, in: range, step: step)
                .tint(Theme.branchIndicator)
            #else
            Slider(value: $value, in: range, step: step)
                .tint(Theme.branchIndicator)
            #endif
        }
        .alert("输入数值", isPresented: $isEditing) {
            TextField("", text: $editText)
                #if os(iOS)
                .keyboardType(intMode ? .numberPad : .decimalPad)
                #endif
            Button("确定") {
                if let v = Double(editText) {
                    value = min(max(v, range.lowerBound), range.upperBound)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - Slot Edit Page (iOS)

#if os(iOS)
struct SlotEditPage: View {
    let slot: PromptSlot
    let index: Int
    let preset: Preset
    let psm: PresetManager

    @Environment(\.dismiss) private var dismiss

    @State private var editName: String = ""
    @State private var editRole: String = ""
    @State private var editContent: String = ""
    @State private var editDepth: String = ""

    /// 有未保存改动 → 保存键亮起。用 @State 而非计算属性：由各字段 onChange 主动刷新，
    /// 强制 toolbar item 重算（TextEditor 直接驱动计算属性时 toolbar 不刷新）。
    @State private var isDirty = false

    /// D4：删除此插槽的确认。这一页是独立 struct 且删完要 `dismiss()`，pending 只能各存各的；
    /// 删除实现与页内两个入口共用文件级的 `deletePromptSlot`（按 preset id + slot id 重找，取消零写）。
    @State private var pendingDelete = false

    private func refreshDirty() {
        isDirty = editName != slot.name ||
            editRole != slot.role ||
            editContent != slot.content ||
            (Int(editDepth) ?? 0) != slot.injectionDepth
    }

    /// 从 psm 读最新 preset 写回，避免用创建时的旧快照互相覆盖
    private func patch(_ mutate: (inout PromptSlot) -> Void) {
        guard var p = psm.preset(byId: preset.id), index < p.prompts.count else { return }
        mutate(&p.prompts[index])
        psm.save(p)
    }

    private func saveAndExit() {
        let autoFilled = slot.id == PromptSlot.memoryInjectionId || slot.id == PromptSlot.chatHistoryId || slot.id == PromptSlot.contextSummaryId || slot.id == PromptSlot.userProfileId
        if !slot.isMarker {
            patch {
                $0.name = editName
                $0.role = editRole
                $0.content = editContent
                SlotOrder.setDepth(Int(editDepth) ?? 0, of: &$0)
            }
        } else {
            patch {
                $0.name = editName
                $0.role = editRole
                if !autoFilled { $0.content = editContent }
            }
        }
        dismiss()
    }

    /// 自定义顶栏：复刻聊天页 iOSChatTopBar 的玻璃返回键 + 标题 + 玻璃保存胶囊。
    /// 不走系统导航栏 —— glassEffect 只有在自定义 overlay 里才正确渲染成玻璃圆/胶囊，
    /// 塞进 .toolbar 会被导航栏接管渲染（不圆、无玻璃）。
    private var slotTopBar: some View {
        ZStack {
            Text(slot.name)
                .font(.system(size: Theme.F.body, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 88)

            HStack {
                GlassBackButton { dismiss() }
                Spacer()
                Button(action: saveAndExit) {
                    Text("保存")
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .foregroundColor(isDirty ? Theme.branchIndicator : Theme.textMuted)
                        .frame(height: 44)
                        .padding(.horizontal, 16)
                        .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(!isDirty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 4)
        .background(Theme.sidebarBg)
    }

    var body: some View {
        List {
            Section("基本") {
                HStack {
                    Text("名称")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textSecondary)
                    TextField("插槽名称", text: $editName)
                        .font(.system(size: Theme.F.body))
                        .multilineTextAlignment(.trailing)
                }

                Picker("角色", selection: $editRole) {
                    Text("system").tag("system")
                    Text("user").tag("user")
                    Text("assistant").tag("assistant")
                }
                .font(.system(size: Theme.F.body))
                .tint(Theme.branchIndicator)

                if !slot.isMarker {
                    HStack {
                        Text("注入深度")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("0=按顺序，>0=从末尾倒数第 N 条插入", text: $editDepth)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                }
            }
            .listRowBackground(Theme.mainBg)

            Section("内容") {
                if slot.id == PromptSlot.memoryInjectionId || slot.id == PromptSlot.chatHistoryId || slot.id == PromptSlot.contextSummaryId || slot.id == PromptSlot.userProfileId {
                    Text("此插槽由系统自动填充")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                } else {
                    if slot.isMarker {
                        Text("留空时由楼层对应字段填充（助手设定/用户描述等）；填了内容则优先用这里的")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                    TextEditor(text: $editContent)
                        .font(.system(size: Theme.F.body))
                        .frame(minHeight: 300)
                        .scrollContentBackground(.hidden)
                }
            }
            .listRowBackground(Theme.mainBg)

            if !slot.isSystemPrompt && !slot.isMarker {
                Section {
                    // D4 入口 ③：只置 pending，确认分支才删（与另两个入口同一实现 `deletePromptSlot`）
                    Button(role: .destructive) {
                        pendingDelete = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("删除此插槽")
                        }
                        .font(.system(size: Theme.F.body))
                        .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Theme.danger.opacity(0.1))
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .background(Theme.sidebarBg)
        .safeAreaInset(edge: .top, spacing: 0) { slotTopBar }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationBarBackButtonHidden(true)
        .confirmationDialog("删除插槽？", isPresented: $pendingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                deletePromptSlot(presetId: preset.id, slotId: slot.id, psm: psm)
                dismiss()
            }
            Button("取消", role: .cancel) { pendingDelete = false }
        }
        .onAppear {
            editName = slot.name
            editRole = slot.role
            editContent = slot.content
            editDepth = "\(slot.injectionDepth)"
            refreshDirty()
        }
        .onChange(of: editName) { _, _ in refreshDirty() }
        .onChange(of: editRole) { _, _ in refreshDirty() }
        .onChange(of: editContent) { _, _ in refreshDirty() }
        .onChange(of: editDepth) { _, _ in refreshDirty() }
    }
}

// MARK: - Slot Navigation Modifier（push vs sheet 切换）

/// 右栏用 sheet 弹出插槽编辑，设置页用 navigationDestination push
struct SlotNavigationModifier: ViewModifier {
    @Binding var selectedSlotIndex: Int?
    let useSheet: Bool

    // 两种初始化：直接传 preset 或从 environment 读
    var preset: Preset?
    var psm: PresetManager?
    var presetManager: PresetManager?
    var profileManager: ProfileManager?

    init(selectedSlotIndex: Binding<Int?>, useSheet: Bool, preset: Preset, psm: PresetManager) {
        self._selectedSlotIndex = selectedSlotIndex
        self.useSheet = useSheet
        self.preset = preset
        self.psm = psm
    }

    init(selectedSlotIndex: Binding<Int?>, useSheet: Bool, presetManager: PresetManager?, profileManager: ProfileManager?) {
        self._selectedSlotIndex = selectedSlotIndex
        self.useSheet = useSheet
        self.presetManager = presetManager
        self.profileManager = profileManager
    }

    private var resolvedPreset: Preset? {
        if let preset { return preset }
        guard let psm = presetManager, let pm = profileManager else { return nil }
        return psm.preset(byId: pm.currentProfile.presetId) ?? Preset.balanced
    }

    private var resolvedPsm: PresetManager? {
        psm ?? presetManager
    }

    func body(content: Content) -> some View {
        if useSheet {
            content
                .sheet(isPresented: Binding(
                    get: { selectedSlotIndex != nil },
                    set: { if !$0 { selectedSlotIndex = nil } }
                )) {
                    if let idx = selectedSlotIndex,
                       let preset = resolvedPreset, let psm = resolvedPsm,
                       idx < preset.prompts.count {
                        NavigationStack {
                            SlotEditPage(slot: preset.prompts[idx], index: idx, preset: preset, psm: psm)
                        }
                    }
                }
        } else {
            content
                .navigationDestination(item: $selectedSlotIndex) { idx in
                    if let preset = resolvedPreset, let psm = resolvedPsm, idx < preset.prompts.count {
                        SlotEditPage(slot: preset.prompts[idx], index: idx, preset: preset, psm: psm)
                    }
                }
        }
    }
}
#endif
