#if os(macOS)
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// 编程会话库的界面门面（mac 单例，plan-wake-native §3「路由」）：侧栏 code 组与主区域详情页只经它读数据。
/// - `isActive` / `selectedKey`：code 组是否激活、选中哪条会话（SidebarView 第四态 + ContentView 主区域分支）
/// - 读用自己的一条索引连接（主线程，分页小查询）；扫描在后台用另一条连接写（WAL 并发）
/// - 详情解析在后台，代号守卫：只有仍选中的那条会话的结果能落地（R-WN #4）
/// - 异步结果都写回发起它的实例（R-WN1 #3：测试注入的实例也拿得到）
@Observable
@MainActor
final class CodingSessionLibrary {
    static let shared = CodingSessionLibrary()
    static let pageSize = 100
    /// 扫描完重读时每个项目最多保留的条数（N0-9：别每轮把翻过的几千条都拉上主线程）
    static let reloadCap = 500

    enum Detail: Equatable {
        case idle
        case loading(key: String)
        case loaded(CodingParsedTranscriptBox)
        case failed(key: String, message: String, filePath: String?)
    }

    var isActive = false
    private(set) var selectedKey: String?
    private(set) var projects: [CodingProjectInfo] = []
    private(set) var projectStreams: [String: CodingSessionStream] = [:]
    /// 时间视图的会话流（全部项目）
    private(set) var timeline = CodingSessionStream()
    private(set) var totalSessions = 0
    /// 当前筛选下的会话数（标题栏角标）
    private(set) var filteredTotal = 0
    /// 有会话的 agent（按声明序）：筛选胶囊只出这些
    private(set) var presentAgents: [CodingAgent] = []
    /// 全部真实数据根（停用的也在，位置 sheet 用）
    private(set) var locations: [CodingLocation] = []
    /// 列表形态（⧫2 默认项目）/ 筛选范围 / 标题筛选 / 排序（只在时间视图生效）；形态与排序记在用户状态里
    private(set) var listMode: CodingListMode = .projects
    private(set) var scope: CodingListScope = .all
    private(set) var titleQuery = ""
    private(set) var sort: CodingSortKey = .updated
    private(set) var ascending = false
    private(set) var progress: CodingSessionScanner.Progress?
    private(set) var lastError: String?
    private(set) var detail: Detail = .idle
    /// Refresh the same transcript in place: loading/error must not destroy its scroll host.
    private(set) var isRefreshingDetail = false
    private(set) var detailRefreshError: String?
    private(set) var detailRevision: UInt64 = 0
    /// 详情要滚到并闪一下的消息 seq（⌘K 命中）
    private(set) var focusSeq: Int?
    /// 侧栏展开的项目（⌘K 命中要能替它展开、翻页、滚到那条）
    var expandedProjects: Set<String> = []
    /// 父子树（N3-d，Wake `SessionsDelegate`）：各根会话看得见的子会话数 / 展开了的根 / 已加载的子会话（懒加载）
    private(set) var childCounts: [String: Int] = [:]
    private(set) var expandedRoots: Set<String> = []
    private(set) var children: [String: [CodingSessionMeta]] = [:]
    /// 侧栏要滚到的会话 key
    private(set) var revealKey: String?
    /// 会话位置 sheet（N3-e）与它的分段（本机位置 / 远程主机，N4）
    var isLocationsPresented = false
    var locationsTab: CodingLocationsTab = .local
    /// 正在同步的远程主机（N4）；空 = 没在同步
    private(set) var syncingHosts: Set<String> = []
    /// 统计整页（N2）：打开时替换详情；有旧数据时重算不转圈
    private(set) var isInsightsPresented = false
    private(set) var insights: CodingInsightsData?
    private(set) var insightsLoading = false

    @ObservationIgnored let state: CodingSessionState
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private var adapters: [CodingSessionAdapter]
    /// 位置配置出来的 roster 可以换代（N3-e）；测试注入的固定 roster 不参与
    @ObservationIgnored private let rosterSource: RosterSource
    /// roster 代号：换代后旧监听晚到的批次一律丢（Wake 是 drop-join 等旧线程退出）
    @ObservationIgnored private let rosterEpoch = CodingEpoch()
    /// 换代时旧 roster 的扫描还在跑：它收完再用新 roster 补一轮
    @ObservationIgnored private var pendingRescan = false
    /// 同步进行中又来的请求：收工后只补这几台（Wake `pending_sync`）
    @ObservationIgnored private var pendingSync: [String] = []
    /// 进行中的一轮远程同步（含收工处理，测试可 await）
    @ObservationIgnored private(set) var remoteSyncTask: Task<Void, Never>?

    private enum RosterSource {
        case fixed
        case configured(home: URL, environment: [String: String])
    }
    @ObservationIgnored private var reader: CodingSessionIndex?
    @ObservationIgnored private var detailGeneration = 0
    @ObservationIgnored private var insightsGeneration = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var didScheduleStartupScan = false
    /// 全量与监听共用一个扫描器（一条写连接，扫描器内部的闸串行化）
    @ObservationIgnored private var scannerStorage: CodingSessionScanner?
    @ObservationIgnored private var watcher: CodingSessionWatcher?
    @ObservationIgnored private let incrementalQueue = DispatchQueue(label: "mp.coding-sessions.incremental", qos: .utility)
    /// 挪废纸篓（测试换成直接删 tmp 文件，别把 fixture 挪进她真的废纸篓）
    @ObservationIgnored var recycle: ([URL], @escaping (Error?) -> Void) -> Void = { urls, done in
        NSWorkspace.shared.recycle(urls) { _, error in done(error) }
    }

    /// - Parameter adapters: 给了 = 固定 roster（测试）；nil = 按用户状态里的位置配置构造（home / environment 可注入）
    init(indexURL: URL = CodingSessionIndex.defaultURL,
         adapters: [CodingSessionAdapter]? = nil,
         state: CodingSessionState? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        let resolvedState = state ?? .shared
        self.indexURL = indexURL
        self.state = resolvedState
        if let adapters {
            self.adapters = adapters
            rosterSource = .fixed
            locations = adapters.flatMap { adapter in
                adapter.dataRoots.map {
                    CodingLocation(agent: adapter.agent, path: $0.path, enabled: true, individuallyRemovable: adapter.supportsIndividualRootRemoval)
                }
            }
        } else {
            let roster = CodingSessionRoster.configured(home: home, environment: environment, overrides: resolvedState.locationOverrides,
                                                        remoteHosts: resolvedState.enabledRemoteHostNames,
                                                        cacheRoot: CodingRemote.cacheRoot(indexURL: indexURL))
            self.adapters = roster.active
            rosterSource = .configured(home: home, environment: environment)
            locations = roster.locations
        }
        let prefs = self.state.snapshot
        listMode = prefs.listMode.flatMap(CodingListMode.init(rawValue:)) ?? .projects
        sort = prefs.sort.flatMap(CodingSortKey.init(rawValue:)) ?? .updated
        ascending = prefs.ascending ?? false
    }

    var isScanning: Bool { progress?.scanning == true }

    // MARK: - 激活 / 刷新

    func activate() {
        isActive = true
        reload()
        refresh()
    }

    func deactivate() {
        isActive = false
        isInsightsPresented = false
    }

    /// 启动后延几秒在后台增量扫一次（R-WN #1），她点开 code 组时已是新的
    func scheduleStartupScan() {
        // 单元测试宿主也会拉起整个 app：别顺手去扫她的真会话目录
        guard !didScheduleStartupScan, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        didScheduleStartupScan = true
        #if DEBUG
        // 自检截图钩子：启动直接进 code 组、等索引就绪后选中第一条会话
        if ProcessInfo.processInfo.arguments.contains("--mp-open-code") {
            openForDebug()
            return
        }
        #endif
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.refresh()
            // 远程同步与首扫并行（Wake 启动同款）：本地扫描不等网络，不可达的主机只拖慢自己
            self?.syncRemoteHosts()
        }
    }

    #if DEBUG
    private func openForDebug() {
        Task { [weak self] in
            // 启动时 ContentView 会托底一个草稿对话，选中对话一变就 deactivate——等它落定再进 code 组，被冲掉就再进
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.activate()
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if !self.isActive { self.activate() }
                if !self.isScanning, let project = self.projects.first {
                    if self.sessions(in: project.path).isEmpty { self.loadMore(project: project.path) }
                    if let first = self.sessions(in: project.path).first { self.select(first.key) }
                    if ProcessInfo.processInfo.arguments.contains("--mp-open-insights") { self.toggleInsights() }
                    // 自检截图用（`--mp-select-key=<key>`）：指定拍哪条，不然只能拍到第一个项目的第一条
                    if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--mp-select-key=") }) {
                        self.select(String(arg.dropFirst("--mp-select-key=".count)))
                    }
                    // 自检截图用（`--mp-focus-seq=<seq>`）：滚到转录中间那条，才拍得到工具卡 / thinking / 子代理
                    if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--mp-focus-seq=") }),
                       let seq = Int(arg.dropFirst("--mp-focus-seq=".count)) {
                        self.focusSeq = seq
                    }
                    if ProcessInfo.processInfo.arguments.contains("--mp-open-locations") { self.isLocationsPresented = true }
                    if ProcessInfo.processInfo.arguments.contains("--mp-open-remote") {
                        self.locationsTab = .remote
                        self.isLocationsPresented = true
                    }
                    if ProcessInfo.processInfo.arguments.contains("--mp-open-connect") {
                        self.locationsTab = .connect
                        self.isLocationsPresented = true
                    }
                    if ProcessInfo.processInfo.arguments.contains("--mp-open-terminal") {
                        NotificationCenter.default.post(name: .openLocalTerminalTool, object: nil)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--mp-open-terminal-demo") { LocalTerminalStore.shared.debugDemo() }
                    // 取证用：在指定目录开一个 tab（`--mp-open-terminal-at=/路径`），查「这个目录到底读不读得进去」
                    if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--mp-open-terminal-at=") }) {
                        let path = String(arg.dropFirst("--mp-open-terminal-at=".count))
                        LocalTerminalStore.shared.present(directory: path, command: "pwd; ls -1 | head -3; echo rc=$?",
                                                          title: nil, origin: .shell)
                    }
                    // 阶段 B 实拍：给选中的这条会话挂一个「正在跑」的假 tab（软链成 claude 的 sleep），
                    // 详情页就会显示「回到终端」——不真去跑她的 agent
                    if ProcessInfo.processInfo.arguments.contains("--mp-bind-terminal-demo"),
                       let first = self.sessions(in: project.path).first {
                        LocalTerminalStore.shared.debugBind(key: first.key, agent: first.agent)
                    }
                    // 退出确认的实拍：app 内 terminate 走的就是她 ⌘Q 那条路（currentAppleEvent == nil → 弹）
                    if ProcessInfo.processInfo.arguments.contains("--mp-quit-prompt-demo") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.terminate(nil) }
                    }
                    return
                }
            }
        }
    }
    #endif

    /// 后台增量扫描（单飞）；完了重读项目与已加载的分页。返回任务（测试可 await）
    @discardableResult
    func refresh(full: Bool = false) -> Task<Void, Never>? {
        if let scanTask { return scanTask }
        guard let scanner = sharedScanner() else { return nil }
        startWatcherIfNeeded() // Watch before enumeration so writes during startup are not lost.
        let isTombstoned = state.tombstoneCheck
        progress = CodingSessionScanner.Progress(scanning: true, done: 0, total: 0)
        let task = Task.detached(priority: .utility) { [weak self] in
            var failure: String?
            do {
                _ = try scanner.run(full: full, isTombstoned: isTombstoned) { state in
                    Task { @MainActor [weak self] in self?.applyProgress(state) }
                }
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanTask = nil
                self.lastError = failure
                if self.progress?.scanning == true { self.progress?.scanning = false }
                self.reload()
                self.reloadDetail()
                self.startWatcherIfNeeded()
                self.recomputeInsightsIfPresented()
                if self.pendingRescan {
                    self.pendingRescan = false
                    self.refresh()
                }
            }
        }
        scanTask = task
        return task
    }

    private func sharedScanner() -> CodingSessionScanner? {
        if let scannerStorage { return scannerStorage }
        do {
            let scanner = CodingSessionScanner(index: try CodingSessionIndex(url: indexURL), adapters: adapters)
            scannerStorage = scanner
            return scanner
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// 扫描前开 FSEvents：批到了在增量队列上解析（与全量共用扫描器的闸），写完回主线程重读
    private func startWatcherIfNeeded() {
        guard watcher == nil, let scanner = sharedScanner() else { return }
        let queue = incrementalQueue
        let isTombstoned = state.tombstoneCheck
        let epoch = rosterEpoch
        let generation = epoch.value
        // 同一文件反复写时限流解析（plan-mac-hang-probe 阶段 3）：只在 queue 上碰
        let throttle = CodingParseThrottle()
        /// 解析一批（到点的 ref + 删除 + 父链），有变化就回主线程合并刷新。在 queue 上跑
        func process(refs: [CodingSessionFileRef], removed: [String], linkAgents: Set<CodingAgent>) {
            var report = CodingSessionScanner.Report()
            if !refs.isEmpty || !removed.isEmpty {
                let started = Date()
                report = (try? scanner.scanFiles(refs, removedPaths: removed, isTombstoned: isTombstoned)) ?? report
                throttle.record(refs, cost: Date().timeIntervalSince(started))
            }
            // 关系边车变了、这批又没有同家的会话文件可扫：单独刷父链（Wake `refresh_parent_links`）
            let linkOnly = linkAgents.subtracting(refs.map(\.agent))
            if !linkOnly.isEmpty, (try? scanner.refreshParentLinks(linkOnly, isTombstoned: isTombstoned)) == true {
                report.linksChanged = true
            }
            guard report.parsed + report.pruned > 0 || report.linksChanged else { return }
            let changed = Set(refs.map(\.filePath))
            Task { @MainActor [weak self] in self?.applyIncremental(changedPaths: changed) }
        }
        /// 推迟的到点再解析；还有没到点的就接着排
        func scheduleRetry(after delay: TimeInterval?) {
            guard let delay, !throttle.retryScheduled else { return }
            throttle.retryScheduled = true
            queue.asyncAfter(deadline: .now() + delay) {
                throttle.retryScheduled = false
                guard epoch.value == generation else { return }
                let (due, next) = throttle.takeDue()
                process(refs: due, removed: [], linkAgents: [])
                scheduleRetry(after: next)
            }
        }
        let watcher = CodingSessionWatcher(adapters: adapters) { [weak self] batch in
            queue.async {
                // roster 换代后旧监听晚到的批次：丢，别拿旧 roster 写库（已移除根的会话会被写回复活）
                guard epoch.value == generation else { return }
                if batch.needsRescan {
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                let (due, retryAfter) = throttle.admit(batch.refs)
                process(refs: due, removed: batch.removedPaths, linkAgents: batch.parentLinkAgents)
                scheduleRetry(after: retryAfter)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// 增量刷新的节拍（plan-mac-hang-probe §2）：正在跑的 CC 会话每几秒写一次、监听 0.8s 一批，
    /// 每批都整列表 + 详情重排会把主线程占满（09-25 她「动不动转菊花」，sample 主线程 100% 在 SwiftUI 重排）。
    /// 窗口内的变化攒起来，最多每 2 秒刷一次
    static let incrementalInterval: TimeInterval = 2
    @ObservationIgnored private var pendingChangedPaths = Set<String>()
    @ObservationIgnored private var incrementalScheduled = false
    @ObservationIgnored private var lastIncrementalAt = Date.distantPast
    /// 测试用：实际刷了几次
    @ObservationIgnored private(set) var incrementalFlushCount = 0

    private func applyIncremental(changedPaths: Set<String>) {
        pendingChangedPaths.formUnion(changedPaths)
        guard !incrementalScheduled else { return }
        incrementalScheduled = true
        let wait = max(0, Self.incrementalInterval - Date().timeIntervalSince(lastIncrementalAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.flushIncremental() }
        }
    }

    private func flushIncremental() {
        incrementalScheduled = false
        lastIncrementalAt = Date()
        incrementalFlushCount += 1
        let changed = pendingChangedPaths
        pendingChangedPaths = []
        reload()
        recomputeInsightsIfPresented()
        // 正看着的会话被写了（她在 CC 里还开着这条）→ 详情跟着更新
        if case .loaded(let box) = detail, changed.contains(box.transcript.meta.filePath) {
            reloadDetail()
        }
    }

    /// 测试入口：模拟监听送来一批变化
    func _testApplyIncremental(changedPaths: Set<String>) { applyIncremental(changedPaths: changedPaths) }

    /// 全文搜索：后台开一条只读连接查（LIKE 慢路径不能占主线程）
    func search(_ query: String) async -> (hits: [CodingSessionIndex.SearchHit], degraded: Bool) {
        let url = indexURL
        let result = await Task.detached(priority: .userInitiated) { () -> (hits: [CodingSessionIndex.SearchHit], degraded: Bool)? in
            guard let index = try? CodingSessionIndex(url: url) else { return nil }
            return try? index.search(query)
        }.value
        return result ?? ([], false)
    }

    /// 搜索命中（全局搜索的编程会话结果）：详情滚到那条消息 → 侧栏展开项目、翻到那条、滚过去（R-WN #5 跨页定位）
    func open(_ hit: CodingSessionIndex.SearchHit) {
        select(hit.meta.key, focusSeq: hit.seq)
        reveal(hit.meta)
    }

    /// 菜单栏快看（research-magpie §2.6）按 key 打开：激活 Code 组、选中、侧栏翻到它。索引里没有这条 → false
    @discardableResult
    func openSession(key: String) -> Bool {
        guard let meta = (try? openReader()?.session(key: key)) ?? nil else { return false }
        if !isActive { activate() }
        select(meta.key)
        reveal(meta)
        return true
    }

    /// 最近 `seconds` 秒内有写入的会话（在外部终端里跑着的那些；监听器保证索引是活的），新到旧
    func recentlyActive(now: Date = Date(), within seconds: TimeInterval = 180, limit: Int = 6) -> [CodingSessionMeta] {
        guard let reader = openReader() else { return [] }
        var filter = CodingListFilter()
        filter.updatedSince = Int64((now.timeIntervalSince1970 - seconds) * 1000)
        return (try? reader.listSessions(projectPath: nil, filter: filter, limit: limit)) ?? []
    }

    private func reveal(_ meta: CodingSessionMeta) {
        // ⌘K 搜的是全部会话：命中不在当前筛选里就先清筛选，不然列表里永远找不到它
        if !listFilter().matches(meta) {
            clearFilters()
        }
        // 只列根时子会话不在分页流里：翻页找它看得见的根（父被归档 = 它自己就是根；Wake `visible_parent_key`）
        let target = listFilter().rootsOnly ? ((try? openReader()?.visibleParentKey(of: meta.key)) ?? nil) ?? meta.key : meta.key
        var pages = 0
        if listMode == .timeline {
            while !timeline.all.contains(where: { $0.key == target }), hasMoreTimeline, pages < 20 {
                loadMoreTimeline()
                pages += 1
            }
        } else {
            let project = meta.projectPath
            expandedProjects.insert(project)
            if sessions(in: project).isEmpty { loadMore(project: project) }
            while !sessions(in: project).contains(where: { $0.key == target }), hasMore(in: project), pages < 20 {
                loadMore(project: project)
                pages += 1
            }
        }
        revealInTree(meta.key)
        revealKey = meta.key
    }

    private func applyProgress(_ state: CodingSessionScanner.Progress) {
        let previousDone = progress?.done ?? 0
        progress = state
        // 首扫期间列表先出已扫的：每推进 200 条重读一次项目
        if state.scanning, state.done - previousDone >= 200 || (previousDone == 0 && state.done > 0 && totalSessions == 0) {
            reloadProjects()
        }
    }

    // MARK: - 列表

    /// 重读项目与已加载的分页（每段最多 reloadCap 条）
    /// 重查一遍。结果先算好、和现在一样就不赋——@Observable 赋同值也会通知，整个侧栏跟着重排（plan-mac-hang-probe §2）
    func reload() {
        reloadProjects()
        var next: [String: CodingSessionStream] = [:]
        for (project, stream) in projectStreams {
            next[project] = fetchPage(project: project, from: CodingSessionStream(), limit: Self.reloadLimit(stream.rows.count))
        }
        update(\.projectStreams, next)
        let nextTimeline = listMode == .timeline
            ? fetchPage(project: nil, from: CodingSessionStream(), limit: Self.reloadLimit(timeline.rows.count))
            : CodingSessionStream()
        update(\.timeline, nextTimeline)
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<CodingSessionLibrary, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private static func reloadLimit(_ loaded: Int) -> Int {
        min(max(loaded, pageSize), reloadCap)
    }

    private func reloadProjects() {
        guard let reader = openReader() else { return }
        do {
            let filter = listFilter()
            update(\.projects, try reader.listProjects(filter: filter))
            update(\.totalSessions, try reader.sessionCount())
            update(\.filteredTotal, try reader.countSessions(filter: filter))
            update(\.presentAgents, try reader.presentAgents())
            let counts = filter.rootsOnly ? try reader.childCounts(filter: filter) : [:]
            update(\.childCounts, counts)
            update(\.expandedRoots, expandedRoots.filter { (counts[$0] ?? 0) > 0 })
            var nextChildren: [String: [CodingSessionMeta]] = [:]
            for key in expandedRoots { nextChildren[key] = pinnedFirst(try reader.listChildren(of: key, filter: filter)) }
            update(\.children, nextChildren)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 当前筛选：收藏范围现取收藏集（toggle 后重读即生效）；项目视图固定按更新时间倒序
    func listFilter() -> CodingListFilter {
        var filter = CodingListFilter()
        switch scope {
        case .all: break
        case .favorites: filter.onlyKeys = state.snapshot.favorites
        case .agent(let agent): filter.agents = [agent]
        }
        // 收藏范围平铺（收藏了的子会话要能直接看见），其余只列根、子会话挂在根下
        if case .favorites = scope {} else { filter.rootsOnly = true }
        filter.titleQuery = titleQuery
        filter.titleMatchKeys = state.keysWithTitle(matching: titleQuery)
        if listMode == .timeline {
            filter.sort = sort
            filter.ascending = ascending
        }
        return filter
    }

    func setListMode(_ mode: CodingListMode) {
        guard mode != listMode else { return }
        listMode = mode
        savePrefs()
        applyFilterChange()
    }

    func setScope(_ newScope: CodingListScope) {
        guard newScope != scope else { return }
        scope = newScope
        applyFilterChange()
    }

    func setTitleQuery(_ query: String) {
        guard query != titleQuery else { return }
        titleQuery = query
        applyFilterChange()
    }

    func setSort(_ key: CodingSortKey, ascending newAscending: Bool) {
        guard key != sort || newAscending != ascending else { return }
        sort = key
        ascending = newAscending
        savePrefs()
        applyFilterChange()
    }

    func clearFilters() {
        scope = .all
        titleQuery = ""
        applyFilterChange()
    }

    private func savePrefs() {
        state.setListPrefs(mode: listMode.rawValue, sort: sort.rawValue, ascending: ascending)
    }

    /// 筛选 / 排序 / 形态变了：旧分页作废，从第一页重读（同步读，不会有迟到的旧页混进来）
    private func applyFilterChange() {
        projectStreams = [:]
        timeline = CodingSessionStream()
        reloadProjects()
        if listMode == .timeline {
            loadMoreTimeline()
        } else {
            for project in expandedProjects { loadMore(project: project) }
        }
    }

    func sessions(in project: String) -> [CodingSessionMeta] {
        projectStreams[project]?.all ?? []
    }

    /// 侧栏当前看得见的行：根 + 已展开的子会话（project nil = 时间视图）
    func visibleRows(inProject project: String?) -> [CodingSessionMeta] {
        let roots = project.map { sessions(in: $0) } ?? timeline.all
        return roots.flatMap { [$0] + (expandedRoots.contains($0.key) ? children[$0.key] ?? [] : []) }
    }

    /// 展开 / 收起根会话的子会话（懒加载）；没有子会话的行什么也不做
    func toggleRoot(_ key: String) {
        guard (childCounts[key] ?? 0) > 0 else { return }
        if expandedRoots.remove(key) != nil {
            children[key] = nil
            return
        }
        guard let list = try? openReader()?.listChildren(of: key, filter: listFilter()) else { return }
        expandedRoots.insert(key)
        children[key] = pinnedFirst(list)
    }

    /// 子会话里置顶的排前面（置顶只把根行提进 Pinned；子会话的钉在展开里显示）
    private func pinnedFirst(_ list: [CodingSessionMeta]) -> [CodingSessionMeta] {
        let pins = state.snapshot.pins
        return list.filter { pins.contains($0.key) } + list.filter { !pins.contains($0.key) }
    }

    /// 选中的是子会话（⌘K 命中等）：把它的根展开，这一行才看得见（Wake `ensure_expanded`）
    private func revealInTree(_ key: String) {
        guard listFilter().rootsOnly, let parent = (try? openReader()?.visibleParentKey(of: key)) ?? nil,
              !expandedRoots.contains(parent) else { return }
        toggleRoot(parent)
    }

    func hasMore(in project: String) -> Bool {
        !(projectStreams[project]?.exhausted ?? false)
    }

    var hasMoreTimeline: Bool { !timeline.exhausted }

    /// 展开项目 / 点「更多」：从已加载的最后一条往后翻一页
    func loadMore(project: String) {
        loadPage(project: project, limit: Self.pageSize)
    }

    /// 时间视图触底预取
    func loadMoreTimeline() {
        loadPage(project: nil, limit: Self.pageSize)
    }

    /// 读一页（project nil = 时间视图）：首页先带上这个范围里的置顶（同一排序），之后 keyset 从最后一条非置顶往后翻；
    /// 失败的页停住等刷新（Wake：禁止触底重试风暴）
    private func loadPage(project: String?, limit: Int) {
        let current = project.map { projectStreams[$0] ?? CodingSessionStream() } ?? timeline
        let stream = fetchPage(project: project, from: current, limit: limit)
        if let project {
            if projectStreams[project] != stream { projectStreams[project] = stream }
        } else {
            update(\.timeline, stream)
        }
    }

    /// 在 `start` 后面接一页（纯查询，不碰界面状态）
    private func fetchPage(project: String?, from start: CodingSessionStream, limit: Int) -> CodingSessionStream {
        var stream = start
        guard let reader = openReader(), !stream.exhausted else { return stream }
        let filter = listFilter()
        let pins = state.snapshot.pins
        do {
            if stream.pinned.isEmpty, stream.rows.isEmpty, !pins.isEmpty {
                var pinFilter = filter
                pinFilter.onlyKeys = filter.onlyKeys.map { $0.intersection(pins) } ?? pins
                stream.pinned = try reader.listSessions(projectPath: project, filter: pinFilter, limit: pins.count)
            }
            let page = try reader.listSessions(projectPath: project, filter: filter, excludeKeys: pins, limit: limit, after: stream.rows.last)
            stream.rows.append(contentsOf: page)
            if page.count < limit { stream.exhausted = true }
        } catch {
            lastError = error.localizedDescription
            stream.exhausted = true
        }
        return stream
    }

    private func openReader() -> CodingSessionIndex? {
        if let reader { return reader }
        do {
            reader = try CodingSessionIndex(url: indexURL)
        } catch {
            lastError = error.localizedDescription
        }
        return reader
    }

    // MARK: - 详情

    func select(_ key: String, focusSeq: Int? = nil) {
        isInsightsPresented = false
        selectedKey = key
        self.focusSeq = focusSeq
        revealInTree(key)
        loadDetail(key)
    }

    func reloadDetail() {
        if let selectedKey { loadDetail(selectedKey) }
    }

    private func loadDetail(_ key: String) {
        detailGeneration += 1
        let generation = detailGeneration
        let retainingContent: Bool
        if case .loaded(let box) = detail { retainingContent = box.transcript.meta.key == key }
        else { retainingContent = false }
        isRefreshingDetail = retainingContent
        detailRefreshError = nil
        func fail(_ message: String, path: String?) {
            isRefreshingDetail = false
            if retainingContent { detailRefreshError = message }
            else { detail = .failed(key: key, message: message, filePath: path) }
        }
        #if DEBUG
        ShellProbe.keep("[PROBE coding.detail.load] generation=\(generation) retain=\(retainingContent)")
        #endif
        guard let reader = openReader(), let meta = try? reader.session(key: key) else {
            fail("索引里找不到这条会话，刷新一下试试。", path: nil)
            return
        }
        guard let adapter = adapter(for: meta) else {
            fail("没有能读 \(meta.agent.displayName) 会话的解析器（\(meta.filePath)）。", path: meta.filePath)
            return
        }
        guard let ref = (adapter.fileRef(URL(fileURLWithPath: meta.filePath)) ?? CodingSessionFileRef.fromMeta(meta)) else {
            fail("会话文件不见了或是空的：\(meta.filePath)", path: meta.filePath)
            return
        }
        if !retainingContent { detail = .loading(key: key) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try adapter.parseTranscript(ref) }
            await MainActor.run { [weak self] in
                guard let self, generation == self.detailGeneration, self.selectedKey == key else { return }
                self.isRefreshingDetail = false
                switch result {
                case .success(var transcript):
                    // 标题 / key 以索引为准（Codex 的 state DB 命名在扫描时已合并进索引）
                    transcript.meta = meta
                    self.detail = .loaded(CodingParsedTranscriptBox(transcript))
                    self.detailRevision &+= 1
                case .failure(let error):
                    let message = "解析失败：\(error.localizedDescription)"
                    if retainingContent { self.detailRefreshError = message }
                    else { self.detail = .failed(key: key, message: message, filePath: meta.filePath) }
                }
            }
        }
    }

    // MARK: - 收藏 / 置顶 / 导出 / 删除 / 续跑目标（N1-f / N1-g / N1-h / N1-k）

    /// 收藏 / 置顶变了：重读已加载的分页（置顶挪到最前、收藏筛选下增减行）
    func toggleFavorite(_ key: String) {
        state.toggleFavorite(key)
        reload()
    }

    func togglePin(_ key: String) {
        state.togglePin(key)
        reload()
    }

    /// 改名（plan-mac-code-mode-gaps §1）：空串 = 回到原名
    func rename(_ key: String, to title: String) {
        state.setTitle(title, for: key)
        reload()
    }

    /// 远程会话的「继续」= 复制 `ssh -t` 命令（Wake Copy SSH command）；回错误说明
    func copySSHCommand(_ meta: CodingSessionMeta) -> String? {
        guard let command = CodingSessionResume.sshCommand(for: meta) else { return CodingSessionResume.noResume(meta) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        return nil
    }

    /// 续跑：记住这次用的目标
    func resume(_ meta: CodingSessionMeta, target: CodingResumeTarget) -> String? {
        state.setTerminal(target.rawValue)
        if target == .memoryPalace {
            // 这条已经在某个 tab 里跑着就切过去，不再开第二个——两个 agent 写同一个 jsonl 会打架（阶段 B / R-B B1）
            if let live = LocalTerminalStore.shared.liveSession(forKey: meta.key) {
                LocalTerminalStore.shared.focus(live.id)
                return nil
            }
            guard let request = Self.inAppResume(meta) else { return CodingSessionResume.noResume(meta) }
            LocalTerminalStore.shared.present(directory: request.directory, command: request.command, title: meta.title,
                                              origin: .codingSession(key: meta.key, agent: meta.agent))
            return nil
        }
        return CodingSessionResume.resume(meta, target: target)
    }

    /// 在 MP 终端面板里续跑（plan-mp-local-terminal A5 / R-MT I6）：目录交给 forkpty（在就用），命令只是 `bin + 单引号参数`；这家续不了回 nil
    static func inAppResume(_ meta: CodingSessionMeta) -> (directory: String?, command: String)? {
        guard let invocation = CodingSessionResume.invocation(for: meta) else { return nil }
        let exists = !meta.projectPath.isEmpty && FileManager.default.fileExists(atPath: meta.projectPath)
        return (exists ? meta.projectPath : nil, LocalTerminalLaunch.command(bin: invocation.bin, args: invocation.args))
    }

    /// 上次用的目标（不适用于这家 agent 就回终端）；这家连终端都续不了（Kiro / Gemini / OpenClaw）回 nil
    func preferredTarget(for agent: CodingAgent) -> CodingResumeTarget? {
        if let raw = state.snapshot.terminal, let target = CodingResumeTarget(rawValue: raw), target.supports(agent) { return target }
        return CodingResumeTarget.terminal.supports(agent) ? .terminal : nil
    }

    /// 导出 Markdown：另存为（记住上次目录）；取消回 nil，失败回说明
    func exportMarkdown(_ meta: CodingSessionMeta) -> String? {
        guard let adapter = adapter(for: meta) else { return "没有能读这条会话的解析器" }
        let markdown: String
        do {
            markdown = try CodingSessionExport.render(adapter: adapter, meta: meta)
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CodingSessionExport.defaultFileName(meta)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if let dir = state.snapshot.lastExportDir { panel.directoryURL = URL(fileURLWithPath: dir) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            state.setLastExportDir(url.deletingLastPathComponent().path)
            return nil
        } catch {
            return "写文件失败：\(error.localizedDescription)"
        }
    }

    /// 存图：另存为（与导出共用上次目录，R-WN1 #9）；取消回 nil，失败回说明
    func saveImage(_ image: CodingImage, suggestedName: String) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + "." + image.fileExtension
        if let type = UTType(mimeType: image.mediaType) { panel.allowedContentTypes = [type] }
        if let dir = state.snapshot.lastExportDir { panel.directoryURL = URL(fileURLWithPath: dir) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try image.data.write(to: url, options: .atomic)
            state.setLastExportDir(url.deletingLastPathComponent().path)
            return nil
        } catch {
            return "存图失败：\(error.localizedDescription)"
        }
    }

    /// 删除会挪进废纸篓的全部路径（确认框列出来，R-WN1 #7）
    func deletionPaths(for meta: CodingSessionMeta) -> [String] {
        adapter(for: meta)?.sessionPaths(meta) ?? [meta.filePath]
    }

    /// 删除的范围：这条连同整棵子树（不受筛选与归档影响），每条按自己的胜出文件找 adapter 取路径，去重保序（Wake `confirm_delete`）
    func deletionPlan(for meta: CodingSessionMeta) -> (sessions: [CodingSessionMeta], paths: [String]) {
        let sessions = [meta] + ((try? openReader()?.allDescendants(of: meta.key)) ?? [])
        var seen = Set<String>()
        var paths: [String] = []
        for session in sessions {
            for path in deletionPaths(for: session) where seen.insert(path).inserted { paths.append(path) }
        }
        return (sessions, paths)
    }

    /// 删除：整棵子树先进废纸篓，成功回调里才写墓碑 → 删索引 → 选看得见的下一条（跳过整棵子树；R-WN1 #10）；失败不进后序
    func delete(_ meta: CodingSessionMeta, completion: @escaping (String?) -> Void) {
        // 远程会话只读（菜单项已隐藏，这里兜住其余入口）：本地只有缓存副本，挪走它下次同步就复活（Wake `confirm_delete`）
        guard meta.host.isEmpty else {
            completion(Self.remoteReadOnly)
            return
        }
        let plan = deletionPlan(for: meta)
        let doomed = Set(plan.sessions.map(\.key))
        let list = visibleRows(inProject: listMode == .timeline ? nil : meta.projectPath)
        var neighbor: CodingSessionMeta?
        if let i = list.firstIndex(where: { $0.key == meta.key }) {
            neighbor = list[(i + 1)...].first { !doomed.contains($0.key) } ?? list[..<i].last { !doomed.contains($0.key) }
        }
        let urls = plan.paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        recycle(urls) { error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    completion("挪进废纸篓失败：\(error.localizedDescription)")
                    return
                }
                for session in plan.sessions { self.state.bury(path: session.filePath, key: session.key) }
                try? self.openReader()?.removeSessions(plan.sessions.map(\.key))
                self.reload()
                if let selected = self.selectedKey, doomed.contains(selected) {
                    if let neighbor {
                        self.select(neighbor.key)
                    } else {
                        self.selectedKey = nil
                        self.detail = .idle
                        self.isRefreshingDetail = false
                        self.detailRefreshError = nil
                    }
                }
                completion(nil)
            }
        }
    }

    // MARK: - 会话位置（N3-e，Wake Settings → Session locations）

    /// 位置 sheet 的一行
    struct LocationRow: Identifiable, Equatable {
        var agent: CodingAgent
        /// 真实数据根（完整路径）
        var path: String
        var display: String
        var count: Int
        var exists: Bool
        /// 属于哪条自定义配置（落库路径可能是这条根的上层）；nil = 默认位置
        var custom: String?
        var individuallyRemovable: Bool
        var enabled: Bool

        var id: String { agent.rawValue + "\u{0}" + path }
    }

    /// 每条真实数据根一行（停用的也列），同家的自定义紧跟默认；会话数一次扫表归属（Wake `location_settings_snapshot`）
    func locationRows() -> [LocationRow] {
        let order = Dictionary(uniqueKeysWithValues: CodingAgent.allCases.enumerated().map { ($1, $0) })
        let flat = locations.enumerated()
            .sorted { (order[$0.element.agent] ?? 0, $0.offset) < (order[$1.element.agent] ?? 0, $1.offset) }
            .map(\.element)
        let counts = try? openReader()?.counts(byLocation: flat.map { (agent: $0.agent, root: $0.path) })
        let customs = state.locationOverrides.customRoots
        return flat.enumerated().map { i, location in
            LocationRow(agent: location.agent, path: location.path, display: CodingLocations.tildePath(location.path),
                        count: counts?[i] ?? 0, exists: FileManager.default.fileExists(atPath: location.path),
                        custom: customs.first { $0.agent == location.agent.rawValue && CodingLocations.pathOwns($0.path, location.path) }?.path,
                        individuallyRemovable: location.individuallyRemovable, enabled: location.enabled)
        }
    }

    /// 偏离默认（有自定义 / 移除 / 停用）才能「恢复默认」
    var locationsDiverged: Bool {
        let overrides = state.locationOverrides
        return !overrides.customRoots.isEmpty || !overrides.removedDefaults.isEmpty || !overrides.removedDefaultRoots.isEmpty
            || locations.contains { !$0.enabled }
    }

    /// 编辑表单预填：自定义行填落库路径；默认行填真实根，SQLite 库文件填所在目录（免得存成 <库>/<库>）
    func editPrefill(_ row: LocationRow) -> String {
        if let custom = row.custom { return custom }
        return CodingLocations.isFile(URL(fileURLWithPath: row.path)) ? (row.path as NSString).deletingLastPathComponent : row.path
    }

    /// 添加 / 编辑提交（Wake `commit_location_form`）：展开 ~ → 必须绝对路径 → 去尾分隔符 → 按家整形 → 没改就算了 → 同家重叠拒（嵌进别家
    /// 树里是合法的，同家嵌套才是重复读取）→ 落配置 → roster 换代 + 补扫。回错误文案，nil = 成了
    @discardableResult
    func commitLocation(editing row: LocationRow?, agent: CodingAgent, path rawPath: String) -> String? {
        let expanded = CodingLocations.expandTilde(rawPath.trimmingCharacters(in: .whitespacesAndNewlines))
        guard expanded.hasPrefix("/") else { return "请填绝对路径（以 / 或 ~ 开头）" }
        var trimmed = expanded
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let path = CodingLocations.normalizeCustomRoot(agent, URL(fileURLWithPath: trimmed)).path
        if let row, row.agent == agent, CodingLocations.normalizeCustomRoot(agent, URL(fileURLWithPath: editPrefill(row))).path == path {
            return nil
        }
        let customs = state.locationOverrides.customRoots
        let covered = locations.filter { $0.agent == agent }.contains { location in
            if let row, row.agent == agent {
                // 排除被编辑单元自身派生的根：自定义单元 = 落库路径之下的根；可单独移除的默认 = 这一条根；其余默认 = 不属于任何自定义的根
                if let unit = row.custom {
                    if CodingLocations.pathOwns(unit, location.path) { return false }
                } else if row.individuallyRemovable {
                    if location.path == row.path { return false }
                } else if !customs.contains(where: { $0.agent == agent.rawValue && CodingLocations.pathOwns($0.path, location.path) }) {
                    return false
                }
            }
            return CodingLocations.pathOwns(path, location.path) || CodingLocations.pathOwns(location.path, path)
        }
        if covered { return "这个文件夹已经在会话位置里了" }
        if let row {
            state.replaceLocation(oldAgent: row.agent, oldCustomPath: row.custom,
                                  oldDefaultRoot: row.custom == nil && row.individuallyRemovable ? row.path : nil,
                                  oldDataRoot: row.path, newAgent: agent, newPath: path)
        } else {
            state.addCustomRoot(agent: agent, path: path)
        }
        rebuildRoster()
        return nil
    }

    /// 移除自定义位置（默认位置不给移除，用开关停；磁盘文件始终不动）
    @discardableResult
    func removeLocation(_ row: LocationRow) -> Task<Void, Never>? {
        guard let custom = row.custom else { return nil }
        state.removeCustomRoot(agent: row.agent, path: custom)
        return rebuildRoster()
    }

    /// 停用 = 暂时不读：下轮扫描按「磁盘上没了」出清该根的行（不写墓碑）；重开 = 增量扫回
    @discardableResult
    func setLocationEnabled(_ row: LocationRow, enabled: Bool) -> Task<Void, Never>? {
        state.setLocationEnabled(agent: row.agent, path: row.path, enabled: enabled)
        return rebuildRoster()
    }

    @discardableResult
    func restoreDefaultLocations() -> Task<Void, Never>? {
        state.clearLocationOverrides()
        return rebuildRoster()
    }

    /// 位置变了：roster 换代 + 补扫（Wake `rebuild_roster` + `kick_incremental_scan`）——代号先进一位（旧监听晚到的批次作废）→ 停监听
    /// → 等增量队列排空（旧批次拿着旧 roster 在写库，不等收尾，被移除根的会话会在补扫之后被写回复活）→ 换扫描器 → 补一轮增量；
    /// 扫完起新监听。旧 roster 的全量还在跑就等它收完再补
    @discardableResult
    func rebuildRoster() -> Task<Void, Never>? {
        guard case .configured(let home, let environment) = rosterSource else { return nil }
        rosterEpoch.advance()
        watcher?.stop()
        watcher = nil
        incrementalQueue.sync {}
        let roster = CodingSessionRoster.configured(home: home, environment: environment, overrides: state.locationOverrides,
                                                    remoteHosts: state.enabledRemoteHostNames, cacheRoot: CodingRemote.cacheRoot(indexURL: indexURL))
        adapters = roster.active
        locations = roster.locations
        scannerStorage = nil
        if let scanTask {
            pendingRescan = true
            return scanTask
        }
        return refresh()
    }

    // MARK: - 远程主机（N4，Wake Settings → Remote hosts）

    static let remoteReadOnly = "远程会话只读——文件还在远端主机上"

    /// 远程主机页的一行：只存事实（会话数 / 上次成功 / 上次错误），状态句在视图里现算
    struct RemoteHostRow: Identifiable, Equatable {
        var name: String
        var enabled: Bool
        var count: Int
        var lastSyncAt: Int64?
        var lastSyncError: String?

        var id: String { name }
    }

    func remoteHostRows() -> [RemoteHostRow] {
        let counts = (try? openReader()?.hostCounts()) ?? [:]
        return state.remoteHosts.map {
            RemoteHostRow(name: $0.name, enabled: $0.enabled, count: counts[$0.name] ?? 0, lastSyncAt: $0.lastSyncAt, lastSyncError: $0.lastSyncError)
        }
    }

    /// 添加（Wake `add_remote_host`）：校验 → 写配置 → roster 换代 → 只同步这台（别把既有主机整棵树再协商一遍）；回错误说明，nil = 成功
    @discardableResult
    func addRemoteHost(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.addRemoteHost(name) else { return "只能填 SSH 别名或 user@host（字母、数字和 . _ - @）" }
        rebuildRoster()
        syncRemoteHosts([name])
        return nil
    }

    /// 开关 = 同位置停用：换代 → 补扫把该主机的行按「磁盘已删」出清，缓存保留，重开即收编
    @discardableResult
    func setRemoteHostEnabled(_ name: String, enabled: Bool) -> Task<Void, Never>? {
        state.setRemoteHostEnabled(name, enabled: enabled)
        return rebuildRoster()
    }

    /// 移除：删配置 → 排队里剔除 → 换代（补扫出清库内行，远端不动）→ 后台删缓存目录（大树别冻住界面）。进行中的 rsync 取消不了，
    /// 它写回的目录由收工时的孤儿清理兜底
    @discardableResult
    func removeRemoteHost(_ name: String) -> Task<Void, Never>? {
        state.removeRemoteHost(name)
        pendingSync.removeAll { $0 == name }
        let task = rebuildRoster()
        let cache = CodingRemote.hostCacheDir(CodingRemote.cacheRoot(indexURL: indexURL), host: name)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: cache) }
        return task
    }

    /// 同步（启动 / 刷新 / 立即同步 / 添加共用；names nil = 全部启用的）。单飞：进行中再来的排队，收工后只补它们。rsync 在后台线程、
    /// 与扫描并行；收工：后台清孤儿缓存 → 回主线程写状态 → 起排队的 → 缓存里长出监听集之外的新根就重挂监听 → 补一轮增量
    @discardableResult
    func syncRemoteHosts(_ names: [String]? = nil) -> Task<Void, Never>? {
        guard case .configured(_, let environment) = rosterSource else { return nil }
        let targets = names ?? state.enabledRemoteHostNames
        guard !targets.isEmpty else { return remoteSyncTask }
        guard syncingHosts.isEmpty else {
            for name in targets where !pendingSync.contains(name) { pendingSync.append(name) }
            return remoteSyncTask
        }
        syncingHosts = Set(targets)
        let root = CodingRemote.cacheRoot(indexURL: indexURL)
        let task = Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                CodingRemote.syncHosts(targets, cacheRoot: root, environment: environment)
            }.value
            // 孤儿清理在后台、先于收工（GB 级缓存树的删除不上主线程；同步途中被移除的主机，rsync 写回的目录在这里清掉）
            guard let known = self.map({ Set($0.state.remoteHosts.map(\.name)) }) else { return }
            await Task.detached(priority: .utility) { CodingRemote.purgeOrphanCaches(root, known: known) }.value
            self?.finishRemoteSync(results)
        }
        remoteSyncTask = task
        return task
    }

    private func finishRemoteSync(_ results: [String: String?]) {
        for (name, error) in results { state.recordRemoteSync(name, error: error) }
        syncingHosts = []
        remoteSyncTask = nil
        let queued = pendingSync
        pendingSync = []
        syncRemoteHosts(queued)
        // 首次同步建出了监听起跑时还不存在的根：重挂（稳态下 rsync 落盘由现有监听收编，不白付停 / 起的代价）
        if let watcher, adapters.flatMap(\.dataRoots).contains(where: { root in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue && !watcher.watchedPaths.contains(root.path)
        }) {
            watcher.stop()
            self.watcher = nil
            incrementalQueue.sync {}
            startWatcherIfNeeded()
        }
        // 补扫不能省：SQLite 型库监听不认，远程缓存里这些库的更新只有扫描能收
        if scanTask != nil {
            pendingRescan = true
        } else {
            refresh()
        }
    }

    // MARK: - AI 工具（W-N N5）

    /// 聊天里的编程会话工具：主线程取当前 roster（含远程）与收藏快照，后台新开只读连接执行
    func runCodingTool(name: String, argumentsJSON: String) async -> CodingTools.Result {
        let adapters = self.adapters
        let favorites = state.snapshot.favorites
        let url = indexURL
        return await Task.detached(priority: .userInitiated) {
            CodingTools.run(name: name, argumentsJSON: argumentsJSON, indexURL: url, adapters: adapters, favorites: favorites)
        }.value
    }

    // MARK: - 统计（N2）

    /// 入口钮：开 / 关统计整页（与详情互斥）
    func toggleInsights() {
        isInsightsPresented.toggle()
        if isInsightsPresented { recomputeInsights() }
    }

    private func recomputeInsightsIfPresented() {
        if isInsightsPresented { recomputeInsights() }
    }

    /// 后台算（任务内新建连接，不碰主线程 reader）；代际守卫：只有最新一次落地。失败时首开落空态，已有数据保留
    private func recomputeInsights() {
        insightsGeneration += 1
        let generation = insightsGeneration
        if insights == nil { insightsLoading = true }
        let url = indexURL
        let today = CodingDay(Date())
        Task.detached(priority: .utility) { [weak self] in
            let result = try? CodingSessionIndex(url: url).insights(today: today)
            await MainActor.run { [weak self] in
                guard let self, generation == self.insightsGeneration else { return }
                if let result { self.insights = result }
                self.insightsLoading = false
            }
        }
    }

    // MARK: - 子代理（N1-j）

    /// 当前详情里某个子代理的类型 / 描述
    func sidechainInfo(_ id: String) -> CodingSidechain? {
        guard case .loaded(let box) = detail else { return nil }
        return box.transcript.sidechains.first { $0.id == id }
    }

    /// 懒加载当前详情会话的子代理对话（后台解析，图片同样走转录预算）
    func loadSidechain(id: String) async -> Result<[CodingMessage], CodingLoadError> {
        guard case .loaded(let box) = detail else { return .failure(CodingLoadError(text: "会话还没加载")) }
        let meta = box.transcript.meta
        guard let adapter = adapter(for: meta), let ref = (adapter.fileRef(URL(fileURLWithPath: meta.filePath)) ?? CodingSessionFileRef.fromMeta(meta)) else {
            return .failure(CodingLoadError(text: "会话文件不见了"))
        }
        return await Task.detached(priority: .userInitiated) { () -> Result<[CodingMessage], CodingLoadError> in
            do {
                return .success(try adapter.loadSidechain(ref, id: id))
            } catch {
                return .failure(CodingLoadError(text: error.localizedDescription))
            }
        }.value
    }

    /// 会话归属的实例（最长根：一家多实例时不能按 agent 找第一个，R-WN3 #7）
    func adapter(for meta: CodingSessionMeta) -> CodingSessionAdapter? {
        CodingSessionRoster.owner(of: meta, in: adapters)
    }
}

/// 转录体量大，Equatable 只比 key + 消息数（Detail 状态比较用，不逐条比）
struct CodingLoadError: Error, Equatable {
    let text: String
}

/// 位置 sheet 的分段（N4）
enum CodingLocationsTab: Hashable {
    case local
    case remote
    /// 接入（N6-d）：mp-code 路径与三家接入片段
    case connect
}

/// 列表形态（⧫2：默认按项目）
enum CodingListMode: String, Sendable {
    case projects, timeline
}

/// 列表筛选范围（胶囊：全部 / 收藏 / 各家 agent）
enum CodingListScope: Equatable, Sendable {
    case all
    case favorites
    case agent(CodingAgent)
}

/// 一段会话流：首页先带上这个范围里的置顶，其余按 keyset 翻页
struct CodingSessionStream: Equatable {
    var pinned: [CodingSessionMeta] = []
    var rows: [CodingSessionMeta] = []
    var exhausted = false

    var all: [CodingSessionMeta] { pinned + rows }
}

/// 时间视图分组（Wake `build_row_groups_at` / `session_group_label`）
struct CodingSessionGroup: Equatable {
    var label: String
    var range: Range<Int>

    /// 按时间倒序：置顶单列 Pinned，其余今天 / 昨天 / 本周 / 月份（跨年补年份）；按消息数或升序平铺（一组、无标题）
    static func build(_ sessions: [CodingSessionMeta], pinnedCount: Int, filter: CodingListFilter,
                      now: Date = Date(), calendar: Calendar = .current) -> [CodingSessionGroup] {
        guard !sessions.isEmpty, filter.isTimeDescending else { return [CodingSessionGroup(label: "", range: 0..<sessions.count)] }
        var groups: [CodingSessionGroup] = []
        let pinned = min(pinnedCount, sessions.count)
        if pinned > 0 { groups.append(CodingSessionGroup(label: "Pinned", range: 0..<pinned)) }
        var start = pinned
        while start < sessions.count {
            let label = Self.label(filter.sortValue(sessions[start]), now: now, calendar: calendar)
            var end = start + 1
            while end < sessions.count, Self.label(filter.sortValue(sessions[end]), now: now, calendar: calendar) == label {
                end += 1
            }
            groups.append(CodingSessionGroup(label: label, range: start..<end))
            start = end
        }
        return groups
    }

    /// 周一起算（Wake `num_days_from_monday`，不跟系统的周首日）；今天及以后都算今天
    static func label(_ ms: Int64, now: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        let today = calendar.startOfDay(for: now)
        if day >= today { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day >= yesterday { return "昨天" }
        let fromMonday = (calendar.component(.weekday, from: today) + 5) % 7
        if let weekStart = calendar.date(byAdding: .day, value: -fromMonday, to: today), day >= weekStart { return "本周" }
        let parts = calendar.dateComponents([.year, .month], from: day)
        let month = parts.month ?? 0
        if parts.year == calendar.component(.year, from: today) { return "\(month)月" }
        return "\(parts.year ?? 0)年\(month)月"
    }
}

struct CodingParsedTranscriptBox: Equatable {
    let transcript: CodingParsedTranscript

    init(_ transcript: CodingParsedTranscript) {
        self.transcript = transcript
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transcript.meta == rhs.transcript.meta && lhs.transcript.mainline.count == rhs.transcript.mainline.count
    }
}
#endif
