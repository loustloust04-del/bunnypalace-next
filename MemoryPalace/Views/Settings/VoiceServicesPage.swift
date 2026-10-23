import SwiftUI
import AVFoundation

// MARK: - 设置 · 语音 · 语音服务（plan-voice-providers V1d）

/// 语音服务列表：每张卡 名字 / 厂商 / 在用楼层数 / 试听（错误显示在卡上）；点卡编辑，菜单添加
struct VoiceServicesPage: View {
    @Environment(\.settingsMetrics) private var m
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var editing: VoiceServiceDraft?
    @State private var pendingDelete: VoiceService?
    @State private var auditioningId: String?
    /// 试听任务 + 代际：停止 / 离开 / 重试时取消旧任务、代际 +1，迟到的结果对不上代际就丢
    @State private var auditionTask: Task<Void, Never>?
    @State private var auditionGeneration = 0
    @State private var errors: [String: String] = [:]
    @State private var player = VoiceAuditionPlayer()
    private var store: VoiceServiceStore { .shared }

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                if store.services.isEmpty {
                    Text("还没有语音服务")
                        .font(m.secondary)
                        .foregroundColor(Theme.textMuted)
                }
                ForEach(store.services) { service in
                    card(service)
                }
            } footer: {
                Text("每个楼层在「语音 › 声音」里选用哪个服务和声音。")
            }
            Section {
                Menu {
                    ForEach(VoiceServiceKind.addable, id: \.rawValue) { kind in
                        Button(kind.displayName) { editing = VoiceServiceDraft(service: .blank(kind: kind), isNew: true) }
                    }
                } label: {
                    Label("添加语音服务", systemImage: "plus")
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("语音服务")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $editing) { draft in
            NavigationStack {
                VoiceServiceEditor(draft: draft)
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 440)
            #endif
        }
        .alert(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .onDisappear { stopAudition() }
    }

    // MARK: 卡

    private func card(_ service: VoiceService) -> some View {
        let inUse = floors(using: service).count
        return HStack(spacing: 10) {
            Button { editing = VoiceServiceDraft(service: service, isNew: false) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(m.label)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(inUse > 0 ? "\(service.kind.displayName) · \(inUse) 个楼层在用" : service.kind.displayName)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                    if let err = errors[service.id] {
                        Text(err)
                            .font(m.caption)
                            .foregroundColor(Theme.danger)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if auditioningId == service.id { stopAudition() } else { startAudition(service) }
            } label: {
                Group {
                    if auditioningId == service.id && !player.isPlaying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: auditioningId == service.id ? "stop.circle" : "play.circle")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("试听")
        }
        .contextMenu {
            Button("编辑") { editing = VoiceServiceDraft(service: service, isNew: false) }
            Button("删除", role: .destructive) { requestDelete(service) }
        }
    }

    // MARK: 试听

    private func startAudition(_ service: VoiceService) {
        stopAudition()
        let generation = auditionGeneration
        auditioningId = service.id
        errors[service.id] = nil
        auditionTask = Task { await audition(service, generation: generation) }
    }

    private func isCurrentAudition(_ generation: Int) -> Bool {
        generation == auditionGeneration && !Task.isCancelled
    }

    private func audition(_ service: VoiceService, generation: Int) async {
        let synth = service.makeSynthesizer()
        do {
            var voice = profileManager?.currentProfile.voiceServiceId == service.id
                ? profileManager?.currentProfile.voiceId : nil
            voice = voice ?? floors(using: service).compactMap(\.voiceId).first
            if voice == nil, service.kind != .system, synth.capabilities.canFetchVoices {
                voice = try await synth.fetchVoices().first?.id
            }
            let clip = try await synth.synthesize(text: "你好，这是一段试听。", voice: voice,
                                                  model: synth.capabilities.resolvedModel(nil),
                                                  tuning: VoiceTuning.current())
            guard isCurrentAudition(generation) else { return }
            try player.play(clip) {
                guard generation == auditionGeneration else { return }
                auditioningId = nil
                auditionTask = nil
            }
        } catch {
            guard isCurrentAudition(generation) else { return }
            errors[service.id] = store.errorMessage(error, serviceId: service.id)
            auditioningId = nil
            auditionTask = nil
        }
    }

    private func stopAudition() {
        auditionTask?.cancel()
        auditionTask = nil
        auditionGeneration += 1
        player.stop()
        auditioningId = nil
    }

    // MARK: 删除

    private func floors(using service: VoiceService) -> [Profile] {
        VoiceServiceDeletion.floors(using: service, in: profileManager)
    }

    private func requestDelete(_ service: VoiceService) {
        pendingDelete = service
    }

    private var deleteTitle: String {
        pendingDelete.map { "删除「\($0.name)」？" } ?? ""
    }

    private var deleteMessage: String {
        pendingDelete.map { VoiceServiceDeletion.message(for: $0, in: profileManager) } ?? ""
    }

    private func confirmDelete() {
        guard let s = pendingDelete else { return }
        VoiceServiceDeletion.perform(s, in: profileManager)
        errors[s.id] = nil
        pendingDelete = nil
    }
}

/// 删服务：先清在用楼层的声音，再删配置和 key（列表页右键 / 编辑页底部共用）
enum VoiceServiceDeletion {
    static func floors(using service: VoiceService, in pm: ProfileManager?) -> [Profile] {
        pm?.profiles.filter { $0.voiceServiceId == service.id } ?? []
    }

    static func message(for service: VoiceService, in pm: ProfileManager?) -> String {
        let used = floors(using: service, in: pm)
        guard !used.isEmpty else { return "它的 key 也会一起删掉。" }
        let names = used.prefix(3).map(\.name).joined(separator: "、") + (used.count > 3 ? " 等" : "")
        return "\(used.count) 个楼层在用（\(names)），删除后这些楼层的声音会清空，key 也会一起删掉。"
    }

    static func perform(_ service: VoiceService, in pm: ProfileManager?) {
        if let pm {
            for var p in floors(using: service, in: pm) {
                p.setVoice(service: nil, voiceId: nil, voiceName: nil)
                pm.updateProfile(p)
            }
        }
        VoiceServiceStore.shared.delete(id: service.id)
    }
}

// MARK: - 编辑表单

struct VoiceServiceDraft: Identifiable {
    var service: VoiceService
    var isNew: Bool
    var id: String { service.id }
}

/// 先选厂商（添加菜单里选好）→ 按厂商出字段：名字、key、地址、厂商专有参数
struct VoiceServiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    let draft: VoiceServiceDraft

    @State private var service: VoiceService
    @State private var key = ""
    @State private var originalKey: String?
    @State private var modelsText = ""
    @State private var confirmingDelete = false

    init(draft: VoiceServiceDraft) {
        self.draft = draft
        _service = State(initialValue: draft.service)
        _modelsText = State(initialValue: draft.service.openAICompatibleOptions.models.joined(separator: ", "))
    }

    private var kind: VoiceServiceKind { service.kind }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("厂商")
                    Spacer()
                    Text(kind.displayName).foregroundColor(Theme.textMuted)
                }
                TextField("名字", text: $service.name)
                if kind.needsKey {
                    SecureField("API Key", text: $key)
                }
                if let field = kind.baseURLField {
                    TextField(field.required ? "地址（\(field.placeholder)）" : "地址（留空用 \(field.placeholder)）",
                              text: Binding(get: { service.baseURL ?? "" }, set: { service.baseURL = $0 }))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }
            } footer: {
                if kind.isUnknown {
                    Text("这个服务需要更新版本的 app 才能用。")
                }
            }

            vendorSection

            if !draft.isNew {
                Section {
                    Button("删除这个服务", role: .destructive) { confirmingDelete = true }
                        .foregroundColor(Theme.danger)
                }
            }
        }
        .formStyle(.grouped)
        .panelSheetTitle(draft.isNew ? "添加\(kind.displayName)" : "编辑语音服务")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .foregroundColor(Theme.branchIndicator)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(!canSave)
            }
        }
        .alert("删除「\(draft.service.name)」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                VoiceServiceDeletion.perform(draft.service, in: profileManager)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(VoiceServiceDeletion.message(for: draft.service, in: profileManager))
        }
        .onAppear {
            guard originalKey == nil, !draft.isNew else { return }
            originalKey = VoiceServiceStore.shared.key(for: draft.service.id) ?? ""
            key = originalKey ?? ""
        }
    }

    @ViewBuilder private var vendorSection: some View {
        switch kind {
        case .openAICompatible:
            Section {
                TextField("模型（逗号分隔）", text: $modelsText)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("输出格式", selection: Binding(
                    get: { service.openAICompatibleOptions.responseFormat ?? "" },
                    set: { service.openAICompatibleOptions.responseFormat = $0.isEmpty ? nil : $0 }
                )) {
                    Text("自动").tag("")
                    ForEach(OpenAICompatibleOptions.formats, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("楼层的语音条模型、通话模型从这里选。输出格式「自动」：地址是 Groq 用 wav，其余用 mp3。")
            }
        case .miniMax:
            Section {
                TextField("Group ID（可选）", text: Binding(get: { service.miniMaxOptions.groupId },
                                                           set: { service.miniMaxOptions.groupId = $0 }))
                    .autocorrectionDisabled()
            }
        case .elevenLabs, .system, .unknown:
            EmptyView()
        }
    }

    private var canSave: Bool {
        guard !service.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind.isUnknown { return false }
        if let field = kind.baseURLField, field.required, service.trimmedBaseURL == nil { return false }
        return true
    }

    private func save() {
        var s = service
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        s.baseURL = s.trimmedBaseURL
        if kind == .openAICompatible {
            let models = modelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            s.openAICompatibleOptions.models = models.isEmpty ? OpenAICompatibleOptions.defaultModels : models
        }
        let store = VoiceServiceStore.shared
        if draft.isNew { store.add(s) } else { store.update(s) }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind.needsKey, trimmedKey != (originalKey ?? "") {
            store.setKey(trimmedKey, for: s)
        }
        dismiss()
    }
}

// MARK: - 试听播放器

/// 设置页试听用：一次放一段，放完回调
@Observable
final class VoiceAuditionPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var onFinish: (() -> Void)?

    func play(_ clip: AudioClip, onFinish: @escaping () -> Void) throws {
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let p = try AVAudioPlayer(data: clip.playableData)
        p.delegate = self
        guard p.play() else { throw VoiceSynthError.badAudio }
        player = p
        self.onFinish = onFinish
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        onFinish = nil
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            let done = self.onFinish
            self.stop()
            done?()
        }
    }
}
