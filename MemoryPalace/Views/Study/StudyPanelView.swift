import SwiftUI
import SwiftData

/// page2「学堂」（plan-study-zero-engine §4.3 E1 / §4.11）：当前对话不在学堂里 = 课程列表（开一门课 + 模板状态条 + 课）；
/// 在学堂里 = 课堂（顶栏 + 这门课的 HTML 笔记）。引擎版的课程主页在这个页面上往下长。
struct StudyPanelView: View {
    var viewModel: ConversationViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @AppStorage("selectedChatModel") private var globalModelId = ""
    /// 「有新版，你改过这份」点了「不用了」的文件夹 id（逗号串，按模板版本分 key）
    @AppStorage("studyUpgradeDismissed_v\(StudyTemplate.version)") private var dismissedUpgradeIds = ""

    @State private var folders: [ConversationTag] = []
    @State private var courses: [Conversation] = []
    @State private var showStart = false
    @State private var browsingList = false
    @State private var notePath: String?

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    private var classroomConversation: Conversation? {
        guard !browsingList, let conversation = viewModel.selectedConversation,
              let folderId = conversation.folderId, folders.contains(where: { $0.id == folderId }) else { return nil }
        return conversation
    }

    var body: some View {
        Group {
            if let conversation = classroomConversation {
                classroom(conversation)
            } else {
                courseList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolPageBackground(Theme.mainBg)
        .onAppear(perform: reload)
        .onChange(of: profileId) { _, _ in reload() }
        .onChange(of: viewModel.selectedConversation?.id) { _, _ in
            browsingList = false
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationTagsChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .fileLibraryDidChange)) { _ in
            if notePath == nil { reloadNotePath() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            folders = []
            courses = []
            notePath = nil
        }
        .sheet(isPresented: $showStart) {
            StudyStartSheet(viewModel: viewModel)
        }
    }

    // MARK: - 课程列表

    private var courseList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(folders) { folder in
                    templateBanner(folder)
                }
                if courses.isEmpty {
                    Text("还没有课。点上面的「开一门课」")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(courses) { course in
                            courseRow(course)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "graduationcap")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("学堂")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button { showStart = true } label: {
                Label("开一门课", systemImage: "plus")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accent.opacity(0.6)))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func templateBanner(_ folder: ConversationTag) -> some View {
        let label = folders.count > 1 ? "「\(folder.name)」" : "这份"
        switch StudyTemplate.status(of: folder.instructions) {
        case .currentModified:
            Text("你改过\(label)学堂说明")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
        case .outdated:
            bannerCard("\(label)学堂说明有新版，正在上的课也会用新说明") {
                Button("更新") { StudyTemplate.upgrade(folder: folder, context: modelContext) }
            }
        case .outdatedModified where !hasCurrentFolder && !dismissedIds.contains(folder.id):
            bannerCard("学堂说明有新版，你改过\(label)") {
                Button("另建一个新版学堂") { StudyTemplate.forkUpgrade(profileId: profileId, context: modelContext) }
                Button("不用了") { dismissedUpgradeIds = (dismissedIds + [folder.id]).joined(separator: ",") }
            }
        default:
            EmptyView()
        }
    }

    private var dismissedIds: [String] { dismissedUpgradeIds.split(separator: ",").map(String.init) }

    private var hasCurrentFolder: Bool {
        folders.contains { (StudyTemplate.parse(instructions: $0.instructions)?.version ?? 0) >= StudyTemplate.version }
    }

    private func bannerCard<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textPrimary)
            HStack(spacing: 14) { actions() }
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(Theme.branchIndicator)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.branchIndicator.opacity(0.10)))
    }

    private func courseRow(_ course: Conversation) -> some View {
        Button { open(course) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(course.title)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(course.updateTime, style: .date)
                    if isClaudeCode(course) {
                        Text("Claude Code")
                    }
                }
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sidebarBg.opacity(0.7)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isClaudeCode(_ course: Conversation) -> Bool {
        guard let pm = providerManager else { return false }
        let model = pm.resolveModel(conversationModelId: course.selectedModelId, globalFallbackId: globalModelId)
        guard let credential = pm.provider(for: model) else { return false }
        return credential.type == .ccBridge && credential.id != APIProvider.codexBridge.id
    }

    // MARK: - 课堂

    private func classroom(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(conversation.title)
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { browsingList = true } label: {
                    Label("课程列表", systemImage: "chevron.left")
                }
                if let notePath {
                    Button {
                        navigator?.pendingTarget = .init(tool: "fileLibrary", id: notePath)
                    } label: {
                        Label("文件库", systemImage: "folder")
                    }
                }
                #if os(iOS)
                if horizontalSizeClass == .compact {
                    Button {
                        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
                    } label: {
                        Label("回到聊天", systemImage: "bubble.left")
                    }
                }
                #endif
            }
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .font(.system(size: Theme.F.secondary))
            .buttonStyle(.plain)
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            StudyNotePane(notePath: notePath, conversationId: conversation.id, profileId: profileId,
                          toolsAvailable: toolsAvailable(conversation), isClaudeCode: isClaudeCode(conversation),
                          refreshKey: .init(updated: conversation.updateTime, tailId: viewModel.currentPath.last?.id,
                                            tailLength: viewModel.currentPath.last?.content.utf8.count ?? 0))
        }
    }

    private func toolsAvailable(_ conversation: Conversation) -> Bool {
        guard let pm = providerManager else { return true }
        let model = pm.resolveModel(conversationModelId: conversation.selectedModelId, globalFallbackId: globalModelId)
        return pm.provider(for: model)?.toolsSupported != false
    }

    // MARK: - 数据

    private func reload() {
        guard !profileId.isEmpty else { return }
        folders = StudyTemplate.studyFolders(profileId: profileId, context: modelContext)
        let folderIds = Set(folders.map(\.id))
        let pid = profileId
        // folderId 是 optional，#Predicate 直接比较会静默查不到（SidebarView.folderConversationIds 同法）：按楼层取、内存里筛
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid && !$0.isTrashed },
            sortBy: [SortDescriptor(\.updateTime, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.id, \.folderId, \.title, \.updateTime, \.selectedModelId]
        let all = (try? modelContext.fetch(descriptor)) ?? []
        courses = all.filter { $0.folderId.map(folderIds.contains) ?? false }
        reloadNotePath()
    }

    private func reloadNotePath() {
        guard let conversation = viewModel.selectedConversation, !viewModel.isDraftConversation else {
            notePath = nil
            return
        }
        notePath = StudyNotePane.notePath(conversationId: conversation.id, profileId: profileId, context: modelContext)
    }

    private func open(_ course: Conversation) {
        let id = course.id
        let pid = profileId
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate {
            $0.id == id && $0.profileId == pid && !$0.isTrashed
        })
        guard let selected = try? modelContext.fetch(descriptor).first else {
            ToastCenter.shared.show("这门课已经不在了")
            reload()
            return
        }
        viewModel.loadConversation(selected, context: modelContext)
        browsingList = false
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
    }
}
