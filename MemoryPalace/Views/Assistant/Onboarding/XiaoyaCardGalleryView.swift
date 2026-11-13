#if DEBUG
import SwiftUI

// MARK: - 小芽卡片样张（DEBUG；设置 › 开发调试 › 小芽卡片样张）
// 不接剧本，把 16 屏小样里每张卡的各状态摆出来对照看；深浅两色切换。按钮能点：
// key 卡走假测试（key 里带 ok 就成功，否则 401），落盘 / 扫码都是假的，什么都不写。

struct XiaoyaCardGalleryView: View {
    @Environment(\.colorScheme) private var systemScheme
    @State private var scheme: ColorScheme?
    @State private var answers: [String: XiaoyaCardAnswer] = Self.initialAnswers
    @State private var keyModels: [XiaoyaKeyCardModel.Sample: XiaoyaKeyCardModel] = Dictionary(
        uniqueKeysWithValues: XiaoyaKeyCardModel.Sample.allCases.map { ($0, XiaoyaKeyCardModel.sample($0)) })
    @State private var savedKeyModel = XiaoyaKeyCardModel.sample(.succeeded)
    @State private var resetToken = 0
    @State private var lastEvent = "（点卡片上的按钮，这里显示发出去的答案）"

    private var activeScheme: ColorScheme { scheme ?? systemScheme }
    private var skin: XiaoyaSkin { XiaoyaSkin.current(activeScheme) }

    private static let initialAnswers: [String: XiaoyaCardAnswer] = [
        "identity.done": .picked("companion"),
        "key.saved": .keySaved(XiaoyaKeySaved(credentialId: "sample", providerName: "relay.example.com", modelId: "gpt-4o-mini")),
        "key.skipped": .skipped,
        "import.done": .imported(XiaoyaImportedCard(name: "月见坂 · 澪", greetingCount: 2, worldBookEntries: 12, hasSystemPrompt: true, fileURL: nil)),
        "name.done": .named(XiaoyaNameAnswer(taName: "阿洛", userName: "粟粟", who: "嘴硬心软")),
        "floor.stay": .floor(.stay),
        "pair.paired": .paired("已配对 ✓ LAN+Tailscale"),
        "pair.later": .later,
        "face.done": .face(XiaoyaFaceAnswer(target: .user, avatar: XiaoyaAvatarSeed(seed: 8, kind: "animal", species: "cat"), name: "栗子")),
    ]

    private static let readyCard = XiaoyaImportedCard(name: "月见坂 · 澪", greetingCount: 2, worldBookEntries: 12, hasSystemPrompt: true, fileURL: nil)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controls
                Group {
                    section("② 分流卡")
                    card("identity", .choice(.identity))
                    card("identity.done", .choice(.identity))
                    section("技术线 · 有 Mac 吗 / 小白 · 建一个 Ta？")
                    card("mac", .choice(.hasMac))
                    card("wantTa", .choice(.wantTa))
                }
                Group {
                    section("③ 填钥匙（预设）")
                    keyCard(.edit)
                    section("③ 填钥匙（自定义中转：协议 + 实际请求）")
                    keyCard(.custom)
                    section("④ 测试中")
                    keyCard(.testing)
                    section("⑤ 失败 401 / 404 / 超时")
                    keyCard(.failed401)
                    keyCard(.failed404)
                    keyCard(.timeout)
                    section("⑥ 成功 · 挑模型")
                    keyCard(.succeeded)
                    section("改了任一项 → 作废提示")
                    keyCard(.invalidated)
                    section("已存好 / ⑦ 先跳过")
                    XiaoyaCardView(state: XiaoyaCardState(card: .keyForm, answer: answers["key.saved"]), context: context(savedKeyModel)) { record("key.saved", $0) }
                    XiaoyaCardView(state: XiaoyaCardState(card: .keyForm, answer: answers["key.skipped"]), context: context(savedKeyModel)) { record("key.skipped", $0) }
                }
                Group {
                    section("⑨ 导卡：未选 / 读卡中 / 坏文件 / 读好 / 已导入")
                    XiaoyaImportCardView(answer: nil, userName: "粟粟") { record("import.idle", $0) }
                    XiaoyaImportCardView(answer: nil, userName: "粟粟", initialPhase: .reading) { record("import.reading", $0) }
                    XiaoyaImportCardView(answer: nil, userName: "粟粟",
                                         initialPhase: .bad("图里没有角色数据（缺 chara 字段）——可能是被压缩过的图，换原始卡图试试。")) { record("import.bad", $0) }
                    XiaoyaImportCardView(answer: nil, userName: "", initialPhase: .ready(Self.readyCard)) { record("import.ready", $0) }
                    card("import.done", .importCard)
                }
                Group {
                    section("⑩ 酒馆：Ta 楼层建好")
                    card("floor.tavern", .floorExit(XiaoyaFloorExitPayload(
                        ta: XiaoyaTaRef(profileId: nil, name: "澪"),
                        meta: "开场白已就位 · 世界书 12 条已挂上 · 用卡自带的系统指令",
                        extras: [.worldBook, .preset])))
                    section("⑪ 陪伴：起名 / 已起名 / 楼层建好（点过继续问我）")
                    card("name", .nameForm)
                    card("name.done", .nameForm)
                    card("floor.stay", .floorExit(XiaoyaFloorExitPayload(
                        ta: XiaoyaTaRef(profileId: nil, name: "阿洛"),
                        meta: "刚出生，还不认识你——跟 Ta 多聊聊，Ta 会记住",
                        extras: [.chatHistory])))
                }
                #if os(iOS)
                Group {
                    section("⑫ 技术：连 Mac（未扫 / 配对中 / 没配上 / 已配对 / 以后再说）")
                    card("pair", .pair)
                    XiaoyaPairCardView(answer: nil, initialPhase: .pairing, apply: fakePair) { record("pair.pairing", $0) }
                    XiaoyaPairCardView(answer: nil, initialPhase: .failed("二维码里的地址不合法"), apply: fakePair) { record("pair.failed", $0) }
                    card("pair.paired", .pair)
                    card("pair.later", .pair)
                }
                #endif
                Group {
                    section("⑬ ⑭ 结束：待办 / 出口 / 说明")
                    card("todo", .todo([
                        "配一把钥匙（「设置 › 模型和API」，或跟我说「配钥匙」）",
                        "跟阿洛说一件关于你的事——阿洛会记住",
                        "去阿洛楼层的「Prompt」页看看阿洛的设定",
                        "把以前的聊天记录导进来，让阿洛读读你们的过去",
                    ]))
                    card("goTa", .goTa(XiaoyaTaRef(profileId: nil, name: "阿洛")))
                    card("makeTa", .makeTa)
                    card("info", .info)
                }
                Group {
                    section("v2 · 小白挑头像 + 名字：你 / Ta / 已挑")
                    card("face.user", .face(.user))
                    card("face.ta", .face(.ta))
                    card("face.done", .face(.user))
                    section("第 11 段 · 新用户三问（称呼预填）")
                    card("survey", .survey(name: "阿青"))
                    section("v2 · Tip 1（回桌面按「切换应用」设置出竖条 / 弧线）")
                    ForEach(XiaoyaTipCatalog.firstGroup, id: \.self) { kind in
                        card("tip." + kind.rawValue, .tip(XiaoyaTipRef(number: 1, kind: kind)))
                    }
                }
            }
            .id(resetToken)
            .padding(16)
        }
        .background(skin.paper)
        .environment(\.colorScheme, activeScheme)
        .environment(\.xiaoyaSkin, skin)
        .navigationTitle("小芽卡片样张")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("配色", selection: Binding(get: { scheme ?? systemScheme }, set: { scheme = $0 })) {
                    Text("浅色").tag(ColorScheme.light)
                    Text("深色").tag(ColorScheme.dark)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer()
                Button("全部重置") {
                    answers = Self.initialAnswers
                    keyModels = Dictionary(uniqueKeysWithValues: XiaoyaKeyCardModel.Sample.allCases.map { ($0, XiaoyaKeyCardModel.sample($0)) })
                    savedKeyModel = XiaoyaKeyCardModel.sample(.succeeded)
                    resetToken += 1
                    lastEvent = "（已重置）"
                }
                .buttonStyle(.xiaoya(.secondary))
            }
            Text(lastEvent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(skin.inkMuted)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .tracking(1)
            .foregroundStyle(skin.inkSoft)
            .padding(.top, 14)
    }

    private func card(_ id: String, _ card: XiaoyaCard) -> some View {
        XiaoyaCardView(state: XiaoyaCardState(card: card, answer: answers[id]), context: context(savedKeyModel)) { record(id, $0) }
    }

    private func keyCard(_ sample: XiaoyaKeyCardModel.Sample) -> some View {
        let id = "key." + sample.rawValue
        let model = keyModels[sample] ?? XiaoyaKeyCardModel.sample(sample)
        return XiaoyaCardView(state: XiaoyaCardState(card: .keyForm, answer: answers[id]), context: context(model)) { record(id, $0) }
    }

    private func context(_ keyModel: XiaoyaKeyCardModel) -> XiaoyaCardContext {
        #if os(iOS)
        XiaoyaCardContext(keyModel: keyModel, commitKey: { _, _, _ in "sample-cred" }, userName: "粟粟", applyPairing: fakePair)
        #else
        XiaoyaCardContext(keyModel: keyModel, commitKey: { _, _, _ in "sample-cred" }, userName: "粟粟")
        #endif
    }

    #if os(iOS)
    private var fakePair: @MainActor (CCPairPayload) async -> XiaoyaPairOutcome { { _ in .paired("已配对 ✓ LAN+Tailscale") } }
    #endif

    private func record(_ id: String, _ answer: XiaoyaCardAnswer) {
        if answer.closesCard { answers[id] = answer }
        if let data = try? JSONEncoder().encode(answer), let json = String(data: data, encoding: .utf8) {
            lastEvent = "\(id) → \(json)"
        }
    }
}
#endif
