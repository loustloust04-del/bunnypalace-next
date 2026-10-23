#if os(macOS)
import Foundation

// Portions adapted from Wake v0.6.3 (MIT, Copyright (c) 2026 Corey Chiu, github.com/iAmCorey/Wake) — see THIRD_PARTY_LICENSES.md
// W-N 编程会话库（plan-wake-native）。模型与解析规则照 Wake v0.6.3 `crates/wake-core`
// （MIT，github.com/iAmCorey/Wake）移植：列表扫描与详情共用同一解析器，索引 seq = 详情消息序号。

/// 16 家，声明序 = Wake `AgentId::ALL`（= 展示序 = 下拉序）；rawValue = Wake `as_str`（索引 agent_id / key 前缀）
enum CodingAgent: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case grok
    case dsh
    case cursor
    case opencode
    case pi
    case omp
    case kiro
    case kimi
    case gemini
    case copilot
    case antigravity
    case qoder
    case hermes
    case openclaw

    /// Wake `display_name`
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok Build"
        case .dsh: return "DeepSeek Harness"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        case .omp: return "Oh My Pi"
        case .kiro: return "Kiro"
        case .kimi: return "Kimi Code"
        case .gemini: return "Gemini CLI"
        case .copilot: return "Copilot CLI"
        case .antigravity: return "Antigravity CLI"
        case .qoder: return "Qoder CLI"
        case .hermes: return "Hermes Agent"
        case .openclaw: return "OpenClaw"
        }
    }

    /// 筛选胶囊用的短名（去掉 Code / CLI / Build / Agent 这类后缀）
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .grok: return "Grok"
        case .dsh: return "DeepSeek"
        case .kimi: return "Kimi"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .antigravity: return "Antigravity"
        case .qoder: return "Qoder"
        case .hermes: return "Hermes"
        default: return displayName
        }
    }
}

enum CodingRole: String, Sendable {
    case user, assistant, system
}

enum CodingMessageKind: String, Sendable {
    case text
    case meta
    case compactSummary = "compact-summary"
}

enum CodingLimits {
    /// 单条消息正文入库 / 显示上限
    static let maxMessageText = 32 * 1024
    /// 工具输入输出、thinking 上限
    static let maxToolIO = 16 * 1024
    static let maxTitle = 80
    /// 无标题占位（存储值；界面显示成「未命名会话」）
    static let untitled = "Untitled"
    static let imagePlaceholder = "[image]"
}

struct CodingToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var inputPreview: String
    var input: String?
    var output: String?
    var isError: Bool
    var sidechainRef: String?
}

struct CodingMessage: Sendable, Equatable {
    var seq: Int
    var role: CodingRole
    var kind: CodingMessageKind
    var text: String
    var truncated: Bool
    var toolCalls: [CodingToolCall] = []
    var thinking: String?
    /// epoch ms
    var timestamp: Int64?
    var model: String?
    /// 图片块总数：详情路径解出来的进 images，解不了的（远程链接 / 超限 / 索引路径）在正文里是 `[image]`
    var imageCount: Int = 0
    var images: [CodingImage] = []

    static func make(_ role: CodingRole, _ kind: CodingMessageKind, _ text: String, ts: Int64, clip: Bool) -> CodingMessage {
        let (body, truncated) = clip ? CodingParse.clip(text, CodingLimits.maxMessageText) : (text, false)
        return CodingMessage(seq: 0, role: role, kind: kind, text: body, truncated: truncated, timestamp: ts > 0 ? ts : nil)
    }
}

struct CodingSidechain: Sendable, Equatable {
    var id: String
    var agentType: String?
    var description: String?
    var toolUseId: String?
}

struct CodingSessionMeta: Sendable, Equatable, Identifiable {
    /// 全局唯一键：本机 `{agent}:{native_id}`，远程 `{agent}:{host}:{native_id}`（`CodingSessionKey`）
    var key: String
    /// 原生会话 id（续跑用）
    var nativeId: String
    var agent: CodingAgent
    var title: String
    var projectPath: String
    var projectName: String
    var filePath: String
    var createdAt: Int64
    var updatedAt: Int64
    var messageCount: Int
    var sizeBytes: Int64
    var gitBranch: String?
    var model: String?
    var tokensUsed: Int64?
    var archived: Bool
    var source: String?
    /// 父会话 key（Grok 子代理 / Hermes 分支续段；空 = 根会话，plan-wake-native-n3 S8）
    var parentKey: String = ""
    /// 远程主机名（空 = 本机；N4，Wake `meta.host`）
    var host: String = ""

    var id: String { key }
}

struct CodingSessionFileRef: Sendable, Equatable {
    var agent: CodingAgent
    var nativeId: String
    var filePath: String
    var mtimeMs: Int64
    var size: Int64
}

extension CodingSessionFileRef {
    /// 按索引里的 meta 造引用（Wake `SessionFileRef::from_meta`）：SQLite 家的 `库#id` 虚拟路径 adapter.fileRef 认不了（默认实现只认
    /// .jsonl 实文件），详情 / 导出 / 子代理 / AI 工具读它们都走这里。mtime / size 取磁盘上的，取不到（虚拟路径）退回索引里的；
    /// 底层文件都不在了回 nil
    static func fromMeta(_ meta: CodingSessionMeta) -> CodingSessionFileRef? {
        guard FileManager.default.fileExists(atPath: CodingVirtualPath.strip(meta.filePath)) else { return nil }
        let values = try? URL(fileURLWithPath: meta.filePath).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CodingSessionFileRef(agent: meta.agent, nativeId: meta.nativeId, filePath: meta.filePath,
                                    mtimeMs: values?.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? meta.updatedAt,
                                    size: values?.fileSize.map(Int64.init) ?? meta.sizeBytes)
    }
}

struct CodingIndexUnit: Sendable, Equatable {
    var seq: Int
    var role: CodingRole
    var timestamp: Int64?
    var text: String
}

struct CodingParsedSession: Sendable {
    var meta: CodingSessionMeta
    var units: [CodingIndexUnit]
    var unknownLines: Int
}

struct CodingParsedTranscript: Sendable {
    var meta: CodingSessionMeta
    var mainline: [CodingMessage]
    var sidechains: [CodingSidechain]
    var unknownLines: Int
}

struct CodingProjectInfo: Sendable, Equatable, Identifiable {
    var path: String
    var name: String
    var sessionCount: Int
    var lastActive: Int64

    var id: String { path }
}

enum CodingSessionError: LocalizedError {
    case unreadable(String)
    case sqlite(String)
    case sqliteTooOld(String)
    case indexMissing(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message): return "读不了会话文件：\(message)"
        case .sqlite(let message): return "编程会话索引出错：\(message)"
        case .sqliteTooOld(let version): return "系统 SQLite \(version) 太旧（全文检索要 ≥ 3.34）"
        case .indexMissing(let path): return "编程会话索引还不存在（\(path)）——先在记忆花园里打开一次 code 组"
        }
    }
}
#endif
