import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct SpeakerIdentitySettingsSection: View {
    @Environment(\.settingsPageExit) private var pageExit
    @AppStorage(SpeakerIdentityStore.enabledKey) private var enabled = false
    @State private var people: [SpeakerIdentity] = []
    @State private var modelName: String?
    @State private var name = ""
    @State private var role: SpeakerRole = .owner
    @State private var consent = false
    @State private var showPicker = false
    @State private var enrollmentID: String?
    @State private var pendingModel: URL?
    @State private var pendingDelete: SpeakerIdentity?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var job: Task<Void, Never>?
    @State private var visible = false
    @State private var confirmReset = false
    private var isRecording: Bool {
        #if os(iOS)
        recordingID != nil
        #else
        false
        #endif
    }
    #if os(iOS)
    @State private var recorder = VoiceNoteRecorder()
    @State private var recordingID: String?
    #endif

    var body: some View {
        Section {
            Toggle("声纹关系线索", isOn: $enabled)
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-tts-speaker")
            DisclosureGroup("声纹档案") {
                Text(modelName.map { "模型：" + $0 } ?? "尚未导入模型")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                Link("兼容模型说明", destination: URL(string: "https://k2-fsa.github.io/sherpa/onnx/speaker-identification/index.html")!)
                Button("导入 ONNX 声纹模型") { enrollmentID = nil; showPicker = true }
                    .disabled(isRecording)
                ForEach(people) { person in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(person.name)
                            Spacer()
                            Text(person.ready ? "已就绪 · \(person.vectors.count)/20" : "\(person.vectors.count)/10")
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(Theme.textMuted)
                            Button(role: .destructive) { pendingDelete = person } label: { Image(systemName: "trash") }
                                .disabled(isRecording)
                                .accessibilityLabel("删除 \(person.name) 的声纹")
                        }
                        HStack {
                            Button("导入一段录音") { enrollmentID = person.id; showPicker = true }
                                .disabled(isRecording)
                            #if os(iOS)
                            Button(recordingID == person.id ? "停止并录入" : "录入一段") {
                                if recordingID == person.id { stopRecording() } else { beginRecording(person.id) }
                            }
                            .disabled(recordingID != nil && recordingID != person.id)
                            if recordingID == person.id {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in Text(VoiceWave.clock(recorder.currentTime)) }
                            }
                            #endif
                        }
                        .disabled(person.vectors.count >= 20 || busy)
                    }
                }
                TextField("称呼", text: $name)
                    .textFieldStyle(.plain)
                Picker("谁的声音", selection: $role) {
                    Text("本人").tag(SpeakerRole.owner)
                    Text("熟人").tag(SpeakerRole.familiar)
                }
                Toggle("录入者已同意在本机保存声纹", isOn: $consent)
                    .tint(Theme.branchIndicator)
                Button("建立档案") {
                    run {
                        try await SpeakerIdentityStore.shared.add(name: name, role: role)
                        name = ""; consent = false
                    }
                }
                .disabled(isRecording || !consent || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelName == nil)
                Button("清空模型与声纹档案", role: .destructive) { confirmReset = true }
                    .disabled(isRecording)
                if busy { ProgressView("正在处理声纹…") }
            }
            .searchAnchor("leaf-tts-speaker-enroll")
        } header: { Text("本机声纹") } footer: {
            Text("一位本人、最多三位已同意的熟人。导入 Sherpa 兼容的说话人 embedding ONNX 模型，再录入至少十段不同时间或距离的一至三十秒自然说话。只保存向量，不额外保存录音；不是认证、活体检测或门锁，不能防录音回放与克隆。线索随新语音条发送给聊天模型，不自动切换楼层或私密记忆。")
        }
        .disabled(busy)
        // 收尾别挂 Section 的 .onDisappear：会摊到每一行，任一行滚出屏幕就掐掉录音。登记给页面，真离开才跑
        .task {
            visible = true
            pageExit?.onExit("speaker-identity") { leave() }
            await reload()
        }
        .onChange(of: enabled) { _, _ in Task { await SpeakerIdentityStore.shared.invalidatePending() } }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: enrollmentID == nil ? [.data] : [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error):
                if (error as NSError).code != CocoaError.Code.userCancelled.rawValue { errorMessage = error.localizedDescription }
            case .success(let urls):
                guard let url = urls.first else { return }
                if let id = enrollmentID { enroll(url, id: id, temporary: false) }
                else { importModel(url, reset: false) }
            }
        }
        .confirmationDialog("更换模型并清空旧声纹档案？", isPresented: Binding(get: { pendingModel != nil }, set: { if !$0 { pendingModel = nil } }), titleVisibility: .visible) {
            if let url = pendingModel { Button("更换并重新录入", role: .destructive) { importModel(url, reset: true) } }
        } message: { Text("不同模型的向量不能混用。旧声纹会删除，需要重新录入本人和熟人。") }
        .confirmationDialog("删除声纹档案？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            if let person = pendingDelete {
                Button("删除 \(person.name)", role: .destructive) { run { try await SpeakerIdentityStore.shared.remove(id: person.id) } }
            }
        } message: { Text("会清除该人的所有注册向量，不删除聊天里的原始语音。") }
        .alert("声纹处理失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("清空本机模型和全部声纹档案？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("清空", role: .destructive) { run { try await SpeakerIdentityStore.shared.resetAll() } }
        } message: { Text("注册向量与模型会删除，聊天中的原始语音不受影响。") }
    }

    private func leave() {
        visible = false
        job?.cancel()
        #if os(iOS)
        recorder.cancel(); recordingID = nil
        recorder.onTick = nil; recorder.onInterrupted = nil
        #endif
    }

    @MainActor private func reload() async {
        do {
            people = try await SpeakerIdentityStore.shared.identities()
            modelName = try await SpeakerIdentityStore.shared.modelName()
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
    @MainActor private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        job = Task { @MainActor in
            defer { busy = false }
            do { try await work(); if !Task.isCancelled { await reload() } }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
    private func importModel(_ url: URL, reset: Bool) {
        run {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try await SpeakerIdentityStore.shared.importModel(url, reset: reset) }
            catch SpeakerIdentityError.resetRequired { pendingModel = url }
        }
    }
    private func enroll(_ url: URL, id: String, temporary: Bool) {
        run {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                if temporary { try? FileManager.default.removeItem(at: url) }
            }
            try await SpeakerIdentityStore.shared.enroll(url: url, id: id)
        }
    }
    #if os(iOS)
    private func beginRecording(_ id: String) {
        guard !CallSession.activeSnapshot else { errorMessage = "请先结束通话再录入"; return }
        busy = true
        job = Task { @MainActor in
            defer { busy = false }
            guard await AVAudioApplication.requestRecordPermission() else { errorMessage = "没有麦克风权限"; return }
            guard !Task.isCancelled, visible, people.contains(where: { $0.id == id }) else { return }
            guard recorder.start() == .started else { errorMessage = "录音没开起来"; return }
            recordingID = id
            recorder.onTick = { if recorder.currentTime >= 30 { stopRecording() } }
            recorder.onInterrupted = { recorder.cancel(); recordingID = nil; recorder.onTick = nil; recorder.onInterrupted = nil }
        }
    }
    private func stopRecording() {
        guard let id = recordingID else { return }
        recordingID = nil
        guard let recording = recorder.stop() else { return }
        recorder.onTick = nil; recorder.onInterrupted = nil
        enroll(recording.url, id: id, temporary: true)
    }
    #endif
}
