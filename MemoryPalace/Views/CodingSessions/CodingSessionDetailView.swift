#if os(macOS)
import AppKit
import SwiftUI

/// 主区域编程会话详情（plan-wake-native N0）：详情头五层 + 阅读面；加载失败不退化成空白（R-WN #4）。
struct CodingSessionDetailView: View {
    /// 全屏模式下这页也装在正文卡里，底由卡出（见 MacChatCard）
    @Environment(\.macChatCarded) private var macChatCarded
    @State private var resumeError: String?
    @State private var flashSeq: Int?
    /// 阶段 B7：跟这条会话说话（复用聊天页的 `InputFieldContainer`）
    @State private var composerText = ""
    @State private var composerDropTargeted = false
    @FocusState private var composerFocused: Bool
    @State private var pendingDelete: CodingSessionMeta?
    @State private var previewImage: CodingImagePreviewItem?
    /// 刚复制过 SSH 命令的会话（按钮原地变「已复制」1.6 s，不弹通知）
    @State private var copiedKey: String?

    private var library: CodingSessionLibrary { .shared }

    /// 连着的同一个角色只在第一条出「谁 + 什么时候」（她 09-16：「这不是还是好多时间戳…一个消息一个时间戳吧」）。
    /// 她眼中的「一条消息」是一整轮，jsonl 里却是十几条——每个工具调用各占一条，挨个出行头就成了一屏的
    /// `Claude Code 5:59 AM`。压缩摘要 / 注入内容这类非消息块会打断这一轮
    static func showsHeader(_ visible: [CodingMessage], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let prev = visible[index - 1]
        guard prev.kind == .text, visible[index].kind == .text else { return true }
        return prev.role != visible[index].role
    }

    /// 只有 thinking、没有正文也没有工具调用的中间事件不进阅读视图（Wake DESIGN §对话阅读面）
    static func isThinkingOnly(_ message: CodingMessage) -> Bool {
        guard message.role == .assistant, message.kind == .text else { return false }
        return message.text.isEmpty && message.toolCalls.isEmpty && message.imageCount == 0
    }

    var body: some View {
        Group {
            if library.isInsightsPresented {
                CodingInsightsView()
            } else {
            switch library.detail {
            case .idle:
                placeholder(icon: "terminal", title: "没有选中的会话", subtitle: "从左侧 code 组里选一条。")
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(_, let message, let filePath):
                failure(message: message, filePath: filePath)
            case .loaded(let box):
                loaded(box.transcript)
                    .environment(\.openURL, OpenURLAction { url in openLink(url, meta: box.transcript.meta) })
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(macChatCarded ? Color.clear : Theme.mainBg)
        .overlay {
            if let item = previewImage {
                CodingImagePreview(item: item) { previewImage = nil }
            }
        }
        .onChange(of: library.selectedKey) { _, _ in previewImage = nil }
        .confirmationDialog("删除这条编程会话？",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { meta in
            Button("移到废纸篓", role: .destructive) {
                library.delete(meta) { resumeError = $0 }
            }
            Button("取消", role: .cancel) {}
        } message: { meta in
            let plan = library.deletionPlan(for: meta)
            let subtree = plan.sessions.count > 1 ? "连同它的 \(plan.sessions.count - 1) 个子会话，" : ""
            Text(subtree + "这些文件会移到废纸篓（可以从废纸篓恢复），之后不再出现在列表里：\n" + plan.paths.joined(separator: "\n"))
        }
    }

    // MARK: - 已加载

    private func loaded(_ transcript: CodingParsedTranscript) -> some View {
        let meta = transcript.meta
        let visible = transcript.mainline.filter { !Self.isThinkingOnly($0) }
        return VStack(spacing: 0) {
            header(meta)
            Divider()
            ScrollViewReader { proxy in
            MacCodingTranscriptScroll(sessionKey: meta.key, revision: library.detailRevision, focusSeq: library.focusSeq) {
                LazyVStack(alignment: .leading, spacing: MacShellMetrics.shared[.messageGap]) {
                    ForEach(Array(visible.enumerated()), id: \.element.seq) { index, message in
                        CodingMessageRow(message: message, agent: meta.agent,
                                         showsHeader: Self.showsHeader(visible, index)) { image in
                            previewImage = CodingImagePreviewItem(image: image,
                                                                  suggestedName: "\(meta.projectName.isEmpty ? "image" : meta.projectName)-\(message.seq)")
                        }
                            .id(message.seq)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(flashSeq == message.seq ? Theme.branchIndicator.opacity(0.14) : Color.clear)
                                .padding(-6))
                    }
                    if transcript.unknownLines > 0 {
                        Text("\(transcript.unknownLines) 行未识别（格式更新或非消息行），已跳过。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, MacShellMetrics.shared[.contentPadX])
                .padding(.vertical, MacShellMetrics.shared[.contentPadY])
                .frame(maxWidth: .infinity)
            }
            .id(meta.key)
            .overlay(alignment: .topTrailing) {
                if library.isRefreshingDetail { ProgressView().controlSize(.small).padding(8) }
            }
            .overlay(alignment: .bottom) {
                if let error = library.detailRefreshError {
                    HStack {
                        Text(error).font(.caption).lineLimit(2)
                        Button("重试") { library.reloadDetail() }
                    }
                    .padding(8).background(Theme.mainBg)
                }
            }
            // ⌘K 命中：滚到那条并闪一下（1.5 s）
            .task(id: "\(meta.key)#\(library.focusSeq ?? -1)") {
                guard let seq = library.focusSeq else { return }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                proxy.scrollTo(seq, anchor: .top)
                flashSeq = seq
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if flashSeq == seq { withAnimation(.easeOut(duration: 0.4)) { flashSeq = nil } }
            }
            }
            // 阶段 B7：在这儿直接跟这条会话说话。正跑着就发进那个 tab；没跑就先续起来再发
            if meta.host.isEmpty, CodingSessionResume.canResume(meta.agent) {
                Divider()
                composer(meta)
                    .id(meta.key)   // 换会话不串草稿（R-B7 B5）
            }
        }
    }

    /// 跟这条会话说话（阶段 B7）：**直接复用聊天页那个输入框**（`InputFieldContainer`），她要的就是平常那个。
    /// 区别只在发出去之后走哪条路——这一句原样进 agent 的 TUI：正跑着就发进那个 tab，没跑就先在终端里续起来、等 agent 上来再发。
    /// 终端里正等她答选择题时不发（免得那个回车替她选，R-B7 B3）
    private func composer(_ meta: CodingSessionMeta) -> some View {
        let live = LocalTerminalStore.shared.session(forKey: meta.key)
        let waitingChoice = live.map { LocalTerminalLaunch.looksLikeChoicePrompt($0.screenText) } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            InputFieldContainer(
                text: $composerText,
                isFocused: $composerFocused,
                isResponding: false,
                hasAttachments: false,
                onSend: { text in sendToTerminal(meta, text: text) },
                onCancelStream: {},
                onStickerTap: nil,
                isCCBridge: false
            )
            .disabled(waitingChoice)
            // 拖文件进来 = 插路径（终端拖文件那种反斜杠转义）；agent 看到图片路径会自己读（plan-mac-code-mode-gaps §6）
            .onDrop(of: FileDrop.types, isTargeted: $composerDropTargeted) { providers in
                FileDrop.loadURLs(providers) { urls in
                    let paths = urls.map { FileDrop.shellEscaped($0.path) }.joined(separator: " ")
                    guard !paths.isEmpty else { return }
                    let sep = composerText.isEmpty || composerText.hasSuffix(" ") || composerText.hasSuffix("\n") ? "" : " "
                    composerText += sep + paths + " "
                    composerFocused = true
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.branchIndicator, lineWidth: 1.5)
                    .opacity(composerDropTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            Text(hint(live: live, waitingChoice: waitingChoice))
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func hint(live: LocalTerminalSession?, waitingChoice: Bool) -> String {
        if waitingChoice { return "终端里有个选择题等着你——先去那边答，这里就不替你按回车了。" }
        guard let live else { return "这条没在跑：发出去 = 在终端里续跑它，再把这句话交给它。" }
        if live.agent == nil { return "那个 tab 只剩 shell 了——发出去会先把 agent 续起来。" }
        return "发出去 = 在那个终端里敲这一句（\(live.agent?.displayName ?? "")）。"
    }

    /// 返回 true = 收下了（输入框会自己清空，与聊天页同一套约定）
    @discardableResult
    private func sendToTerminal(_ meta: CodingSessionMeta, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let store = LocalTerminalStore.shared
        if let live = store.session(forKey: meta.key) {
            live.refreshBadge()                 // 别拿 1 Hz 的旧缓存判（R-B7 B2）
            guard !LocalTerminalLaunch.looksLikeChoicePrompt(live.screenText) else { return false }
            if live.agent != nil {
                live.send(trimmed)
                return true
            }
        }
        // 没在跑（或那个 tab 只剩 shell）：照「继续 → 记忆花园」续起来，agent 上来再发
        resumeError = library.resume(meta, target: .memoryPalace)
        guard resumeError == nil, let tab = store.session(forKey: meta.key) else { return false }
        store.sendWhenReady(tab.id, text: trimmed) {
            composerText = trimmed              // 没起来就把话还给她，别默默吞了
            resumeError = "agent 没起来，这句话还给你了——去终端那边看看。"
        }
        return true
    }

    /// 正文链接（Wake `markdown_links`）：外链交系统；本机会话的文件路径在 Finder 里选中；远程会话的路径一律只读提示（不碰本机 HOME）
    private func openLink(_ url: URL, meta: CodingSessionMeta) -> OpenURLAction.Result {
        switch CodingLinkResolver.resolve(url.absoluteString, remote: !meta.host.isEmpty, projectPath: meta.projectPath,
                                          home: { FileManager.default.homeDirectoryForCurrentUser }) {
        case .external:
            return .systemAction
        case .ignore:
            return .handled
        case .file(let path):
            NSWorkspace.shared.activateFileViewerSelecting([path])
            return .handled
        case .remote:
            resumeError = CodingSessionLibrary.remoteReadOnly
            return .handled
        case .unavailable:
            resumeError = "这个路径在本机不可用"
            return .handled
        }
    }

    /// 远程会话的「继续」：复制 `ssh -t` 命令（Wake Copy SSH command，单段按钮无记忆）
    private func copySSHButton(_ meta: CodingSessionMeta, compact: Bool = false) -> some View {
        let copied = copiedKey == meta.key
        return Button {
            resumeError = library.copySSHCommand(meta)
            guard resumeError == nil else { return }
            copiedKey = meta.key
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if copiedKey == meta.key { copiedKey = nil }
            }
        } label: {
            Group {
                if compact { Image(systemName: copied ? "checkmark" : "terminal") }
                else { Label(copied ? "已复制" : "复制 SSH 命令", systemImage: copied ? "checkmark" : "terminal") }
            }
            .font(.system(size: Theme.F.caption, weight: .medium))
            .accessibilityLabel(copied ? "已复制" : "复制 SSH 命令")
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.branchIndicator)
        .controlSize(.small)
        .fixedSize()
        .help("复制在 \(meta.host) 上继续这条会话的 ssh 命令")
    }

    private func header(_ meta: CodingSessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                headerRow(meta, compact: false)
                headerRow(meta, compact: true)
            }
            if let resumeError {
                Text(resumeError)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, MacShellMetrics.shared[.headerPadX])
        .padding(.vertical, MacShellMetrics.shared[.headerPadY])
    }

    /// Full labels when they fit; compact controls must not impose their ideal
    /// width on the transcript and composer that share this vertical stack.
    private func headerRow(_ meta: CodingSessionMeta, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
                HStack(spacing: 5) {
                    Circle().fill(CodingSessionFormat.color(meta.agent)).frame(width: 7, height: 7)
                    Text(meta.agent.displayName)
                }
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: !compact, vertical: true)
                .help(meta.agent.displayName)
                // 远程会话的主机：薄荷描边（与侧栏的薄荷字同色相，不垫浅薄荷底）
                if !compact, !meta.host.isEmpty {
                    Text("@\(meta.host)")
                        .font(.system(size: Theme.F.caption, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().stroke(Theme.branchIndicator.opacity(0.6), lineWidth: 0.8))
                        .help("远程会话：只读，文件在 \(meta.host) 上")
                }
                if !compact, !meta.projectPath.isEmpty, !meta.host.isEmpty {
                    // 远端路径在本机不存在：只显示，不做打开按钮
                    Label(meta.projectName, systemImage: "folder")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help("远端路径：\(meta.projectPath)")
                } else if !compact, !meta.projectPath.isEmpty {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: meta.projectPath))
                    } label: {
                        Label(meta.projectName, systemImage: "folder")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .help("在 Finder 中打开项目目录")
                }
                if !compact, let branch = meta.gitBranch, !branch.isEmpty, !["HEAD", "detached", "detached HEAD"].contains(branch) {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                iconToggle(library.state.isFavorite(meta.key) ? "star.fill" : "star",
                           on: library.state.isFavorite(meta.key), help: "收藏") { library.toggleFavorite(meta.key) }
                iconToggle(library.state.isPinned(meta.key) ? "pin.fill" : "pin",
                           on: library.state.isPinned(meta.key), help: "置顶") { library.togglePin(meta.key) }
                // Kiro / Gemini / OpenClaw 没有按会话续跑的形制：不出这颗钮；远程会话只有「复制 SSH 命令」一项
                if !meta.host.isEmpty {
                    if CodingSessionResume.canResume(meta.agent) { copySSHButton(meta, compact: compact) }
                } else if let live = LocalTerminalStore.shared.session(forKey: meta.key) {
                    // 这条正在本机终端里跑着（阶段 B）：主钮换成回到那个 tab，不再开第二个
                    backToTerminalButton(live, agent: meta.agent, compact: compact)
                } else if let preferred = library.preferredTarget(for: meta.agent) {
                    Menu {
                        ForEach(CodingResumeTarget.installed(for: meta.agent), id: \.self) { target in
                            Button(target.displayName) { resumeError = library.resume(meta, target: target) }
                        }
                    } label: {
                        Group {
                            if compact { Image(systemName: "terminal") }
                            else { Label(CodingSessionResume.resumeLabel(meta.agent), systemImage: "terminal") }
                        }
                        .font(.system(size: Theme.F.caption, weight: .medium))
                        .accessibilityLabel(CodingSessionResume.resumeLabel(meta.agent))
                    } primaryAction: {
                        resumeError = library.resume(meta, target: preferred)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.branchIndicator)
                    .controlSize(.small)
                    .fixedSize()
                    .help("用\(preferred.displayName)继续；箭头里换别的")
                }
                Menu {
                    if compact {
                        Text(meta.agent.displayName)
                        if !meta.projectPath.isEmpty { Text(meta.projectPath) }
                        if let branch = meta.gitBranch { Text(branch) }
                        if !meta.host.isEmpty { Text("@" + meta.host) }
                        Divider()
                    }
                    Button("导出 Markdown…") { resumeError = library.exportMarkdown(meta) }
                    Button("在 Finder 中显示") { CodingSessionResume.revealInFinder(meta.filePath) }
                    // 远程会话只读：本地能挪走的只有缓存副本，下次同步就复活——删除项整个不出（Wake 同）
                    if meta.host.isEmpty {
                        Divider()
                        Button("删除…", role: .destructive) { pendingDelete = meta }
                    }
                    // 底注：这家 agent 的订阅额度（research-magpie §2.2；只 Claude Code / Codex，远程会话不看本机额度）
                    if meta.host.isEmpty, let quota = SubscriptionQuotaStore.shared.quota(for: meta.agent) {
                        Divider()
                        Text(SubscriptionQuotaParser.summaryLine(quota, now: Date()))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .task(id: meta.agent) {
                    guard meta.host.isEmpty, QuotaProvider(agent: meta.agent) != nil else { return }
                    await SubscriptionQuotaStore.shared.refresh()
                }
                .help("更多")
            }
    }

    /// 「回到终端」：这条会话正在本机终端面板的某个 tab 里跑着（阶段 B）。点了只切 tab + 拉起面板，不再起第二个 agent。
    /// 左边那颗点跟 tab 上的徽章同款：处理中实心 / 等你外加一圈环 / 空闲空心
    private func backToTerminalButton(_ session: LocalTerminalSession, agent: CodingAgent, compact: Bool = false) -> some View {
        Button {
            LocalTerminalStore.shared.focus(session.id)
        } label: {
            HStack(spacing: 5) {
                let color = CodingSessionFormat.color(session.agent ?? agent)
                ZStack {
                    Circle()
                        .fill(session.activity == .busy ? color : .clear)
                        .overlay(Circle().stroke(color, lineWidth: 1.2))
                        .frame(width: 7, height: 7)
                    if session.activity == .awaiting {
                        Circle().stroke(color, lineWidth: 1).frame(width: 11, height: 11)
                    }
                }
                .frame(width: 11, height: 11)
                if compact { Image(systemName: "terminal").accessibilityLabel("回到终端") }
                else { Text("回到终端").font(.system(size: Theme.F.caption, weight: .medium)) }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.branchIndicator)
        .controlSize(.small)
        .fixedSize()
        .help(session.activity == .awaiting ? "这条正在终端里等你回话" : "这条正在终端里跑着——点了切过去，不会再开一个")
    }

    private func iconToggle(_ icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(on ? Theme.branchIndicator : Theme.textMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 空态 / 失败态

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(Theme.textMuted)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(message: String, filePath: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundColor(Theme.textMuted)
            Text("这条会话打不开")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                if let filePath {
                    Button("在 Finder 中显示") { CodingSessionResume.revealInFinder(filePath) }
                }
                Button("重试") { library.reloadDetail() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 一条消息。外壳照聊天页的**文章模式**（角色名时间行 + 气泡 + 同一套圆角 / padding / 最大宽），
/// 正文整个交给聊天页那套渲染器 `MessageSegmentsView`——Markdown、thinking 折叠、工具卡都是聊天页那一份，
/// 字体字号行距段距跟她的外观设置走（她 09-15：「整个 code 界面都要做到跟聊天界面一样」）。
/// 编程会话独有的四块原样留着：上下文压缩分隔线 / 注入内容折叠 / 子代理 / 图片条。
struct CodingMessageRow: View {
    let message: CodingMessage
    /// 助手那边署名写这家 agent（她 09-15：「对，agent 名」）；nil = 退回「助手」
    var agent: CodingAgent? = nil
    /// 这一轮的第一条才出行头（同角色连着的后续消息不重复「谁 + 什么时候」）
    var showsHeader: Bool = true
    var onPreviewImage: (CodingImage) -> Void = { _ in }

    @State private var showMeta = false

    // 跟聊天页读同一批键：她在外观里调什么，这边就跟着变
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("fontScale") private var fontScale = 1.2
    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65
    @AppStorage("bubbleCornerRadius") private var bubbleCornerRadius: Double = 16
    @AppStorage("bubblePaddingH") private var bubblePaddingH: Double = 18
    @AppStorage("bubblePaddingV") private var bubblePaddingV: Double = 15
    @AppStorage("userName") private var userName = "你"
    @AppStorage("hideRoleName") private var hideRoleName = false
    @AppStorage("hideTimestamp") private var hideTimestamp = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        switch (message.role, message.kind) {
        case (_, .compactSummary):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.textMuted.opacity(0.3)).frame(height: 0.5)
                Text("上下文已压缩")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize()
                Rectangle().fill(Theme.textMuted.opacity(0.3)).frame(height: 0.5)
            }
        case (_, .meta):
            metaBlock
        default:
            chatRow
        }
    }

    // MARK: - 照聊天页的行（CardFlowView.articleModeBody）

    private var chatRow: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            roleLine
            bubble
            // 子代理对话（AnyView 断开 行 → 子代理 → 行 的递归不透明类型）
            ForEach(message.toolCalls.compactMap(\.sidechainRef), id: \.self) { id in
                AnyView(CodingSidechainView(sidechainId: id, agent: agent, onPreviewImage: onPreviewImage))
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// 角色名 + 时间（两个都关掉时整行不 render，跟聊天页同一条规则）
    @ViewBuilder
    private var roleLine: some View {
        if showsHeader, !hideRoleName || !hideTimestamp {
            HStack(spacing: 4) {
                if !hideRoleName {
                    Text(isUser ? userName : (agent?.displayName ?? "助手"))
                        .font(.caption2.weight(.medium))
                        .foregroundColor(Theme.textMuted)
                }
                if !hideTimestamp, let ts = message.timestamp {
                    Text(Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
                        .formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageSegmentsView(
                segments: CodingMessageSegments.segments(for: message),
                selectedFont: selectedFont,
                fontScale: fontScale,
                lineSpacingScale: lineSpacingScale,
                paragraphSpacingScale: paragraphSpacingScale,
                // 角色扮演的正则替换不套在 agent 转录上（代码里撞替换正则的概率不为零）
                regexScripts: [],
                isUser: isUser,
                // 编程会话不属于任何楼层：解 ref / 存成问题 / 读文件库那几条路全部不给走
                profileId: "",
                // 没有可锚的消息节点 → 不出划线子菜单（收生词照常）
                nodeId: nil,
                onQuoteText: nil,
                toolSummary: { name, json in CodingMessageSegments.toolSummary(name: name, inputJSON: json) }
            )
            imageStrip
            notes
        }
        .padding(.horizontal, isToolOnly ? 0 : bubblePaddingH)
        .padding(.vertical, isToolOnly ? 0 : bubblePaddingV)
        .background(
            RoundedRectangle(cornerRadius: bubbleCornerRadius)
                .fill(isToolOnly ? Color.clear : (isUser ? Theme.userBubble : Theme.assistantBubble))
        )
        .if(isUser) { view in
            view.frame(maxWidth: 500, alignment: .trailing)
        }
    }

    /// 这条消息只有工具调用（没正文、没 thinking、没图）。编程会话里「一条消息 = 一个工具调用」很常见，
    /// 每条都套一层气泡 = 气泡里就一张卡，连着四五条全是壳（她 09-16：「纯工具调用的消息不套气泡试试」）。
    /// 工具卡自己就有卡形，这种消息直接裸放
    private var isToolOnly: Bool {
        !message.toolCalls.isEmpty
            && message.text.isEmpty
            && (message.thinking?.isEmpty ?? true)
            && message.images.isEmpty
    }

    // MARK: - 编程会话独有

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            disclosure(title: message.role == .user ? "注入内容" : "系统消息", isOpen: $showMeta)
            if showMeta {
                Text(message.text)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
        }
    }

    /// 解出的图排在正文下面（顺序同源内容块）；解不了的留在正文里的 `[image]`
    @ViewBuilder
    private var imageStrip: some View {
        if !message.images.isEmpty {
            CodingImageStrip(images: message.images, onOpen: onPreviewImage)
        }
    }

    @ViewBuilder
    private var notes: some View {
        if message.truncated {
            Text("正文过长，已截断")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
        }
    }

    private func disclosure(title: String, isOpen: Binding<Bool>) -> some View {
        Button {
            isOpen.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                Text(title)
            }
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
