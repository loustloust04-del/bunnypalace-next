#if os(iOS)
import SwiftUI
import Observation

/// 终端页当前停在哪：首页 / 某个 Agent session / 某个全局窗口 / 手机里的小电脑的某个 shell（#045）
enum TerminalTarget: Hashable {
    case home
    case agent(String)
    case window(String)
    case local(String)

    /// hub 那边的 session 名。小电脑的 shell 不在 hub 上，为 nil
    var sessionName: String? {
        switch self {
        case .home, .local: return nil
        case .agent(let session): return session
        case .window(let code): return "mp-win-\(code)"
        }
    }
}

/// tab 条上的一项（⌂ 除外）。标题已经过重名编号。
struct TerminalTabItem: Identifiable, Equatable {
    let target: TerminalTarget
    let title: String
    let engine: TerminalEngine
    let dot: TerminalDot?
    /// 全局窗口才有：收起 / 结束只对它们有意义
    let window: TerminalWindowInfo?

    var id: TerminalTarget { target }
}

/// 改名弹窗的对象：全局窗口给 code，对话 Agent 给 session 名（hub 两种都认）
struct TerminalRenameRequest: Identifiable {
    let id: String
    var text: String
}

/// tab 条、窗口面板、首页共用的状态和动作。界面一律经这里改 target，不各自乱切。
@MainActor
@Observable
final class TerminalPanelModel {
    var target: TerminalTarget?
    /// tab 条最左边那个「这条对话的 Agent」。普通对话为 nil（D3：不再落到 mp-cc）
    var pinnedAgent: String?
    /// 当前 attach 的 session 最近一次用量帧（窗口面板底部那行）
    var usage: TerminalUsage = .empty
    /// 「重新绘制画面」：当前 session 的终端看到它变了就重拉快照
    var refreshSeq = 0

    var showWindowPanel = false
    var panelExpandsClosed = false
    var showSandbox = false
    var showConnect = false
    var renaming: TerminalRenameRequest?
    var ending: TerminalWindowInfo?
    /// 要结束的小电脑 shell（二次确认，D1）
    var endingLocal: String?
    /// 当前楼层（小电脑 shell 起在它的文件库里）。终端页 Root 跟着楼层更新
    var profileId: String?

    private var store: TerminalWindowStore { .shared }
    private var localStore: ISHTerminalSessionStore { .shared }
    /// 刚开出来 / 恢复回来、列表还没跟上的窗口：别被「窗口没了」误判踢走。
    /// 值是记下时 store 的 `syncSeq`，下一次权威对账到了就到期
    @ObservationIgnored private var freshCodes: [String: Int] = [:]
    /// 发了 end_window 还没回音的（client 那边 5 秒 / 断连必回一次）
    @ObservationIgnored private var pendingEnds: Set<String> = []

    var current: TerminalTarget { target ?? .home }

    /// tab 条 / 窗口面板的条目：Agent 固定项 + 开着的窗口，重名统一编号
    var tabItems: [TerminalTabItem] {
        var raw: [(TerminalTarget, String, TerminalEngine, TerminalDot?, TerminalWindowInfo?)] = []
        if let session = pinnedAgent {
            let state = store.sessionStates[session]
            let engine = TerminalEngine.forAgentSession(session, reported: state?.engine)
            raw.append((.agent(session),
                        TerminalTitle.resolve(title: state?.title, engine: engine.rawName, code: session),
                        engine,
                        TerminalDot.resolve(phase: state?.phase, dead: state.map { !$0.alive } ?? false),
                        nil))
        }
        for window in store.windows {
            let engine = TerminalEngine.forWindow(reported: window.engine)
            raw.append((.window(window.code),
                        TerminalTitle.resolve(title: window.title, engine: engine.rawName, code: window.code),
                        engine,
                        TerminalDot.resolve(phase: window.phase, dead: store.isStale || !window.alive),
                        window))
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
            TerminalTabItem(target: item.0, title: name, engine: item.2, dot: item.3, window: item.4)
        }
    }

    // MARK: 切换

    func select(_ target: TerminalTarget) {
        self.target = target
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
        guard case .window(let code) = current else { return }
        if store.windows.contains(where: { $0.code == code }) {
            freshCodes[code] = nil
            return
        }
        if let seq = freshCodes[code], seq == store.syncSeq { return }
        freshCodes[code] = nil
        guard !store.closed.contains(where: { $0.code == code }) else { return }
        select(pinnedAgent.map(TerminalTarget.agent) ?? .home)
    }

    /// 收起 / 结束当前那个后停哪：相邻的窗口，没有了就回首页（「窗口全收起时默认停在首页」）
    private func leave(_ code: String) {
        guard current == .window(code) else { return }
        let codes = store.windows.map(\.code)
        guard let index = codes.firstIndex(of: code) else { select(.home); return }
        let rest = codes.filter { $0 != code }
        if rest.isEmpty { select(.home); return }
        select(.window(rest[min(index, rest.count - 1)]))
    }

    // MARK: 窗口操作

    func open(engine: String?) {
        store.open(engine: engine) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let code):
                self.freshCodes[code] = self.store.syncSeq
                self.select(.window(code))
            case .failure(let error):
                ToastCenter.shared.show(Self.failureReason("开不了新窗口", hubReason: error.fromHub ? error.reason : nil))
            }
        }
    }

    func restore(_ code: String) {
        store.restore(code) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let restored):
                self.freshCodes[restored] = self.store.syncSeq
                self.select(.window(restored))
            case .failure(let error):
                ToastCenter.shared.show(Self.failureReason("这个窗口没恢复回来", hubReason: error.fromHub ? error.reason : nil))
            }
        }
    }

    func collapse(_ code: String) {
        leave(code)
        store.close(code)
    }

    /// 结束 = hub 真 kill tmux（D4），不能恢复。调用前已经二次确认过。
    /// 成功后 store 把它从两个列表删掉，当前停在它上面的由 `ejectIfGone` 挪走；失败 / 超时窗口原样留着。
    func end(_ window: TerminalWindowInfo) {
        let code = window.code
        guard pendingEnds.insert(code).inserted else { return }
        store.end(code) { [weak self] result in
            guard let self else { return }
            self.pendingEnds.remove(code)
            guard case .failure(let error) = result else { return }
            switch error {
            case .timedOut: ToastCenter.shared.show("没结束成功：电脑上的 hub 需要更新")
            case .offline: ToastCenter.shared.show("没结束成功：没连上我的电脑")
            case .refused: ToastCenter.shared.show(Self.failureReason("没结束成功"))
            }
        }
    }

    func rename(_ request: TerminalRenameRequest) {
        if localStore.session(request.id) != nil {
            localStore.rename(request.id, to: request.text)
            return
        }
        CCBridgeWebSocketClient.shared.renameWindow(code: request.id, title: request.text)
    }

    func renameRequest(for item: TerminalTabItem) -> TerminalRenameRequest? {
        if case .local(let id) = item.target {
            return TerminalRenameRequest(id: id, text: localStore.session(id)?.title ?? "")
        }
        guard let id = item.window?.code ?? item.target.sessionName else { return nil }
        return TerminalRenameRequest(id: id, text: item.window?.title ?? store.sessionStates[id]?.title ?? "")
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
    private static func failureReason(_ what: String, hubReason: String? = nil) -> String {
        guard CCBridgeWebSocketClient.shared.isConnected else { return "\(what)：没连上我的电脑" }
        if let hubReason { return "\(what)：\(hubReason)" }
        return "\(what)：电脑那边没开出来，等一下再试"
    }
}
#endif
