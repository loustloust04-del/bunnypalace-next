import Foundation
import SwiftData

// MARK: - 小芽 v2 · 盖章与撤销（plan-小芽-v2 §4.3/§4.4 v1.1）
// 所有落地和撤销都经这里，对着一个「工作台」接口做——线上是真的卡库 / 预设 / 世界书，
// 测试换内存假货（mac 单测跑在粟粟真实的偏好域里，不能拿真卡库练手）。

@MainActor
protocol AssistantWorkspace {
    var profileId: String { get }
    var currentPresetId: String { get }
    func setCurrentPresetId(_ id: String)

    func card(id: String) -> CharacterCard?
    func cards() -> [CharacterCard]
    func addCard(_ card: CharacterCard) throws
    func updateCard(_ card: CharacterCard) throws
    func deleteCard(id: String) throws

    func preset(id: String) -> Preset?
    func savePreset(_ preset: Preset)
    func instantiate(templateId: String, name: String) -> Preset
    func removeInstance(id: String)

    /// nil = 书不在（或不属于当前楼层）
    func worldBookEntries(bookId: String) -> [WorldBookEntry]?
    func setWorldBookEntries(bookId: String, _ entries: [WorldBookEntry]) throws

    // P3 外观（全局，不分楼层）
    /// 已存盘的外观（不是预览中的 displayed）
    var page2Appearance: Page2Appearance { get }
    func savePage2Appearance(_ appearance: Page2Appearance) throws
    /// 自由桌面才吃这套外观；针脚桌面不读它（astra A8）
    var page2HomeIsFree: Bool { get }
    var stageTheme: String { get }
    func setStageTheme(_ raw: String)
}

enum AssistantStampError: LocalizedError, Equatable {
    case staleFloor
    case targetMissing(String)
    case changedSince(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .staleFloor: "楼层换了，这条作废——让小芽在这层重新提一次"
        case .targetMissing(let what): "找不到\(what)了"
        case .changedSince(let what): "\(what)在这之后被改过，让小芽重新看一眼"
        case .invalid(let why): why
        }
    }
}

enum AssistantUndoOutcome: Equatable {
    case done(String)
    /// 这之后又被改过；force 再来一次会覆盖掉那些改动
    case conflict(String)
    case failed(String)
}

@MainActor
enum AssistantStamp {

    // MARK: 盖章前校验：楼层锚 + 目标锚 + 现在 == 改前

    static func validate(_ change: AssistantChange, in ws: AssistantWorkspace) throws {
        if let pid = change.profileId, pid != ws.profileId { throw AssistantStampError.staleFloor }
        switch change {
        case .createCharacter(let card):
            if ws.card(id: card.id) != nil { throw AssistantStampError.invalid("这张卡已经建过了") }
            if ws.cards().contains(where: { $0.name == card.name }) {
                throw AssistantStampError.invalid("卡库里已经有叫「\(card.name)」的卡")
            }
        case .updateCharacterField(let cardId, _, let field, let before, _):
            guard let card = ws.card(id: cardId) else { throw AssistantStampError.targetMissing("这张角色卡") }
            guard let current = AssistantTools.characterField(card, field) else { throw AssistantStampError.invalid("没有字段 \(field)") }
            if current != before { throw AssistantStampError.changedSince("这个字段") }
        case .createPreset(_, let templateId, _, _, let previous, _):
            guard ws.preset(id: templateId) != nil else { throw AssistantStampError.targetMissing("模板预设") }
            if ws.currentPresetId != previous { throw AssistantStampError.changedSince("楼层绑的预设") }
        case .updatePresetSlot(_, let presetId, let slotId, _, let before, _):
            if ws.currentPresetId != presetId { throw AssistantStampError.changedSince("楼层绑的预设") }
            guard let slot = ws.preset(id: presetId)?.prompts.first(where: { $0.id == slotId }) else {
                throw AssistantStampError.targetMissing("这个插槽")
            }
            if slot.isLocked { throw AssistantStampError.invalid("「\(slot.name)」是骨架槽，不能改") }
            if slot.content != before { throw AssistantStampError.changedSince("这个插槽") }
        case .updatePresetSampling(_, let presetId, _, let changes):
            if ws.currentPresetId != presetId { throw AssistantStampError.changedSince("楼层绑的预设") }
            guard let preset = ws.preset(id: presetId) else { throw AssistantStampError.targetMissing("预设") }
            for c in changes where samplingValue(preset.sampling, c.key) != c.before {
                throw AssistantStampError.changedSince("采样参数 \(c.key)")
            }
        case .addWorldBookEntry(_, let bookId, _, let entry):
            guard let entries = ws.worldBookEntries(bookId: bookId) else { throw AssistantStampError.targetMissing("这本世界书") }
            if entries.contains(where: { $0.id == entry.id }) { throw AssistantStampError.invalid("这条已经加过了") }
        case .updateWorldBookEntry(_, let bookId, _, let before, _):
            guard let entries = ws.worldBookEntries(bookId: bookId) else { throw AssistantStampError.targetMissing("这本世界书") }
            guard let current = entries.first(where: { $0.id == before.id }) else { throw AssistantStampError.targetMissing("这个条目") }
            if current != before { throw AssistantStampError.changedSince("这个条目") }
        case .deleteWorldBookEntry(_, let bookId, _, let entry, _):
            guard let entries = ws.worldBookEntries(bookId: bookId) else { throw AssistantStampError.targetMissing("这本世界书") }
            guard let current = entries.first(where: { $0.id == entry.id }) else { throw AssistantStampError.targetMissing("这个条目") }
            if current != entry { throw AssistantStampError.changedSince("这个条目") }
        case .page2Appearance(let before, let after):
            guard ws.page2HomeIsFree else { throw AssistantStampError.invalid(Self.stitchedHome) }
            try after.validate()
            if after.currentValues(in: ws.page2Appearance) != before { throw AssistantStampError.changedSince("主屏外观") }
        case .appIcon(let toolId, _, let before, let after):
            guard ws.page2HomeIsFree else { throw AssistantStampError.invalid(Self.stitchedHome) }
            if let symbol = after.symbol, !Page2IconChoices.symbols.contains(symbol) { throw AssistantStampError.invalid("没有 \(symbol) 这个符号") }
            if Page2IconChoices.tints[after.tint] == nil { throw AssistantStampError.invalid("没有 \(after.tint) 这个颜色") }
            if ws.page2Appearance.icons[toolId] != before { throw AssistantStampError.changedSince("这个图标") }
        case .stageTheme(let before, let after):
            guard XiaoyaStageTheme(rawValue: after) != nil else { throw AssistantStampError.invalid("没有这个舞台") }
            if ws.stageTheme != before { throw AssistantStampError.changedSince("舞台") }
        }
    }

    static let stitchedHome = "现在用的是针脚主屏，这些外观设置不影响它"

    // MARK: 落地：先 validate，返回回执（补上落地时才知道的 id）

    static func apply(_ change: AssistantChange, in ws: AssistantWorkspace) throws -> AssistantChange {
        try validate(change, in: ws)
        switch change {
        case .createCharacter(let card):
            try ws.addCard(card)
            return change
        case .updateCharacterField(let cardId, _, let field, _, let after):
            guard var card = ws.card(id: cardId) else { throw AssistantStampError.targetMissing("这张角色卡") }
            try AssistantTools.setCharacterField(&card, field, after)
            try ws.updateCard(card)
            return change
        case .createPreset(let pid, let templateId, let tplName, let name, let previous, _):
            let inst = ws.instantiate(templateId: templateId, name: name)
            ws.setCurrentPresetId(inst.id)
            return .createPreset(profileId: pid, templateId: templateId, templateName: tplName, name: name,
                                 previousPresetId: previous, newInstanceId: inst.id)
        case .updatePresetSlot(_, let presetId, let slotId, _, _, let after):
            guard var preset = ws.preset(id: presetId),
                  let idx = preset.prompts.firstIndex(where: { $0.id == slotId }) else { throw AssistantStampError.targetMissing("这个插槽") }
            preset.prompts[idx].content = after
            ws.savePreset(preset)
            return change
        case .updatePresetSampling(_, let presetId, _, let changes):
            guard var preset = ws.preset(id: presetId) else { throw AssistantStampError.targetMissing("预设") }
            for c in changes { setSampling(&preset.sampling, c.key, c.after) }
            ws.savePreset(preset)
            return change
        case .addWorldBookEntry(_, let bookId, _, let entry):
            try editEntries(bookId, in: ws) { $0.append(entry) }
            return change
        case .updateWorldBookEntry(_, let bookId, _, let before, let after):
            try editEntries(bookId, in: ws) { entries in
                if let i = entries.firstIndex(where: { $0.id == before.id }) { entries[i] = after }
            }
            return change
        case .deleteWorldBookEntry(let pid, let bookId, let bookName, let entry, _):
            var removedAt = 0
            try editEntries(bookId, in: ws) { entries in
                if let i = entries.firstIndex(where: { $0.id == entry.id }) { removedAt = i; entries.remove(at: i) }
            }
            return .deleteWorldBookEntry(profileId: pid, bookId: bookId, bookName: bookName, entry: entry, index: removedAt)
        case .page2Appearance(_, let after):
            // 套在「盖章这一刻」的外观上，不存整份草稿（astra B2）
            try ws.savePage2Appearance(after.applied(to: ws.page2Appearance))
            return change
        case .appIcon(let toolId, _, _, let after):
            var appearance = ws.page2Appearance
            appearance.icons[toolId] = after
            try ws.savePage2Appearance(appearance)
            return change
        case .stageTheme(_, let after):
            ws.setStageTheme(after)
            return change
        }
    }

    // MARK: 撤销：拿回执反着做；现在 != 改后 → conflict，force 才覆盖

    static func undo(_ receipt: AssistantChange, in ws: AssistantWorkspace, force: Bool) -> AssistantUndoOutcome {
        if let pid = receipt.profileId, pid != ws.profileId {
            return .failed("这是别的楼层的改动，切回那层再撤销")
        }
        let conflict = "这之后又被改过，撤销会把那些改动一起覆盖掉"
        do {
            switch receipt {
            case .createCharacter(let card):
                guard let current = ws.card(id: card.id) else { return .failed("这张卡已经不在了") }
                if current != card, !force { return .conflict(conflict) }
                try ws.deleteCard(id: card.id)
                return .done("删掉了角色卡「\(card.name)」")
            case .updateCharacterField(let cardId, _, let field, let before, let after):
                guard var card = ws.card(id: cardId) else { return .failed("这张卡已经不在了") }
                if AssistantTools.characterField(card, field) != after, !force { return .conflict(conflict) }
                try AssistantTools.setCharacterField(&card, field, before)
                try ws.updateCard(card)
                return .done("「\(card.name)」的\(AssistantChange.characterFieldLabel(field))改回去了")
            case .createPreset(_, _, _, let name, let previous, let newId):
                guard let newId else { return .failed("缺新预设的记录，没法撤销") }
                if ws.currentPresetId != newId { return .failed("楼层已经不在用「\(name)」了，没法自动撤销") }
                guard ws.preset(id: previous) != nil else { return .failed("原来那份预设不在了") }
                ws.setCurrentPresetId(previous)
                ws.removeInstance(id: newId)
                return .done("换回原来的预设，删掉了「\(name)」")
            case .updatePresetSlot(_, let presetId, let slotId, let slotName, let before, let after):
                guard var preset = ws.preset(id: presetId),
                      let idx = preset.prompts.firstIndex(where: { $0.id == slotId }) else { return .failed("插槽已经不在了") }
                if preset.prompts[idx].content != after, !force { return .conflict(conflict) }
                preset.prompts[idx].content = before
                ws.savePreset(preset)
                return .done("插槽「\(slotName)」改回去了")
            case .updatePresetSampling(_, let presetId, _, let changes):
                guard var preset = ws.preset(id: presetId) else { return .failed("预设已经不在了") }
                if changes.contains(where: { samplingValue(preset.sampling, $0.key) != $0.after }), !force { return .conflict(conflict) }
                for c in changes { setSampling(&preset.sampling, c.key, c.before) }
                ws.savePreset(preset)
                return .done("采样参数改回去了")
            case .addWorldBookEntry(_, let bookId, _, let entry):
                guard let entries = ws.worldBookEntries(bookId: bookId) else { return .failed("世界书已经不在了") }
                guard let current = entries.first(where: { $0.id == entry.id }) else { return .failed("这条已经不在了") }
                if current != entry, !force { return .conflict(conflict) }
                try editEntries(bookId, in: ws) { $0.removeAll { $0.id == entry.id } }
                return .done("删掉了新加的条目")
            case .updateWorldBookEntry(_, let bookId, _, let before, let after):
                guard let entries = ws.worldBookEntries(bookId: bookId) else { return .failed("世界书已经不在了") }
                guard let current = entries.first(where: { $0.id == before.id }) else { return .failed("这条已经不在了") }
                if current != after, !force { return .conflict(conflict) }
                try editEntries(bookId, in: ws) { entries in
                    if let i = entries.firstIndex(where: { $0.id == before.id }) { entries[i] = before }
                }
                return .done("条目改回去了")
            case .deleteWorldBookEntry(_, let bookId, _, let entry, let index):
                guard let entries = ws.worldBookEntries(bookId: bookId) else { return .failed("世界书已经不在了") }
                if entries.contains(where: { $0.id == entry.id }) { return .failed("这条已经回来了") }
                try editEntries(bookId, in: ws) { $0.insert(entry, at: min(index, $0.count)) }
                return .done("删掉的条目放回去了")
            case .page2Appearance(let before, let after):
                let current = ws.page2Appearance
                if after.currentValues(in: current) != after, !force { return .conflict(conflict) }
                try ws.savePage2Appearance(before.applied(to: current))
                return .done("主屏换回原来的样子了")
            case .appIcon(let toolId, let name, let before, let after):
                var appearance = ws.page2Appearance
                if appearance.icons[toolId] != after, !force { return .conflict(conflict) }
                appearance.icons[toolId] = before   // 原来没自定义 → 删掉这一项，回到默认图标
                try ws.savePage2Appearance(appearance)
                return .done("「\(name)」的图标换回去了")
            case .stageTheme(let before, let after):
                if ws.stageTheme != after, !force { return .conflict(conflict) }
                ws.setStageTheme(before)
                return .done("舞台换回「\(XiaoyaStageTheme(rawValue: before)?.title ?? before)」")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: 帮手

    private static func editEntries(_ bookId: String, in ws: AssistantWorkspace, _ edit: (inout [WorldBookEntry]) -> Void) throws {
        guard var entries = ws.worldBookEntries(bookId: bookId) else { throw AssistantStampError.targetMissing("这本世界书") }
        edit(&entries)
        try ws.setWorldBookEntries(bookId: bookId, entries)
    }

    nonisolated static let integerSamplingKeys: Set<String> = ["maxTokens", "contextDepth"]

    nonisolated static func samplingValue(_ s: SamplingParams, _ key: String) -> Double? {
        switch key {
        case "temperature": s.temperature
        case "topP": s.topP
        case "maxTokens": Double(s.maxTokens)
        case "contextDepth": Double(s.contextDepth)
        default: nil
        }
    }

    nonisolated private static func setSampling(_ s: inout SamplingParams, _ key: String, _ v: Double) {
        switch key {
        case "temperature": s.temperature = v
        case "topP": s.topP = v
        case "maxTokens":
            s.maxTokens = Int(v)
            s.maxTokensAuto = nil
        case "contextDepth": s.contextDepth = Int(v)
        default: break
        }
    }
}

// MARK: - 线上工作台

@MainActor
struct LiveAssistantWorkspace: AssistantWorkspace {
    let env: AssistantEnv

    var profileId: String { env.profileId }
    var currentPresetId: String { env.profileManager.currentProfile.presetId }

    func setCurrentPresetId(_ id: String) {
        var profile = env.profileManager.currentProfile
        profile.presetId = id
        env.profileManager.updateProfile(profile)
    }

    func card(id: String) -> CharacterCard? { env.cardManager.cards.first { $0.id == id } }
    func cards() -> [CharacterCard] { env.cardManager.cards }
    func addCard(_ card: CharacterCard) throws { try env.cardManager.add(card) }
    func updateCard(_ card: CharacterCard) throws { try env.cardManager.update(card) }
    func deleteCard(id: String) throws {
        if let card = card(id: id) { try env.cardManager.delete(card) }
    }

    func preset(id: String) -> Preset? { env.presetManager.preset(byId: id) }
    func savePreset(_ preset: Preset) { env.presetManager.save(preset) }
    func instantiate(templateId: String, name: String) -> Preset {
        var inst = env.presetManager.instantiate(templateId: templateId, for: env.profileId)
        inst.name = name
        env.presetManager.save(inst)
        return inst
    }
    func removeInstance(id: String) {
        if let inst = env.presetManager.preset(byId: id) { env.presetManager.removeInstance(inst) }
    }

    private func book(_ bookId: String) -> WorldBook? {
        let pid = env.profileId
        let descriptor = FetchDescriptor<WorldBook>(predicate: #Predicate<WorldBook> { $0.profileId == pid })
        return ((try? env.modelContext.fetch(descriptor)) ?? []).first { $0.id.uuidString == bookId }
    }

    func worldBookEntries(bookId: String) -> [WorldBookEntry]? { book(bookId)?.entries }

    var page2Appearance: Page2Appearance { Page2AppearanceStore.shared.value }

    func savePage2Appearance(_ appearance: Page2Appearance) throws {
        let store = Page2AppearanceStore.shared
        guard store.save(appearance) else {
            throw AssistantStampError.invalid(store.errorMessage ?? "外观没有保存")
        }
    }

    var page2HomeIsFree: Bool {
        (UserDefaults.standard.string(forKey: "page2HomePresentation_v1") ?? "free") == "free"
    }

    var stageTheme: String { XiaoyaStageTheme.current.rawValue }
    func setStageTheme(_ raw: String) { UserDefaults.standard.set(raw, forKey: XiaoyaStageTheme.storageKey) }

    /// 存失败就把这本书的条目放回原样再抛（不做全 context rollback，免得误伤别处没存的编辑，astra B5）
    func setWorldBookEntries(bookId: String, _ entries: [WorldBookEntry]) throws {
        guard let book = book(bookId) else { throw AssistantStampError.targetMissing("这本世界书") }
        let old = book.entries
        book.entries = entries
        do {
            try env.modelContext.save()
        } catch {
            book.entries = old
            throw error
        }
    }
}
