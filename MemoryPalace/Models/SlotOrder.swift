import Foundation

/// ④a 预设插槽顺序的唯一读写入口：导入酒馆预设、插槽编辑器拖动 / 新增、PresetManager 落盘、导出、组装全走这里。
///
/// - 读：整份都没有 sequenceIndex（旧数据）→ 按 injectionOrder 稳定排序，和旧 PromptAssembler 的顺序一致；
///   有 sequenceIndex 的按它排，个别没有的（按数组位插进来的新槽）守住自己的数组位。
/// - 写：数组顺序 = 序列顺序，sequenceIndex 连续 0…n-1。injectionOrder 不参与序列，只管 absolute 同深度内先后。
enum SlotOrder {

    /// 酒馆 promptOrder.strategy = 'global' 时唯一生效那组的 character_id（openai.js `dummyId: 100001`）
    static let globalCharacterId = 100001

    // MARK: - 读

    static func ordered(_ slots: [PromptSlot]) -> [PromptSlot] {
        let indexed = Array(slots.enumerated())
        guard indexed.contains(where: { $0.element.sequenceIndex != nil }) else {
            return indexed.sorted { ($0.element.injectionOrder, $0.offset) < ($1.element.injectionOrder, $1.offset) }.map(\.element)
        }
        let sequenced = indexed.filter { $0.element.sequenceIndex != nil }
            .sorted { ($0.element.sequenceIndex ?? 0, $0.offset) < ($1.element.sequenceIndex ?? 0, $1.offset) }
        var next = sequenced.map(\.element).makeIterator()
        return slots.map { slot in slot.sequenceIndex == nil ? slot : (next.next() ?? slot) }
    }

    // MARK: - 写

    /// 按读顺序重排数组并写连续 sequenceIndex（幂等；不改发送顺序）
    static func normalized(_ slots: [PromptSlot]) -> [PromptSlot] {
        numbered(ordered(slots))
    }

    static func normalized(_ preset: Preset) -> Preset {
        var copy = preset
        copy.prompts = normalized(preset.prompts)
        return copy
    }

    /// iOS List.onMove：偏移按当前序列（PresetManager 里的数组已是序列顺序）
    static func moving(_ slots: [PromptSlot], fromOffsets offsets: IndexSet, toOffset: Int) -> [PromptSlot] {
        let list = ordered(slots)
        let moved = offsets.filter { $0 < list.count }.map { list[$0] }
        var rest = list.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertAt = min(rest.count, max(0, toOffset - offsets.filter { $0 < toOffset }.count))
        rest.insert(contentsOf: moved, at: insertAt)
        return numbered(rest)
    }

    /// mac 拖放：把 slotId 挪到目标行的位置（与旧实现同：先拿出再插到目标下标）
    static func moving(_ slots: [PromptSlot], slotId: String, toIndex: Int) -> [PromptSlot] {
        var list = ordered(slots)
        guard let from = list.firstIndex(where: { $0.id == slotId }) else { return numbered(list) }
        let item = list.remove(at: from)
        list.insert(item, at: min(max(0, toIndex), list.count))
        return numbered(list)
    }

    /// 新增插槽排到序列末尾
    static func appending(_ slot: PromptSlot, to slots: [PromptSlot]) -> [PromptSlot] {
        numbered(ordered(slots) + [slot])
    }

    /// 插槽编辑器改深度：>0 即 absolute；从 >0 改回 0 = 「按顺序」（relative，编辑器文案口径）；深度没变不动位置
    static func setDepth(_ depth: Int, of slot: inout PromptSlot) {
        guard depth != slot.injectionDepth else { return }
        slot.injectionDepth = depth
        slot.injectionPosition = depth > 0 ? .absolute : .relative
    }

    private static func numbered(_ list: [PromptSlot]) -> [PromptSlot] {
        list.enumerated().map { index, slot in
            var copy = slot
            copy.sequenceIndex = index
            return copy
        }
    }

    // MARK: - 酒馆 prompt_order

    /// 按酒馆 global 策略挑 character_id == 100001 的唯一一组。
    /// 没有这组 / 多份 / 引用缺失或重复 / 格式认不出 → entries = nil（调用方走原行为兜底），notes 说明原因。绝不取 `.last`。
    static func globalPromptOrder(_ raw: Any?, promptIds: [String]) -> (entries: [(id: String, enabled: Bool)]?, notes: [String]) {
        let fallback = "插槽已按文件里的顺序导入并全部打开，请在插槽列表里核对顺序和开关。"
        guard let raw else { return (nil, ["预设里没有 prompt_order。" + fallback]) }
        guard let groups = raw as? [[String: Any]] else { return (nil, ["prompt_order 格式认不出。" + fallback]) }
        let matches = groups.filter { characterId($0["character_id"]) == globalCharacterId }
        guard matches.count == 1 else {
            let reason = matches.isEmpty ? "prompt_order 里没有 \(globalCharacterId) 组（共 \(groups.count) 组）。"
                                         : "prompt_order 里有 \(matches.count) 份 \(globalCharacterId) 组，无法确定用哪份。"
            return (nil, [reason + fallback])
        }
        guard let items = matches[0]["order"] as? [[String: Any]] else {
            return (nil, ["\(globalCharacterId) 组没有 order 列表。" + fallback])
        }
        let known = Set(promptIds)
        var seen = Set<String>()
        var entries: [(id: String, enabled: Bool)] = []
        var missing: [String] = []
        var duplicated: [String] = []
        for item in items {
            guard let id = item["identifier"] as? String else { missing.append("（无 identifier）"); continue }
            guard seen.insert(id).inserted else { duplicated.append(id); continue }
            guard known.contains(id) else { missing.append(id); continue }
            entries.append((id: id, enabled: item["enabled"] as? Bool ?? true))
        }
        var notes: [String] = []
        if !missing.isEmpty { notes.append("\(globalCharacterId) 组引用了预设里不存在的插槽：\(missing.joined(separator: "、"))。") }
        if !duplicated.isEmpty { notes.append("\(globalCharacterId) 组重复列出：\(duplicated.joined(separator: "、"))。") }
        guard notes.isEmpty else { return (nil, notes + [fallback]) }
        return (entries, [])
    }

    /// 顺序和开关按选中的组；组里没列的插槽排在后面并关闭（酒馆里它们不参与发送）
    static func applyingPromptOrder(_ entries: [(id: String, enabled: Bool)], to slots: [PromptSlot]) -> [PromptSlot] {
        var used = Set<Int>()
        var listed: [PromptSlot] = []
        for entry in entries {
            guard let index = slots.indices.first(where: { !used.contains($0) && slots[$0].id == entry.id }) else { continue }
            used.insert(index)
            var slot = slots[index]
            slot.isEnabled = entry.enabled
            listed.append(slot)
        }
        let rest = slots.indices.filter { !used.contains($0) }.map { index -> PromptSlot in
            var slot = slots[index]
            slot.isEnabled = false
            return slot
        }
        return numbered(listed + rest)
    }

    /// character_id 在酒馆里是数字，也容忍字符串
    static func characterId(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    // MARK: - 卡级 depth_prompt（plan §3.6）

    /// 卡 `data.extensions.depth_prompt = {prompt, depth, role}`，prompt 非空 → 追加一个 absolute 插槽（order 100）。
    /// 已有同 id 插槽不重复加；prompt 为空 / 缺字段不加。role 照存（system/user/assistant，认不出按 system）；depth 缺省 4（酒馆默认）。
    static func appendingCardDepthPrompt(cardJSON: Data?, to preset: Preset) -> Preset {
        guard !preset.prompts.contains(where: { $0.id == PromptSlot.cardDepthPromptId }),
              let cardJSON,
              let raw = try? JSONSerialization.jsonObject(with: cardJSON) as? [String: Any] else { return preset }
        let data = raw["data"] as? [String: Any] ?? raw
        guard let extensions = data["extensions"] as? [String: Any],
              let depthPrompt = extensions["depth_prompt"] as? [String: Any],
              let prompt = depthPrompt["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return preset }
        let depthValue = depthPrompt["depth"]
        let depth = (depthValue as? NSNumber)?.intValue ?? (depthValue as? String).flatMap { Int($0) } ?? 4
        let role = depthPrompt["role"] as? String ?? "system"
        let slot = PromptSlot(id: PromptSlot.cardDepthPromptId, name: "角色深度提示",
                              role: ["system", "user", "assistant"].contains(role) ? role : "system",
                              content: prompt, isSystemPrompt: false, isEnabled: true, isMarker: false,
                              injectionDepth: max(0, depth), injectionOrder: 100, injectionPosition: .absolute)
        var copy = preset
        copy.prompts = appending(slot, to: preset.prompts)
        return copy
    }
}
