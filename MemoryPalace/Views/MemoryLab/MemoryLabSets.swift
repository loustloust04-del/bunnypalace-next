import MemoryCore
import SwiftUI

// MARK: - 记忆实验台第二片：测试集一排 + 挑进测试集（plan-memory-lab-2 §2）
// 两页（模拟对话 / 一份测试集）共用的零件也在这：执行器怎么建、台子用哪个模型、参数胶囊。

extension MemoryLabRunner {
    /// 页面上建这层楼的执行器（环境不齐 = nil）
    static func page(_ profiles: ProfileManager?, _ providers: ProviderManager?, _ presets: PresetManager?) -> MemoryLabRunner? {
        guard let profiles, let providers else { return nil }
        let profile = profiles.currentProfile
        return MemoryLabRunner(profile: profile, preset: presets?.preset(byId: profile.presetId) ?? .balanced,
                               providers: providers, container: profiles.container)
    }

    /// 台子自己记的「上次在这里选的模型」（台子的便利项，不是她的记忆设置）
    static func modelKey(_ profileId: String) -> String { "memoryLabModel_\(profileId)" }

    /// 台子用的模型（台子自己的选择，按楼层记住）：上次在台子里选的 → 这层楼现在的模型 → 空（没选）。走 CC 桥的问不了，不算
    func labModelId() -> String {
        func usable(_ model: ProviderModel) -> Bool { providers.provider(for: model)?.type != .ccBridge }
        if let saved = UserDefaults.standard.string(forKey: Self.modelKey(profile.id)), let model = providers.model(byId: saved),
           usable(model) {
            return saved
        }
        let floor = currentModel
        return usable(floor) && providers.model(byId: floor.id) != nil ? floor.id : ""
    }
}

extension MemoryLabRunner {
    /// 参数卡上的模型菜单：同主对话选择器的收藏（没收藏就列能用的卡上全部），不列走 Claude Code 桥的
    func modelChoices() -> [(APICredential, [ProviderModel])] {
        let favorites = providers.favoritesByCredential.filter { $0.0.type != .ccBridge }
        if !favorites.isEmpty { return favorites }
        return providers.credentials
            .filter { $0.type != .ccBridge && providers.isUsable($0) && !$0.models.isEmpty }
            .map { ($0, $0.models) }
    }
}

/// 顶上那颗参数胶囊：「现在的设置 · 每轮都带 N 项 · 推送开 · 翻开 · 模型 ⌄」。`action` = nil 时只读（测试集页）
struct MemoryLabCapsule: View {
    /// 这一组叫什么（「现在的设置」/ 组名）
    var title = "现在的设置"
    let params: MemoryLabParams?
    let assistant: String
    let modelName: (String) -> String
    var changed = false
    var action: (() -> Void)? = nil

    @Environment(\.settingsMetrics) private var m

    private var summary: String {
        guard let params else { return "" }
        let n = MemoryLabWords.items(assistant: assistant).filter {
            params[keyPath: $0.path] || ($0.key == MemoryLabRecord.Item.rootIndex && params.rootIndexCarried)
        }.count
        return "每轮都带 \(n) 项 · 推送\(params.systemPush ? "开" : "关") · 翻\(params.recallTool ? "开" : "关") · "
            + (params.modelId.isEmpty ? "选模型" : modelName(params.modelId))
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { face(chevron: true) }
                    .buttonStyle(.plain)
            } else {
                face(chevron: false)
            }
        }
        .opacity(params == nil ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
    }

    private func face(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(m.secondary.weight(.semibold)).foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
            if changed { Circle().fill(Theme.branchIndicator).frame(width: 7, height: 7) }
            Text(summary).font(m.caption).foregroundColor(Theme.textSecondary).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(m.caption).foregroundColor(Theme.textMuted) }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Theme.mainBg, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .contentShape(Capsule())
    }
}

/// 首页胶囊下面那一排：照文件库「最近」的纸卡横着滚（宽 118、纸高 148、间距 11），纸上是数、纸下是名字，最后一张 ＋
struct MemoryLabSetShelf: View {
    let sets: [MemoryLabStore.SetSummary]
    /// 纸下那行小字（`MemoryLabGroupWords.shelfLine`）
    let line: (MemoryLabStore.SetSummary) -> String
    let onOpen: (String) -> Void
    let onNew: () -> Void

    @Environment(\.chatMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileLibrarySectionHeader(title: "测试集") { EmptyView() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 11) {
                    ForEach(sets) { summary in
                        // 横滚里的 Button 会被滚动手势吞，照文件库用点按
                        card(summary)
                            .frame(width: FileLibraryUI.size(118))
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(summary.id) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                    }
                    plus
                        .frame(width: FileLibraryUI.size(118))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onNew)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                }
                .padding(.horizontal, metrics.fileLibHeaderInsetH)
                .padding(.vertical, 6)
            }
            .padding(.vertical, -6)
        }
    }

    /// 纸上：几个 👍 / 几句（大字）+ 一个小拇指；空的写「还是空的」。纸下：名字 +「最近 · 组名」（没跑过「N 句」）
    private func card(_ summary: MemoryLabStore.SetSummary) -> some View {
        item(caption: summary.set.name ?? "", sub: line(summary)) {
            paper.overlay(alignment: .bottomLeading) {
                Group {
                    if summary.count > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(summary.up)/\(summary.count)")
                                .font(.system(size: FileLibraryUI.size(30), weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Image(systemName: "hand.thumbsup")
                                .font(.system(size: FileLibraryUI.size(11)))
                                .foregroundColor(Theme.textSecondary)
                        }
                    } else {
                        Text("还是空的")
                            .font(FileLibraryUI.font(12))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.leading, 11)
                .padding(.bottom, 12)
            }
        }
    }

    private var plus: some View {
        item(caption: "新建一份", sub: nil) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(height: FileLibraryUI.size(148))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: FileLibraryUI.size(22), weight: .light))
                        .foregroundColor(Theme.textMuted)
                }
        }
    }

    /// 文件库「最近」那种纸：`FileLibraryPaper` 一定带右下角的类型角标，测试集不要，所以照它的尺寸 / 圆角 / 描边 / 影子 / 纸色自己画
    private var paper: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.mainBg)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.textPrimary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: Theme.textPrimary.opacity(0.06), radius: 5, y: 3)
            .frame(height: FileLibraryUI.size(148))
    }

    /// 纸 + 纸下的字（字号同 `FileLibraryPaperCard`）
    private func item<Paper: View>(caption: String, sub: String?, @ViewBuilder paper: () -> Paper) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            paper()
            Text(caption)
                .font(FileLibraryUI.font(13, .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.top, 8)
            if let sub {
                Text(sub)
                    .font(FileLibraryUI.font(11))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
        }
    }
}

/// 挑进测试集（小样 11）：一张白卡列出各份（名字 + 几句，这句在里面的打勾，点一行 = 挑进 / 拿出），下面一行起名「建」——建完这句直接进去
struct MemoryLabPickSheet: View {
    let sets: [MemoryLabStore.SetSummary]
    /// 这句在哪几份里（`MemoryLabPicks.sets`）
    let picked: Set<String>
    let onToggle: (String) -> Void
    let onCreate: (String) -> Void

    @Environment(\.settingsMetrics) private var m
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MemoryLabSheetFrame(title: "挑进测试集") {
            if !sets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(sets.enumerated()), id: \.element.id) { i, summary in
                        Button { onToggle(summary.id) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.set.name ?? "").font(m.body).foregroundColor(Theme.textPrimary)
                                    Text("\(summary.count) 句").font(m.caption).foregroundColor(Theme.textMuted)
                                }
                                Spacer(minLength: 8)
                                if picked.contains(summary.id) {
                                    Image(systemName: "checkmark").font(m.body.weight(.semibold)).foregroundColor(Theme.branchIndicator)
                                }
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked.contains(summary.id) ? .isSelected : [])
                        if i < sets.count - 1 { Divider().opacity(0.5) }
                    }
                }
                .padding(.horizontal, 14)
                .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous))
            }
            HStack(spacing: 8) {
                TextField("", text: $name, prompt: Text("新建一份，比如：深夜聊天").foregroundColor(Theme.textMuted))
                    .textFieldStyle(.plain)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                    .onSubmit(create)
                Button(action: create) {
                    Text("建")
                        .font(m.body.weight(.semibold))
                        .foregroundColor(MemoryAuditStyle.onAccent)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Theme.branchIndicator.opacity(trimmed.isEmpty ? 0.45 : 1), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous))
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        name = ""
    }
}

/// 挑进 / 测试集页的纯逻辑（页面和测试共用）
enum MemoryLabPicks {
    /// 这句话在哪几份测试集里：以集子为准（`MemoryLabStore.membership`），不看记录上的回指
    static func sets(for record: MemoryLabRecord, in membership: [String: [String]]) -> Set<String> {
        Set(membership[record.sentence] ?? [])
    }

    /// 首页对话里列的：句子的键就是它自己的记录（自由聊说的，含被挑进测试集的原句）；重放出来的不列
    static func freeChat(_ records: [MemoryLabRecord]) -> [MemoryLabRecord] {
        records.filter { $0.sentence == $0.id }
    }

    /// 测试集页的三段
    enum Segment: Hashable, CaseIterable {
        case unseen, up, down
    }

    static func segment(_ entry: MemoryLabStore.SetEntry) -> Segment {
        switch entry.record?.judgment?.verdict {
        case .up: return .up
        case .down: return .down
        case nil: return .unseen
        }
    }

    /// 三段的数：只数这组下跑过的（没问成的那条算「没看过」；没跑过的不进牌堆）
    static func counts(_ entries: [MemoryLabStore.SetEntry]) -> [Segment: Int] {
        Dictionary(grouping: entries.filter { $0.record != nil }, by: segment).mapValues(\.count)
    }

    /// 这一段的那一叠（按挑进的先后）；这组下没跑过的句子不进来
    static func deck(_ entries: [MemoryLabStore.SetEntry], _ segment: Segment) -> [MemoryLabStore.SetEntry] {
        entries.filter { $0.record != nil && self.segment($0) == segment }
    }

    /// 这一段那一叠的先后：撤回放回来的那张在最上面，跳过的按跳的先后排到最后，其余按挑进的先后
    static func ordered(_ deck: [MemoryLabStore.SetEntry], skipped: [String], front: String?) -> [MemoryLabStore.SetEntry] {
        let rank = Dictionary(uniqueKeysWithValues: skipped.enumerated().map { ($1, $0) })
        return deck.enumerated().sorted { a, b in
            func key(_ e: (offset: Int, element: MemoryLabStore.SetEntry)) -> (Int, Int) {
                if e.element.id == front { return (0, 0) }
                if let r = rank[e.element.id] { return (2, r) }
                return (1, e.offset)
            }
            return key(a) < key(b)
        }.map(\.element)
    }

    /// 跳过一张：挪到跳过的最后（跳过两次的不重复）
    static func skipping(_ id: String, in skipped: [String]) -> [String] {
        skipped.filter { $0 != id } + [id]
    }

    /// 点了一个拇指以后的判断：没看过 → 那个拇指；在 👍 / 👎 段点另一个 = 改判；点同一个 = 回到没看过
    static func verdict(after tapped: MemoryLabRecord.Verdict, current: MemoryLabRecord.Verdict?) -> MemoryLabRecord.Verdict? {
        current == tapped ? nil : tapped
    }
}
