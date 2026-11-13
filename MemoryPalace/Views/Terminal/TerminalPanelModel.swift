#if os(iOS)
import SwiftUI
import Observation

/// 终端页当前停在哪：首页 / 某个 Agent session / 某个全局窗口 / 手机里的小电脑的某个 shell（#045）。
/// hub 上的两种带着在哪台（plan-multi-hub B3.4）：两台都有 `mp-cc` 也分得开
enum TerminalTarget: Hashable {
    case home
    case agent(hub: String, session: String)
    case window(hub: String, code: String)
    case local(String)

    /// hub 那边的 session 名。小电脑的 shell 不在 hub 上，为 nil
    var sessionName: String? {
        switch self {
        case .home, .local: return nil
        case .agent(_, let session): return session
        case .window(_, let code): return "mp-win-\(code)"
        }
    }

    /// 在哪台 hub 上。小电脑的 shell / 首页为 nil
    var hubId: String? {
        switch self {
        case .home, .local: return nil
        case .agent(let hub, _), .window(let hub, _): return hub
        }
    }
}

/// tab 条最左边那个「这条对话的 Agent」：哪台 hub 上的哪个 session
struct TerminalAgentRef: Hashable {
    let hubId: String
    let session: String

    var target: TerminalTarget { .agent(hub: hubId, session: session) }
}

/// tab 条上的一项（⌂ 除外）。标题已经过重名编号。
struct TerminalTabItem: Identifiable, Equatable {
    let target: TerminalTarget
    let title: String
    let engine: TerminalEngine
    let dot: TerminalDot?
    /// 全局窗口才有：收起 / 结束只对它们有意义
    let window: TerminalWindowInfo?
    /// ≥2 台时那条在哪台电脑上（tab 条 / 窗口面板的电脑名标签）；1 台 / 小电脑为 nil
    var hubName: String? = nil

    var id: TerminalTarget { target }
}

/// 某台 hub 上的一个全局窗口（结束确认框要知道发给哪台）
struct TerminalHubWindow {
    let hubId: String
    let window: TerminalWindowInfo

    var key: String { "\(hubId)|\(window.code)" }
}

/// 改名弹窗的对象：全局窗口给 code，对话 Agent 给 session 名（hub 两种都认）；hubId = 发给哪台，小电脑的 shell 为 nil
struct TerminalRenameRequest: Identifiable {
    let id: String
    var text: String
    var hubId: String? = nil
}

/// tab 条、窗口面板、首页共用的状态和动作。界面一律经这里改 target，不各自乱切。
@MainActor
@Observable
final class TerminalPanelModel {
    var target: TerminalTarget?
    /// tab 条最左边那个「这条对话的 Agent」。普通对话为 nil（D3：不再落到 mp-cc）
    var pinnedAgent: TerminalAgentRef?
    /// ＋ 菜单 / ⌘T 新开窗口开在哪台：≥2 台时 ＋ 菜单顶上「在哪台」选，记住上次选的；那台删了 / 1 台 = 主 hub（B4.3）。
    /// tab 条 / 窗口面板 / 「最近」放全部电脑的（B4.2c），首页每台一行明说开在哪台
    var hubId: String {
        get { TerminalHubChoice.resolve(chosenHubId, hubs: hubs.map(\.id)) }
        set {
            chosenHubId = newValue
            TerminalHubChoice.save(newValue)
        }
    }
    private var chosenHubId = TerminalHubChoice.load()
    /// 当前 attach 的 session 最近一次用量帧（窗口面板底部那行）
    var usage: TerminalUsage = .empty
    /// 「重新绘制画面」：当前 session 的终端看到它变了就重拉快照
    var refreshSeq = 0

    var showWindowPanel = false
    var panelExpandsClosed = false
    var showSandbox = false
    var showConnect = false
    /// 再接一台（扫码 / 手填 → 认是哪台 → 新增或更新，B4.3）
    var addingHub = false
    /// 底部条「管理这台」开着的那台
    var managingHub: String?
    /// 首页那行「重新扫码」开着的那台（待配对 / 换了机器，B7.2 B3）
    var rescanningHub: String?
    /// 连不上那台「最近」里点了收起的窗口：先停在断桥卡，那台连上后再恢复、恢复成了才接（b4 #8）
    var pendingRestore: (hubId: String, code: String)?
    var renaming: TerminalRenameRequest?
    var ending: TerminalHubWindow?
    /// 要结束的小电脑 shell（二次确认，D1）
    var endingLocal: String?
    /// 当前楼层（小电脑 shell 起在它的文件库里）。终端页 Root 跟着楼层更新
    var profileId: String?

    /// 选中那台的窗口表 / 连接。那台不在了（删掉）→ nil，窗口操作一律不做
    var store: TerminalWindowStore? { CCHubRegistry.shared.windowStore(for: hubId) }
    var client: CCBridgeWebSocketClient? { try? CCHubRegistry.shared.route(hubId).get() }
    private var localStore: ISHTerminalSessionStore { .shared }
    /// 刚开出来 / 恢复回来、列表还没跟上的窗口：别被「窗口没了」误判踢走。
    /// 值是记下时 store 的 `syncSeq`，下一次权威对账到了就到期
    @ObservationIgnored private var freshCodes: [String: Int] = [:]
    /// 发了 end_window 还没回音的（client 那边 5 秒 / 断连必回一次）
    @ObservationIgnored private var pendingEnds: Set<String> = []

    var current: TerminalTarget { target ?? .home }

    /// 名单里的电脑：主电脑第一，其余按添加顺序
    var hubs: [CCHubRegistry.HubProfile] { CCHubRegistry.shared.hubs }
    var isMultiHub: Bool { hubs.count >= 2 }

    /// ≥2 台才给电脑名（1 台什么都不多出）
    func hubName(_ id: String?) -> String? {
        guard let id, isMultiHub else { return nil }
        return hubs.first { $0.id == id }?.name
    }

    /// 所有电脑的窗口表（tab 条 / 窗口面板 / 同步都跟全部电脑）
    var hubStores: [(hubId: String, store: TerminalWindowStore)] {
        hubs.compactMap { hub in CCHubRegistry.shared.windowStore(for: hub.id).map { (hub.id, $0) } }
    }

    /// tab 条 / 窗口面板的条目：Agent 固定项 + 每台开着的窗口（主电脑在前）+ 小电脑，重名统一编号
    var tabItems: [TerminalTabItem] {
        var raw: [(TerminalTarget, String, TerminalEngine, TerminalDot?, TerminalWindowInfo?)] = []
        if let pinned = pinnedAgent, !TerminalHubPrune.isGone(pinned.hubId, hubs: Set(hubs.map(\.id))) {
            let session = pinned.session
            let state = CCHubRegistry.shared.windowStore(for: pinned.hubId)?.sessionStates[session]
            let engine = TerminalEngine.forAgentSession(session, reported: state?.engine)
            raw.append((pinned.target,
                        TerminalTitle.resolve(title: state?.title, engine: engine.rawName, code: session),
                        engine,
                        TerminalDot.resolve(phase: state?.phase, dead: state.map { !$0.alive } ?? false),
                        nil))
        }
        for (hub, store) in hubStores {
            for window in store.windows {
                let engine = TerminalEngine.forWindow(reported: window.engine)
                raw.append((.window(hub: hub, code: window.code),
                            TerminalTitle.resolve(title: window.title, engine: engine.rawName, code: window.code),
                            engine,
                            TerminalDot.resolve(phase: window.phase, dead: store.isStale || !window.alive),
                            window))
            }
        }
        for session in localStore.sessions {
            let dead: Bool
            switch session.state {
            case .exited, .failed: dead = true
            case .starting, .running: dead = false
            }
            raw.append((.local(session.id), session.title, .phone, dead ? .dead : nil, nil))
        }
        let names = TerminalNames.numbered(raw.map { $0.1 })
        return zip(raw, names).map { item, name in
            TerminalTabItem(target: item.0, title: name, engine: item.2, dot: item.3, window: item.4,
                            hubName: hubName(item.0.hubId))
        }
    }

    // MARK: 切换

    func select(_ target: TerminalTarget) {
        self.target = target
        if let pending = pendingRestore, target != .window(hub: pending.hubId, code: pending.code) { pendingRestore = nil }
    }

    /// 删了一台（名单变了）：固定的 Agent、当前停的、改名 / 结束 / 管理 / 重新扫码弹窗只要指着它就收掉（b4 #6）
    func pruneRemovedHubs() {
        let ids = Set(hubs.map(\.id))
        if TerminalHubPrune.isGone(pinnedAgent?.hubId, hubs: ids) { pinnedAgent = nil }
        if TerminalHubPrune.isGone(current.hubId, hubs: ids) { select(.home) }
        if TerminalHubPrune.isGone(renaming?.hubId, hubs: ids) { renaming = nil }
        if TerminalHubPrune.isGone(ending?.hubId, hubs: ids) { ending = nil }
        if TerminalHubPrune.isGone(managingHub, hubs: ids) { managingHub = nil }
        if TerminalHubPrune.isGone(rescanningHub, hubs: ids) { rescanningHub = nil }
    }

    func refresh(_ target: TerminalTarget) {
        if current == target { refreshSeq += 1 } else { select(target) }
    }

    /// 当前停着的窗口从 hub 那边没了（结束成功时 hub 先推一帧不含它的 terminal_state，再回 window_ended；
    /// 或者别处结束了它）→ 落回这条对话的 Agent，没有就回首页，别留一块死终端。收起的不算（它还在 closed 里）。
    func ejectIfGone() {
        if case .local(let id) = current {
            if localStore.session(id) == nil { select(.home) }
            return
        }
        guard case .window(let hub, let code) = current else { return }
        // 那台删了：窗口跟着没了
        guard let store = CCHubRegistry.shared.windowStore(for: hub) else { select(pinnedAgent?.target ?? .home); return }
        if store.windows.contains(where: { $0.code == code }) {
            freshCodes[code] = nil
            return
        }
        if let seq = freshCodes[code], seq == store.syncSeq { return }
        freshCodes[code] = nil
        guard !store.closed.contains(where: { $0.code == code }) else { return }
        select(pinnedAgent?.target ?? .home)
    }

    /// 收起 / 结束当前那个后停哪：同一台上相邻的窗口，没有了就回首页（「窗口全收起时默认停在首页」）
    private func leave(_ code: String, hub: String) {
        guard current == .window(hub: hub, code: code) else { return }
        let codes = CCHubRegistry.shared.windowStore(for: hub)?.windows.map(\.code) ?? []
        guard let index = codes.firstIndex(of: code) else { select(.home); return }
        let rest = codes.filter { $0 != code }
        if rest.isEmpty { select(.home); return }
        select(.window(hub: hub, code: rest[min(index, rest.count - 1)]))
    }

    // MARK: 窗口操作

    /// hub：开在哪台，nil = 默认那台（＋ 菜单 / ⌘T）
    func open(engine: String?, hub: String? = nil) {
        let hub = hub ?? hubId
        guard let store = CCHubRegistry.shared.windowStore(for: hub) else {
            ToastCenter.shared.show(CCHubRegistry.Unavailable.removed.message)
            return
        }
        store.open(engine: engine) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let code):
                self.freshCodes[code] = store.syncSeq
                self.select(.window(hub: hub, code: code))
            case .failure(let error):
                ToastCenter.shared.show(self.failureReason("开不了新窗口", hub: hub, hubReason: error.fromHub ? error.reason : nil))
            }
        }
    }

    func restore(_ code: String, hub: String) {
        guard let store = CCHubRegistry.shared.windowStore(for: hub) else { return }
        store.restore(code) { [weak self] result in
            guard let self else { return }
            let waited = self.pendingRestore.map { $0.hubId == hub && $0.code == code } == true
            switch result {
            case .success(let restored):
                self.pendingRestore = nil
                self.freshCodes[restored] = store.syncSeq
                self.select(.window(hub: hub, code: restored))
            case .failure(let error):
                ToastCenter.shared.show(self.failureReason("这个窗口没恢复回来", hub: hub, hubReason: error.fromHub ? error.reason : nil))
                if waited, self.current == .window(hub: hub, code: code) { self.select(.home) }
            }
        }
    }

    /// 「最近」里收起的窗口：那台连着就直接恢复；连不上先进断桥卡等它（b4 #8）
    func openClosed(_ code: String, hub: String) {
        guard (try? CCHubRegistry.shared.route(hub).get())?.isConnected != true else { restore(code, hub: hub); return }
        select(.window(hub: hub, code: code))
        pendingRestore = (hub, code)
    }

    func collapse(_ code: String, hub: String) {
        leave(code, hub: hub)
        CCHubRegistry.shared.windowStore(for: hub)?.close(code)
    }

    /// 结束 = hub 真 kill tmux（D4），不能恢复。调用前已经二次确认过。
    /// 成功后 store 把它从两个列表删掉，当前停在它上面的由 `ejectIfGone` 挪走；失败 / 超时窗口原样留着。
    func end(_ ref: TerminalHubWindow) {
        let code = ref.window.code
        let hub = ref.hubId
        guard let store = CCHubRegistry.shared.windowStore(for: hub), pendingEnds.insert("\(hub)|\(code)").inserted else { return }
        store.end(code) { [weak self] result in
            guard let self else { return }
            self.pendingEnds.remove("\(hub)|\(code)")
            guard case .failure(let error) = result else { return }
            switch error {
            case .timedOut: ToastCenter.shared.show("没结束成功：电脑上的 hub 需要更新")
            case .offline: ToastCenter.shared.show("没结束成功：没连上我的电脑")
            case .refused: ToastCenter.shared.show(self.failureReason("没结束成功", hub: hub))
            }
        }
    }

    func rename(_ request: TerminalRenameRequest) {
        if localStore.session(request.id) != nil {
            localStore.rename(request.id, to: request.text)
            return
        }
        // 回到弹窗打开时那台（不按现在选中哪台）；那台用不了就不发
        guard let hub = request.hubId else { return }
        switch CCHubRegistry.shared.route(hub) {
        case .success(let client): client.renameWindow(code: request.id, title: request.text)
        case .failure(let why): ToastCenter.shared.show(why.message)
        }
    }

    func renameRequest(for item: TerminalTabItem) -> TerminalRenameRequest? {
        if case .local(let id) = item.target {
            return TerminalRenameRequest(id: id, text: localStore.session(id)?.title ?? "")
        }
        guard let id = item.window?.code ?? item.target.sessionName, let hub = item.target.hubId else { return nil }
        let states = CCHubRegistry.shared.windowStore(for: hub)?.sessionStates
        return TerminalRenameRequest(id: id, text: item.window?.title ?? states?[id]?.title ?? "", hubId: hub)
    }

    // MARK: 手机里的小电脑（#045）

    /// 开一个新的小电脑 shell 并切过去，起点是当前楼层的文件库。满 4 个 toast（D2）
    func openLocal() {
        guard let profileId else { return }
        guard let session = localStore.open(profileId: profileId) else {
            ToastCenter.shared.show(localStore.resetting
                ? "小电脑正在重置，重启 App 后再开"
                : "最多开 \(ISHTerminalSessionStore.maxSessions) 个小电脑终端，先关掉一个")
            return
        }
        select(.local(session.id))
    }

    /// 结束 = 杀掉里面跑的一切（文件还在）。调用前已经二次确认过
    func endLocal(_ id: String) {
        if current == .local(id) {
            let ids = tabItems.map(\.target)
            if let index = ids.firstIndex(of: .local(id)) {
                let rest = ids.filter { $0 != .local(id) }
                select(rest.isEmpty ? .home : rest[min(index, rest.count - 1)])
            } else {
                select(.home)
            }
        }
        localStore.end(id)
    }

    /// hubReason：失败回帧里 hub 给的中文原因（新 hub 才有，#046）；老 hub 只会是「hub 没给 code」这类，照旧说通用那句
    private func failureReason(_ what: String, hub: String, hubReason: String? = nil) -> String {
        guard (try? CCHubRegistry.shared.route(hub).get())?.isConnected == true else { return "\(what)：没连上我的电脑" }
        if let hubReason { return "\(what)：\(hubReason)" }
        return "\(what)：电脑那边没开出来，等一下再试"
    }
}
#endif
