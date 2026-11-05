import SwiftUI
import SwiftData

// MARK: - 审计台的「台」注册表（plan-memory-audit-home-trial 第二节）
// 首页（`MemoryAuditHome`）照 `AuditStation.all` 一块一块画，不写死几张。
// 加一个台 = `all` 里加一行 + `AuditStationPage` 里接上它的页面。

enum AuditStationID: String, CaseIterable, Hashable, Identifiable {
    case desk     // 整理台：卡片审碎片（人整理）
    case wiki     // wiki：翻页 + 整理提案
    case trial    // 试写台：测提示词和管线（第 ③ 段点亮）
    case recall   // 召回测试台：以后做

    var id: String { rawValue }
}

/// 方块的现场数字：有数就大字 + 旁边一句（「12 没看过」）；没事时数字位置只写一句状态（「都看过了」）
struct AuditStationPulse: Equatable, Sendable {
    var figure: String?
    var label: String
}

/// 算现场数字时拿得到的东西（主线程）；重活自己丢后台
struct AuditStationContext {
    let profileId: String
    let modelContext: ModelContext
}

struct AuditStation: Identifiable {
    /// 方块底色：只用主题令牌，深浅色 / 换主题自动跟
    enum Surface {
        case userBubble        // userBubble 底
        case assistantBubble   // assistantBubble 底
        case outlined          // mainBg 底 + branchIndicator 描边
    }

    let id: AuditStationID
    let name: String
    let icon: String
    let surface: Surface
    /// 方块底下一行小字：这个台干什么
    let note: String
    /// false = 灰着、不能点
    let isOpen: Bool
    /// 现场数字没算出来 / 没有现场数字时，数字位置写的那句
    let placeholder: String
    /// 现场数字怎么算；nil = 没有
    let pulse: (@MainActor (AuditStationContext) async -> AuditStationPulse)?

    static var all: [AuditStation] {
        [
            AuditStation(id: .desk, name: "整理台", icon: "rectangle.stack", surface: .userBubble,
                         note: "一条一张卡：留、删、改", isOpen: true, placeholder: "",
                         pulse: { ctx in
                             let all = SwiftDataMemoryStore().listAll(profileId: ctx.profileId, context: ctx.modelContext)
                             return deskPulse(unreviewed: MemoryAudit.counts(all, filter: MemoryAudit.Filter())[.unreviewed] ?? 0)
                         }),
            AuditStation(id: .wiki, name: "wiki", icon: "book.closed", surface: .assistantBubble,
                         note: "整理好的档案和整理提案", isOpen: true, placeholder: "",
                         pulse: { ctx in
                             let pid = ctx.profileId
                             let (tally, pages) = await Task.detached(priority: .utility) {
                                 let wiki = WikiStore(profileId: pid)
                                 return (proposalTally(WikiProposalStore(wiki: wiki).list()),
                                         wiki.branchPageCounts().reduce(0) { $0 + $1.count })
                             }.value
                             return wikiPulse(pending: tally.pending, unread: tally.unread, pages: pages)
                         }),
            AuditStation(id: .trial, name: "试写台", icon: "flask", surface: .outlined,
                         note: "测提示词和管线准不准", isOpen: false, placeholder: "还在搭",
                         pulse: nil),
            AuditStation(id: .recall, name: "召回测试台", icon: "scope", surface: .outlined,
                         note: "测召回准不准、注入位置", isOpen: false, placeholder: "以后做",
                         pulse: nil),
        ]
    }

    static func deskPulse(unreviewed: Int) -> AuditStationPulse {
        unreviewed > 0 ? AuditStationPulse(figure: "\(unreviewed)", label: "没看过") : AuditStationPulse(figure: nil, label: "都看过了")
    }

    /// 待批（条目等她批）和待阅（没收进页、她还没看过）分开数（astra P3：`pendingItemCount` 是两样的和）
    static func wikiPulse(pending: Int, unread: Int, pages: Int) -> AuditStationPulse {
        if pending > 0 {
            return AuditStationPulse(figure: "\(pending)", label: unread > 0 ? "待批 · \(unread) 待阅" : "待批")
        }
        if unread > 0 { return AuditStationPulse(figure: "\(unread)", label: "待阅") }
        return AuditStationPulse(figure: nil, label: pages > 0 ? "\(pages) 页 · 没有待批" : "还没有页")
    }

    /// wiki 台「整理提案」那一段的段名，同一套分开数
    static func proposalsSegmentTitle(pending: Int, unread: Int) -> String {
        switch (pending > 0, unread > 0) {
        case (true, true): return "整理提案 \(pending) · 待阅 \(unread)"
        case (true, false): return "整理提案 \(pending)"
        case (false, true): return "整理提案 · 待阅 \(unread)"
        case (false, false): return "整理提案"
        }
    }

    static func proposalTally(_ proposals: [WikiProposal]) -> (pending: Int, unread: Int) {
        proposals.reduce((0, 0)) { ($0.0 + $1.pendingCount, $0.1 + $1.unreadCount) }
    }
}

/// 现场数字刷新（astra P2）：`.task` / 记忆变动 / C3 跑完各要一次，跑着时再要的合成一次、排在后面跑，同一时刻只跑一份。
/// 每跑一次领一张递增的票；回写前 `isCurrent` 核票——后面又有人要刷新、切了楼层（`invalidate`）、取消了（`cancel`）都算旧票，结果扔掉
@MainActor
final class AuditRefreshQueue {
    typealias Work = @MainActor (_ ticket: Int) async -> Void

    private(set) var ticket = 0
    private var work: Work?
    private var dirty = false
    private var task: Task<Void, Never>?
    private var runId = 0

    var isIdle: Bool { task == nil }

    func request(_ work: @escaping Work) {
        self.work = work
        dirty = true
        guard task == nil else { return }
        runId += 1
        let id = runId
        task = Task {
            while dirty, !Task.isCancelled, let work = self.work {
                dirty = false
                ticket += 1
                await work(ticket)
            }
            if runId == id { task = nil }
        }
    }

    func isCurrent(_ t: Int) -> Bool { t == ticket && !dirty && !Task.isCancelled }

    /// 切楼层：飞着的那张作废（排着的照跑，跑时读的是新楼层）
    func invalidate() { ticket += 1 }

    /// 页面走了：停掉，飞着的作废
    func cancel() {
        task?.cancel()
        task = nil
        dirty = false
        ticket += 1
    }
}

/// 点进一个台推的页面
struct AuditStationPage: View {
    let id: AuditStationID
    var viewState: MemoryAuditViewState
    let viewModel: ConversationViewModel?

    var body: some View {
        switch id {
        case .desk:
            MemoryAuditPage(viewState: viewState)
        case .wiki:
            MemoryWikiPage(viewState: viewState, viewModel: viewModel)
        case .trial, .recall:
            // 灰着点不进来；防万一推进来了也不空白
            MemoryEmptyState(title: "还没开放", message: "以后在这里")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolPageBackground()
        }
    }
}
