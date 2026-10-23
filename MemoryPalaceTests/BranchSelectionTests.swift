import XCTest
import SwiftData
@testable import 记忆花园

/// 卡库 ③b：分支选择表唯一 resolver + {{char}}/{{user}} 显示 / 发送副本展开
final class BranchSelectionTests: XCTestCase {

    // MARK: - 夹具

    /// 按 (id, parent) 顺序建链接；孩子顺序 = 出现顺序（稳定序）
    private func links(_ pairs: [(String, String?)]) -> [BranchSelection.Link] {
        var children: [String: [String]] = [:]
        for (id, parent) in pairs { if let parent { children[parent, default: []].append(id) } }
        return pairs.map { BranchSelection.Link(id: $0.0, parentId: $0.1, childrenIds: children[$0.0] ?? []) }
    }

    ///       R ─ U1 ┬ A1 ─ U2 ─ A3
    ///              └ A2 ─ U3 ─ A4
    private var fork: [BranchSelection.Link] {
        links([("R", nil), ("U1", "R"), ("A1", "U1"), ("A2", "U1"), ("U2", "A1"), ("A3", "U2"), ("U3", "A2"), ("A4", "U3")])
    }

    /// 改造前 buildTreeInBackground 的选法：currentNodeId 反向追主线，分叉取主线上的孩子，否则第一个
    private func legacyPath(_ links: [BranchSelection.Link], currentNodeId: String) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        var main = Set<String>()
        var root: String?
        var cursor: String? = currentNodeId
        while let id = cursor, let link = byId[id] {
            main.insert(id)
            if link.parentId == nil || byId[link.parentId ?? ""] == nil { root = id }
            cursor = link.parentId
        }
        if root == nil {   // currentNodeId 失效：无父节点里 id 最小的
            root = links.filter { $0.parentId == nil || byId[$0.parentId ?? ""] == nil }.map(\.id).min()
        }
        var path: [String] = []
        var node = root
        while let id = node, let link = byId[id] {
            path.append(id)
            let kids = link.childrenIds
            node = kids.isEmpty ? nil : (kids.first(where: main.contains) ?? kids[0])
        }
        return path
    }

    // MARK: - resolver

    func testNoSelectionMatchesLegacyCurrentNodePath() {
        for current in ["A4", "A3", "U1", "R", "不存在"] {
            let r = BranchSelection.resolve(links: fork, selection: [:], legacyCurrentNodeId: current)
            XCTAssertEqual(r.pathIds, legacyPath(fork, currentNodeId: current), "currentNodeId=\(current)")
        }
        let r = BranchSelection.resolve(links: fork, selection: [:], legacyCurrentNodeId: "A4")
        XCTAssertEqual(r.leafId, "A4")
        XCTAssertEqual(r.selection, ["U1": "A2"], "旧对话首次加载：从旧路径生成一份")
        XCTAssertTrue(r.changed)
    }

    func testSelectionTableWinsOverCurrentNode() {
        let r = BranchSelection.resolve(links: fork, selection: ["U1": "A1"], legacyCurrentNodeId: "A4")
        XCTAssertEqual(r.pathIds, ["R", "U1", "A1", "U2", "A3"])
        XCTAssertEqual(r.leafId, "A3")
        XCTAssertFalse(r.changed, "表已经完整：不需要写回")
    }

    func testDeletedChildInTableIsRepaired() {
        let r = BranchSelection.resolve(links: fork, selection: ["U1": "被删的", "已删父": "A1"], legacyCurrentNodeId: "A4")
        XCTAssertEqual(r.leafId, "A4", "记录失效 → 取旧 currentNodeId 路径上的孩子")
        XCTAssertEqual(r.selection, ["U1": "A2"])
        XCTAssertTrue(r.changed)

        let noLegacy = BranchSelection.resolve(links: fork, selection: ["U1": "被删的"], legacyCurrentNodeId: "")
        XCTAssertEqual(noLegacy.leafId, "A3", "旧路径也没有 → 稳定序第一个")
    }

    func testSyntheticRootThreeOpeningsPickSecond() {
        let tree = links([("S", nil), ("O1", "S"), ("O2", "S"), ("O3", "S")])
        let r = BranchSelection.resolve(links: tree, selection: ["S": "O2"], legacyCurrentNodeId: "O1")
        XCTAssertEqual(r.pathIds, ["S", "O2"])
        XCTAssertEqual(r.leafId, "O2")
    }

    func testFollowUpUnderSecondOpeningSurvivesSwitchingAway() {
        var tree = links([("S", nil), ("O1", "S"), ("O2", "S"), ("O3", "S")])
        var selection = BranchSelection.resolve(links: tree, selection: ["S": "O2"], legacyCurrentNodeId: "O2").selection
        // 第 2 支下接一轮：新节点落点走 selecting（发送 / 追加同一函数）
        tree = links([("S", nil), ("O1", "S"), ("O2", "S"), ("O3", "S"), ("U", "O2"), ("A", "U")])
        let byId = Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0) })
        selection = BranchSelection.selecting("A", in: selection, parentOf: { byId[$0]?.parentId },
                                              childCount: { byId[$0]?.childrenIds.count ?? 0 })
        XCTAssertEqual(BranchSelection.resolve(links: tree, selection: selection, legacyCurrentNodeId: "A").leafId, "A")

        selection["S"] = "O1"
        let away = BranchSelection.resolve(links: tree, selection: selection, legacyCurrentNodeId: "O1")
        XCTAssertEqual(away.pathIds, ["S", "O1"])

        selection = away.selection
        selection["S"] = "O2"
        let back = BranchSelection.resolve(links: tree, selection: selection, legacyCurrentNodeId: "O2")
        XCTAssertEqual(back.pathIds, ["S", "O2", "U", "A"], "切回第 2 支，后续还在")
    }

    func testOrphanChildDiscoveredByParentIdIsStableOrder() {
        // childrenIds 没挂上的孩子按 id 排序追加
        let tree = [BranchSelection.Link(id: "R", parentId: nil, childrenIds: ["b"]),
                    BranchSelection.Link(id: "b", parentId: "R", childrenIds: []),
                    BranchSelection.Link(id: "z", parentId: "R", childrenIds: []),
                    BranchSelection.Link(id: "c", parentId: "R", childrenIds: [])]
        let r = BranchSelection.resolve(links: tree, selection: [:], legacyCurrentNodeId: "")
        XCTAssertEqual(r.children["R"], ["b", "c", "z"])
        XCTAssertEqual(r.leafId, "b")
    }

    func testEncodeDecodeAndRemap() {
        XCTAssertNil(BranchSelection.encode([:]))
        XCTAssertEqual(BranchSelection.decode(nil), [:])
        XCTAssertEqual(BranchSelection.decode(Data("坏数据".utf8)), [:])
        let data = BranchSelection.encode(["p": "c", "q": "d"])
        XCTAssertEqual(BranchSelection.decode(data), ["p": "c", "q": "d"])
        let remapped = BranchSelection.remap(data) { ["p": "P", "c": "C", "q": "Q"][$0] }
        XCTAssertEqual(BranchSelection.decode(remapped), ["P": "C"], "映射不到的记录丢掉")
    }

    // MARK: - 切支 → 重开（ViewModel 集成）

    @MainActor
    func testSwitchBranchPersistsAndReopenKeepsIt() async throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let pid = "test-branch-selection"
        let conv = Conversation(id: "branch-sel", title: "fixture", createTime: Date(), updateTime: Date(),
                                currentNodeId: "O1", provider: "sillytavern", profileId: pid)
        ctx.insert(conv)
        let root = MessageNode(id: "S", role: "system", content: "", contentType: "text", createTime: Date(),
                               parentId: nil, childrenIds: ["O1", "O2", "O3"], conversationId: conv.id, profileId: pid)
        root.isSyntheticRoot = true
        ctx.insert(root)
        for id in ["O1", "O2", "O3"] {
            ctx.insert(MessageNode(id: id, role: "assistant", content: "{{char}} 开场 \(id)", contentType: "text",
                                   createTime: Date(), parentId: "S", childrenIds: [], conversationId: conv.id, profileId: pid))
        }
        try ctx.save()

        let vm = ConversationViewModel()
        vm.loadConversation(conv, context: ctx)
        for _ in 0..<200 where vm.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(vm.currentPath.map(\.id), ["O1"])
        XCTAssertEqual(BranchSelection.decode(conv.branchSelectionData), ["S": "O1"], "首次加载生成选择表")

        vm.switchBranch(at: "S", to: 1)
        XCTAssertEqual(vm.currentPath.map(\.id), ["O2"])
        XCTAssertEqual(conv.currentNodeId, "O2", "选择表与派生 currentNodeId 同次保存")
        XCTAssertEqual(BranchSelection.decode(conv.branchSelectionData), ["S": "O2"])

        let reader = ModelContext(container)
        let reopened = try XCTUnwrap(reader.fetch(FetchDescriptor<Conversation>()).first)
        let vm2 = ConversationViewModel()
        vm2.loadConversation(reopened, context: reader)
        for _ in 0..<200 where vm2.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(vm2.currentPath.map(\.id), ["O2"], "退出重开仍在第 2 支")

        // 搜索跳转是临时浏览：显示 O3，持久表不动
        vm2.loadConversation(reopened, context: reader, scrollTargetNodeId: "O3")
        for _ in 0..<200 where vm2.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(vm2.currentPath.map(\.id), ["O3"])
        XCTAssertEqual(BranchSelection.decode(reopened.branchSelectionData), ["S": "O2"])
        XCTAssertEqual(reopened.currentNodeId, "O2")
    }

    // MARK: - 宏

    func testExpandsCharAndUserOnlyAndKeepsUnknownMacros() {
        let raw = "{{char}}看着{{user}}，{{Char}}说：{{USER}}好。{{unknown}} {{persona}} {{ char }} {{"
        let out = EffectiveCharacterContext.expandNames(raw, charName: "小岚", userName: "禾禾")
        XCTAssertEqual(out, "小岚看着禾禾，小岚说：禾禾好。{{unknown}} {{persona}} {{ char }} {{")
        XCTAssertEqual(raw, "{{char}}看着{{user}}，{{Char}}说：{{USER}}好。{{unknown}} {{persona}} {{ char }} {{", "原文不变")
        XCTAssertEqual(EffectiveCharacterContext.expandNames("没有宏", charName: "a", userName: "b"), "没有宏")
    }

    func testNamesAreNotExpandedTwiceAndFallbacksMatchMacroExpander() {
        XCTAssertEqual(EffectiveCharacterContext.expandNames("{{char}}", charName: "{{user}}", userName: "禾禾"), "{{user}}")
        let ctx = EffectiveCharacterContext(charName: "", userName: "")
        XCTAssertEqual(ctx.expand("{{char}}/{{user}}"), MacroExpander.expand("{{char}}/{{user}}", userName: "", charName: ""))
    }

    func testProfileUserNameFallsBackToStoredUserName() throws {
        let suite = "BranchSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var profile = Profile(name: "t", emoji: "🧪", description: "", userName: "", assistantName: "小岚")
        XCTAssertEqual(EffectiveCharacterContext(profile: profile, defaults: defaults).userName, "你")
        defaults.set("阿禾", forKey: "userName")
        XCTAssertEqual(EffectiveCharacterContext(profile: profile, defaults: defaults).userName, "阿禾")
        profile.userName = "禾禾"
        XCTAssertEqual(EffectiveCharacterContext(profile: profile, defaults: defaults).userName, "禾禾")
    }

    func testSendCopyOfHistoryExpandsNamesButTemplateKeepsRaw() {
        let profile = Profile(name: "t", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚")
        var preset = Preset(name: "t")
        preset.prompts = [PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system",
                                     isSystemPrompt: true, isMarker: true, injectionOrder: 60)]
        let raw = "*{{char}}抬头看{{user}}* {{unknown}}"
        let segs = PromptAssembler.assembleTagged(preset: preset, profile: profile, memories: [],
                                                  chatHistory: [("assistant", raw), ("user", "你好")]).segments
        let opening = segs.first { $0.source == .chatHistory && $0.role == "assistant" }
        XCTAssertEqual(opening?.content, "*小岚抬头看禾禾* {{unknown}}")
        XCTAssertEqual(opening?.template, raw)
    }
}
