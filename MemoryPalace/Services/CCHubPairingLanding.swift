import Foundation

/// 扫码 / 手填之后那一页说什么（plan-multi-hub B4.3，小样第 4 屏）：classifyPairing 的结果 → 标题 / 变了什么 / 选项 / 按钮。
/// 只出界面状态，提交由页面按 `commit` 调 addHub / updatePairing
struct CCHubPairingLanding: Equatable {
    enum Kind: Equatable {
        /// 认出来了：更新这台
        case update(String)
        case addNew
        /// 老 hub 报不出身份、口令也对不上：让人选
        case choose
        case unreachable
    }

    /// 地址哪行变了（旧的划掉 → 新的）
    struct Change: Equatable {
        let label: String
        let old: String?
        let new: String?
    }

    /// 「X 换了口令」（hubId = X）/「这是一台新电脑」（hubId = nil）
    struct Choice: Hashable {
        let hubId: String?
        let title: String
        let detail: String
    }

    /// 按下去做什么
    enum Commit: Equatable {
        case update(String)
        case add
    }

    let kind: Kind
    let title: String
    let hint: String
    var changes: [Change] = []
    var tokenChanged = false
    var choices: [Choice] = []
    /// 新电脑名字框的默认值：hub 报的主机名
    var suggestedName = ""

    static let fallbackName = "新电脑"

    /// match：classifyPairing 的结果；hostName：握手 hello 报的主机名；target：从哪台的「重新扫码」进来（nil = 再接一台）；
    /// pairing(of:) / fingerprint(of:)：已有那台现在的地址 / 口令指纹
    static func make(_ match: CCHubRegistry.PairingMatch, hostName: String?, hubs: [CCHubRegistry.HubProfile], target: String?,
                     new: CCHubPairing, token: String, pairing: (String) -> CCHubPairing?, fingerprint: (String) -> String?) -> CCHubPairingLanding {
        func name(_ id: String) -> String { hubs.first { $0.id == id }?.name ?? "这台电脑" }
        let suggested = hostName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName

        func update(_ id: String, prefix: String = "") -> CCHubPairingLanding {
            let changes = diff(pairing(id) ?? CCHubPairing(), new)
            let tokenChanged = fingerprint(id) != CCHubPairingStore.fingerprint(token)
            let what = !changes.isEmpty ? "，只是地址变了" : tokenChanged ? "，只是口令变了" : ""
            return CCHubPairingLanding(kind: .update(id), title: "认出来了：这是 \(name(id))",
                                       hint: prefix + "同一台电脑\(what)。对话、终端窗口、读到哪都留着。",
                                       changes: changes, tokenChanged: tokenChanged)
        }

        switch match {
        case .update(let id):
            return update(id)
        case .differentMachine(let target, let matching?):
            return update(matching, prefix: "这不是 \(name(target))，是 \(name(matching))。")
        case .differentMachine(let target, nil):
            return CCHubPairingLanding(kind: .addNew, title: "这是一台新电脑",
                                       hint: "不是 \(name(target))，不会覆盖它。", suggestedName: suggested)
        case .addNew:
            let names = hubs.map(\.name).joined(separator: "、")
            return CCHubPairingLanding(kind: .addNew, title: "这是一台新电脑",
                                       hint: "和已经接上的 \(names)\(hubs.count > 1 ? "都" : "")不是同一台。", suggestedName: suggested)
        case .needsChoice:
            let candidates = target.map { t in hubs.filter { $0.id == t } } ?? hubs
            let rekey = candidates.map { Choice(hubId: $0.id, title: "\($0.name) 换了口令", detail: "更新 \($0.name)，对话和窗口都留着") }
            return CCHubPairingLanding(kind: .choose, title: "认不出这是哪台",
                                       hint: "这台电脑上的 hub 比较老，报不出自己是谁；口令也和已有的对不上。你说是哪种：",
                                       choices: rekey + [Choice(hubId: nil, title: "这是一台新电脑", detail: "新加一台，从空开始")],
                                       suggestedName: suggested)
        case .unreachable(let reason):
            return CCHubPairingLanding(kind: .unreachable, title: "连不上这台电脑",
                                       hint: (reason.isEmpty ? "" : reason + "。") + "确认电脑上的 hub 在跑、地址这台手机能到，再试一次。")
        }
    }

    /// 主 / 备 / 中继三行里变了的
    static func diff(_ old: CCHubPairing, _ new: CCHubPairing) -> [Change] {
        [("主", old.primaryURL, new.primaryURL), ("备", old.backupURL, new.backupURL), ("中继", old.relayURL, new.relayURL)]
            .filter { $0.1 != $0.2 }
            .map { Change(label: $0.0, old: $0.1, new: $0.2) }
    }

    /// 选中 choice（只有 .choose 用）时按钮做什么；unreachable 没有提交
    func commit(choice: Choice?) -> Commit? {
        switch kind {
        case .update(let id): return .update(id)
        case .addNew: return .add
        case .choose: return choice.map { $0.hubId.map(Commit.update) ?? .add }
        case .unreachable: return nil
        }
    }

    /// 要不要出名字框
    func needsName(choice: Choice?) -> Bool { commit(choice: choice) == .add }

    func buttonTitle(choice: Choice?, names: (String) -> String) -> String {
        switch commit(choice: choice) {
        case .update(let id)?:
            if case .choose = kind { return "更新 \(names(id)) 的口令" }
            if !changes.isEmpty { return "更新 \(names(id)) 的地址" }
            return tokenChanged ? "更新 \(names(id)) 的口令" : "重新连接 \(names(id))"
        case .add?: return "添加为新电脑"
        case nil: return "再试一次"
        }
    }

    /// 提交没成时说什么（成了 = nil）
    static func failure(_ result: CCHubRegistry.AddResult, names: (String) -> String) -> String? {
        switch result {
        case .added: return nil
        case .duplicateToken(let id): return "这个口令已经是「\(names(id))」在用了：同一台电脑别加两次"
        case .duplicateIdentity(let id): return "这台就是「\(names(id))」，已经接着了"
        case .secretWriteFailed: return Self.secretWriteFailed
        }
    }

    static func failure(_ result: CCHubRegistry.UpdateResult, target: String, names: (String) -> String) -> String? {
        switch result {
        case .updated: return nil
        case .duplicateToken(let id): return "这个口令已经是「\(names(id))」在用了，没改「\(names(target))」"
        case .duplicateIdentity(let id): return "这台其实是「\(names(id))」，没改「\(names(target))」"
        case .differentMachine: return "这是另一台电脑，不能拿来更新「\(names(target))」"
        case .secretWriteFailed: return Self.secretWriteFailed
        }
    }

    static let secretWriteFailed = "口令没存进钥匙串，什么都没改，再试一次"

    /// ws:// 连的是公网地址（不是局域网 / Tailscale / 本机）：明文过公网，管理页一行灰字提醒，不拦
    static func isPlaintextPublic(_ address: String?) -> Bool {
        guard let address, let url = URL(string: address), url.scheme == "ws", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") || host == "::1" { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return false
        case (172, 16...31): return false
        case (100, 64...127): return false
        default: return true
        }
    }
}
