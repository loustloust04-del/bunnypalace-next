import Foundation

/// 酒馆整包导入界面（卡库 ⑧c 界面，小样 09 / plan §6.3）用的纯逻辑：盘点页 / 报告页 / 来源列表 / 撤回结果怎么摆、
/// 错误怎么说。不碰存储、不碰视图，独立 xctest 直接验。
enum SillyTavernImportPresentation {

    struct Row: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let value: String
    }

    // MARK: - 盘点页

    struct Attention: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        /// 会少东西 / 不导入的（红）；其余只是提醒
        let isProblem: Bool
    }

    /// 盘点里可以勾掉的文件（坏文件 / 有坏行 / 缺卡的聊天）。paths 是要传给 `commit(excluded:)` 的相对路径
    struct Excludable: Equatable, Identifiable {
        var id: String { key }
        /// 显示用：文件相对路径，或缺卡聊天的目录
        let key: String
        let reason: String
        let paths: [String]
    }

    static func counts(_ s: SillyTavernPackageSummary) -> [Row] {
        [Row(title: "角色卡", value: "\(s.cards) 张"),
         Row(title: "聊天", value: "\(s.chats) 份"),
         Row(title: "世界书", value: "\(s.worlds) 本"),
         Row(title: "预设", value: "\(s.presets) 份"),
         Row(title: "快捷回复", value: "\(s.quickReplies) 组"),
         Row(title: "用户身份", value: "\(s.personas) 个")]
    }

    /// 聊天下面那行小字：带 swipes 和真多候选分开说
    static func messageNote(_ s: SillyTavernPackageSummary) -> String {
        "共 \(s.messages) 条消息，其中 \(s.swipeGroups) 条带 swipes、\(s.multiCandidateMessages) 条有多个候选"
    }

    static func attention(_ plan: SillyTavernPackagePlan) -> [Attention] {
        let s = plan.summary
        var out: [Attention] = []
        if s.cardsWithHelperScripts > 0 {
            out.append(.init(title: "\(s.cardsWithHelperScripts) 张卡带脚本", detail: "原样保留，交互还不完整", isProblem: false))
        }
        out.append(.init(title: "群聊", detail: s.groupChats + s.groups == 0 ? "0 个 · 本包未包含"
                         : "\(s.groups) 组 · \(s.groupChats) 份记录，只读归档，不能续聊", isProblem: false))
        let attachments = s.attachments.userFiles + s.attachments.userImages
        if attachments > 0 {
            out.append(.init(title: "文件附件", detail: "\(attachments) 个", isProblem: false))
        }
        if s.placeholderChats > 0 {
            out.append(.init(title: "\(s.placeholderChats) 份聊天找不到卡",
                             detail: "建占位角色楼层放进去（\(s.placeholderCharacters) 个）", isProblem: false))
        }
        let badFiles = badFileCount(plan)
        if badFiles > 0 {
            out.append(.init(title: "\(badFiles) 个坏文件", detail: "读不出，只归档原件；可以在下面排除", isProblem: true))
        }
        if s.badChatLines > 0 {
            out.append(.init(title: "\(s.badChatLines) 行聊天坏了", detail: "在 \(s.chatsWithBadLines) 份聊天里；坏行跳过，其余照导", isProblem: true))
        }
        if s.hasCredentials {
            out.append(.init(title: "含 API 凭据", detail: "不读、不存、不导入", isProblem: true))
        }
        let missing = missingWorldNames(plan)
        if !missing.isEmpty {
            out.append(.init(title: "\(missing.count) 本世界书找不到", detail: "被引用但包里没有：" + missing.joined(separator: "、"), isProblem: true))
        }
        return out
    }

    /// 被引用但包里没有的书名（去重、排序）
    static func missingWorldNames(_ plan: SillyTavernPackagePlan) -> [String] {
        Array(Set(plan.worldBindings.filter { $0.resolvedPath == nil }.map(\.bookName))).sorted()
    }

    /// 整个文件读不出 / 解析失败（不含坏行、缺卡、凭据）
    static func badFileCount(_ plan: SillyTavernPackagePlan) -> Int {
        let entryPaths = Set(plan.snapshot.entries.map(\.relativePath))
        return Set(plan.problems.filter { $0.line == nil && entryPaths.contains($0.relativePath)
            && $0.relativePath != SillyTavernPackageParser.credentialsPath }.map(\.relativePath)).count
    }

    static func excludable(_ plan: SillyTavernPackagePlan) -> [Excludable] {
        let entries = plan.snapshot.entries.map(\.relativePath)
        let entryPaths = Set(entries)
        var reasons: [String: [String]] = [:]
        var badLines: [String: Int] = [:]
        for problem in plan.problems where problem.relativePath != SillyTavernPackageParser.credentialsPath {
            if problem.line != nil {
                badLines[problem.relativePath, default: 0] += 1
            } else if !(reasons[problem.relativePath] ?? []).contains(problem.reason) {
                reasons[problem.relativePath, default: []].append(problem.reason)
            }
        }
        var out: [Excludable] = []
        for key in Set(reasons.keys).union(badLines.keys).sorted() {
            var parts = reasons[key] ?? []
            if let lines = badLines[key] { parts.append("\(lines) 行坏了") }
            let paths = entryPaths.contains(key) ? [key] : entries.filter { $0.hasPrefix(key + "/") }.sorted()
            guard !paths.isEmpty else { continue }
            out.append(.init(key: key, reason: parts.joined(separator: "；"), paths: paths))
        }
        return out
    }

    static func excludedPaths(_ items: [Excludable], excludedKeys: Set<String>) -> Set<String> {
        Set(items.filter { excludedKeys.contains($0.key) }.flatMap(\.paths))
    }

    /// 来源默认值：同名的已有来源 → 重导它；否则用文件名起新来源
    enum SourceDraft: Equatable {
        case new(name: String)
        case existing(id: String)
    }

    static func defaultSource(fileName: String, sources: [ImportSource]) -> SourceDraft {
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty || base == "default-user" ? "酒馆" : base
        if let match = sources.first(where: { $0.name == name }) { return .existing(id: match.id) }
        return .new(name: name)
    }

    // MARK: - 报告页

    struct CategoryRow: Equatable, Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let source: Int
        let created: Int
        let skipped: Int
        let archivedOnly: Int
        let failed: Int
        let unsupported: Int
    }

    struct IssueRow: Equatable, Identifiable {
        let id: Int
        let location: String
        let reason: String
        let action: String
        let retryable: Bool
    }

    /// 只列包里有的类别；凭据不列（另有问题行说明）
    static func categoryRows(_ report: SillyTavernImportReport) -> [CategoryRow] {
        report.categories.filter { $0.sourceFiles > 0 && $0.key != SillyTavernFileCategory.credentials.rawValue }.map {
            CategoryRow(key: $0.key, title: $0.title, source: $0.sourceFiles, created: $0.created, skipped: $0.skipped,
                        archivedOnly: $0.archivedOnly, failed: $0.failed, unsupported: $0.unsupported)
        }
    }

    /// 表下的补充：内容变了只归档、盘点时排除
    static func categoryFootnotes(_ report: SillyTavernImportReport) -> [String] {
        let changed = report.categories.reduce(0) { $0 + $1.changed }
        let excluded = report.categories.reduce(0) { $0 + $1.excluded }
        var out: [String] = []
        if changed > 0 { out.append("\(changed) 个文件和上次导入时不同：保留新版原件，未覆盖已导入的东西") }
        if excluded > 0 { out.append("\(excluded) 个文件在盘点时排除：只归档原件，没建对象") }
        return out
    }

    /// 内容数字。「带 swipes 的消息」和「真多候选」分两行
    static func contentRows(_ report: SillyTavernImportReport) -> [Row] {
        let n = report.numbers
        var rows = [Row(title: "消息", value: "\(n.messages) 条"),
                    Row(title: "带 swipes 的消息", value: "\(n.messagesWithSwipes) 条"),
                    Row(title: "真多候选", value: "\(n.multiCandidateMessages) 条 · 共 \(n.candidates) 个候选")]
        func add(_ title: String, _ value: Int, _ unit: String) {
            if value > 0 { rows.append(Row(title: title, value: "\(value) \(unit)")) }
        }
        add("正文和选中候选不同", n.mesDiffers, "条（两份都留）")
        add("隐藏消息", n.hiddenMessages, "条（不显示、不发送）")
        add("坏行", n.badLines, "行（跳过）")
        add("候选序号越界", n.swipeIdOutOfRange, "条")
        add("缺卡的占位楼层", n.placeholderFloors, "个")
        add("群聊归档楼层", n.groupArchiveFloors, "个（只读）")
        if n.attachmentRefsResolved + n.attachmentRefsMissing > 0 {
            rows.append(Row(title: "附件引用", value: "找到 \(n.attachmentRefsResolved) · 缺 \(n.attachmentRefsMissing)"))
        }
        add("导入后先关掉的全局正则", n.globalRegexDisabledOnImport, "条")
        add("没绑定、先停用的世界书", n.unboundWorldsDisabled, "本")
        rows.append(Row(title: "原件归档", value: "新存 \(n.archivedBlobsNew) · 复用 \(n.archivedBlobsReused)"))
        return rows
    }

    static func kindTitle(_ raw: String) -> String {
        switch ImportTarget.Kind(rawValue: raw) {
        case .card: "角色卡"
        case .floor: "楼层"
        case .floorPreset: "楼层预设"
        case .conversation: "对话"
        case .worldBook: "楼层世界书"
        case .globalWorldBook: "全局世界书"
        case .preset: "预设模板"
        case .globalRegex: "全局正则"
        case .persona: "用户身份"
        case .attachment: "附件"
        case nil: raw
        }
    }

    /// 新建的对象，按目标类别；0 的不列
    static func objectRows(_ report: SillyTavernImportReport) -> [Row] {
        ImportTarget.Kind.allCases.compactMap { kind in
            guard let count = report.objects[kind.rawValue], count > 0 else { return nil }
            return Row(title: kindTitle(kind.rawValue), value: "\(count)")
        }
    }

    static func issueRows(_ report: SillyTavernImportReport) -> [IssueRow] {
        report.issues.enumerated().map { index, issue in
            var location = issue.relativePath
            if let line = issue.line { location += " · 第 \(line) 行" }
            if let field = issue.field { location += " · \(field)" }
            return IssueRow(id: index, location: location, reason: issue.reason, action: issue.action, retryable: issue.retryable)
        }
    }

    static func headline(_ report: SillyTavernImportReport) -> String {
        let created = report.objects.filter { $0.key != ImportTarget.Kind.attachment.rawValue }.values.reduce(0, +)
        let skipped = report.categories.reduce(0) { $0 + $1.skipped }
        if created == 0 && report.isReimport {
            return "没有新东西 · \(skipped) 个文件和上次一样，全部跳过"
        }
        return report.issues.isEmpty ? "导入已完成" : "导入已完成 · 还有 \(report.issues.count) 项问题"
    }

    /// 「去卡墙看看」定位到的卡：本批新建的第一张（按相对路径）
    static func firstCardId(source: ImportSource?, batchId: String) -> String? {
        guard let source else { return nil }
        for path in source.files.keys.sorted() {
            for version in source.files[path] ?? [] where version.batchId == batchId {
                if let card = version.targets.first(where: { $0.kind == .card && $0.retractedAt == nil }) { return card.id }
            }
        }
        return nil
    }

    // MARK: - 来源列表

    struct BatchRow: Equatable, Identifiable {
        let id: String
        let date: Date
        let reportFile: String
        /// 本批新建的对象数（不算附件）
        let objectCount: Int
        /// 其中撤回后已删 / 已不在的
        let retractedCount: Int
        let retractedAt: Date?
    }

    /// 新的在前
    static func batchRows(_ source: ImportSource) -> [BatchRow] {
        var all: [String: Set<String>] = [:]
        var gone: [String: Set<String>] = [:]
        for versions in source.files.values {
            for version in versions {
                for target in version.targets where target.kind != .attachment {
                    all[version.batchId, default: []].insert(target.id)
                    if target.retractedAt != nil { gone[version.batchId, default: []].insert(target.id) }
                }
            }
        }
        return source.batches.map {
            BatchRow(id: $0.id, date: $0.date, reportFile: $0.reportFile, objectCount: all[$0.id]?.count ?? 0,
                     retractedCount: gone[$0.id]?.count ?? 0, retractedAt: $0.retractedAt)
        }.sorted { $0.date > $1.date }
    }

    static func batchSubtitle(_ row: BatchRow, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDate(row.date, equalTo: now, toGranularity: .year) ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        var parts = [formatter.string(from: row.date), row.objectCount == 0 ? "没有新对象" : "\(row.objectCount) 个对象"]
        if row.retractedAt != nil { parts.append("已撤回 \(row.retractedCount) 个") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 撤回结果

    struct RetractGroup: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let items: [RetractLine]
    }

    struct RetractLine: Equatable, Identifiable {
        var id: String { objectId + kind }
        let objectId: String
        let kind: String
        let title: String
        let reason: String
    }

    static let retractConfirmMessage = "只删导入以后没改过、也没被别的东西用到的。改过的（加过消息、改过名字、改过设定…）会留下，结果里逐项列出来；原件和报告都保留。"

    static func retractSummary(_ report: SillyTavernRetractReport) -> String {
        "删了 \(report.count(.deleted)) 项，留下 \(report.count(.kept)) 项" + (report.count(.alreadyGone) > 0 ? "，\(report.count(.alreadyGone)) 项已经不在" : "")
    }

    /// 留 → 删 → 已不在；组内按类别、路径
    static func retractGroups(_ report: SillyTavernRetractReport) -> [RetractGroup] {
        let order: [(SillyTavernRetractReport.Item.Action, String)] = [(.kept, "留下"), (.deleted, "删掉"), (.alreadyGone, "已经不在")]
        return order.compactMap { action, title in
            let items = report.items.filter { $0.action == action }
                .sorted { (kindTitle($0.kind), $0.relativePath) < (kindTitle($1.kind), $1.relativePath) }
                .map { RetractLine(objectId: $0.id, kind: $0.kind, title: "\(kindTitle($0.kind)) · \($0.relativePath)", reason: $0.reason) }
            return items.isEmpty ? nil : RetractGroup(title: "\(title)（\(items.count)）", items: items)
        }
    }

    // MARK: - 错误

    struct FailureText: Equatable {
        let message: String
        /// 上次导入没收尾：给「去恢复」
        let needsRecovery: Bool
    }

    /// 导入 / 撤回失败怎么说。磁盘满 / 限额 / 权限都说清原因，且明说「没有导入」
    static func failure(_ error: Error) -> FailureText {
        if let failure = error as? SillyTavernImportCommitter.Failure, case .batchPending = failure {
            return FailureText(message: "上次导入没收尾。先恢复（清掉没写完的那批，或把已经写好的收尾），再重新导入。", needsRecovery: true)
        }
        let nothing = "这次没有导入任何东西。"
        if let package = error as? SillyTavernPackageError {
            return FailureText(message: (package.errorDescription ?? "盘点失败") + "。" + nothing, needsRecovery: false)
        }
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let codes = [ns, underlying].compactMap { $0 }
        if codes.contains(where: { ($0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)) }) {
            return FailureText(message: "磁盘空间不够，写到一半停下了；已经写的都清掉了。" + nothing + "腾出空间再试。", needsRecovery: false)
        }
        let permissionCodes = [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue]
        if codes.contains(where: { ($0.domain == NSCocoaErrorDomain && permissionCodes.contains($0.code))
            || ($0.domain == NSPOSIXErrorDomain && ($0.code == Int(EACCES) || $0.code == Int(EPERM))) }) {
            return FailureText(message: "没有读写权限（\(error.localizedDescription)）。" + nothing + "重新选一次文件再试。", needsRecovery: false)
        }
        if let failure = error as? SillyTavernImportCommitter.Failure, case .rollback = failure {
            return FailureText(message: (failure.errorDescription ?? "") + "。下次打开 app 会再清一次；清完之前不能再导入。", needsRecovery: true)
        }
        return FailureText(message: error.localizedDescription + "。" + nothing, needsRecovery: false)
    }

    static func recoveryText(_ outcome: SillyTavernImportCommitter.RecoveryOutcome) -> String {
        switch outcome {
        case .none: "没有要恢复的，可以直接导入。"
        case .rolledBack(_, let targets): "上次没写完的那批已经清掉（\(targets) 项），可以重新导入。"
        case .finished: "上次的导入已经收尾，东西都在。可以继续。"
        }
    }
}
