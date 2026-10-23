import SwiftUI
import SwiftData

/// 设置 › 数据与备份 › 补原图（#057）：已导进来的 Claude / ChatGPT 对话里只有占位的图，按编号从下好的文件夹填回去。
/// 看缺多少 → 选文件夹 → 预览 → 补上 → 完成（可在导入历史撤回）。样式照导入页（#043）。
struct ImageBackfillView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var session = ImageBackfillSession()
    @State private var showFolderPicker = false

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        let _ = themeManager?.themeChangeID
        Group {
            #if os(iOS)
            NavigationStack {
                List { content }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Theme.sidebarBg)
                    .navigationTitle("补原图")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { dismiss() }
                                .foregroundColor(session.isBusy ? Theme.textMuted : Theme.branchIndicator)
                                .disabled(session.isBusy)
                        }
                    }
            }
            #else
            VStack(spacing: 0) {
                HStack {
                    Text("补原图")
                        .font(.title3.weight(.medium))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button("关闭") { dismiss() }
                        .disabled(session.isBusy)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
            }
            .frame(minWidth: 460, idealWidth: 480, minHeight: 440, idealHeight: 560)
            .background(Theme.mainBg)
            #endif
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): session.open(url, container: modelContext.container, profileId: profileId)
            case .failure(let error): session.fail("选文件夹出错：\(error.localizedDescription)")
            }
        }
        .interactiveDismissDisabled(session.isBusy)
        .task { session.load(container: modelContext.container, profileId: profileId) }
        .onDisappear { session.reset() }
    }

    // MARK: - 各状态

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading: busyGroup("正在查", "在找这个楼层里还缺原图的对话…")
        case .idle: idleContent
        case .reading: busyGroup("正在读文件夹", "核对编号和图片…")
        case .preview(let preview): previewContent(preview)
        case .applying(let fraction): applyingContent(fraction)
        case .done(let result): doneContent(result)
        case .failed(let message): failedContent(message)
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        if let inventory = session.inventory {
            group("这个楼层里还缺原图的", footer: "只补图片；文档类附件（pdf、md…）不在这里补。") {
                ForEach(ImageBackfill.Source.allCases) { source in
                    let missing = inventory.missingIds(source).count
                    resultRow(source.displayName, "\(missing) 张",
                              missing > 0 ? "在 \(inventory.conversationsWithPlaceholders(source)) 段对话里" : nil)
                }
                if (inventory.conversationCount[.chatgpt] ?? 0) > 0, inventory.missingIds(.chatgpt).isEmpty {
                    howToText("你的 ChatGPT 对话如果是以前导入的，图片当时没留位置。先去 导入对话 开「叠加」把 OpenAI 包再导一次，这里才有得补。")
                }
            }
        }
        group("补法", footer: "只按文件名里的编号对，不按图片名字猜。补进去的图可以在 导入历史 整次撤回。") {
            howToText("导出包里没有这些图，只有编号，花园自己补不了。要你另外给一个文件夹：把原图按编号下到一个文件夹（文件名就是编号，比如 1f3c….png），在这里选这个文件夹。")
        }
        primaryButton("选下好的文件夹", enabled: !(session.inventory?.byId.isEmpty ?? true)) { showFolderPicker = true }
    }

    @ViewBuilder
    private func previewContent(_ preview: ImageBackfill.Preview) -> some View {
        group("能补上的", footer: "存进文件库各对话的附件文件夹，约 \(Self.bytes(preview.fillableBytes))。") {
            if preview.isEmpty {
                howToText("文件夹里没有这个楼层能用上的图。")
            }
            ForEach(preview.sources) { source in
                resultRow(source.displayName, "\(preview.placeholderCount[source] ?? 0) 处",
                          "在 \(preview.conversationCount[source] ?? 0) 段对话里")
            }
        }
        let missing = preview.stillMissing.values.reduce(0, +)
        if preview.notInFloor + preview.notImage.count + missing > 0 {
            group("补不上的") {
                if missing > 0 {
                    resultRow("还缺", "\(missing) 张",
                              preview.reportedNotFound > 0 ? "其中 \(preview.reportedNotFound) 张下载时服务器说找不到" : "文件夹里没有")
                }
                if !preview.notImage.isEmpty {
                    resultRow("不是图片", "\(preview.notImage.count) 个", "多半是下载失败存下来的报错页")
                }
                if preview.notInFloor > 0 {
                    resultRow("这层楼没有", "\(preview.notInFloor) 个", "编号不在这个楼层的对话里（可能在别的楼层）")
                }
            }
        }
        primaryButton("补上", enabled: !preview.isEmpty) { session.apply() }
        secondaryButton("换一个文件夹") { session.backToIdle() }
    }

    private func applyingContent(_ fraction: Double) -> some View {
        group("正在补") {
            ProgressView(value: fraction)
                .tint(Theme.branchIndicator)
            Text("别关这个页面。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
        }
    }

    @ViewBuilder
    private func doneContent(_ result: ImageBackfill.Result) -> some View {
        group("补好了", footer: "可在 数据与备份 › 导入历史 整次撤回：只把补进去的图换回占位，对话里别的内容不动。") {
            ForEach(ImageBackfill.Source.allCases.filter { (result.filled[$0] ?? 0) > 0 }) { source in
                resultRow(source.displayName, "\(result.filled[source] ?? 0) 处",
                          "在 \(result.conversations[source] ?? 0) 段对话里")
            }
            if !result.failed.isEmpty {
                resultRow("没补上", "\(result.failed.count) 张", "读不出来或存不进文件库，还是占位")
            }
        }
        primaryButton("完成", enabled: true) { dismiss() }
    }

    @ViewBuilder
    private func failedContent(_ message: String) -> some View {
        group("出错了") {
            Text(message)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        secondaryButton("返回") { session.backToIdle() }
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    // MARK: - 小部件（同导入页：iOS 是 List 的 Section / 行，mac 是卡片）

    @ViewBuilder
    private func group<C: View>(_ title: String?, footer: String? = nil, @ViewBuilder _ rows: () -> C) -> some View {
        #if os(iOS)
        Section {
            rows()
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer).font(.system(size: Theme.F.caption)) }
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
        #else
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: Theme.F.secondary, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 10) { rows() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.sidebarBg))
            if let footer {
                Text(footer)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif
    }

    private func resultRow(_ title: String, _ value: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: Theme.F.secondary, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private func busyGroup(_ title: String, _ text: String) -> some View {
        group(title) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func howToText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        Section {
            Button(action: action) {
                HStack { Spacer(); Text(title); Spacer() }
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .listRowBackground(enabled ? Theme.branchIndicator : Theme.textMuted)
        }
        .listRowSeparator(.hidden)
        #else
        HStack {
            Spacer()
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(Theme.branchIndicator)
                .disabled(!enabled)
        }
        #endif
    }

    @ViewBuilder
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        Section {
            Button(action: action) {
                HStack { Spacer(); Text(title); Spacer() }
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.branchIndicator)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        #else
        HStack {
            Spacer()
            Button(title, action: action)
        }
        #endif
    }
}

/// 补原图页的状态。扫描 / 读文件夹 / 写库都在后台跑
@MainActor
@Observable
final class ImageBackfillSession {
    enum Phase {
        case loading
        case idle
        case reading
        case preview(ImageBackfill.Preview)
        case applying(Double)
        case done(ImageBackfill.Result)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var inventory: ImageBackfill.Inventory?
    private var container: ModelContainer?
    private var profileId = ""
    /// iOS 选的文件夹要一直拿着访问权，直到补完
    private var folderURL: URL?
    private var scoped = false

    var isBusy: Bool {
        switch phase {
        case .loading, .reading, .applying: true
        default: false
        }
    }

    func load(container: ModelContainer, profileId: String) {
        self.container = container
        self.profileId = profileId
        phase = .loading
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ImageBackfill.scan(profileId: profileId, context: ModelContext(container)) }
            }.value
            switch result {
            case .success(let inventory):
                self.inventory = inventory
                phase = .idle
            case .failure(let error):
                phase = .failed("查不出来：\(error.localizedDescription)")
            }
        }
    }

    func open(_ url: URL, container: ModelContainer, profileId: String) {
        releaseFolder()
        guard let inventory else { return }
        folderURL = url
        scoped = url.startAccessingSecurityScopedResource()
        phase = .reading
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { ImageBackfill.preview(inventory: inventory, folder: try ImageBackfill.readFolder(url)) }
            }.value
            switch result {
            case .success(let preview): phase = .preview(preview)
            case .failure(let error): fail("读不了这个文件夹：\(error.localizedDescription)")
            }
        }
    }

    func apply() {
        guard case .preview(let preview) = phase, let inventory, let container, let folderURL else { return }
        let profileId = profileId
        let folderName = folderURL.lastPathComponent
        phase = .applying(0)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ImageBackfill.apply(preview: preview, inventory: inventory, folderName: folderName,
                                            profileId: profileId, container: container) { fraction in
                        Task { @MainActor in
                            if case .applying = self.phase { self.phase = .applying(fraction) }
                        }
                    }
                }
            }.value
            releaseFolder()
            switch result {
            case .success(let done): phase = .done(done)
            case .failure(let error): phase = .failed("补到一半出错：\(error.localizedDescription)\n已经补上的可以在导入历史撤回。")
            }
        }
    }

    func backToIdle() {
        releaseFolder()
        guard let container else { return }
        load(container: container, profileId: profileId)
    }

    func fail(_ message: String) {
        releaseFolder()
        phase = .failed(message)
    }

    func reset() {
        releaseFolder()
    }

    private func releaseFolder() {
        if scoped { folderURL?.stopAccessingSecurityScopedResource() }
        scoped = false
        folderURL = nil
    }
}
