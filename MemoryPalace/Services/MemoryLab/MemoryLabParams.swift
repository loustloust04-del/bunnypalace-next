import MemoryCore
import Foundation

/// 记忆实验台的一组参数：一句话在哪些开关下跑（plan-memory-lab §2）。
/// 纯值，只管这一次模拟：`current` 只读她的设置，这里没有任何一处往设置里写。
///
/// 前七项就是 设置 › 记忆 › 开窗口带什么 那一页的勾（A2 除外：单句没有本窗摘要）。实验台按「新开一个窗口说第一句」跑，
/// 所以它们怎么变成这个窗口带什么，照新窗口的现成规矩（`MemoryWindowChoices.defaults`）：见 `windowChoices`。
struct MemoryLabParams: Equatable, Sendable {
    var timeline: Bool
    var pending: Bool
    var selfMemory: Bool
    /// wiki 目录
    var rootIndex: Bool
    var previousWindow: Bool
    var pinned: Bool
    /// 原子事实每轮全带
    var everyRound: Bool
    /// 系统推送那一页的数、翻记忆那一页的数；系统推送的开关也在里面（`systemPush`）
    var tuning: RecallTuning
    /// {助手}主动翻：这一次下不下发 recall 工具
    var recallTool: Bool
    /// `ProviderModel.id`
    var modelId: String

    /// 系统推送给{助手}
    var systemPush: Bool {
        get { tuning.archiveTriggerEnabled }
        set { tuning.archiveTriggerEnabled = newValue }
    }

    /// 她现在的设置（只读偏好）
    static func current(profileId: String, modelId: String,
                        defaults: UserDefaults = MemoryReadEnvironment.defaults) -> MemoryLabParams {
        let floor = MemoryWindowChoices.defaults(profileId: profileId, defaults: defaults)
        return MemoryLabParams(
            timeline: floor.timeline, pending: floor.pending, selfMemory: floor.selfMemory,
            rootIndex: MemoryOpenWindow.isChecked(.c, profileId: profileId, defaults: defaults),
            previousWindow: floor.previousWindow, pinned: floor.pinned,
            everyRound: MemoryOpenWindow.everyRound(profileId: profileId, defaults: defaults),
            tuning: RecallTuningStore.load(profileId: profileId, defaults: defaults),
            recallTool: RecallTool.enabled, modelId: modelId)
    }

    /// 按这组参数新开的窗口纸条上那六项。「档案」= wiki 目录、系统推送、每轮全带三样有一样开着就开（同 `MemoryWindowChoices.defaults`）
    var windowChoices: MemoryWindowChoices {
        MemoryWindowChoices(timeline: timeline, pending: pending, selfMemory: selfMemory,
                            archive: rootIndex || systemPush || everyRound,
                            previousWindow: previousWindow, pinned: pinned)
    }

    /// wiki 目录被别的开关带着：系统推送 / 原子事实每轮全带有一样开着，「档案」就开（`windowChoices`），目录跟着带，
    /// 这时那一勾不管勾没勾都算带着（页面上那颗 chip 显示开着、点不掉）
    var rootIndexCarried: Bool { systemPush || everyRound }

    /// 这一轮的记忆参与度。`memory: false` = 同一组参数但记忆整个关掉（只为比提示词多了什么）
    func participation(memory: Bool = true) -> EffectiveMemoryParticipation {
        let choices = windowChoices.participationChoices
        return EffectiveMemoryParticipation(.init(
            master: memory, window: true, slot: true, choices: choices, legacy: choices,
            a2Checked: false, archiveTrigger: systemPush, everyRound: everyRound))
    }

    /// 存进记录的样子
    func recorded(model: ProviderModel?, provider: String?, settings: MemoryLabParams) -> MemoryLabRecord.Params {
        typealias Item = MemoryLabRecord.Item
        return MemoryLabRecord.Params(
            items: [Item.timeline: timeline, Item.pending: pending, Item.selfMemory: selfMemory, Item.rootIndex: rootIndex,
                    Item.previousWindow: previousWindow, Item.pinned: pinned],
            everyRound: everyRound, systemPush: systemPush, recallTool: recallTool, tuning: tuning,
            model: .init(id: modelId, name: model?.name, provider: provider),
            differences: differences(from: settings))
    }

    /// 跟她的设置比差在哪（一样 = 空）。键见 `MemoryLabRecord.Item`；系统推送那一页的数是 `tuning.` + 字段名
    func differences(from settings: MemoryLabParams) -> [MemoryLabRecord.Difference] {
        typealias Item = MemoryLabRecord.Item
        var out: [MemoryLabRecord.Difference] = []
        func compare<T: Equatable>(_ key: String, _ path: KeyPath<MemoryLabParams, T>) {
            let mine = self[keyPath: path], hers = settings[keyPath: path]
            if mine != hers { out.append(.init(key: key, settings: "\(hers)", lab: "\(mine)")) }
        }
        compare(Item.timeline, \.timeline)
        compare(Item.pending, \.pending)
        compare(Item.selfMemory, \.selfMemory)
        compare(Item.everyRound, \.everyRound)
        compare(Item.rootIndex, \.rootIndex)
        compare(Item.previousWindow, \.previousWindow)
        compare(Item.pinned, \.pinned)
        compare(Item.systemPush, \.systemPush)
        compare(Item.recallTool, \.recallTool)
        compare(Item.tuningPrefix + "cooldownEnabled", \.tuning.cooldownEnabled)
        for field in RecallTuning.Field.allCases {
            let mine = field.value(in: tuning), hers = field.value(in: settings.tuning)
            guard mine != hers else { continue }
            func shown(_ value: Double) -> String { field.isFraction ? "\(value)" : "\(Int(value))" }
            out.append(.init(key: Item.tuningPrefix + field.rawValue, settings: shown(hers), lab: shown(mine)))
        }
        compare(Item.model, \.modelId)
        return out
    }
}

// 放在 extension 里：写在 struct 里面会把逐成员的那个 init 顶掉
extension MemoryLabParams {
    /// 从记录 / 存下来的一组里还原参数；没存参数的旧记录 = nil
    init?(recorded p: MemoryLabRecord.Params?) {
        guard let p, let tuning = p.tuning else { return nil }
        typealias Item = MemoryLabRecord.Item
        let items = p.items ?? [:]
        self.init(timeline: items[Item.timeline] ?? false, pending: items[Item.pending] ?? false,
                  selfMemory: items[Item.selfMemory] ?? false, rootIndex: items[Item.rootIndex] ?? false,
                  previousWindow: items[Item.previousWindow] ?? false, pinned: items[Item.pinned] ?? false,
                  everyRound: p.everyRound ?? false, tuning: tuning, recallTool: p.recallTool ?? false,
                  modelId: p.model?.id ?? "")
    }
}
