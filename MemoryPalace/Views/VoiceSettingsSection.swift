import SwiftUI
import AVFoundation

// MARK: - 语音条设置（设置-朗读 内）

/// 朗读页里的「语音条」两个 Section（两端一份，刀 3 合流后 mac 也用它）
struct VoiceMessageSettingsIOSSections: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage(VoiceTuning.proactiveKey) private var proactiveEnabled = false

    var body: some View {
        Section {
            FloorVoiceRows()
            Toggle("AI 主动发语音", isOn: Binding(
                get: { PermissionCenter.level(.voiceProactive) == .bypass },
                set: { PermissionCenter.setLevel($0 ? .bypass : .notAllowed, for: .voiceProactive) }
            ))
                .tint(Theme.branchIndicator)
                // 楼层语音设置改了（服务/声音/模型/嗓子说明/素材/主动开关）→ 立刻同步 cc-rp CLAUDE.md 标记块（按内容去重）。
                // 挂在单行 Toggle 上：挂 Section 会摊到每一行
                .onChange(of: profileManager?.currentProfile) { _, p in syncCCVoiceInstructions(p) }
                .onChange(of: proactiveEnabled) { _, _ in syncCCVoiceInstructions(profileManager?.currentProfile) }
        } header: {
            Text("声音")
        } footer: {
            Text("本楼层的语音服务和声音同时用于发语音条和语音通话。开启「AI 主动发语音」后 \(assistantName) 会在想让你听见语气的时刻主动发语音条。")
        }
        Section {
            DisclosureGroup("声音效果") {
                VoiceEffectControls()
            }
            #if os(macOS)
            // J2b：mac 折叠三角跟次要文字色，不用系统强调色
            .tint(ShellStyle.secondaryText)
            #endif
        }
        VoiceProsodySettingsSection()
        VoiceEffectsSettingsSection()
        SpeakerIdentitySettingsSection()
        #if os(iOS)
        NativeCallSettingsSection()
        #endif
    }

    private func syncCCVoiceInstructions(_ profile: Profile?) {
        guard let profile else { return }
        CCBridgeWebSocketClient.shared.syncVoiceInstructions(VoicePromptInjector.ccInstructionsBlock(profile: profile))
    }
}

/// 语气是本机测量的线索，开启后的新语音随聊天发送；不会改变胶囊的转写 / 复制内容。
struct VoiceProsodySettingsSection: View {
    @AppStorage(VoiceProsodyStore.enabledKey) private var enabled = false
    @State private var confirmClear = false

    var body: some View {
        Section {
            Toggle("听语气", isOn: $enabled)
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-tts-prosody")
            Button("清空声音基线", role: .destructive) { confirmClear = true }
                .searchAnchor("leaf-tts-prosody-reset")
        } header: {
            Text("听语气")
        } footer: {
            Text("在本机估计语音条的静音、停顿和相对声音变化，随该条语音的文字发送给聊天模型。不同录音设备分开比较，不猜测心情。基线不足时只给出当前录音的线索。关闭后不分析新录音。")
        }
        .confirmationDialog("清空声音基线？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { VoiceProsodyStore.shared.clear() }
        } message: {
            Text("会重新学习你的声音，已有语音和转写不会删除。")
        }
        .onChange(of: enabled) { _, value in
            // 使关闭前的分析失效，即使很快重新打开也不能把旧结果写入。
            if !value { VoiceProsodyStore.shared.invalidatePending() }
        }
    }
}

/// 声音效果控件 + 恢复默认（双端共用）。显示哪些跟本楼层语音服务的语音条模型走（`capabilities.tunables`）；
/// 楼层没选服务时全显示。
struct VoiceEffectControls: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage(VoiceTuning.stabilityKey) private var stability = VoiceTuning.defaultStability
    @AppStorage(VoiceTuning.styleKey) private var style = VoiceTuning.defaultStyle
    @AppStorage(VoiceTuning.speedKey) private var speed = VoiceTuning.defaultSpeed

    /// (显示哪些参数, 表演感是不是三档)。三档只有 v3 / 没选服务的老楼层；v4 系是连续滑杆（V0 探针）
    private var config: (shown: Set<VoiceTunable>, discreteStability: Bool) {
        guard let p = profileManager?.currentProfile,
              let service = VoiceServiceStore.shared.service(id: p.voiceServiceId) else { return (Set(VoiceTunable.allCases), true) }
        let caps = service.makeSynthesizer().capabilities
        let model = caps.resolvedModel(p.messageModel)
        return (Set(caps.tunables(for: model)), service.kind == .elevenLabs && model == ElevenLabsSynthesizer.v3)
    }

    var body: some View {
        let cfg = config
        let shown = cfg.shown
        VStack(alignment: .leading, spacing: 10) {
            if shown.contains(.stability) {
                if cfg.discreteStability {
                    Picker("表演感", selection: $stability) {
                        Text("奔放").tag(0.0)
                        Text("自然").tag(0.5)
                        Text("沉稳").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                    .onAppear {
                        // 历史脏值 / v4 滑杆留下的非三档值钳回最近档，防 segmented 无选中
                        if ![0.0, 0.5, 1.0].contains(stability) { stability = ElevenLabsSynthesizer.v3Stability(stability) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("表演感：\(stability, specifier: "%.2f")")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(Theme.textMuted)
                        Slider(value: $stability, in: 0...1, step: 0.05)
                    }
                }
                Text("越低（奔放）标签响应越强、越随机；越高（沉稳）越平稳。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }

            if shown.contains(.style) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("风格强度：\(style, specifier: "%.2f")")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.textMuted)
                    Slider(value: $style, in: 0...1, step: 0.01)
                }
            }
            if shown.contains(.speed) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("语速：\(speed, specifier: "%.2f")")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.textMuted)
                    Slider(value: $speed, in: 0.7...1.5, step: 0.01)
                }
            }
            if shown.isDisjoint(with: [.stability, .style, .speed]) {
                Text("这个楼层的语音服务没有可调的声音效果。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            }

            Button("恢复默认") {
                VoiceTuning.resetToDefaults()
            }
            .font(.system(size: Theme.SettingsFont.secondary))
            .buttonStyle(.plain)
            .foregroundColor(Theme.branchIndicator)
        }
    }
}

// MARK: - 楼层声音（服务 + 声音 + 两个模型）

/// 「声音」区的楼层行：语音服务 picker → 声音（能拉列表就弹选择器，拉不到就手填）→ 语音条模型 / 通话模型
struct FloorVoiceRows: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var showPicker = false
    @State private var manualVoiceId = ""
    private var store: VoiceServiceStore { .shared }

    private var profile: Profile? { profileManager?.currentProfile }
    private var service: VoiceService? { store.service(id: profile?.voiceServiceId) }

    var body: some View {
        Picker("语音服务", selection: serviceBinding) {
            Text("未选择").tag(String?.none)
            ForEach(store.services) { s in
                Text(s.name).tag(Optional(s.id))
            }
        }
        if let service {
            let caps = service.makeSynthesizer().capabilities
            if caps.canFetchVoices {
                voicePickRow(service)
            } else {
                manualVoiceRow(service)
            }
            VoiceExtraNoteRow()
            if !caps.models.isEmpty {
                Picker("语音条模型", selection: modelBinding(\.messageModel, caps)) {
                    ForEach(caps.models) { Text($0.name).tag($0.id) }
                }
                Picker("通话模型", selection: modelBinding(\.callModel, caps)) {
                    ForEach(caps.models) { Text($0.name).tag($0.id) }
                }
                if profile?.voiceEffects?.callActive == true,
                   caps.models.first(where: { $0.id == caps.resolvedModel(profile?.callModel) })?.streaming == true {
                    Text("开着通话音效时整句合成，不边收边播")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
            }
        }
    }

    private func voicePickRow(_ service: VoiceService) -> some View {
        Button { showPicker = true } label: {
            HStack {
                Text("声音")
                    .font(.system(size: Theme.SettingsFont.label))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize()
                Spacer()
                Text(profile?.voiceName ?? "未选择")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.textMuted)
                    // 长 voice 名截断，别挤掉左标题和 chevron（A-7）
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) { VoicePickerSheet(service: service) }
    }

    private func manualVoiceRow(_ service: VoiceService) -> some View {
        HStack(spacing: 8) {
            Text("声音")
                .font(.system(size: Theme.SettingsFont.label))
                .foregroundColor(Theme.textPrimary)
                .fixedSize()
            TextField("填声音 ID", text: $manualVoiceId)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .onSubmit { saveManualVoice(service) }
        }
        .onAppear { manualVoiceId = profile?.voiceId ?? "" }
        .onChange(of: profile?.voiceId) { _, new in manualVoiceId = new ?? "" }
        .onDisappear { saveManualVoice(service) }
    }

    private func saveManualVoice(_ service: VoiceService) {
        let trimmed = manualVoiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile?.voiceServiceId == service.id, trimmed != (profile?.voiceId ?? "") else { return }
        update { $0.setVoice(service: service, voiceId: trimmed, voiceName: trimmed) }
    }

    private var serviceBinding: Binding<String?> {
        Binding(
            get: { service?.id },
            set: { newId in
                guard newId != profile?.voiceServiceId else { return }
                update { $0.setVoice(service: store.service(id: newId), voiceId: nil, voiceName: nil) }
            }
        )
    }

    private func modelBinding(_ keyPath: WritableKeyPath<Profile, String?>, _ caps: VoiceCapabilities) -> Binding<String> {
        Binding(
            get: { caps.resolvedModel(profile?[keyPath: keyPath]) ?? "" },
            set: { new in update { $0[keyPath: keyPath] = new } }
        )
    }

    private func update(_ change: (inout Profile) -> Void) {
        guard let pm = profileManager else { return }
        var p = pm.currentProfile
        change(&p)
        pm.updateProfile(p)
    }
}

/// 楼层「嗓子补充说明」：多行输入，失焦 / 离开时存（追加在语音条提示词末尾）
struct VoiceExtraNoteRow: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var text = ""
    @State private var loadedProfileId: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("嗓子补充说明", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.SettingsFont.label))
                .focused($focused)
            Text("附在语音条提示词末尾。可以写音色气质、口头禅、标签和拟声词的写法等。")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .onAppear { load() }
        .onChange(of: profileManager?.currentProfile.id) { _, _ in load() }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .onDisappear { save() }
    }

    private func load() {
        guard let p = profileManager?.currentProfile else { return }
        loadedProfileId = p.id
        text = p.voiceExtraNote ?? ""
    }

    private func save() {
        guard let pm = profileManager, pm.currentProfile.id == loadedProfileId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String? = trimmed.isEmpty ? nil : trimmed
        var p = pm.currentProfile
        guard p.voiceExtraNote != note else { return }
        p.voiceExtraNote = note
        pm.updateProfile(p)
    }
}

/// 声音列表选择器：拉服务的声音列表 + 试听 + 选中存楼层；列表外的声音可以手填
struct VoicePickerSheet: View {
    let service: VoiceService
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var voices: [VoiceOption] = []
    @State private var loading = false
    @State private var errorPhrase: String? = nil
    @State private var manualId = ""
    @State private var previewPlayer: AVPlayer? = nil
    @State private var previewingId: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorPhrase {
                    VStack(spacing: 12) {
                        Text("拉不到声音列表（\(errorPhrase)）")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await load() } }
                            .foregroundColor(Theme.branchIndicator)
                        HStack(spacing: 8) {
                            TextField("或者手填声音 ID", text: $manualId)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Button("用这个") { select(id: manualId, name: manualId) }
                                .foregroundColor(Theme.branchIndicator)
                                .disabled(manualId.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    voiceList
                }
            }
            .navigationTitle("选声音")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
        .task { await load() }
        .onDisappear { previewPlayer?.pause() }
    }

    private var voiceList: some View {
        List {
            ForEach(voices) { voice in
                HStack(spacing: 10) {
                    Button {
                        select(id: voice.id, name: voice.name)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name)
                                    .foregroundColor(Theme.textPrimary)
                                if let detail = voice.detail {
                                    Text(detail)
                                        .font(.system(size: Theme.SettingsFont.caption))
                                        .foregroundColor(Theme.textMuted)
                                }
                            }
                            Spacer()
                            if isSelected(voice) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.branchIndicator)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if let url = voice.previewURL {
                        Button {
                            preview(url: url, id: voice.id)
                        } label: {
                            Image(systemName: previewingId == voice.id ? "speaker.wave.2.fill" : "play.circle")
                                .foregroundColor(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                HStack(spacing: 8) {
                    TextField("手填声音 ID", text: $manualId)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                    Button("用这个") { select(id: manualId, name: manualId) }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(manualId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("列表里没有的声音，填它的 ID。")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func isSelected(_ voice: VoiceOption) -> Bool {
        guard let p = profileManager?.currentProfile else { return false }
        return p.voiceServiceId == service.id && p.voiceId == voice.id
    }

    private func load() async {
        let store = VoiceServiceStore.shared
        loading = true
        errorPhrase = nil
        if service.kind.needsKey && store.key(for: service.id) == nil {
            errorPhrase = "先在「语音服务」里给它填 key"
        } else {
            do {
                voices = try await service.makeSynthesizer().fetchVoices()
            } catch {
                errorPhrase = store.errorMessage(error, serviceId: service.id)
            }
        }
        loading = false
    }

    private func select(id: String, name: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pm = profileManager, !id.isEmpty else { return }
        var p = pm.currentProfile
        p.setVoice(service: service, voiceId: id, voiceName: name)
        pm.updateProfile(p)
        dismiss()
    }

    private func preview(url: URL, id: String) {
        if previewingId == id {
            previewPlayer?.pause()
            previewingId = nil
            return
        }
        previewPlayer?.pause()
        previewPlayer = AVPlayer(url: url)
        previewPlayer?.play()
        previewingId = id
    }
}

#if os(iOS)
struct NativeCallSettingsSection: View {
    @AppStorage(NativeCallCoordinator.enabledKey) private var enabled = false
    var body: some View {
        Section {
            Toggle("允许 CC 原生来电", isOn: $enabled)
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-tts-incoming")
            if enabled {
                LabeledContent("这台设备", value: NativeCallCoordinator.shared.installID)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .textSelection(.enabled)
                if let error = NativeCallCoordinator.shared.errorMessage {
                    Text((NativeCallCoordinator.shared.errorAt.map { NativeVoiceCall.clock($0) + " · " } ?? "") + error)
                        .foregroundColor(Theme.textMuted)
                }
            }
        } header: { Text("来电") } footer: {
            Text("默认关闭。开启后，已配对的 CC bridge 可以向明确指定的这台 iPhone 发起系统来电；接听后才启动麦克风。需要 bridge 的 APNs VoIP 能力与网络连接，来电六十秒无人接听会结束。")
        }
        .onChange(of: enabled) { _, _ in NativeCallCoordinator.shared.configure() }
    }
}
#endif
