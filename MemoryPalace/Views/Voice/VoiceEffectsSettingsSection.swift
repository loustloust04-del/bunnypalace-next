import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// 楼层音效 = 文件库 `音效/` 下的文件夹（一个文件夹一组）；配置只存用法 / 已选路径 / 音量。旧楼层默认不启用。
struct VoiceEffectsSettingsSection: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var groups: [VoiceEffectGroup] = []
    @State private var loadedProfileID: String?
    @State private var importTarget: ImportTarget?
    @State private var showImporter = false
    @State private var busy = false
    @State private var job: Task<Void, Never>?
    @State private var previewJob: Task<Void, Never>?
    @State private var player: AVAudioPlayer?
    @State private var previewID: String?
    @State private var previewEpoch = 0
    @State private var prompt: NamePrompt?
    @State private var nameDraft = ""
    @State private var deletion: Deletion?
    @State private var errorMessage: String?
    @State private var dbDrafts: [String: Double] = [:]
    @State private var dbEditOwner: String?

    private struct ImportTarget { let profileID: String; let group: String; let mode: VoiceEffectMode }
    private enum NamePrompt {
        case newGroup, renameGroup(String), renameClip(VoiceEffectClip), newKind(VoiceEffectClip)
        var title: String {
            switch self {
            case .newGroup: "新建组"
            case .renameGroup: "改组名"
            case .renameClip: "改名"
            case .newKind: "放进新种类"
            }
        }
    }
    private enum Deletion {
        case group(String), clip(VoiceEffectClip)
        var name: String { switch self { case .group(let name): name; case .clip(let clip): clip.name } }
    }

    private var profileID: String? { profileManager?.currentProfile.id }
    private var configuration: VoiceEffectConfiguration { profileManager?.currentProfile.voiceEffects ?? VoiceEffectConfiguration() }
    private var library: VoiceEffectLibrary { .shared }

    /// 文件夹里的组 + 配置里有勾选但文件夹没了的组（好让她看到「找不到」并清掉）
    private var displayGroups: [VoiceEffectGroup] {
        guard loadedProfileID != nil, loadedProfileID == profileID else { return [] }
        let names = Set(groups.map(\.name))
        let orphans = configuration.groups.filter { !names.contains($0.key) && !$0.value.selected.isEmpty }.keys.sorted()
        return groups + orphans.map { VoiceEffectGroup(name: $0, clips: [], kinds: []) }
    }

    var body: some View {
        Section {
            Toggle("启用本机音效", isOn: Binding(get: { configuration.enabled }, set: { new in _ = save { $0.enabled = new } }))
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-tts-effects")
            Toggle("通话也使用音效", isOn: Binding(get: { configuration.callEnabled }, set: { new in _ = save { $0.callEnabled = new } }))
                .disabled(!configuration.enabled)
                .tint(Theme.branchIndicator)
                .searchAnchor("leaf-tts-effects-call")
            if busy { ProgressView("正在处理素材…") }
        } header: { Text("本机音效") } footer: {
            Text("素材放在文件库「音效」里，一个文件夹一组。插入组：台词之间插一段（最多十秒，从勾选里随机）；垫底组：垫在后面的台词底下（最多一分钟，选一段）。普通文字不触发；素材不上传给语音厂商。导入可多选，或选一个 zip。通话音效按块合成，首音可能更慢；停止回应或挂断会一起停止。")
        }
        .disabled(profileID == nil || busy)
        // 挂 Section 会摊到每一行：行滚进屏幕也会跑一遍。同楼层已加载就跳过，只有换楼层才清空、取消、重扫
        .task(id: profileID) {
            guard loadedProfileID != profileID else { return }
            job?.cancel()
            stopPreview()
            groups = []; loadedProfileID = nil; dbDrafts = [:]
            guard let id = profileID else { return }
            await reload(id)
            guard !Task.isCancelled, profileID == id else { return }
            // 旧版 UUID 引用改写成路径（迁移表在库第一次访问这个楼层时已写好）
            let table = await library.legacyMap(profileID: id)
            guard !Task.isCancelled, profileID == id, !table.isEmpty else { return }
            _ = save { config in
                for (name, group) in config.groups {
                    config.groups[name]?.selected = group.selected.map { ref in
                        guard UUID(uuidString: ref) != nil, let mapped = table[ref], mapped.hasPrefix(name + "/") else { return ref }
                        return String(mapped.dropFirst(name.count + 1))
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .zip], allowsMultipleSelection: true) { result in
            guard let target = importTarget else { return }
            switch result {
            case .failure(let error):
                if (error as NSError).code != CocoaError.Code.userCancelled.rawValue { errorMessage = error.localizedDescription }
            case .success(let urls):
                guard !urls.isEmpty, profileID == target.profileID else { return }
                importFiles(urls, into: target)
            }
        }
        .alert("音效处理失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: profileID) { _, _ in deletion = nil; prompt = nil; showImporter = false; importTarget = nil; dbEditOwner = nil }

        ForEach(displayGroups) { group in groupSection(group) }
            .disabled(profileID == nil || busy)

        Section {
            Button { nameDraft = ""; prompt = .newGroup } label: { Label("新建组", systemImage: "plus") }
                .searchAnchor("leaf-tts-effects-import")
        }
        .disabled(profileID == nil || busy)
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("名字", text: $nameDraft)
            if case .newGroup? = prompt {
                Button("建成插入组") { createGroup(.insert) }
                Button("建成垫底组") { createGroup(.bed) }
            } else {
                Button("好") { commitPrompt() }
            }
            Button("取消", role: .cancel) { prompt = nil }
        } message: {
            if case .newGroup? = prompt { Text("插入：台词之间插一段，最多十秒。垫底：垫在后面的台词底下，最多一分钟。") }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let item = deletion {
                Button("删除 \(item.name)", role: .destructive) { remove(item) }
            }
        } message: {
            if case .group? = deletion { Text("文件库「音效」里这个文件夹连同里面的素材一起删掉；已经生成的语音条保留。") }
            else { Text("会从文件库里删掉这个文件，并取消本楼层对它的选择；已经生成的语音条保留。") }
        }
    }

    private var deletionTitle: String {
        if case .group? = deletion { return "删除这个组？" }
        return "删除这个音效素材？"
    }

    // MARK: 组小节

    private func groupSection(_ group: VoiceEffectGroup) -> some View {
        let settings = configuration.groups[group.name]
        let mode = settings?.mode ?? group.guessedMode
        let selected = settings?.selected ?? []
        let paths = Set(group.clips.map(\.path))
        let missing = selected.filter { !paths.contains($0) }
        return Section {
            if group.clips.isEmpty {
                Text("导入后 AI 可写 \(marker(group.name, mode))")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            } else if mode == .insert {
                let sections = kindSections(group)
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    if !section.title.isEmpty {
                        Text(section.title)
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                    ForEach(section.clips) { clip in
                        clipRow(clip, group: group, mode: mode, selected: selected.contains(clip.path))
                    }
                }
            } else {
                Button { choose(nil, group: group, mode: mode) } label: {
                    HStack(spacing: 10) {
                        radio(selected.isEmpty)
                        Text("不用")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(group.clips) { clip in
                    clipRow(clip, group: group, mode: mode, selected: selected.first == clip.path)
                }
                if !selected.isEmpty { volumeRow(group.name, db: settings?.db ?? -18) }
            }
            if !missing.isEmpty {
                HStack {
                    Text("\(missing.count) 段已选素材找不到了")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.danger)
                    Spacer()
                    Button("清掉") { _ = save { $0.groups[group.name]?.selected.removeAll { missing.contains($0) } } }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(summary(group, mode: mode, selected: selected.filter(paths.contains).count))
                    .lineLimit(1)
                Spacer()
                Button("导入") { beginImport(group.name, mode: mode) }
                    .buttonStyle(.borderless)
                Menu {
                    Button { nameDraft = group.name; prompt = .renameGroup(group.name) } label: { Label("改名", systemImage: "pencil") }
                    Picker("用法", selection: Binding(get: { mode }, set: { setMode($0, group: group) })) {
                        ForEach(VoiceEffectMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Button(role: .destructive) { deletion = .group(group.name) } label: { Label("删除组", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(group.name) 更多")
            }
            .textCase(nil)
        } footer: {
            Text("文件在 文件库 › 音效 › \(group.name)。" + footerHint(group, mode: mode))
        }
    }

    private func clipRow(_ clip: VoiceEffectClip, group: VoiceEffectGroup, mode: VoiceEffectMode, selected: Bool) -> some View {
        let issue = clip.issue ?? (clip.duration > mode.maxDuration + 0.05 ? "太长，\(mode.title)最多 \(Int(mode.maxDuration)) 秒" : nil)
        return HStack(spacing: 10) {
            Button { choose(clip, group: group, mode: mode) } label: {
                HStack(spacing: 10) {
                    if mode == .insert {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selected ? Theme.branchIndicator : Theme.textMuted)
                    } else {
                        radio(selected)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.name).lineLimit(1)
                            .foregroundColor(issue == nil ? nil : Theme.textMuted)
                        if let issue {
                            Text(issue)
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(issue != nil)
            if issue == nil {
                Text(String(format: "%.1fs", clip.duration))
                    .font(.system(size: Theme.SettingsFont.secondary).monospacedDigit())
                    .foregroundColor(Theme.textMuted)
            }
            Button { preview(clip) } label: { Image(systemName: previewID == clip.id ? "stop.fill" : "play.fill") }
                .buttonStyle(.borderless)
                .disabled(issue != nil)
                .accessibilityLabel("试听 \(clip.name)")
        }
        // 试听跟着正在放的那一行走：它滚出屏幕或离开页面才停（别挂 Section，会摊到每一行）
        .onDisappear { if previewID == clip.id { stopPreview() } }
        .contextMenu {
            Button { preview(clip) } label: { Label("试听", systemImage: "play") }
                .disabled(issue != nil)
            Button { nameDraft = clip.name; prompt = .renameClip(clip) } label: { Label("改名", systemImage: "pencil") }
            if mode == .insert {
                Menu {
                    ForEach(group.kinds.filter { $0 != clip.kind }, id: \.self) { kind in
                        Button(kind) { move(clip, to: kind) }
                    }
                    Button("新种类…") { nameDraft = ""; prompt = .newKind(clip) }
                } label: { Label("放进种类", systemImage: "folder") }
                if clip.kind != nil {
                    Button { move(clip, to: nil) } label: { Label("移出种类", systemImage: "folder.badge.minus") }
                }
            }
            #if os(macOS)
            Button { reveal(clip) } label: { Label("在访达中显示", systemImage: "magnifyingglass") }
            #endif
            Divider()
            Button(role: .destructive) { deletion = .clip(clip) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func radio(_ on: Bool) -> some View {
        Image(systemName: on ? "largecircle.fill.circle" : "circle")
            .foregroundColor(on ? Theme.branchIndicator : Theme.textMuted)
    }

    private func volumeRow(_ group: String, db: Double) -> some View {
        let value = dbDrafts[group] ?? boundedDB(db)
        return VStack(alignment: .leading, spacing: 4) {
            Text("相对音量：\(value, specifier: "%.0f") dB")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
            Slider(value: Binding(get: { dbDrafts[group] ?? boundedDB(db) }, set: { dbDrafts[group] = $0 }), in: -30 ... -6, step: 1) { editing in
                if editing { dbEditOwner = profileID }
                else {
                    if dbEditOwner == profileID, let draft = dbDrafts[group] { _ = save { $0.groups[group]?.db = draft } }
                    dbEditOwner = nil
                    dbDrafts[group] = nil
                }
            }
        }
    }

    private func kindSections(_ group: VoiceEffectGroup) -> [(title: String, clips: [VoiceEffectClip])] {
        guard group.clips.contains(where: { $0.kind != nil }) else { return [("", group.clips)] }
        var sections = group.kinds.map { kind in (title: kind, clips: group.clips.filter { $0.kind == kind }) }.filter { !$0.clips.isEmpty }
        let loose = group.clips.filter { $0.kind == nil }
        if !loose.isEmpty { sections.append(("未分类", loose)) }
        return sections
    }

    private func marker(_ name: String, _ mode: VoiceEffectMode) -> String {
        mode == .insert ? "[sfx:\(name)]" : "[sfx:\(name)]…[/sfx:\(name)]"
    }

    private func summary(_ group: VoiceEffectGroup, mode: VoiceEffectMode, selected: Int) -> String {
        guard !group.clips.isEmpty else { return "\(mode.title) · 还没有素材" }
        return mode == .insert ? "插入 · 已选 \(selected) / \(group.clips.count)" : "垫底 · \(group.clips.count) 段"
    }

    private func footerHint(_ group: VoiceEffectGroup, mode: VoiceEffectMode) -> String {
        let kinds = group.kinds.filter { kind in group.clips.contains { $0.kind == kind } }
        guard mode == .insert, !kinds.isEmpty else { return "AI 可写 \(marker(group.name, mode))。" }
        return "AI 可写 " + kinds.map { "[sfx:\(group.name):\($0)]" }.joined(separator: " ") + "，不写种类就随机。"
    }

    // MARK: 动作

    @discardableResult
    private func save(_ edit: (inout VoiceEffectConfiguration) -> Void) -> Bool {
        guard let manager = profileManager else { return false }
        let original = manager.currentProfile
        var updated = original, config = configuration
        edit(&config)
        if config == (original.voiceEffects ?? VoiceEffectConfiguration()) { return true }
        updated.voiceEffects = config
        guard manager.updateProfilesPersisting([updated]) else {
            _ = manager.updateProfilesPersisting([original])
            errorMessage = "楼层音效设置没保存成功"
            return false
        }
        return true
    }

    private func boundedDB(_ value: Double) -> Double { value.isFinite ? min(-6, max(-30, value)) : -18 }

    private func reload(_ id: String) async {
        do {
            let loaded = try await library.groups(profileID: id)
            guard !Task.isCancelled, profileID == id else { return }
            groups = loaded
            loadedProfileID = id
        } catch { if !Task.isCancelled, profileID == id { errorMessage = error.localizedDescription } }
    }

    /// 改文件的动作串行跑，跑完重扫
    private func perform(_ work: @escaping @MainActor (String) async throws -> Void) {
        guard let id = profileID else { return }
        stopPreview()
        busy = true
        job = Task { @MainActor in
            defer { busy = false }
            do { try await work(id) } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            if !Task.isCancelled, profileID == id { await reload(id) }
        }
    }

    /// 插入组：勾 / 取消；垫底组：单选（nil = 不用）
    private func choose(_ clip: VoiceEffectClip?, group: VoiceEffectGroup, mode: VoiceEffectMode) {
        _ = save { config in
            var settings = config.groups[group.name] ?? .init(mode: mode)
            if let clip, mode == .insert {
                if settings.selected.contains(clip.path) { settings.selected.removeAll { $0 == clip.path } }
                else { settings.selected.append(clip.path) }
            } else {
                settings.selected = clip.map { [$0.path] } ?? []
            }
            config.groups[group.name] = settings
        }
    }

    private func setMode(_ mode: VoiceEffectMode, group: VoiceEffectGroup) {
        _ = save { config in
            var settings = config.groups[group.name] ?? .init(mode: group.guessedMode)
            settings.mode = mode
            if mode == .bed { settings.selected = Array(settings.selected.prefix(1)) }  // 垫底只选一段
            config.groups[group.name] = settings
        }
    }

    private func createGroup(_ mode: VoiceEffectMode) {
        let raw = nameDraft
        prompt = nil
        perform { id in
            let name = try await library.createGroup(raw, profileID: id)
            if profileID == id { _ = save { $0.groups[name] = .init(mode: mode) } }
        }
    }

    private func commitPrompt() {
        guard let current = prompt else { return }
        let raw = nameDraft
        prompt = nil
        switch current {
        case .newGroup: break
        case .renameGroup(let old):
            perform { id in
                let name = try await library.renameGroup(old, to: raw, profileID: id)
                guard name != old, profileID == id else { return }
                _ = save { config in
                    if let settings = config.groups.removeValue(forKey: old) { config.groups[name] = settings }
                }
            }
        case .renameClip(let clip):
            perform { id in
                let path = try await library.renameClip(group: clip.group, path: clip.path, to: raw, profileID: id)
                if profileID == id { repoint(clip, to: path) }
            }
        case .newKind(let clip): move(clip, to: raw)
        }
    }

    private func move(_ clip: VoiceEffectClip, to kind: String?) {
        perform { id in
            let path = try await library.moveClip(group: clip.group, path: clip.path, toKind: kind, profileID: id)
            if profileID == id { repoint(clip, to: path) }
        }
    }

    /// 文件改名 / 挪种类后，已选引用跟着走
    private func repoint(_ clip: VoiceEffectClip, to path: String) {
        guard path != clip.path else { return }
        _ = save { config in
            guard var settings = config.groups[clip.group] else { return }
            settings.selected = settings.selected.map { $0 == clip.path ? path : $0 }
            config.groups[clip.group] = settings
        }
    }

    private func remove(_ item: Deletion) {
        deletion = nil
        switch item {
        case .group(let name):
            guard save({ $0.groups[name] = nil }) else { return }
            perform { id in try await library.removeGroup(name, profileID: id) }
        case .clip(let clip):
            guard save({ $0.groups[clip.group]?.selected.removeAll { $0 == clip.path } }) else { return }
            perform { id in try await library.removeClip(group: clip.group, path: clip.path, profileID: id) }
        }
    }

    private func beginImport(_ group: String, mode: VoiceEffectMode) {
        guard let id = profileID else { return }
        importTarget = ImportTarget(profileID: id, group: group, mode: mode)
        showImporter = true
    }

    private func importFiles(_ urls: [URL], into target: ImportTarget) {
        stopPreview()
        busy = true
        job = Task { @MainActor in
            defer { busy = false }
            var imported: [String] = [], failures: [String] = []
            // 逐个导入，一个坏文件不拖累其余，最后一起报
            @MainActor func importOne(_ file: URL, kind: String?, label: String) async {
                guard !Task.isCancelled, profileID == target.profileID else { return }
                do {
                    let clip = try await library.importAudio(file, group: target.group, kind: target.mode == .insert ? kind : nil,
                                                             mode: target.mode, profileID: target.profileID)
                    imported.append(clip.path)
                } catch {
                    if !Task.isCancelled { failures.append("\(label)：\(error.localizedDescription)") }
                }
            }
            for url in urls {
                guard !Task.isCancelled, profileID == target.profileID else { break }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard url.pathExtension.lowercased() == "zip" else {
                    await importOne(url, kind: nil, label: url.lastPathComponent)
                    continue
                }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voice-effects-zip-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                do {
                    let entries = try await Task.detached(priority: .utility) { try VoiceEffectZip.extractAudioEntries(url, to: tmp) }.value
                    if entries.isEmpty { failures.append("\(url.lastPathComponent)：里面没有可导入的音频") }
                    let kinds = VoiceEffectZip.kinds(entries.map(\.path))
                    for (index, entry) in entries.enumerated() {
                        await importOne(entry.url, kind: kinds[index], label: "\(url.lastPathComponent) › \(entry.url.lastPathComponent)")
                    }
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            // 导进来的自动勾上；垫底组之前没选的话选上第一段
            if !imported.isEmpty, profileID == target.profileID {
                _ = save { config in
                    var settings = config.groups[target.group] ?? .init(mode: target.mode)
                    if settings.mode == .insert { settings.selected += imported.filter { !settings.selected.contains($0) } }
                    else if settings.selected.isEmpty { settings.selected = [imported[0]] }
                    config.groups[target.group] = settings
                }
            }
            if profileID == target.profileID, !Task.isCancelled { await reload(target.profileID) }
            if !Task.isCancelled, !failures.isEmpty {
                errorMessage = (imported.isEmpty ? "" : "已导入 \(imported.count) 段，以下未导入：\n") + failures.joined(separator: "\n")
            }
        }
    }

    #if os(macOS)
    private func reveal(_ clip: VoiceEffectClip) {
        guard let id = profileID else { return }
        Task { @MainActor in
            guard let url = await library.fileURL(group: clip.group, path: clip.path, profileID: id) else {
                errorMessage = VoiceEffectError.notFound.localizedDescription
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    #endif

    private func stopPreview() {
        previewEpoch &+= 1
        previewJob?.cancel(); previewJob = nil
        player?.stop(); player = nil; previewID = nil
    }

    private func preview(_ clip: VoiceEffectClip) {
        let wasPlaying = previewID == clip.id
        stopPreview()
        guard !wasPlaying, let id = profileID else { return }
        guard !CallSession.activeSnapshot else { errorMessage = "通话中暂不试听本机素材"; return }
        let epoch = previewEpoch
        previewJob = Task { @MainActor in
            do {
                guard let audioClip = try await library.clip(group: clip.group, path: clip.path, profileID: id),
                      !Task.isCancelled, previewEpoch == epoch, profileID == id else { return }
                VoiceMessagePlayer.shared.stop()
                MusicCardPlayer.shared.stop()
                SpeechService.shared.stop()
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                #endif
                let audio = try AVAudioPlayer(data: audioClip.playableData)
                guard audio.play() else { throw VoiceEffectError.badAudio }
                player = audio; previewID = clip.id
                try await Task.sleep(for: .seconds(audio.duration))
                if previewEpoch == epoch { stopPreview() }
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}
