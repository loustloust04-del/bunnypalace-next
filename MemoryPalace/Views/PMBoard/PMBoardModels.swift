#if PERSONAL_APPS
#if DEBUG
import SwiftUI

// MARK: - page2 pmBoard 子应用的数据（docs/plan-pm-board-app.md §2.1 / docs/plan-dev-subapp-v2.md §3）
// 字段对 Mac 上 session 看板服务 4793 的 /api/home、/api/board?view=phone、/api/session（scripts/pm/phone.ts），经 hub pm_req 帧转来。
// 只进 Debug：只有粟粟的 Mac 上跑着 4793。

extension Notification.Name {
    /// userInfo: ["type": String（pm_req_result 等）, "data": Data（整帧原文）]
    static let pmBoardFrame = Notification.Name("pmBoardFrame")
}

enum PMState: String, Decodable, CaseIterable {
    case wait, busy, external, idle

    var title: String {
        switch self {
        case .wait: "在等你"
        case .busy: "在忙"
        case .external: "等外部"
        case .idle: "闲着"
        }
    }
    /// 看板 board.html 同一套四色
    var color: Color {
        switch self {
        case .wait: Color(hex: 0xC98F9E)
        case .busy: Color(hex: 0x6F9A80)
        case .external: Color(hex: 0x9B93B8)
        case .idle: Color(hex: 0xA7ACA6)
        }
    }
}

struct PMCounts: Decodable {
    let wait: Int
    let external: Int
    let busy: Int
    let idle: Int
    func count(_ s: PMState) -> Int {
        switch s { case .wait: wait; case .busy: busy; case .external: external; case .idle: idle }
    }
}

struct PMLight: Decodable, Identifiable {
    let k: String
    let tone: String
    let text: String
    var id: String { k }
    var color: Color {
        switch tone {
        case "warn": PMState.wait.color
        case "busy": PMState.external.color
        case "ok": PMState.busy.color
        default: PMState.idle.color
        }
    }
}

struct PMCall: Decodable, Identifiable {
    let at: Double
    let atText: String
    let src: String
    let srcText: String
    let label: String
    let text: String
    let sid: String?
    let who: String
    let live: Bool
    let recent: Bool
    var id: String { "\(at)-\(src)-\(sid ?? label)" }
}

struct PMBadges: Decodable {
    let merges: Int
    let mergeAsk: Bool
    let devices: [String]
    let build: String?
    let agents: Int
}

struct PMSession: Decodable, Identifiable {
    let sid: String
    let name: String
    let role: String?
    let zone: String?
    let cwdShort: String
    let state: PMState
    let stateText: String
    let garden: Bool
    let host: String
    let openable: Bool
    let doing: String
    let lastActive: Double
    let badges: PMBadges
    var id: String { sid }
}

struct PMNode: Decodable, Identifiable {
    let kind: String
    let sid: String?
    let name: String?
    let aid: String?
    let label: String?
    let children: [PMNode]
    var id: String { sid ?? aid ?? name ?? kind }
}

struct PMTile: Decodable, Identifiable {
    let label: String
    let cur: Double?
    let prev: Double?
    let fmt: String
    let better: String
    let main: Bool
    let sub: String
    var id: String { label }
}

struct PMKpi: Decodable {
    let windowText: String
    let error: String?
    let alerts: [String]
    let tiles: [PMTile]
}

struct PMBoard: Decodable {
    let generatedAt: Double
    let generatedText: String
    let counts: PMCounts
    let lights: [PMLight]
    let calls: [PMCall]
    let sessions: [PMSession]
    let tree: PMNode
    let unassigned: [PMNode]
    let kpi: PMKpi?
    let errors: [String]
}

// MARK: - 对话列表（/api/home，docs/plan-dev-subapp-v2.md §3.2）

struct PMPreview: Decodable {
    let who: String           // self = 它自己说的；其余是说话人（粟粟 / 上级名）
    let text: String
    let at: Double
}

struct PMUnanswered: Decodable {
    let n: Int
    let lastAt: Double
    let lastText: String
}

struct PMPerson: Decodable, Identifiable {
    let sid: String
    let displayName: String
    let rawName: String
    let title: String?
    let kind: String          // steward | planner | worker
    let scope: String         // garden | other
    let project: String
    let zones: [String]
    let state: PMState
    let stateText: String
    let preview: PMPreview?
    let lastAt: Double
    let unanswered: PMUnanswered?
    let badges: PMBadges
    let openable: Bool
    let pinnedDefault: Bool
    let parent: String?
    let attachments: [String]?
    var id: String { sid }

    /// 名字后面那一小段：头衔，没有就第一个工位
    var subtitle: String? { title ?? zones.first }
    var searchText: String { ([displayName, rawName, title ?? "", project, preview?.text ?? ""] + zones).joined(separator: " ") }
}

struct PMStripItem: Decodable {
    let tone: String
    let text: String
    var color: Color { PMLight(k: "", tone: tone, text: text).color }
}

struct PMDing: Decodable {
    let at: Double
    let text: String
    let src: String
    let sid: String?
}

struct PMStrip: Decodable {
    let build: PMStripItem?
    let device: PMStripItem?
    let merge: PMStripItem?
    let frozen: Bool
    let zonePaused: Bool
    let lastDing: PMDing?
}

struct PMHome: Decodable {
    let generatedAt: Double
    let generatedText: String
    let strip: PMStrip
    let people: [PMPerson]
    let dingsToday: Int
    let errors: [String]
}

// MARK: - 详情（三块：想跟你说的话 · 恢复命令 · 最近 50 条）

struct PMAsk: Decodable, Identifiable {
    let kind: String          // permission | merge | verify | call | needsusu
    let text: String
    let at: Double
    let live: Bool
    let answered: Bool
    var id: String { "\(kind)-\(at)-\(text.prefix(20))" }
    var icon: String {
        switch kind {
        case "permission": "hand.raised.fill"
        case "merge": "arrow.triangle.merge"
        case "verify": "iphone"
        case "needsusu": "checklist"
        default: "bell"
        }
    }
}

struct PMTurn: Decodable {
    let who: String           // susu | upper | self
    let name: String?
    let via: String?
    let text: String
    let at: Double
}

/// 4793 outbox 里的一条（先收下、等它空了再送）；sending / failed 是本机还没交到 4793 的
struct PMOutItem: Decodable, Identifiable {
    let id: String
    let sid: String
    let text: String
    let createdAt: Double
    var state: String         // sending | failed（本机）· queued | typing | queued-busy | stuck | sent | cancelled | expired
    var why: String
    let stale: Bool
    let seen: Bool
    var prefix: String? = nil   // 4793 自己送的摘要（【pmBoard·路线图】），不是手机原话

    var isLive: Bool { !["sent", "cancelled", "expired"].contains(state) }
}

struct PMCanSend: Decodable {
    let ok: Bool
    let why: String
    let code: String
    let busy: Bool?
}

struct PMDetail: Decodable {
    let generatedAt: Double
    let sid: String
    let name: String
    let person: PMPerson?
    let asks: [PMAsk]
    let resumeCmd: String
    let turns: [PMTurn]
    let outbox: [PMOutItem]
    let canSend: PMCanSend
}

// MARK: - 占用（/api/occupancy，docs/plan-dev-subapp-v2.md P1-a）

/// 「谁」：活着的能点进详情；人走了的只剩名字（sid 还在也能点，详情页给恢复命令）
struct PMWho: Decodable, Hashable {
    let sid: String?
    let name: String
    let title: String?
    let alive: Bool
}

struct PMOccZone: Decodable, Identifiable {
    let zone: String
    let desc: String
    let exists: Bool
    let owner: PMWho?
    let since: Double?
    let ahead: Int?
    let dirty: Int?
    let warn: String?
    var id: String { zone }
}

struct PMOccBuild: Decodable {
    struct Holder: Decodable { let who: PMWho; let `where`: String; let cmd: String; let since: Double; let state: String; let overloadWhy: String? }
    struct Queued: Decodable, Identifiable { let pos: Int; let who: PMWho; let `where`: String; let cmd: String; let queuedAt: Double?; let prio: Bool; var id: Int { pos } }
    struct Last: Decodable { let `where`: String; let secs: Double?; let ok: Bool; let at: Double }
    let frozen: String?
    let zonePaused: Bool
    let holder: Holder?
    let queue: [Queued]
    let last: Last?
}

struct PMOccDevice: Decodable, Identifiable {
    struct Holder: Decodable { let who: PMWho; let why: String; let label: String; let since: Double; let expires: Double?; let asked: Double?; let pinned: Bool }
    struct Queued: Decodable { let who: PMWho; let label: String }
    let dev: String
    let note: String
    let holder: Holder?
    let queue: [Queued]
    var id: String { dev }
}

struct PMOccMerge: Decodable, Identifiable {
    let id: String
    let branch: String
    let why: String
    let from: String
    let submitted: String
    let resolved: String
    let result: String
    let who: PMWho
}

struct PMOccupancy: Decodable {
    struct Merges: Decodable { let lockHeld: Bool; let processing: [PMOccMerge]; let pending: [PMOccMerge]; let recent: [PMOccMerge] }
    let generatedText: String
    let zones: [PMOccZone]
    let build: PMOccBuild
    let devices: [PMOccDevice]
    let merges: Merges
}

// MARK: - 待验（/api/task，主仓 TASK.md 只读，P1-d）

struct PMTaskItem: Decodable {   // 列表按 line 区分（id 是 TASK.md 编号，可能为空）
    let id: String            // TASK.md 里的编号（她手写没编号的为空）
    let text: String
    let done: Bool
    let line: Int
    let req: String?
    let needs: String?
    let zone: String?
    let who: PMWho?
    let mergedAt: String?

    /// 长按看到的「谁做的」
    var whoLine: String? {
        guard let who else { return req.map { "合并单 #\($0)，对不上人" } }
        var parts = [who.title.map { "\(who.name)（\($0)）" } ?? who.name]
        if !who.alive { parts[0] += " · 已退出" }
        if let zone { parts.append("工位 \(zone)") }
        if let req { parts.append("#\(req)") }
        if let mergedAt { parts.append("\(mergedAt) 合") }
        return parts.joined(separator: " · ")
    }
}

struct PMTaskGroup: Decodable {
    let title: String
    let note: String
    let items: [PMTaskItem]
}

struct PMTaskSection: Decodable {
    let title: String
    let groups: [PMTaskGroup]
}

struct PMTaskBoard: Decodable {
    struct Temp: Decodable { let who: PMWho; let text: String; let at: Double }
    let mtime: Double
    let sections: [PMTaskSection]
    let temp: [Temp]
}

/// hub / 4793 回帧的公共外壳：出错时只有这些
struct PMEnvelope: Decodable {
    let ok: Bool?
    let error: String?
    let message: String?
    let code: String?
    let state: String?
    let req_id: String?
    let http: Int?
    var errorText: String? { ok == false ? (error ?? message ?? "出错了") : nil }
}

/// pm_doc_result：主仓 docs/<name>.html 原文（4793 /api/doc 现读，mtime 毫秒）
struct PMDoc: Decodable {
    let name: String
    let html: String
    let mtime: Double
}

enum PMTime {
    /// 毫秒时间戳 → 「刚刚 / N 分钟前 / N 小时前 / N 天前」
    static func ago(_ ms: Double, now: Date = .now) -> String {
        guard ms > 0 else { return "—" }
        let s = max(0, now.timeIntervalSince1970 - ms / 1000)
        if s < 90 { return "刚刚" }
        if s < 3600 { return "\(Int((s / 60).rounded())) 分钟前" }
        if s < 86400 * 1.5 { return "\(Int((s / 3600).rounded())) 小时前" }
        return "\(Int((s / 86400).rounded())) 天前"
    }
}
#endif
#endif
