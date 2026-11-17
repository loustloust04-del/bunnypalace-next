import MemoryCore
import SwiftUI

// MARK: - 记忆实验台第三片：一组参数（plan-memory-lab-3 §3；小样 12–16、22、27）
// 两页（模拟对话 / 一份测试集）各拿一份 `MemoryLabGroups`：现在选的是哪一组、这组存的值、页面上拨过的值。
// 拨的只是页面上的 `params`；存成一组写 `lab/params/`；从不写她的设置。
// 模型跟组分开（小样 15：组只讲记忆参数，模型菜单单独在卡右上角）：模型是台子按楼层记住的那个，换组 / 载入一组不动它，
// 选模型不算「改过」，「改过」只比记忆那些参数。

@MainActor @Observable
final class MemoryLabGroups {
    /// 胶囊点开的参数卡上能点进去的那几张
    enum Sheet: String, Identifiable {
        case groups, push, pull
        var id: String { rawValue }
    }

    /// 存过的各组（不含「现在的设置」）
    var groups: [MemoryLabParamSet] = []
    var groupId = MemoryLabParamSet.currentId
    /// 页面上的这一组参数（拨的就是它）
    var params: MemoryLabParams?
    /// 这一组存的样子；跟它不一样的项带薄荷点、算「改过」
    var base: MemoryLabParams?
    /// 她现在的设置（模型换成台子用的那个）：「现在的设置」那一组就是它，各组「跟设置比」也跟它比
    var settings: MemoryLabParams?
    var sheet: Sheet?
    var failure: String?

    /// 页面上跟这组存的差在哪：只比记忆参数，模型不算
    var changes: [MemoryLabRecord.Difference] {
        guard let params, let base else { return [] }
        return params.differences(from: base).filter { $0.key != MemoryLabRecord.Item.model }
    }

    var changed: Bool { !changes.isEmpty }

    /// 记录上写哪一组：改过没存 = nil
    var runId: String? { changed ? nil : groupId }
    var name: String { name(of: groupId) }

    func name(of id: String?) -> String { MemoryLabGroupWords.name(of: id, groups: groups) }

    /// 进页面：读存过的各组，选上 `select`（nil / 找不到 =「现在的设置」）
    func load(_ lab: MemoryLabRunner, select: String? = nil) async {
        let store = lab.store
        groups = await Task.detached(priority: .userInitiated) { store.paramSets() }.value
        var now = lab.currentParams()
        now.modelId = lab.labModelId()
        settings = now
        params = nil
        self.select(select ?? MemoryLabParamSet.currentId)
    }

    /// 别处（另一页）存了 / 删了组之后重读列表；选着的那组被删了就回到「现在的设置」，页面上拨的值不动
    func refresh(_ lab: MemoryLabRunner) async {
        let store = lab.store
        groups = await Task.detached(priority: .userInitiated) { store.paramSets() }.value
        if groupId != MemoryLabParamSet.currentId, !groups.contains(where: { $0.id == groupId }) { select(MemoryLabParamSet.currentId) }
    }

    /// 换一组：页面上的记忆参数换成这组存的值；模型不动（组里存的模型不看）
    func select(_ id: String) {
        let saved = groups.first { $0.id == id }.flatMap { MemoryLabParams(recorded: $0.params) }
        guard id == MemoryLabParamSet.currentId || saved != nil, var value = saved ?? settings else {
            if id != MemoryLabParamSet.currentId { select(MemoryLabParamSet.currentId) }
            return
        }
        value.modelId = params?.modelId ?? settings?.modelId ?? ""
        groupId = id
        base = value
        params = value
    }

    /// 存成一组：存的是页面上现在的值；存完就在这一组上
    func save(name: String, lab: MemoryLabRunner) async {
        guard let params else { return }
        let store = lab.store, values = lab.recorded(params)
        do {
            let saved = try await Task.detached(priority: .userInitiated) { try store.createParamSet(name: name, params: values) }.value
            groups.append(saved)
            groupId = saved.id
            base = params
        } catch {
            failure = error.localizedDescription
        }
    }

    func rename(_ id: String, to name: String, lab: MemoryLabRunner) async {
        let store = lab.store
        do {
            let renamed = try await Task.detached(priority: .userInitiated) { try store.renameParamSet(id: id, name: name) }.value
            if let i = groups.firstIndex(where: { $0.id == id }) { groups[i] = renamed }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// 删一组（不删记录）；删的是正在用的那组就回到「现在的设置」
    func delete(_ id: String, lab: MemoryLabRunner) async {
        let store = lab.store
        do {
            try await Task.detached(priority: .userInitiated) { try store.deleteParamSet(id: id) }.value
            groups.removeAll { $0.id == id }
            if groupId == id { select(MemoryLabParamSet.currentId) }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// 另一页此刻的组和页面上的参数（首页点进一份测试集时带过去）
    struct Start {
        let groupId: String
        let params: MemoryLabParams?
    }

    /// 接着用另一页的组和参数：改过没存的照带（到测试集页就是「先存成一组」那个样子）；那组已经没了 =「现在的设置」上带着这些值
    func adopt(_ start: Start) {
        select(start.groupId)
        if let params = start.params { self.params = params }
    }

    /// 选模型：台子按楼层记住，下次进来、换组都用它；不算改过
    func pickModel(_ id: String, profileId: String) {
        params?.modelId = id
        base?.modelId = id
        settings?.modelId = id
        UserDefaults.standard.set(id, forKey: MemoryLabRunner.modelKey(profileId))
    }
}

/// 一组参数的说法（页面和测试共用）
enum MemoryLabGroupWords {
    /// 「现在的设置」/ 组名 /「删掉的一组」（记录上指向的组已经删了）/「改过的参数」（在一组上改过没存就跑的）
    static func name(of id: String?, groups: [MemoryLabParamSet]) -> String {
        guard let id else { return "改过的参数" }
        if id == MemoryLabParamSet.currentId { return "现在的设置" }
        guard let group = groups.first(where: { $0.id == id }) else { return "删掉的一组" }
        return group.name ?? "没名字的一组"
    }

    /// 首页纸卡下面那行：一句没跑过写「N 句」，跑过写「最近 · 组名」
    static func shelfLine(_ summary: MemoryLabStore.SetSummary, groups: [MemoryLabParamSet]) -> String {
        guard summary.latestAt != nil else { return "\(summary.count) 句" }
        return "最近 · " + name(of: summary.latestParamsId, groups: groups)
    }

    /// 牌堆上面那一行：还有没跑完的（没问成的单说）；都跑过 = nil
    static func pendingLine(_ summary: MemoryLabStore.RunSummary) -> String? {
        guard summary.notRun > 0 else { return nil }
        if summary.failed == summary.notRun { return "\(summary.failed) 句没问成" }
        if summary.failed > 0 { return "还有 \(summary.notRun) 句没跑，其中 \(summary.failed) 句没问成" }
        return "还有 \(summary.notRun) 句没跑"
    }

    /// 一组跟她的设置比差在哪（各组的小字、「这组还没跑过」那行）；一样 =「跟 设置 › 记忆 一样」
    static func versusSettings(_ params: MemoryLabParams?, settings: MemoryLabParams?, assistant: String,
                               model: (String) -> String) -> String {
        guard let params, let settings else { return "" }
        let diff = params.differences(from: settings).filter { $0.key != MemoryLabRecord.Item.model }
        return diff.isEmpty ? "跟 设置 › 记忆 一样" : MemoryLabWords.differences(diff, assistant: assistant, model: model)
    }
}

// MARK: - 胶囊点开的参数卡 + 它点进去的三张 sheet（两页共用）

extension View {
    /// 页面顶上的参数卡（`open` 时盖在内容上，点卡外收回）和它的三张 sheet：换一组 / 自动推送 / {助手}主动翻
    func memoryLabParams(_ groups: MemoryLabGroups, open: Binding<Bool>, lab: MemoryLabRunner?, profileId: String,
                         assistant: String, modelName: @escaping (String) -> String,
                         models: [(APICredential, [ProviderModel])]) -> some View {
        modifier(MemoryLabParamsPanel(groups: groups, open: open, lab: lab, profileId: profileId, assistant: assistant,
                                      modelName: modelName, models: models))
    }
}

private struct MemoryLabParamsPanel: ViewModifier {
    @Bindable var groups: MemoryLabGroups
    @Binding var open: Bool
    let lab: MemoryLabRunner?
    let profileId: String
    let assistant: String
    let modelName: (String) -> String
    let models: [(APICredential, [ProviderModel])]

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if open, let params = groups.params, let base = groups.base {
                    ZStack(alignment: .top) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { open = false }
                        MemoryLabParamCard(
                            params: Binding(get: { groups.params ?? params }, set: { groups.params = $0 }),
                            baseline: base, title: groups.name, assistant: assistant, changed: groups.changed,
                            modelName: params.modelId.isEmpty ? nil : modelName(params.modelId), models: models,
                            onPickModel: { groups.pickModel($0, profileId: profileId) },
                            onSheet: { groups.sheet = $0 },
                            onClose: { open = false })
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: open)
            .sheet(item: $groups.sheet) { sheet in
                switch sheet {
                case .groups:
                    MemoryLabGroupSheet(groups: groups, lab: lab, assistant: assistant, modelName: modelName)
                case .push, .pull:
                    if let base = groups.base {
                        MemoryLabTuningSheet(push: sheet == .push,
                                             params: Binding(get: { groups.params ?? base }, set: { groups.params = $0 }),
                                             base: base, assistant: assistant)
                    }
                }
            }
    }
}
