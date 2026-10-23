#if os(macOS)
import Foundation

/// agent 数据源适配器（Wake `AgentAdapter`）。枚举必须廉价、绝不全量解析；列表与详情共用同一解析器。
protocol CodingSessionAdapter: Sendable {
    var agent: CodingAgent { get }
    /// 远程主机名（空 = 本机实例；远程实例由 `CodingRemoteAdapter` 装饰，N4）。扫描器的去重域 = `CodingSessionKey.make(agent, host, native)`
    var host: String { get }
    /// 本家会话文件所在根（不论存不存在）
    var dataRoots: [URL] { get }
    func listSessionFiles() -> [CodingSessionFileRef]
    /// 路径 → 会话引用；nil = 非会话文件
    func fileRef(_ url: URL) -> CodingSessionFileRef?
    /// 快路径：不解析文件直接给 meta（Codex 走 state DB），键 = filePath
    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]?
    func mergeQuickMeta(_ parsed: CodingSessionMeta, _ quick: CodingSessionMeta) -> CodingSessionMeta
    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession
    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript
    func loadSidechain(_ ref: CodingSessionFileRef, id: String) throws -> [CodingMessage]
    /// 会话在磁盘上的全部归属路径（删除时一并挪废纸篓）
    func sessionPaths(_ meta: CodingSessionMeta) -> [String]
    /// 一轮扫描开始：刷新实例的共享快照（Grok 归组 / 子代理登记）。全量、增量、父链刷新入口都先调
    func beginScan()
    /// 父子关系由这家的快照给（Grok 子代理、Hermes 分支），扫描器收尾统一同步到 parent_key（Wake `manages_parent_links`）
    var managesParentLinks: Bool { get }
    /// 本实例能确认的直接边 (child key, parent key)；扫描器合并全部实例后再扁平到根
    func parentLinks() -> [(child: String, parent: String)]
    /// 这个路径是关系边车（不是会话主文件）：变了只刷父链
    func isParentLinkEvent(_ path: String) -> Bool
    /// 以自定义数据根造本家的另一个实例（位置 sheet 的「添加位置」）：各家把选中的目录整形成自己默认根的形态（家目录或数据目录
    /// 任一层都认，SQLite 型在里面找库文件），侧档全部相对 dir 派生、不落回默认家（Wake `with_custom_root`，新 adapter 必须实现）
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter
    /// 能否单独移除某条默认数据根（OpenCode 的 stable / next 库彼此独立）；多数家的多个根共同组成一个位置
    var supportsIndividualRootRemoval: Bool { get }
    /// 排除这些数据根后的同类实例（逐行停用 / 单独移除用）；nil = 不支持局部裁剪
    func excludingDataRoots(_ roots: [URL]) -> CodingSessionAdapter?
}

extension CodingSessionAdapter {
    var host: String { "" }

    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        CodingParse.defaultFileRef(agent, url)
    }

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? { nil }

    /// 默认：parsed 为准，quick 只补 source / model / tokens 缺口
    func mergeQuickMeta(_ parsed: CodingSessionMeta, _ quick: CodingSessionMeta) -> CodingSessionMeta {
        var merged = parsed
        if merged.source == nil { merged.source = quick.source }
        if merged.model == nil { merged.model = quick.model }
        if merged.tokensUsed == nil { merged.tokensUsed = quick.tokensUsed }
        return merged
    }

    func loadSidechain(_ ref: CodingSessionFileRef, id: String) throws -> [CodingMessage] { [] }

    func sessionPaths(_ meta: CodingSessionMeta) -> [String] { [meta.filePath] }

    func beginScan() {}

    var managesParentLinks: Bool { false }

    func parentLinks() -> [(child: String, parent: String)] { [] }

    func isParentLinkEvent(_ path: String) -> Bool { false }

    var supportsIndividualRootRemoval: Bool { false }

    func excludingDataRoots(_ roots: [URL]) -> CodingSessionAdapter? { nil }
}

/// 全部 adapter 的唯一构造点。`home` 可注入（测试指向合成 fixture，不碰真目录）
enum CodingSessionRoster {
    static func adapters(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> [CodingSessionAdapter] {
        [
            ClaudeCodeAdapter(root: home.appendingPathComponent(".claude/projects", isDirectory: true)),
            CodexAdapter.make(home: home, environment: environment),
            QoderAdapter.make(home: home, environment: environment),
            CopilotAdapter(home: home),
            CursorAdapter(home: home),
            OpenCodeAdapter.make(home: home, environment: environment),
            KiroAdapter(home: home),
            GeminiAdapter(home: home),
            PiAdapter.make(home: home, agent: .pi),
            PiAdapter.make(home: home, agent: .omp),
            GrokAdapter(home: home),
            KimiCodeAdapter(home: home.appendingPathComponent(".kimi-code", isDirectory: true)),
            AntigravityAdapter(home: home),
            DshAdapter(home: home),
            HermesAdapter.make(home: home, environment: environment),
            OpenClawAdapter.make(home: home, environment: environment),
        ]
    }

    /// 这个文件归哪个实例：**最长数据根**（Wake scanner `owner_of` / watcher `resolve_watch_agent`）——自定义根可以落在
    /// 别家树里、一家可以多实例，按 agent 找第一个会找错。虚拟路径先剥回库路径；前缀相同的兄弟目录不算。nil = 没有根认领
    static func ownerIndex(of path: String, in adapters: [CodingSessionAdapter]) -> Int? {
        let file = CodingParse.canonicalPath(CodingVirtualPath.strip(path))
        var best: (length: Int, index: Int)?
        for (ix, adapter) in adapters.enumerated() {
            for root in adapter.dataRoots {
                let base = CodingParse.canonicalPath(root.path)
                guard file == base || file.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { continue }
                if base.count > (best?.length ?? -1) { best = (base.count, ix) }
            }
        }
        return best?.index
    }

    /// 会话归属的实例：最长根认领且同家的那个；没有根认领（路径在所有根之外）回同家第一个
    static func owner(of meta: CodingSessionMeta, in adapters: [CodingSessionAdapter]) -> CodingSessionAdapter? {
        if let ix = ownerIndex(of: meta.filePath, in: adapters), adapters[ix].agent == meta.agent { return adapters[ix] }
        // 没有根认领（远程主机被移除 / 缓存被系统清掉后残留的行）：只找同家同主机的实例，别错绑本机实例去读本机的库（R-WN4 #3）
        return adapters.first { $0.agent == meta.agent && $0.host == meta.host }
    }
}
#endif
