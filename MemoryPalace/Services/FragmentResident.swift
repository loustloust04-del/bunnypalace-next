import MemoryCore
import Foundation
import SwiftData

/// 「聊天时本来就带着的内容」：这个窗口每轮请求里她手写的那几段，给 C2 写手和「C2 整理」看——里面写明的事不用再记成卡。
/// 只收真发得出去的：开着的插槽（主提示 / 助手设定 / 用户描述 / 场景 / 自定义插槽…，空 marker 槽退回楼层字段）、
/// 常驻（蓝灯）世界书条目、对话所在文件夹的说明。
/// 机器写的一律不收：记忆槽（「我的记忆」、档案根索引、钉住的卡）、用户画像、上下文摘要、时间轴——
/// 拿它们当「已经有了」去删新卡是循环的（卡因为画像里有被删，画像下次重写又因为没有卡把这句丢了）。
/// 关键词世界书、聊天历史这些每轮会变的也不收。CC 窗口不调这里（它每轮带的是电脑上的文件，app 拿不到），那一块传空
enum FragmentResident {
    static let worldBookTitle = "常驻世界书"
    static let folderTitle = "文件夹说明"

    /// 纯函数（可测）：base = 楼层完整底图（和 Prompt 页同一份）；preset = 这一层的预设实例（看世界书槽开没开）；
    /// world = 扫出来的世界书条目；folder = 文件夹说明
    static func sections(base: CatalogFloorBase?, preset: Preset?, world: [ResolvedEntry], folder: String?) -> [FragmentVerdict.ResidentSection] {
        var out: [FragmentVerdict.ResidentSection] = []
        let sent = (base?.sections ?? []).filter { $0.isEnabled == true }
        out += sent.map { FragmentVerdict.ResidentSection(title: $0.name, text: $0.text) }
        // 助手性格没有自己的槽：助手设定那个 marker 槽空着、退回楼层字段时，它跟着助手设定一起发（`Preset.characterFormat`）
        if sent.contains(where: { $0.path == PromptFolder.path(for: .field(.characterDescription)) }),
           let personality = base?.sections.first(where: { $0.path == PromptFolder.path(for: .field(.characterPersonality)) }) {
            out.append(.init(title: personality.name, text: personality.text))
        }
        // 世界书(前) / (后) 的槽在预设里关着 = 那一桶整个不发（同 `PromptAssembler`）
        func slotOff(_ id: String) -> Bool { preset?.prompts.first { $0.id == id }?.isEnabled == false }
        let constant = world.filter { entry in
            guard entry.isConstant else { return false }
            switch entry.position {
            case .beforeCharDef: return !slotOff(PromptSlot.worldInfoBeforeId)
            case .afterCharDef: return !slotOff(PromptSlot.worldInfoAfterId)
            default: return true
            }
        }
        if !constant.isEmpty {
            out.append(.init(title: worldBookTitle, text: constant.map(\.content).joined(separator: "\n\n")))
        }
        if let folder, !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.init(title: folderTitle, text: folder))
        }
        return out.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// app 里的真取法（主线程）：对话级身份、楼层 / 对话范围的世界书、全局世界书、条数和 token 上限都和发消息那条路同口径。
    /// 没接 `PresetManager`（只有测试）时没有插槽那几段
    @MainActor
    static func current(profile: Profile, conversationId: String, context: ModelContext) -> [FragmentVerdict.ResidentSection] {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == conversationId })
        descriptor.fetchLimit = 1
        let conversation = try? context.fetch(descriptor).first
        let send = SendContextResolver.resolve(profile: profile, conversation: conversation, context: context,
                                               globalEntries: (GlobalWorldBookManager.live?.enabledBooks ?? []).flatMap(\.entries))
        var world = WorldBookScanner.scan(worldBooks: send.worldBooks, recentMessages: [], profile: send.profile, globalEntries: send.globalEntries)
        let budget = UserDefaults.standard.integer(forKey: CardLibraryPreferences.worldBookTokenBudgetKey)
        let maxEntries = UserDefaults.standard.integer(forKey: CardLibraryPreferences.worldBookMaxEntriesKey)
        if budget > 0 || maxEntries > 0 { world = WorldBookScanner.limited(world, maxEntries: maxEntries, tokenBudget: budget) }
        var folder: String?
        if let folderId = conversation?.folderId {
            var tag = FetchDescriptor<ConversationTag>(predicate: #Predicate<ConversationTag> { $0.id == folderId })
            tag.fetchLimit = 1
            folder = (try? context.fetch(tag).first)?.instructions
        }
        return sections(base: CatalogRunner.shared.floorBase(profile: send.profile),
                        preset: CatalogRunner.shared.floorPreset(profile: send.profile), world: world, folder: folder)
    }
}
