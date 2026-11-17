import MemoryCore
import SwiftUI

// MARK: - 记忆实验台：一句话的两张 sheet（plan-memory-lab §4）
// 「这一次的条件」= 参数 + 那一刻 + 跟设置比 + 比真聊天少了哪几段；「提示词多了什么」= 因为这句话推送的 / 每轮都带的，按段列。

/// 参数的名字和值怎么说（键见 `MemoryLabRecord.Item`；名字用 设置 › 记忆 里的原名）
enum MemoryLabWords {
    typealias Item = MemoryLabRecord.Item

    /// 参数卡上 chip 的顺序和名字（开窗口带什么 那一页的原名）
    static func items(assistant: String) -> [(key: String, name: String, path: WritableKeyPath<MemoryLabParams, Bool>)] {
        [(Item.timeline, MemoryNoteItem.timeline.title(assistant: assistant), \.timeline),
         (Item.pending, MemoryNoteItem.pending.title(assistant: assistant), \.pending),
         (Item.selfMemory, MemoryNoteItem.selfMemory.title(assistant: assistant), \.selfMemory),
         (Item.everyRound, "原子事实每轮全带", \.everyRound),
         (Item.rootIndex, "wiki 目录", \.rootIndex),
         (Item.previousWindow, MemoryNoteItem.previousWindow.title(assistant: assistant), \.previousWindow),
         (Item.pinned, MemoryNoteItem.pinned.title(assistant: assistant), \.pinned)]
    }

    static func name(_ key: String, assistant: String) -> String {
        if let item = items(assistant: assistant).first(where: { $0.key == key }) { return item.name }
        switch key {
        case Item.systemPush: return "自动推送"
        case Item.recallTool: return "\(assistant)主动翻"
        case Item.model: return "模型"
        case Item.tuningPrefix + "cooldownEnabled": return "冷却"
        default:
            let raw = key.hasPrefix(Item.tuningPrefix) ? String(key.dropFirst(Item.tuningPrefix.count)) : key
            return RecallTuning.Field(rawValue: raw)?.title ?? raw
        }
    }

    static func value(_ key: String, _ raw: String, model: (String) -> String) -> String {
        if key == Item.model { return raw.isEmpty ? "没选" : model(raw) }
        guard raw == "true" || raw == "false" else { return raw }
        let on = raw == "true"
        if key == Item.systemPush || key == Item.recallTool || key.hasPrefix(Item.tuningPrefix) { return on ? "开" : "关" }
        return on ? "勾上" : "不勾"
    }

    /// 「wiki 目录 勾上 · 自动推送 开」；一样 = 空串
    static func differences(_ list: [MemoryLabRecord.Difference], assistant: String, model: (String) -> String) -> String {
        list.map { "\(name($0.key, assistant: assistant)) \(value($0.key, $0.lab, model: model))" }.joined(separator: " · ")
    }

    /// 自动推送那一行：「开 · 一轮最多 3 页 · 最多 5 条 · 冷却 3 句」
    static func push(_ params: MemoryLabRecord.Params?) -> String {
        guard params?.systemPush == true, let t = params?.tuning else { return "关" }
        return ["开", "一轮最多 \(t.maximumPages) 页", "最多 \(t.maximumFragments) 条",
                t.cooldownEnabled ? "冷却 \(t.cooldownTurns) 句" : "不冷却"].joined(separator: " · ")
    }

    static func pull(_ params: MemoryLabRecord.Params?) -> String {
        guard params?.recallTool == true else { return "关" }
        return params?.tuning.map { "开 · 最多翻 \($0.maximumRecallCalls) 次" } ?? "开"
    }

    static func day(_ date: Date) -> String { format(date, "MM-dd") }
    static func time(_ date: Date) -> String { format(date, "yyyy-MM-dd HH:mm") }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// 两张 sheet 共用的壳：标题 + 完成，浅薄荷底上一块块白卡
struct MemoryLabSheetFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.sidebarBg)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(Theme.branchIndicator)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 640)
        #endif
    }
}

/// sheet 里的小标题 / 白卡 / 一行键值
private struct LabSegment: View {
    let text: String
    @Environment(\.settingsMetrics) private var m
    var body: some View {
        Text(text).font(m.secondary).foregroundColor(Theme.textSecondary).padding(.top, 8).padding(.leading, 4)
    }
}

private struct LabCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous))
    }
}

private struct LabKeyValue: View {
    let key: String
    let value: String
    var last = false
    @Environment(\.settingsMetrics) private var m
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key).font(m.body).foregroundColor(Theme.textMuted).frame(width: 76, alignment: .leading)
                Text(value).font(m.body).foregroundColor(Theme.textPrimary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            if !last { Divider().opacity(0.5) }
        }
    }
}

// MARK: - 这一次的条件

struct MemoryLabConditionsSheet: View {
    let record: MemoryLabRecord
    let assistant: String
    /// 楼层编号 → 名字
    let floorName: (String) -> String?
    let modelName: (String) -> String

    var body: some View {
        let params = record.params
        let differences = params?.differences ?? []
        let changed = Set(differences.map(\.key))
        let items = params?.items ?? [:]
        let carried = params?.systemPush == true || params?.everyRound == true
        MemoryLabSheetFrame(title: "这一次的条件") {
            LabSegment(text: differences.isEmpty ? "参数 · 现在的设置" : "参数 · 改过的「现在的设置」")
            LabCard {
                FlowLayout(spacing: 6, lineSpacing: 0) {
                    ForEach(MemoryLabWords.items(assistant: assistant), id: \.key) { item in
                        let on = item.key == MemoryLabRecord.Item.everyRound ? params?.everyRound == true
                            : (items[item.key] ?? false) || (item.key == MemoryLabRecord.Item.rootIndex && carried)
                        MemoryEntryChip(text: item.name, look: on ? .mine : .empty, changed: changed.contains(item.key), name: item.name)
                    }
                }
                .padding(.vertical, 6)
            }
            LabCard {
                LabKeyValue(key: "自动推送", value: MemoryLabWords.push(params))
                LabKeyValue(key: "主动翻", value: MemoryLabWords.pull(params))
                LabKeyValue(key: "模型", value: params?.model?.name ?? params?.model.map { modelName($0.id) } ?? "没选")
                LabKeyValue(key: "跟设置比", value: differences.isEmpty ? "一样"
                            : MemoryLabWords.differences(differences, assistant: assistant, model: modelName), last: true)
            }
            let env = record.environment
            LabSegment(text: "那一刻")
            LabCard {
                LabKeyValue(key: "时间", value: MemoryLabWords.time(record.input.at))
                LabKeyValue(key: "楼层", value: env?.profileId.flatMap(floorName) ?? env?.profileId ?? "—")
                LabKeyValue(key: "记忆", value: memory(env?.counts))
                LabKeyValue(key: "提示词", value: env?.presetName.map { "楼层预设「\($0)」" } ?? "—")
                LabKeyValue(key: "版本", value: version(env), last: true)
            }
            if let missing = record.happened?.missing, !missing.isEmpty {
                LabSegment(text: "比真聊天少了这几段")
                LabCard {
                    ForEach(Array(missing.enumerated()), id: \.offset) { i, line in
                        LabKeyValue(key: "\(i + 1)", value: line, last: i == missing.count - 1)
                    }
                }
            }
        }
    }

    private func memory(_ c: MemoryLabRecord.Counts?) -> String {
        guard let c else { return "—" }
        var parts: [String] = []
        if let all = c.allFacts { parts.append("原子事实 \(all) 条" + (c.approvedFacts.map { "（批过 \($0)）" } ?? "")) }
        if let pages = c.wikiPages { parts.append("wiki \(pages) 页") }
        if let pinned = c.pinned { parts.append("钉住 \(pinned) 条") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func version(_ env: MemoryLabRecord.Environment?) -> String {
        let app = env?.appVersion.map { v in env?.build.map { "\(v)（\($0)）" } ?? v }
        let parts = [app, env?.commit.map { String($0.prefix(8)) }].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - 提示词多了什么

struct MemoryLabPromptSheet: View {
    let record: MemoryLabRecord
    let assistant: String

    var body: some View {
        let prompt = record.happened?.prompt
        let pushed = (prompt?.pushed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = (record.happened?.rounds ?? []).flatMap(\.calls)
        let everyRound = (prompt?.everyRound ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let memory = SegmentSource.memory.displayName
        let others = (prompt?.segments ?? []).filter { $0.source != memory }
        MemoryLabSheetFrame(title: "提示词多了什么") {
            LabSegment(text: "因为这句话推送的")
            if !pushed.isEmpty { LabBlock(label: "自动推送", text: pushed, marked: true) }
            ForEach(Array(calls.enumerated()), id: \.offset) { i, call in
                LabBlock(label: "\(assistant)主动翻 · 第 \(i + 1) 次", text: call.result ?? "（没翻到）", marked: true)
            }
            if pushed.isEmpty && calls.isEmpty { LabFoot(text: "这句话没让提示词多出东西。") }
            LabSegment(text: "每轮都带的")
            if !everyRound.isEmpty { LabBlock(label: memory, text: everyRound, marked: false) }
            ForEach(Array(others.enumerated()), id: \.offset) { _, segment in
                LabBlock(label: segment.source, text: segment.with, marked: false)
            }
            if everyRound.isEmpty && others.isEmpty { LabFoot(text: "都没勾。") }
        }
    }
}

private struct LabBlock: View {
    let label: String
    let text: String
    let marked: Bool
    @Environment(\.settingsMetrics) private var m
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(m.caption).foregroundColor(Theme.textMuted)
            Text(text).font(m.secondary).foregroundColor(Theme.textPrimary).textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous))
        .overlay(alignment: .leading) {
            if marked {
                Capsule().fill(Theme.branchIndicator).frame(width: 3).padding(.vertical, 8)
            }
        }
    }
}

private struct LabFoot: View {
    let text: String
    @Environment(\.settingsMetrics) private var m
    var body: some View {
        Text(text).font(m.secondary).foregroundColor(Theme.textMuted).padding(.horizontal, 6)
    }
}

// MARK: - 换一组参数（第三片，小样 15 / 22）

/// 改过时顶上「现在这组改过：…」+ 起名「存」；「存过的」：现在的设置 + 各组（小字 = 跟设置比差在哪）。点一行换过去；长按改名 / 删（删组不删记录）
struct MemoryLabGroupSheet: View {
    @Bindable var groups: MemoryLabGroups
    let lab: MemoryLabRunner?
    let assistant: String
    let modelName: (String) -> String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m
    @State private var name = ""
    @State private var renaming: MemoryLabParamSet?
    @State private var renameDraft = ""
    @State private var deleting: MemoryLabParamSet?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MemoryLabSheetFrame(title: "换一组参数") {
            if groups.changed {
                LabSegment(text: "现在这组改过：" + MemoryLabWords.differences(groups.changes, assistant: assistant, model: modelName))
                HStack(spacing: 8) {
                    TextField("", text: $name, prompt: Text("给这组参数起个名").foregroundColor(Theme.textMuted))
                        .textFieldStyle(.plain)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                        .onSubmit(save)
                    Button(action: save) {
                        Text("存")
                            .font(m.body.weight(.semibold))
                            .foregroundColor(MemoryAuditStyle.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Theme.branchIndicator.opacity(trimmed.isEmpty ? 0.45 : 1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty || lab == nil)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous))
            }
            LabSegment(text: "存过的")
            LabCard {
                row(id: MemoryLabParamSet.currentId, title: "现在的设置", sub: "跟 设置 › 记忆 一样", last: groups.groups.isEmpty)
                ForEach(Array(groups.groups.enumerated()), id: \.element.id) { i, group in
                    row(id: group.id, title: group.name ?? "",
                        sub: MemoryLabGroupWords.versusSettings(MemoryLabParams(recorded: group.params), settings: groups.settings,
                                                                assistant: assistant, model: modelName),
                        last: i == groups.groups.count - 1)
                    .contextMenu {
                        Button("改名", systemImage: "pencil") {
                            renameDraft = group.name ?? ""
                            renaming = group
                        }
                        Button("删掉这组", systemImage: "trash", role: .destructive) { deleting = group }
                    }
                }
            }
            if let failure = groups.failure {
                LabFoot(text: failure)
            }
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $renameDraft)
            Button("好") {
                let newName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renaming?.id, let lab, !newName.isEmpty { Task { await groups.rename(id, to: newName, lab: lab) } }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("删掉「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删", role: .destructive) {
                if let id = deleting?.id, let lab { Task { await groups.delete(id, lab: lab) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删这一组参数，用它跑过的记录还在。")
        }
    }

    private func row(id: String, title: String, sub: String, last: Bool) -> some View {
        Button {
            groups.select(id)
            dismiss()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(m.body).foregroundColor(Theme.textPrimary)
                        Text(sub).font(m.caption).foregroundColor(Theme.textMuted).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if groups.groupId == id && !groups.changed {
                        Image(systemName: "checkmark").font(m.body.weight(.semibold)).foregroundColor(Theme.branchIndicator)
                    }
                }
                .padding(.vertical, 10)
                if !last { Divider().opacity(0.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard !trimmed.isEmpty, let lab else { return }
        let newName = trimmed
        name = ""
        groups.failure = nil
        Task {
            await groups.save(name: newName, lab: lab)
            if groups.failure == nil { dismiss() }
        }
    }
}

// MARK: - 自动推送 / {助手}主动翻 那一页的数（第三片，小样 12）

/// 行从 `RecallTuning.Field` 来（分组顺序同 设置 › 记忆 那两页），绑页面上的参数；跟这组存的值不一样的行带薄荷点。只改这次模拟
struct MemoryLabTuningSheet: View {
    let push: Bool
    @Binding var params: MemoryLabParams
    let base: MemoryLabParams
    let assistant: String

    @Environment(\.settingsMetrics) private var m

    /// 设置 › 系统推送给{助手} 那一页的分组（`RecallParametersPage` 的顺序；页数、条数、冷却放在上面两块，同小样）
    static let pushGroups: [[RecallTuning.Field]] = [
        [.minimumEffectiveLength], [.minimumSharedTerms, .activeOverlapThreshold],
        [.minimumHanTermLength, .minimumLatinTermLength], [.maximumQueryTerms, .minimumFullTextTerms, .fullTextCoverageThreshold],
    ]

    var body: some View {
        MemoryLabSheetFrame(title: push ? "自动推送" : "\(assistant)主动翻") {
            if push {
                LabCard {
                    toggleRow("系统推送给\(assistant)", sub: "聊到哪页、哪条记忆条目，就推送哪个", \.systemPush)
                }
                if params.systemPush {
                    LabCard {
                        fieldRow(.maximumPages)
                        Divider().opacity(0.5)
                        fieldRow(.maximumFragments)
                    }
                    LabCard {
                        toggleRow("冷却", sub: "推送了你没接茬就先停几句", \.tuning.cooldownEnabled)
                        if params.tuning.cooldownEnabled {
                            Divider().opacity(0.5)
                            fieldRow(.cooldownTurns)
                        }
                    }
                    ForEach(Self.pushGroups, id: \.self) { fields in
                        LabSegment(text: fields[0].group)
                        LabCard {
                            ForEach(Array(fields.enumerated()), id: \.element) { i, field in
                                if i > 0 { Divider().opacity(0.5) }
                                fieldRow(field)
                            }
                        }
                    }
                }
            } else {
                LabCard {
                    toggleRow("翻记忆", sub: "\(assistant)可以搜旧对话原话和记忆（带出处）", \.recallTool)
                }
                if params.recallTool {
                    LabCard { fieldRow(.maximumRecallCalls) }
                }
            }
            LabFoot(text: "只改这次模拟，不改设置。")
        }
    }

    private var dot: some View {
        Circle().fill(Theme.branchIndicator).frame(width: 7, height: 7)
    }

    private func toggleRow(_ title: String, sub: String, _ path: WritableKeyPath<MemoryLabParams, Bool>) -> some View {
        MemorySwitchRow(title: title, sub: sub, isOn: $params[dynamicMember: path])
            .padding(.vertical, 8)
            .overlay(alignment: .leading) {
                if params[keyPath: path] != base[keyPath: path] { dot.offset(x: -10) }
            }
    }

    private func fieldRow(_ field: RecallTuning.Field) -> some View {
        let value = field.value(in: params.tuning)
        let bounds = field.range
        return Group {
            if let path = field.integerKeyPath {
                LimitStepper(title: field.title, value: "\(Int(value)) \(Self.unit(field))",
                             number: Binding(get: { params.tuning[keyPath: path] }, set: { params.tuning[keyPath: path] = $0 }),
                             range: Int(bounds.lowerBound)...Int(bounds.upperBound), step: Int(field.step))
            } else {
                Stepper(value: Binding(get: { field.value(in: params.tuning) }, set: { field.set($0, in: &params.tuning) }),
                        in: bounds, step: field.step) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.title).font(m.body).foregroundColor(Theme.textPrimary)
                        Text(String(format: "%.2f", value)).font(m.caption.monospaced()).foregroundColor(Theme.textMuted)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            if value != field.value(in: base.tuning) { dot.offset(x: -10) }
        }
    }

    /// 同 设置 › 记忆 那两页的单位
    static func unit(_ field: RecallTuning.Field) -> String {
        switch field {
        case .maximumPages: "页"
        case .minimumEffectiveLength, .minimumHanTermLength: "字"
        case .cooldownTurns: "句"
        case .maximumFragments: "条"
        case .maximumRecallCalls: "次"
        default: "个"
        }
    }
}

// MARK: - 跟「现在的设置」比（第三片，小样 26）

/// 同一句话，这组和「现在的设置」：两边的回复、推送的差在哪、各翻了什么、两次的参数差在哪
struct MemoryLabCompareSheet: View {
    let here: MemoryLabRecord
    /// 「现在的设置」下这句最新的一条；nil = 还没跑过
    let there: MemoryLabRecord?
    let groupName: String
    let assistant: String
    /// 「现在的设置」那条跑的时候，她的设置跟此刻已经不一样：写一行说明
    let note: String?
    let modelName: (String) -> String

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        let comparison = MemoryLabComparison.make(here: here, there: there)
        MemoryLabSheetFrame(title: "跟「现在的设置」比") {
            if let note { LabFoot(text: note) }
            side("「\(groupName)」", record: here)
            if let there {
                side("「现在的设置」", record: there)
                LabSegment(text: "推送的")
                LabCard {
                    pushed("只有「\(groupName)」推送的", comparison.here?.only ?? [])
                    pushed("只有「现在的设置」推送的", comparison.there?.only ?? [])
                    pushed("两边都推送的", comparison.both)
                }
                let reads = [(groupName, comparison.here?.reads ?? []), ("现在的设置", comparison.there?.reads ?? [])]
                if reads.contains(where: { !$0.1.isEmpty }) {
                    LabSegment(text: "\(assistant)主动翻")
                    LabCard {
                        ForEach(reads, id: \.0) { name, list in
                            LabKeyValue(key: "「\(name)」",
                                        value: list.isEmpty ? "没翻" : list.map { RecallCardModel.read($0) }
                                            .map { "\($0.title)（\($0.status)）" }.joined(separator: "\n"),
                                        last: name == "现在的设置")
                        }
                    }
                }
                if let diff = differences {
                    LabSegment(text: "两组差在")
                    LabFoot(text: diff)
                }
            } else {
                LabSegment(text: "「现在的设置」")
                LabFoot(text: "现在的设置下这句还没跑过。")
            }
        }
    }

    /// 两条记录各自那一次的参数差在哪；一样 = nil
    private var differences: String? {
        guard let mine = MemoryLabParams(recorded: here.params), let theirs = MemoryLabParams(recorded: there?.params) else { return nil }
        let diff = mine.differences(from: theirs)
        return diff.isEmpty ? nil : MemoryLabWords.differences(diff, assistant: assistant, model: modelName)
    }

    private func side(_ label: String, record: MemoryLabRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(m.secondary).foregroundColor(Theme.textSecondary)
                switch record.judgment?.verdict {
                case .up: Image(systemName: "hand.thumbsup.fill").font(m.caption).foregroundColor(Theme.branchIndicator)
                case .down: Image(systemName: "hand.thumbsdown.fill").font(m.caption).foregroundColor(Theme.danger)
                case nil: EmptyView()
                }
            }
            .padding(.top, 8)
            .padding(.leading, 4)
            if let reply = record.happened?.reply {
                Text(reply)
                    .font(.system(size: Theme.F.label))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(BubbleTailShape(isUser: false, radius: 18).fill(Theme.mainBg))
                    .padding(.trailing, 40)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(Theme.danger)
                    Text(record.happened?.error ?? "模型没有回话").foregroundColor(Theme.textSecondary)
                }
                .font(m.secondary)
                .padding(.horizontal, 6)
            }
        }
    }

    private func pushed(_ title: String, _ items: [RecallItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(m.caption).foregroundColor(Theme.textMuted)
            if items.isEmpty {
                Text("没有").font(m.body).foregroundColor(Theme.textMuted)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(MemoryLabRecall.title(item)).font(m.body).foregroundColor(Theme.textPrimary)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
