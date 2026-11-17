import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 原子事实怎么自动带进聊天（11-15）：钉住的只听「钉住的」那一勾；「每轮全带」是开窗口页里自己的一项；
/// 「wiki 目录」那一勾只管目录那一段。夹具全是编的
@MainActor
final class EveryRoundCardsTests: XCTestCase {
    private let pid = "xctest-every-round-云桥城"
    private let keys = ["mem_master", "mem_inject_keyword", "mem_inject_full", "mem_inject_vector", "mem_inject_graph",
                        "mem_inject_catalog", "mem_inject_budget", "mem_self_recent_count", "mem_self_budget_percent",
                        MemoryOpenWindow.a2Key, MemoryOpenWindow.a4Key, MemoryOpenWindow.b4Key, MemoryOpenWindow.cKey,
                        MemoryOpenWindowStore.storageKey, RecallTuningStore.storageKey, "mem_every_round_split_v1"]
    private var saved: [String: Any?] = [:]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        super.tearDown()
    }

    private func profile() -> Profile {
        Profile(id: pid, name: "云桥城", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func window(_ id: String, _ context: ModelContext, choices: MemoryWindowChoices?) -> Conversation {
        let c = Conversation(id: id, title: "窗口\(id)", createTime: Date(timeIntervalSince1970: 1), updateTime: Date(timeIntervalSince1970: 1),
                             currentNodeId: "", provider: "api", profileId: pid)
        c.memoryWindowChoices = choices
        context.insert(c)
        return c
    }

    @discardableResult
    private func card(_ content: String, who: String? = nil, importance: Int? = nil, tags: [String] = [], category: String = "fact",
                      approved: Bool = true, pinned: Bool = false, age: TimeInterval, in context: ModelContext) -> Memory {
        let memory = Memory(content: content, category: category, keywords: tags, profileId: pid, isUserExplicit: pinned)
        if !pinned { memory.occurredDay = "2026-11-01" }
        memory.reviewedAt = approved ? Date(timeIntervalSince1970: 1_799_500_000) : nil
        memory.subject = who
        memory.importance = importance
        memory.createdAt = Date(timeIntervalSince1970: 1_799_000_000 - age)
        memory.updatedAt = memory.createdAt
        context.insert(memory)
        return memory
    }

    /// 15 条批过的（没有钉住的）+ 一条没批的 + 一条失效的
    private func seedCards(_ context: ModelContext) throws {
        card("下周去云桥城看灯会", who: "槐序", importance: 3, age: 100, in: context)
        card("对花生过敏", who: "槐序", importance: 5, age: 900, in: context)
        card("搬去了云桥城北岸", who: "槐序", importance: 3, age: 10, in: context)
        card("养了一只叫团绒的猫", who: "槐序", importance: 2, age: 5, in: context)
        card("每周三下午开门", who: "皮影作坊", tags: ["皮影作坊", "开门"], age: 200, in: context)
        card("新排了一出《渡月》", who: "皮影作坊", importance: 4, age: 300, in: context)
        card("怕打雷，会钻进柜子", who: "团绒", age: 400, in: context)
        card("只吃鸡肉味的罐头", who: "团绒", importance: 4, tags: ["罐头"], category: "preference", age: 500, in: context)
        card("喜欢喝桂花茶", who: "岚舟", category: "preference", age: 600, in: context)
        card("在筹备合成展览的布展清单", who: "岚舟", importance: 4, tags: ["布展", "展览"], category: "goal", age: 700, in: context)
        card("答应过周末陪看皮影戏", who: "星砚", importance: 4, age: 800, in: context)
        card("云桥城冬天会下雪", age: 1_000, in: context)
        card("槐序巷的路灯是暖黄色的", tags: ["槐序巷"], age: 1_100, in: context)
        card("渡口的晚班船九点收", importance: 1, tags: ["渡口", "晚班船"], age: 1_200, in: context)
        let organized = card("林栖在云桥城筹备合成展览", who: "林栖", age: 1_300, in: context)
        organized.organizedPage = "人/林栖"
        organized.organizedAt = Date(timeIntervalSince1970: 1_799_600_000)
        card("还没批的一条", who: "槐序", approved: false, age: 50, in: context)
        card("已经失效的一条", who: "槐序", age: 60, in: context).supersededAt = Date(timeIntervalSince1970: 1_799_700_000)
        try context.save()
    }

    private var wiki: WikiInjectionSnapshot {
        WikiInjectionSnapshot(indexLines: ["- [[人/林栖]] 林栖：在云桥城筹备合成展览", "- [[地点/渡口]] 渡口：晚班船"],
                              pages: [.init(path: "人/林栖", title: "林栖", triggers: [], hook: "谈到林栖的计划", now: "在云桥城筹备合成展览", version: "v1"),
                                      .init(path: "地点/渡口", title: "渡口", triggers: ["晚班船"], hook: "", now: "晚班船九点收", version: "v1")])
    }

    private func roundInputs(_ conversation: Conversation?, _ context: ModelContext) -> MemoryInjector.RoundInputs {
        let participation = EffectiveMemoryParticipation.resolve(profileId: pid, conversation: conversation, preset: nil)
        return MemoryInjector.roundInputs(profileId: pid, participation: participation, store: SwiftDataMemoryStore(), context: context,
                                          warmedWiki: .init(generation: 0, snapshot: wiki), useCachedWiki: false)
    }

    private func select(_ text: String, turn: String, state: RecallConversationState, conversation: Conversation?,
                        _ context: ModelContext, recent: [String] = []) -> (decision: RecallTurnDecision, layers: RecallMemoryLayers) {
        let participation = EffectiveMemoryParticipation.resolve(profileId: pid, conversation: conversation, preset: nil)
        return RecallSelection.prepare(profile: profile(), conversationId: conversation?.id ?? "", turnId: turn, branchAnchor: "branch",
                                       text: text, state: state, existingDecision: nil, inputs: roundInputs(conversation, context),
                                       recentMessages: recent.isEmpty ? [text] : recent, now: now,
                                       tuning: RecallTuningStore.load(profileId: pid), enabled: participation.on)
    }

    private func commit(_ decision: RecallTurnDecision, state: inout RecallConversationState) {
        var receipt = RecallTurnReceipt(decision: decision)
        let attempt = receipt.beginAttempt()
        receipt.markAttempt(attempt, status: .submitted)
        XCTAssertTrue(receipt.recordResponse(attemptId: attempt, state: &state,
                                             currentTurnId: decision.turnId, currentBranchAnchor: decision.branchAnchor))
    }

    private func dump(_ label: String, _ layers: RecallMemoryLayers) -> String {
        """
        ## \(label)
        [stable]
        \(layers.stable)
        [volatile]
        \(layers.volatile)
        [hits] \(layers.hits.map { "\($0.retrieverId):\($0.snippet)" }.joined(separator: " | "))
        [units] \(layers.units.map { "\($0.kind):\($0.shown)" }.joined(separator: " | "))

        """
    }

    /// 一个窗口的几轮：没聊到 / 点名 / 词面命中 / wiki 页 / 话题延续，外加不走「聊到才带」的两条路（自己醒来、常驻页预览）
    private func transcript(_ label: String, _ conversation: Conversation?, _ context: ModelContext, container: ModelContainer) -> String {
        var out = ""
        for (name, text) in [("没聊到", "今天帮我看一下这段代码为什么编不过"), ("点名", "槐序最近怎么样了呀"),
                             ("词面", "皮影作坊开门了吗"), ("wiki 页", "林栖的计划进展怎么样"), ("触发词", "晚班船还赶得上吗")] {
            out += dump("\(label) · \(name)", select(text, turn: "u1", state: .init(), conversation: conversation, context).layers)
        }
        var state = RecallConversationState()
        let first = select("槐序最近怎么样了呀", turn: "u1", state: state, conversation: conversation, context)
        commit(first.decision, state: &state)
        out += dump("\(label) · 话题延续", select("槐序后来搬去北岸了吗", turn: "u2", state: state, conversation: conversation, context).layers)
        let wake = WakePrompt.persona(profile: profile(), preset: .balanced, conversation: conversation, context: context, tools: [])
        out += "## \(label) · 自己醒来\n\(wake)\n\n"
        let participation = EffectiveMemoryParticipation.resolve(profileId: pid, conversation: conversation, preset: .balanced)
        let resident = MemoryResident.summary(profile: profile(), participation: participation, container: container,
                                              selfMemories: [], recentMessages: ["槐序最近怎么样了呀"])
        out += "## \(label) · 常驻页预览\n[stable]\n\(resident.stable)\n[volatile]\n\(resident.volatile)\n[full] \(resident.fullFallbackCount)\n\n"
        return out
    }

    /// 她那种状态：聊到才带开（默认，没存过）、全量 / 关键词 / 按意思找都关、钉住 0 条、批过的 15 条。老窗和新窗各走一遍
    private func herStateTranscript() throws -> String {
        for key in ["mem_inject_full", "mem_inject_keyword", "mem_inject_vector"] { UserDefaults.standard.set(false, forKey: key) }
        let container = try container()
        let context = ModelContext(container)
        try seedCards(context)
        let legacy = window("old", context, choices: nil)
        let fresh = window("new", context, choices: MemoryWindowChoices.defaults(profileId: pid))
        try context.save()
        return transcript("老窗", legacy, context, container: container) + transcript("新窗", fresh, context, container: container)
    }

    // MARK: - 她那种状态逐字不变

    /// 期望值是改之前（0445f4c1b）用同一份夹具、同一个 `herStateTranscript()` 录下来的：老窗 / 新窗各七轮
    /// （没聊到 / 点名 / 词面 / wiki 页 / 触发词 / 话题延续）+ 自己醒来 + 常驻页预览，记忆两层的字、命中、清单都在里面
    func testHerStateIsByteIdenticalToBeforeTheSplit() throws {
        let now = try herStateTranscript()
        if now != Self.herStateGolden {
            let a = now.components(separatedBy: "\n"), b = Self.herStateGolden.components(separatedBy: "\n")
            for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : nil) != (i < b.count ? b[i] : nil) {
                XCTFail("第 \(i + 1) 行变了：现在「\(i < a.count ? a[i] : "<没有>")」，改之前「\(i < b.count ? b[i] : "<没有>")」")
                break
            }
        }
        XCTAssertEqual(now, Self.herStateGolden)
    }

    private static let herStateGolden = [
        "## 老窗 · 没聊到",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "",
        "[hits] ",
        "[units] cardIndex:卡的目录 6 组",
        "## 老窗 · 点名",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[关于岚舟·本轮相关]",
        "- 槐序 · 对花生过敏 [事实]",
        "- 槐序 · 搬去了云桥城北岸 [事实]",
        "- 槐序 · 下周去云桥城看灯会 [事实]",
        "[hits] named:槐序 · 对花生过敏 | named:槐序 · 搬去了云桥城北岸 | named:槐序 · 下周去云桥城看灯会",
        "[units] cardIndex:卡的目录 6 组 | fragment:槐序 · 对花生过敏 | fragment:槐序 · 搬去了云桥城北岸 | fragment:槐序 · 下周去云桥城看灯会",
        "## 老窗 · 词面",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[关于岚舟·本轮相关]",
        "- 皮影作坊 · 每周三下午开门 [事实]",
        "- 皮影作坊 · 新排了一出《渡月》 [事实]",
        "[hits] keyword:皮影作坊 · 每周三下午开门 | named:皮影作坊 · 新排了一出《渡月》",
        "[units] cardIndex:卡的目录 6 组 | fragment:皮影作坊 · 每周三下午开门 | fragment:皮影作坊 · 新排了一出《渡月》",
        "## 老窗 · wiki 页",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[C 档案 · 本轮相关]",
        "[[人/林栖]] 林栖",
        "钩子：谈到林栖的计划",
        "现在：在云桥城筹备合成展览",
        "[hits] ",
        "[units] cardIndex:卡的目录 6 组 | page:林栖",
        "## 老窗 · 触发词",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[C 档案 · 本轮相关]",
        "[[地点/渡口]] 渡口",
        "现在：晚班船九点收",
        "[hits] ",
        "[units] cardIndex:卡的目录 6 组 | page:渡口",
        "## 老窗 · 话题延续",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[关于岚舟·本轮相关]",
        "- 槐序 · 对花生过敏 [事实]",
        "- 槐序 · 搬去了云桥城北岸 [事实]",
        "- 槐序 · 下周去云桥城看灯会 [事实]",
        "[hits] active:槐序 · 对花生过敏 | active:槐序 · 搬去了云桥城北岸 | active:槐序 · 下周去云桥城看灯会",
        "[units] cardIndex:卡的目录 6 组 | fragment:槐序 · 对花生过敏 | fragment:槐序 · 搬去了云桥城北岸 | fragment:槐序 · 下周去云桥城看灯会",
        "## 老窗 · 自己醒来",
        "",
        "",
        "## 老窗 · 常驻页预览",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "",
        "[full] 0",
        "",
        "## 新窗 · 没聊到",
        "[stable]",
        "[C 档案 · 索引]",
        "- [[人/林栖]] 林栖：在云桥城筹备合成展览",
        "- [[地点/渡口]] 渡口：晚班船",
        "",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "",
        "[hits] ",
        "[units] rootIndex:根索引 3 行 | cardIndex:卡的目录 6 组",
        "## 新窗 · 点名",
        "[stable]",
        "[C 档案 · 索引]",
        "- [[人/林栖]] 林栖：在云桥城筹备合成展览",
        "- [[地点/渡口]] 渡口：晚班船",
        "",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[关于岚舟·本轮相关]",
        "- 槐序 · 对花生过敏 [事实]",
        "- 槐序 · 搬去了云桥城北岸 [事实]",
        "- 槐序 · 下周去云桥城看灯会 [事实]",
        "[hits] named:槐序 · 对花生过敏 | named:槐序 · 搬去了云桥城北岸 | named:槐序 · 下周去云桥城看灯会",
        "[units] rootIndex:根索引 3 行 | cardIndex:卡的目录 6 组 | fragment:槐序 · 对花生过敏 | fragment:槐序 · 搬去了云桥城北岸 | fragment:槐序 · 下周去云桥城看灯会",
        "## 新窗 · 词面",
        "[stable]",
        "[C 档案 · 索引]",
        "- [[人/林栖]] 林栖：在云桥城筹备合成展览",
        "- [[地点/渡口]] 渡口：晚班船",
        "",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[关于岚舟·本轮相关]",
        "- 皮影作坊 · 每周三下午开门 [事实]",
        "- 皮影作坊 · 新排了一出《渡月》 [事实]",
        "[hits] keyword:皮影作坊 · 每周三下午开门 | named:皮影作坊 · 新排了一出《渡月》",
        "[units] rootIndex:根索引 3 行 | cardIndex:卡的目录 6 组 | fragment:皮影作坊 · 每周三下午开门 | fragment:皮影作坊 · 新排了一出《渡月》",
        "## 新窗 · wiki 页",
        "[stable]",
        "[C 档案 · 索引]",
        "- [[人/林栖]] 林栖：在云桥城筹备合成展览",
        "- [[地点/渡口]] 渡口：晚班船",
        "",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[C 档案 · 本轮相关]",
        "[[人/林栖]] 林栖",
        "钩子：谈到林栖的计划",
        "现在：在云桥城筹备合成展览",
        "[hits] ",
        "[units] rootIndex:根索引 3 行 | cardIndex:卡的目录 6 组 | page:林栖",
        "## 新窗 · 触发词",
        "[stable]",
        "[C 档案 · 索引]",
        "- [[人/林栖]] 林栖：在云桥城筹备合成展览",
        "- [[地点/渡口]] 渡口：晚班船",
        "",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[C 档案 · 本轮相关]",
        "[[地点/渡口]] 渡口",
        "现在：晚班船九点收",
        "[hits] ",
        "[units] rootIndex:根索引 3 行 | cardIndex:卡的目录 6 组 | page:渡口",
        "## 新窗 · 话题延续",
        "[stable]",
        "[C 档案 · 索引]",
        "- [[人/林栖]] 林栖：在云桥城筹备合成展览",
        "- [[地点/渡口]] 渡口：晚班船",
        "",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "[关于岚舟·本轮相关]",
        "- 槐序 · 对花生过敏 [事实]",
        "- 槐序 · 搬去了云桥城北岸 [事实]",
        "- 槐序 · 下周去云桥城看灯会 [事实]",
        "[hits] active:槐序 · 对花生过敏 | active:槐序 · 搬去了云桥城北岸 | active:槐序 · 下周去云桥城看灯会",
        "[units] rootIndex:根索引 3 行 | cardIndex:卡的目录 6 组 | fragment:槐序 · 对花生过敏 | fragment:槐序 · 搬去了云桥城北岸 | fragment:槐序 · 下周去云桥城看灯会",
        "## 新窗 · 自己醒来",
        "",
        "",
        "## 新窗 · 常驻页预览",
        "[stable]",
        "[记忆条目 · 目录]",
        "记过这些人和事的记忆条目（memory/cards/ 下一人一个文件夹）：团绒、岚舟、星砚、林栖、槐序、皮影作坊",
        "聊到的会自动带上；这一轮没带上的不等于没记过。",
        "[volatile]",
        "",
        "[full] 0",
        "",
        "",
    ].joined(separator: "\n")

    // MARK: - 钉住的只听「钉住的」那一勾

    private func lines(_ layers: RecallMemoryLayers, containing text: String) -> Bool {
        (layers.stable + "\n" + layers.volatile).contains(text)
    }

    func testPinnedListensOnlyToItsOwnCheck() throws {
        let container = try container()
        let context = ModelContext(container)
        try seedCards(context)
        card("岚舟钉住的一条坐标", who: "渡口", pinned: true, age: 2_000, in: context)
        try context.save()
        let legacy = window("old", context, choices: nil)
        let fresh = window("new", context, choices: MemoryWindowChoices.defaults(profileId: pid))
        var crossed = MemoryWindowChoices.defaults(profileId: pid)
        crossed.pinned = false
        let unpinnedWindow = window("crossed", context, choices: crossed)
        try context.save()
        let line = "[关于岚舟]\n- 渡口 · 岚舟钉住的一条坐标 [事实]"
        // 别的开关怎么摆都一样：老开关（三个都关 = 11-15 之前带不进去的那种）、聊到才带、每轮全带、wiki 目录
        UserDefaults.standard.set(false, forKey: "mem_inject_vector")
        for old in [false, true] {
            for key in ["mem_inject_full", "mem_inject_keyword"] { UserDefaults.standard.set(old, forKey: key) }
            for trigger in [true, false] {
                RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: trigger), profileId: pid)
                for every in [false, true] {
                    MemoryOpenWindow.setEveryRound(every, profileId: pid)
                    for root in [false, true] {
                        MemoryOpenWindowStore.save(.c, root, profileId: pid)
                        let label = "老开关 \(old) · 聊到才带 \(trigger) · 每轮全带 \(every) · wiki 目录 \(root)"
                        for conversation in [legacy, fresh] {
                            let layers = select("今天帮我看一下这段代码为什么编不过", turn: "u1", state: .init(),
                                                conversation: conversation, context).layers
                            XCTAssertTrue(layers.stable.contains(line), "\(conversation.id) · \(label)")
                            XCTAssertEqual(layers.hits.filter { $0.retrieverId == "persistent" }.count, 1)
                        }
                        XCTAssertFalse(lines(select("今天帮我看一下这段代码为什么编不过", turn: "u1", state: .init(),
                                                    conversation: unpinnedWindow, context).layers, containing: "钉住的一条坐标"),
                                       "这个窗口划掉了「钉住的」· \(label)")
                    }
                }
            }
        }
        // 楼层那一勾去掉：老窗（没存过本窗选择）跟着不带；新窗开出来时勾着的照带
        MemoryWindowChoices.setDefault(.pinned, false, profileId: pid)
        XCTAssertFalse(lines(select("随便聊聊今天的事", turn: "u1", state: .init(), conversation: legacy, context).layers,
                             containing: "钉住的一条坐标"))
        XCTAssertTrue(lines(select("随便聊聊今天的事", turn: "u1", state: .init(), conversation: fresh, context).layers,
                            containing: "钉住的一条坐标"))
    }

    // MARK: - 每轮全带 × 聊到才带，wiki 目录那一勾不管原子事实

    /// 这一轮带进提示的批过的条目（不含钉住的）
    private func carried(_ layers: RecallMemoryLayers) -> [String] {
        layers.hits.filter { $0.retrieverId != "persistent" }.map(\.snippet)
    }

    func testEveryRoundTimesTriggerAndWikiDirectoryCheckDoesNotDecideCards() throws {
        let container = try container()
        let context = ModelContext(container)
        try seedCards(context)
        let legacy = window("old", context, choices: nil)
        try context.save()
        let unrelated = "今天帮我看一下这段代码为什么编不过", named = "槐序最近怎么样了呀"
        let talkedAbout = ["槐序 · 对花生过敏", "槐序 · 搬去了云桥城北岸", "槐序 · 下周去云桥城看灯会"]
        for root in [false, true] {
            MemoryOpenWindowStore.save(.c, root, profileId: pid)
            for trigger in [true, false] {
                RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: trigger), profileId: pid)
                let label = "wiki 目录 \(root) · 聊到才带 \(trigger)"
                MemoryOpenWindow.setEveryRound(false, profileId: pid)
                // 新窗每次按当下的楼层设置开一个
                let fresh = window("new-\(root)-\(trigger)", context, choices: MemoryWindowChoices.defaults(profileId: pid))
                for conversation in [legacy, fresh] {
                    let quiet = select(unrelated, turn: "u1", state: .init(), conversation: conversation, context).layers
                    XCTAssertEqual(carried(quiet), [], "每轮全带不勾、没聊到：不带（\(label)）")
                    let hit = select(named, turn: "u1", state: .init(), conversation: conversation, context).layers
                    // 新窗的「档案」那一项 = 开窗时 wiki 目录勾或聊到才带开；两样都没有的新窗是划掉档案的窗
                    let candidates = conversation.id == "old" || root || trigger
                    XCTAssertEqual(carried(hit), trigger && candidates ? talkedAbout : [],
                                   "每轮全带不勾：聊到才带开着只带聊到的，关着不带（\(conversation.id) · \(label)）")
                    // wiki 目录那一段：老窗听楼层那一勾，新窗听开窗时定下的「档案」
                    let expectRoot = conversation.id == "old" ? root : root || trigger
                    XCTAssertEqual(quiet.stable.contains("[C 档案 · 索引]"), expectRoot, "\(conversation.id) · \(label)")
                }
                MemoryOpenWindow.setEveryRound(true, profileId: pid)
                let freshEvery = window("new-every-\(root)-\(trigger)", context, choices: MemoryWindowChoices.defaults(profileId: pid))
                for conversation in [legacy, freshEvery] {
                    for text in [unrelated, named] {
                        let layers = select(text, turn: "u1", state: .init(), conversation: conversation, context).layers
                        XCTAssertEqual(carried(layers).count, 15, "每轮全带勾着：批过的 15 条都带（\(conversation.id) · \(label)）")
                        XCTAssertEqual(carried(layers).first, "槐序 · 对花生过敏", "重要度高的先")
                        XCTAssertFalse(layers.stable.contains("记忆条目 · 目录"))
                        XCTAssertFalse(layers.volatile.contains("还没批的一条") || layers.volatile.contains("已经失效的一条"))
                    }
                    let page = select("林栖的计划进展怎么样", turn: "u1", state: .init(), conversation: conversation, context)
                    XCTAssertEqual(page.decision.selected.map(\.source.path), trigger ? ["人/林栖"] : [], "wiki 页照旧聊到才带")
                }
            }
        }
        try context.save()
    }

    /// 同一组开关下，只动 wiki 目录那一勾：老窗里带进来的批过的条目一条不差，只多 / 少目录那一段
    func testWikiDirectoryCheckOnlyAddsTheDirectoryBlock() throws {
        let container = try container()
        let context = ModelContext(container)
        try seedCards(context)
        let legacy = window("old", context, choices: nil)
        try context.save()
        for trigger in [true, false] {
            RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: trigger), profileId: pid)
            for every in [false, true] {
                MemoryOpenWindow.setEveryRound(every, profileId: pid)
                for text in ["今天帮我看一下这段代码为什么编不过", "槐序最近怎么样了呀"] {
                    MemoryOpenWindowStore.save(.c, false, profileId: pid)
                    let without = select(text, turn: "u1", state: .init(), conversation: legacy, context).layers
                    MemoryOpenWindowStore.save(.c, true, profileId: pid)
                    let with = select(text, turn: "u1", state: .init(), conversation: legacy, context).layers
                    XCTAssertEqual(with.volatile, without.volatile, "聊到才带 \(trigger) · 每轮全带 \(every) · \(text)")
                    XCTAssertEqual(carried(with), carried(without))
                    let directory = "[C 档案 · 索引]\n- [[人/林栖]] 林栖：在云桥城筹备合成展览\n- [[地点/渡口]] 渡口：晚班船"
                    XCTAssertEqual(with.stable, without.stable.isEmpty ? directory : directory + "\n\n" + without.stable)
                }
            }
        }
    }

    // MARK: - 不走「聊到才带」的两条路

    func testWakeAndReadingCarryCardsOnlyWhenEveryRoundIsChecked() throws {
        let container = try container()
        let context = ModelContext(container)
        try seedCards(context)
        card("岚舟钉住的一条坐标", who: "渡口", pinned: true, age: 2_000, in: context)
        try context.save()
        func wake() -> String { WakePrompt.persona(profile: profile(), preset: .balanced, conversation: nil, context: context, tools: []) }
        func reading() -> String { ReadingSignals.buildPersonaPackage(profile: profile(), context: context) }
        XCTAssertTrue(wake().contains("岚舟钉住的一条坐标") && !wake().contains("对花生过敏"), "每轮全带不勾：只有钉住的")
        XCTAssertTrue(reading().contains("岚舟钉住的一条坐标") && !reading().contains("对花生过敏"))
        MemoryOpenWindow.setEveryRound(true, profileId: pid)
        XCTAssertTrue(wake().contains("岚舟钉住的一条坐标") && wake().contains("对花生过敏"), "每轮全带勾着：批过的也带")
        XCTAssertFalse(wake().contains("还没批的一条"))
        XCTAssertTrue(reading().contains("岚舟钉住的一条坐标") && reading().contains("对花生过敏"))
    }

    // MARK: - 迁移

    func testMigrationChecksEveryRoundOnlyWhereTheFloorWasCarryingEverything() throws {
        let suite = "EveryRoundCardsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // 楼层：聊到才带 / wiki 目录 → 改之前全量开着时是不是每轮都在带全部
        let floors: [(id: String, trigger: Bool?, root: Bool?)] = [
            ("她那样", nil, nil),            // 聊到才带没存过（= 开）、wiki 目录没勾
            ("全带", false, true),
            ("关着但没勾目录", false, false),
            ("开着且勾了目录", true, true),
            ("没存过但勾了目录", nil, true),
        ]
        func install() {
            for floor in floors {
                if let trigger = floor.trigger {
                    RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: trigger), profileId: floor.id, defaults: defaults)
                }
                if let root = floor.root { MemoryOpenWindowStore.save(.c, root, profileId: floor.id, defaults: defaults) }
            }
        }
        func checked() -> [String] {
            floors.map(\.id).filter { MemoryOpenWindow.everyRound(profileId: $0, defaults: defaults) }
        }
        let ids = floors.map(\.id)

        // 全量注入关着（她那种）：哪一层都不勾，什么都不写
        install()
        defaults.set(false, forKey: "mem_inject_full")
        MemoryFlags.migrateEveryRoundIfNeeded(profileIds: ids, defaults: defaults)
        XCTAssertEqual(checked(), [])
        XCTAssertTrue(floors.allSatisfy {
            MemoryOpenWindowStore.load(key: MemoryOpenWindow.everyRoundKey, profileId: $0.id, defaults: defaults) == nil
        }, "不勾的不写")

        // 全量注入开着（没写过 = 开；开没开关键词 / 按意思找都一样——它们只是排在前面，剩下的照样全带）
        for (full, keyword, vector) in [(Bool?.none, false, false), (true, false, false), (true, true, false), (true, false, true)] {
            defaults.removePersistentDomain(forName: suite)
            install()
            if let full { defaults.set(full, forKey: "mem_inject_full") }
            defaults.set(keyword, forKey: "mem_inject_keyword")
            defaults.set(vector, forKey: "mem_inject_vector")
            let before = defaults.dictionaryRepresentation()
            MemoryFlags.migrateEveryRoundIfNeeded(profileIds: ids, defaults: defaults)
            XCTAssertEqual(checked(), ["全带"], "只有聊到才带关 + wiki 目录勾着的那一层在全带")
            // 老键一个不动
            for key in ["mem_inject_full", "mem_inject_keyword", "mem_inject_vector", "mem_inject_graph", RecallTuningStore.storageKey] {
                XCTAssertEqual(defaults.object(forKey: key) as? NSObject, before[key] as? NSObject, key)
            }
            XCTAssertEqual(MemoryOpenWindow.isChecked(.c, profileId: "全带", defaults: defaults), true)
            // 幂等：再跑一遍不变；之后只听它自己——别的开关变了、她自己去掉了，都不会被迁移再改回来
            MemoryFlags.migrateEveryRoundIfNeeded(profileIds: ids, defaults: defaults)
            XCTAssertEqual(checked(), ["全带"])
            MemoryOpenWindow.setEveryRound(false, profileId: "全带", defaults: defaults)
            RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: false), profileId: "开着且勾了目录", defaults: defaults)
            MemoryFlags.migrateEveryRoundIfNeeded(profileIds: ids + ["后来新开的一层"], defaults: defaults)
            XCTAssertEqual(checked(), [], "跑过一次就不再跑")
            XCTAssertFalse(MemoryOpenWindow.everyRound(profileId: "后来新开的一层", defaults: defaults), "新楼层没写过 = 不勾")
        }

        // 已经自己定过的不覆盖
        defaults.removePersistentDomain(forName: suite)
        install()
        MemoryOpenWindow.setEveryRound(false, profileId: "全带", defaults: defaults)
        MemoryFlags.migrateEveryRoundIfNeeded(profileIds: ids, defaults: defaults)
        XCTAssertEqual(checked(), [])
    }

    /// 迁移前后同一层带的东西一样：改之前「聊到才带关 + wiki 目录勾 + 全量注入开」的楼层每轮带全部批过的，迁移后还是
    func testMigratedFloorStillCarriesEverythingEachRound() throws {
        let container = try container()
        let context = ModelContext(container)
        try seedCards(context)
        let legacy = window("old", context, choices: nil)
        try context.save()
        RecallTuningStore.save(RecallTestTuning.make(archiveTriggerEnabled: false), profileId: pid)
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        XCTAssertEqual(carried(select("随便聊聊今天的事", turn: "u1", state: .init(), conversation: legacy, context).layers), [],
                       "迁移还没跑：每轮全带没勾")
        MemoryFlags.migrateEveryRoundIfNeeded(profileIds: [pid])
        let layers = select("随便聊聊今天的事", turn: "u1", state: .init(), conversation: legacy, context).layers
        XCTAssertEqual(carried(layers).count, 15)
        XCTAssertTrue(layers.volatile.hasPrefix("[关于岚舟·本轮相关]\n- 槐序 · 对花生过敏 [事实]\n"))
        XCTAssertEqual(layers.hits.map(\.retrieverId), Array(repeating: "fullFallback", count: 15))
    }
}
