import SwiftUI

// MARK: - 楼层记忆树浏览（文件库首页「记忆」+ 设置里「查看同步过来的文件」共用）
// 文件库首页只列 filesystem/；记忆树（AI 自己的记忆 / 摘要 / 画像 / 日记 / 心声 / CC 同步来的笔记）一直只有 AI 用 fs 工具翻得到。
// 这里给人一个入口：按子文件夹分组。AI 自己的记忆（memory/self/）可编辑（第二刀 B4），其余只读、可选中复制。

struct MemoryTreeBrowserSheet: View {
    let profileId: String
    /// 只看某个子文件夹（如 "cc"）；nil = 整棵树
    var onlyFolder: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var groups: [MemoryTreeGroup] = []
    @State private var selfMemories: [SelfMemory] = []

    /// UI 名字用楼层变量，不写死
    private var assistantName: String {
        let n = profileManager?.profiles.first { $0.id == profileId }?.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty && selfMemories.isEmpty {
                    Text("这里还没有东西")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                        .listRowBackground(Theme.mainBg)
                }
                if onlyFolder == nil, !selfMemories.isEmpty {
                    Section("\(assistantName)的记忆 · \(selfMemories.filter(\.isActive).count) · 可编辑") {
                        ForEach(selfMemories, id: \.slug) { m in
                            NavigationLink {
                                SelfMemoryEditView(profileId: profileId, slug: m.slug, onChange: reload)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.description.isEmpty ? m.name : m.description)
                                        .font(.system(size: Theme.F.body))
                                        .foregroundColor(m.isActive ? Theme.textPrimary : Theme.textMuted)
                                        .lineLimit(2)
                                    Text("\(m.importance) 级 · \(m.created.formatted(.dateTime.month().day()))\(m.isActive ? "" : " · 已删除")")
                                        .font(.system(size: Theme.F.caption))
                                        .foregroundColor(Theme.textMuted)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                }
                ForEach(groups.filter { $0.folder != SelfMemoryStore.folder }) { group in
                    Section("\(group.title) · \(group.files.count)") {
                        ForEach(group.files, id: \.path) { meta in
                            NavigationLink {
                                MemoryTreeFileView(path: meta.path, profileId: profileId)
                            } label: {
                                Text(String(meta.path.dropFirst(group.prefix.count)))
                                    .font(.system(size: Theme.F.body))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(onlyFolder == "cc" ? "CC 同步来的笔记" : "记忆")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 620)
        #endif
        .onAppear(perform: reload)
    }

    private func reload() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("MemoryTreeBrowserSheet.reload") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        groups = MemoryTreeGroup.group(FileLibraryStore.memoryList(profileId: profileId), onlyFolder: onlyFolder)
        // 活着的在前（新→旧），已失效的放最后
        let all = onlyFolder == nil ? SelfMemoryStore.list(profileId: profileId) : []
        selfMemories = all.filter(\.isActive) + all.filter { !$0.isActive }
    }
}

struct MemoryTreeGroup: Identifiable, Equatable {
    let folder: String          // 第一层子文件夹名；"" = 直接放在 memory/ 下的
    let files: [FileLibraryStore.FileMeta]
    var id: String { folder }
    var prefix: String { FileLibraryStore.memoryVirtualPrefix + (folder.isEmpty ? "" : folder + "/") }

    static let titles: [String: String] = [
        "": "画像等", "summaries": "旧对话摘要", "daily": "旧日记",
        "heartvoice": "心声", "cc": "CC 同步来的笔记", "self": "自己的记忆",
        "sessions": "上下文摘要", "windows": "窗口总结", "timeline": "时间轴",
    ]
    var title: String { Self.titles[folder] ?? folder }

    static func == (lhs: MemoryTreeGroup, rhs: MemoryTreeGroup) -> Bool {
        lhs.folder == rhs.folder && lhs.files.map(\.path) == rhs.files.map(\.path)
    }

    /// 纯函数：按 memory/ 下第一层分组；已知分组排前面，其余按名字
    static func group(_ list: [FileLibraryStore.FileMeta], onlyFolder: String?) -> [MemoryTreeGroup] {
        var buckets: [String: [FileLibraryStore.FileMeta]] = [:]
        for meta in list where meta.path.hasPrefix(FileLibraryStore.memoryVirtualPrefix) {
            let rel = meta.path.dropFirst(FileLibraryStore.memoryVirtualPrefix.count)
            let parts = rel.split(separator: "/", maxSplits: 1)
            let folder = parts.count > 1 ? String(parts[0]) : ""
            if let onlyFolder, folder != onlyFolder { continue }
            buckets[folder, default: []].append(meta)
        }
        let order = ["self", "", "timeline", "windows", "sessions", "summaries", "daily", "heartvoice", "cc"]
        return buckets.keys
            .sorted { a, b in
                let ia = order.firstIndex(of: a) ?? order.count
                let ib = order.firstIndex(of: b) ?? order.count
                return ia != ib ? ia < ib : a < b
            }
            .map { MemoryTreeGroup(folder: $0, files: buckets[$0]!.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) }
    }
}

/// 只读看一份：CC 同步来的去掉来源头注释；可选中复制
private struct MemoryTreeFileView: View {
    let path: String
    let profileId: String
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.sidebarBg)
        .navigationTitle(String(path.split(separator: "/").last ?? ""))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            let raw = (try? FileLibraryStore.memoryRead(path, profileId: profileId)) ?? "（读不到这份文件）"
            text = CCMemorySync.unwrap(raw)
        }
    }
}

/// 第二刀 B4：她改 AI 自己的一条记忆——摘要、类型、重要度、正文；标失效 / 复活。不能新建（「记住」是 AI 的事）
struct SelfMemoryEditView: View {
    let profileId: String
    let slug: String
    var onChange: () -> Void = {}
    /// 弹层壳传进来：右上「完成」有没存的改动先存，存失败不关
    var onDone: (() -> Void)? = nil

    @State private var memory: SelfMemory?
    @State private var descriptionText = ""
    @State private var type = "user"
    @State private var importance = 3
    @State private var bodyText = ""
    @State private var saveError: String?

    private static let typeLabels: [(String, String)] = [
        ("user", "关于你"), ("feedback", "你的要求"), ("project", "在做的事"), ("reference", "资料指路"),
    ]

    var body: some View {
        List {
            if let m = memory {
                Section {
                    TextField("一行摘要", text: $descriptionText)
                    Picker("类型", selection: $type) {
                        ForEach(Self.typeLabels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    HStack {
                        Text("重要度")
                        Spacer()
                        ForEach(1...5, id: \.self) { i in
                            Button {
                                importance = i
                            } label: {
                                Image(systemName: i <= importance ? "circle.fill" : "circle")
                                    .foregroundColor(Theme.branchIndicator)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("记于 \(m.created.formatted(.dateTime.year().month().day().hour().minute())) · \(Self.originText(m.origin))\(m.isActive ? "" : " · 已删除")")
                }
                .listRowBackground(Theme.mainBg)
                Section("正文") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                }
                .listRowBackground(Theme.mainBg)
                Section {
                    Button("保存") { save(m) }
                        .foregroundColor(Theme.branchIndicator)
                    Button(m.isActive ? "删除" : "恢复") { toggleActive(m) }
                        .foregroundColor(m.isActive ? Theme.textMuted : Theme.branchIndicator)
                }
                .listRowBackground(Theme.mainBg)
                if let saveError {
                    Text(saveError)
                        .foregroundColor(Theme.danger)
                        .listRowBackground(Theme.mainBg)
                }
            } else {
                Text("这份记忆读不出来（格式坏了或被删了）")
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.mainBg)
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .tint(Theme.branchIndicator)
        .navigationTitle(memory.map { $0.description.isEmpty ? $0.name : $0.description } ?? slug)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if onDone != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { done() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .onAppear(perform: load)
    }

    /// 表单和读进来的那份有没有不一样（「完成」据此决定要不要先存）
    static func hasUnsavedEdits(_ m: SelfMemory, description: String, type: String, importance: Int, body: String) -> Bool {
        description != m.description || type != m.type || importance != m.importance || body != m.body
    }

    private func done() {
        if let m = memory,
           Self.hasUnsavedEdits(m, description: descriptionText, type: type, importance: importance, body: bodyText) {
            guard save(m) else { return }
        }
        onDone?()
    }

    static func typeText(_ type: String) -> String {
        typeLabels.first { $0.0 == type }?.1 ?? type
    }

    static func originText(_ origin: String) -> String {
        switch origin {
        case "asked": return "你让记的"
        case "edited": return "你改过"
        default: return "自己想记的"
        }
    }

    private func load() {
        guard let m = SelfMemoryStore.list(profileId: profileId).first(where: { $0.slug == slug }) else { memory = nil; return }
        memory = m
        descriptionText = m.description
        type = m.type
        importance = m.importance
        bodyText = m.body
    }

    @discardableResult
    private func write(_ m: SelfMemory) -> Bool {
        do {
            try SelfMemoryStore.save(m, profileId: profileId)
            saveError = nil
            memory = m
            onChange()
            return true
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func save(_ m: SelfMemory) -> Bool {
        var updated = m
        updated.description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.type = type
        updated.importance = SelfMemoryStore.clampImportance(importance)
        updated.body = bodyText
        updated.origin = "edited"
        return write(updated)
    }

    private func toggleActive(_ m: SelfMemory) {
        var updated = m
        updated.superseded = m.isActive ? Date() : nil
        write(updated)
    }
}

/// 小克的记忆编辑页的弹层壳：文件库「记忆」文件夹和记忆面板共用这一个
struct SelfMemoryEditSheet: View {
    let profileId: String
    let slug: String
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelfMemoryEditView(profileId: profileId, slug: slug, onChange: onChange, onDone: { dismiss() })
        }
        #if os(macOS)
        .frame(width: 560, height: 620)
        #endif
    }
}
